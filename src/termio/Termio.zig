//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const InitialInput = @import("InitialInput.zig");

const log = std.log.scoped(.io_exec);

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Exec,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// Reader and writer failures never wait for the native mailbox to drain.
fault: @import("FaultSignal.zig") = .{},

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.Io.Timestamp = null,

/// Configured sources are prepared before the subprocess starts, then
/// transferred to the writer loop until the final source has completed.
thread_enter_state: ?*InitialInput = null,

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_write_limit: usize,
    scroll_to_bottom_on_output: bool,
    enquiry_response: []const u8,
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .scroll_to_bottom_on_output = config.@"scroll-to-bottom".output,
            .clipboard_write_limit = config.@"clipboard-write-limit-bytes".value,
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .conditional_state = config._conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(global.io(), alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback_bytes = opts.full_config.@"scrollback-limit-bytes".optional(),
            .max_scrollback_lines = opts.full_config.@"scrollback-limit-lines".optional(),
            .default_modes = default_modes,
            .default_cursor_style = opts.config.cursor_style,
            .default_cursor_blink = opts.config.cursor_blink,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .default,
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = .allWithTempDir(global.tmpDirPath()),
        };
    });
    errdefer term.deinit(alloc);

    // The default palette may be an allocator-owned copy, so it is set
    // once the terminal owns its memory and can release it on deinit.
    try term.colors.palette.changeDefault(alloc, opts.config.palette);

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    backend.initTerminal(&term);

    // Create our stream handler. This points to memory in self so it
    // isn't safe to use until self.* is set.
    const handler: StreamHandler = .{
        .alloc = alloc,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .scroll_to_bottom_on_output = opts.config.scroll_to_bottom_on_output,
        .clipboard_write_limit = opts.config.clipboard_write_limit,
        .enquiry_response = opts.config.enquiry_response,
    };

    const thread_enter_state = try InitialInput.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = handler,
        }),
        .thread_enter_state = thread_enter_state,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.renderer_state.render_hold.deinit(self.alloc);
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Release untransferred input on a startup failure.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    if (self.thread_enter_state) |v| try v.prepare();

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer {
        self.backend.threadExit(data);
        data.deinit();
    }

    // Transfer input ownership to the event loop. A file keeps only one
    // chunk alive until the PTY has completed every partial write of it.
    if (self.thread_enter_state) |v| {
        data.backend.initial_input = v;
        self.thread_enter_state = null;
        v.io = self;
        v.td = data;
        try v.drive();
    }
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Queue an owned write from the IO thread, consuming data even on error.
pub inline fn queueWriteOwned(
    self: *Termio,
    td: *ThreadData,
    data: termio.Message.WriteReq.Alloc,
    linefeed: bool,
) !void {
    try self.backend.queueWriteOwned(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    self.terminal_stream.handler.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette. A config change must not fail here, so
    // if we can't allocate the copy of the configured palette we fall back
    // to the built-in default, which never allocates.
    self.terminal.colors.palette.changeDefault(
        self.alloc,
        config.palette,
    ) catch |err| {
        log.warn("error changing default palette, using built-in default err={}", .{err});
        self.terminal.colors.palette.resetDefault(self.alloc);
    };
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // Set the image limits
    self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    const previous = self.size;
    const grid_size = size.grid();

    // Update the size of our pty.
    try self.backend.resize(grid_size, size.terminal());
    errdefer self.backend.resize(previous.grid(), previous.terminal()) catch |err| {
        log.warn("failed to restore PTY size err={}", .{err});
        self.reportFault(err);
    };

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // Update the size of our terminal state
        self.terminal.resize(
            self.alloc,
            .{
                .cols = grid_size.columns,
                .rows = grid_size.rows,
                .cell_size_px = .{
                    .width = size.cell.width,
                    .height = size.cell.height,
                },
            },
        ) catch |err| {
            // Reflow may have completed a row resize before failing a column
            // allocation. Never keep parsing a partially changed primary grid.
            const pages = &self.terminal.screens.get(.primary).?.pages;
            if (pages.cols != self.terminal.cols or pages.rows != self.terminal.rows) {
                self.reportFault(error.ResizeStateInconsistent);
            }
            return err;
        };
        self.size = size;

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            self.sizeReportLocked(td, .mode_2048) catch |err| {
                // Grid/PTY commit succeeded. Optional report failure must not
                // suppress the renderer notification or retry the grid change.
                log.warn("failed to report committed terminal size err={}", .{err});
            };
        }
    }

    // Mail the renderer so that it can update the GPU and re-render
    _ = self.renderer_mailbox.push(global.io(), .{ .resize = size }, .{ .forever = {} });
    self.renderer_state.search_changes.notify();
    self.renderer_wakeup.notify() catch {};
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_state.search_changes.notify();
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    defer self.renderer_state.search_changes.notify();
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Clear all Kitty graphics state for this screen. This copies
            // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
            // didn't spend time researching whether it only deletes Kitty
            // graphics that are placed above the cursor or if it deletes
            // all of them. We delete all of them for now but if this behavior
            // isn't fully correct we should fix this later.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.io(),
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        // TODO: fix this
        // self.terminal.markSemanticPrompt(.command);
        // assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.scrollViewport(scroll);
    self.renderer_state.search_changes.notify();
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }

    self.renderer_state.search_changes.notify();
    try self.renderer_wakeup.notify();
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock(global.io());

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Publish a sticky failure without holding terminal or mailbox locks.
pub fn reportFault(self: *Termio, err: anyerror) void {
    if (self.fault.publish(err)) {
        self.mailbox.close();
        self.surface_mailbox.app.rt_app.wakeup();
    }
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    if (self.fault.failed()) return;
    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    if (self.fault.failed()) return;
    self.processOutputLocked(buf);
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    self.processOutputLockedWith(buf, &self.terminal_stream);
}

// Tests select VT actions that do not require a native application runtime;
// batch completion and notifications still execute the production code here.
fn processOutputLockedWith(self: *Termio, buf: []const u8, stream: anytype) void {
    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = std.Io.Timestamp.now(global.io(), .awake);
    cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (last.durationTo(now).toMilliseconds() <= 500) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(global.io(), .{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    }

    stream.nextSlice(buf);
    self.renderer_state.output_revision +%= 1;
    // Parsing can temporarily release the terminal mutex to deliver messages.
    // Publish after the whole batch so a refresh during that gap cannot consume
    // the only notification before the remaining bytes have been applied.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}

/// Sends a DSR response for the current color scheme to the pty.
/// Record a Kitty clipboard protocol session grant so future requests
/// carrying the password skip the permission prompt.
pub fn kittyClipboardGrant(
    self: *Termio,
    pw: []const u8,
    dir: terminalpkg.kitty.clipboard.Grants.Direction,
) error{OutOfMemory}!void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.terminal_stream.handler.kittyClipboardGrant(pw, dir);
}

pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const scheme: terminalpkg.device_status.ColorScheme = switch (self.config.conditional_state.theme) {
        .light => .light,
        .dark => .dark,
    };

    var buf: [terminalpkg.device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeColorSchemeReport(&writer, scheme);
    try self.queueWrite(td, writer.buffered(), false);
}

/// Sends a visibility report to the pty. Unforced reports are only sent while
/// DEC mode 2033 is enabled.
pub fn visibilityReport(
    self: *Termio,
    td: *ThreadData,
    visible: bool,
    force: bool,
) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    if (!force and !self.renderer_state.terminal.modes.get(.report_visibility)) {
        return;
    }

    var buf: [terminalpkg.device_status.max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeVisibilityReport(
        &writer,
        if (visible) .potentially_visible else .not_visible,
    );
    try self.queueWrite(td, writer.buffered(), false);
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.Exec.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}

test "Termio output completion republishes after parser releases mutex" {
    const t = std.testing;
    var terminal = try terminalpkg.Terminal.init(t.io, t.allocator, .{ .cols = 32, .rows = 3 });
    defer terminal.deinit(t.allocator);
    var mutex: std.Io.Mutex = .init;
    var shared: renderer.State = .{ .mutex = &mutex, .terminal = &terminal, .output_revision = 40 };
    var render_wakeup = try xev.Async.init();
    defer render_wakeup.deinit();
    var search_wakeup = try xev.Async.init();
    defer search_wakeup.deinit();
    shared.search_changes.attach(&search_wakeup);
    defer shared.search_changes.detach();
    // Preserve the initial pending change until the observer snapshots the
    // partial batch. This models search consuming an already scheduled wake.
    try t.expect(shared.search_changes.pending());
    const render_queue = try renderer.Thread.Mailbox.create(t.allocator);
    defer render_queue.destroy(t.allocator);
    var io: Termio = undefined;
    io.renderer_state = &shared;
    io.renderer_mailbox = render_queue;
    io.last_cursor_reset = null;
    io.mailbox = try termio.Mailbox.initSPSC(t.allocator);
    defer io.mailbox.deinit(t.allocator);
    for (0..64) |_| io.mailbox.send(.{ .write_stable = "pending" }, null);
    io.terminal_stream.handler = undefined;
    io.terminal_stream.handler.alloc = t.allocator;
    io.terminal_stream.handler.terminal = &terminal;
    io.terminal_stream.handler.renderer_state = &shared;
    io.terminal_stream.handler.renderer_wakeup = render_wakeup;
    io.terminal_stream.handler.termio_mailbox = &io.mailbox;
    io.terminal_stream.handler.termio_messaged = false;
    const Parser = struct {
        io: *Termio,
        done: std.Io.Event = .unset,
        pub fn vt(self: *@This(), comptime action: StreamHandler.Stream.Action.Tag, value: StreamHandler.Stream.Action.Value(action)) void {
            switch (action) {
                .print, .print_slice, .device_status => self.io.terminal_stream.handler.vt(action, value),
                else => {},
            }
        }
        pub fn deinit(_: *@This()) void {}
        fn run(self: *@This()) void {
            self.io.renderer_state.mutex.lockUncancelable(global.io());
            defer self.io.renderer_state.mutex.unlock(global.io());
            var stream: terminalpkg.Stream(*@This()) = .init(.{ .allocator = std.testing.allocator, .handler = self });
            defer stream.deinit();
            self.io.processOutputLockedWith("prefix\x1b[5nTAIL", &stream);
            self.done.set(std.testing.io);
        }
    };
    var parser: Parser = .{ .io = &io };
    const thread = try std.Thread.spawn(.{}, Parser.run, .{&parser});
    const queue = io.mailbox.spsc.queue;
    defer {
        // Release blocked parsing independently of the behavior under test so
        // a failure reports Timeout instead of hanging the runner in join.
        queue.mutex.lockUncancelable(t.io);
        queue.closed = true;
        queue.cond_not_full.broadcast(t.io);
        queue.mutex.unlock(t.io);
        thread.join();
    }
    const wait_started = std.Io.Timestamp.now(t.io, .awake);
    var blocked = false;
    while (wait_started.untilNow(t.io, .awake).toMilliseconds() < 1000) {
        queue.mutex.lockUncancelable(t.io);
        blocked = queue.not_full_waiters == 1;
        queue.mutex.unlock(t.io);
        if (blocked) break;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(blocked);
    {
        // The real GUI handler must have released this mutex while waiting
        // for its DSR reply to enter the full IO queue.
        mutex.lockUncancelable(t.io);
        defer mutex.unlock(t.io);
        try t.expectEqual(40, shared.output_revision);
        const partial = try terminal.plainString(t.allocator);
        defer t.allocator.free(partial);
        try t.expectEqualStrings("prefix", partial);
        try t.expect(shared.search_changes.consume());
        try t.expect(!shared.search_changes.pending());
    }
    try t.expectEqualStrings("pending", queue.pop(t.io).?.write_stable);
    try parser.done.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });
    {
        mutex.lockUncancelable(t.io);
        defer mutex.unlock(t.io);
        try t.expectEqual(41, shared.output_revision);
        const complete = try terminal.plainString(t.allocator);
        defer t.allocator.free(complete);
        try t.expectEqualStrings("prefixTAIL", complete);
        // A notification before nextSlice would already have been consumed
        // at the pause above, leaving this completed revision unannounced.
        try t.expect(shared.search_changes.consume());
        try t.expect(!shared.search_changes.consume());
        try t.expect(!io.terminal_stream.handler.termio_messaged);
    }
}

test "IO resize restores real PTY geometry after core allocation failure" {
    const t = std.testing;
    const Pty = @import("../pty.zig").Pty;
    var io: Termio = undefined;
    const previous: renderer.Size = .{
        .screen = .{ .width = 100, .height = 40 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    const requested: renderer.Size = .{
        .screen = .{ .width = 10000, .height = 60 },
        .cell = previous.cell,
        .padding = .{},
    };
    io.size = previous;
    io.fault = .{};
    io.terminal = try terminalpkg.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 2 });
    defer io.terminal.deinit(t.allocator);
    try io.terminal.printString("keep");
    io.backend.subprocess.pty = try Pty.open(.{ .ws_col = 10, .ws_row = 2, .ws_xpixel = 100, .ws_ypixel = 40 });
    defer io.backend.subprocess.pty.?.deinit();
    io.backend.subprocess.grid_size = previous.grid();
    io.backend.subprocess.screen_size = previous.terminal();
    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &io.terminal };
    io.renderer_state = &state;
    io.renderer_mailbox = try renderer.Thread.Mailbox.create(t.allocator);
    defer io.renderer_mailbox.destroy(t.allocator);
    io.renderer_wakeup = try xev.Async.init();
    defer io.renderer_wakeup.deinit();
    var data: ThreadData = undefined;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    io.alloc = failing.allocator();
    try t.expectError(error.OutOfMemory, io.resize(&data, requested));
    try t.expectEqualDeep(previous, io.size);
    const restored = try io.backend.subprocess.pty.?.getSize();
    try t.expectEqual(@as(u16, 10), restored.ws_col);
    try t.expectEqual(@as(u16, 2), restored.ws_row);
    try t.expectEqualDeep(previous.grid(), io.backend.subprocess.grid_size);
    try t.expect(io.renderer_mailbox.pop(t.io) == null);
    try t.expect(!io.fault.failed());
    const text = try io.terminal.plainString(t.allocator);
    defer t.allocator.free(text);
    try t.expectEqualStrings("keep", text);

    // A later retry must commit and notify the renderer exactly once.
    io.alloc = t.allocator;
    try io.resize(&data, requested);
    try t.expectEqualDeep(requested, io.size);
    try t.expectEqual(@as(u16, 1000), (try io.backend.subprocess.pty.?.getSize()).ws_col);
    try t.expectEqual(@as(u16, 1000), io.terminal.cols);
    try t.expectEqualDeep(requested, io.renderer_mailbox.pop(t.io).?.resize);
    try t.expect(io.renderer_mailbox.pop(t.io) == null);

    // A failed ioctl must not publish subprocess/IO geometry.
    const master = io.backend.subprocess.pty.?.master;
    io.backend.subprocess.pty.?.master = -1;
    defer io.backend.subprocess.pty.?.master = master;
    try t.expectError(error.IoctlFailed, io.resize(&data, previous));
    try t.expectEqualDeep(requested, io.size);
    try t.expectEqualDeep(requested.grid(), io.backend.subprocess.grid_size);
    try t.expect(io.renderer_mailbox.pop(t.io) == null);
}
