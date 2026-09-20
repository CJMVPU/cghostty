//! Terminal IO connects the macOS subprocess and PTY to the terminal state.
//!
//! - Termio owns the terminal stream handler and coordinates IO state.
//! - Exec launches the subprocess, owns its PTY and handles reads and writes.
//! - Mailbox carries input, resize and configuration messages to the IO thread.
//! - Thread runs Termio's event loop; Exec's gather and read threads drain PTY
//!   output without blocking terminal input or rendering.

const stream_handler = @import("termio/stream_handler.zig");

const message = @import("termio/message.zig");
pub const mailbox = @import("termio/mailbox.zig");
pub const Exec = @import("termio/Exec.zig");
pub const Options = @import("termio/Options.zig");
pub const Termio = @import("termio/Termio.zig");
pub const Thread = @import("termio/Thread.zig");
pub const DerivedConfig = Termio.DerivedConfig;
pub const Mailbox = mailbox.Mailbox;
pub const Message = message.Message;
pub const StreamHandler = stream_handler.StreamHandler;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("termio/shell_integration.zig");
}
