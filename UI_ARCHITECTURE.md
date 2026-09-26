# Native UI architecture

## Delivery contract

The UI uses SwiftUI for content, Observation for shared presentation state, and
AppKit for window coordination and native terminal input. This is an internal
refactor, not a new application framework or a visual redesign. Existing window
styles, native tabs, quick terminal, configuration, shortcuts and terminal
protocol behavior remain product requirements.

## Ownership

- App state and configuration are read on the main actor. C handles remain owned
  by their existing resource objects; Observation must not extend their lifetime.
- A window owns its terminal presentation state and split tree. The split tree
  keeps stable native surface instances, including while moving between windows.
- Each surface owns one observable presentation state. SwiftUI recreation must
  never create or destroy its terminal session. The surface handle retains its
  owning app until core teardown completes, including deferred main-actor frees.
  The app must never be freed while one of its surface handles still exists.
- AppKit controllers execute window operations. Native surface views execute
  input, scrolling, accessibility and core calls. UI state has one source of truth.
- Loaded terminal windows have explicit native controller ownership until close.
  Their lifetime must not depend on SwiftUI retaining an observable controller.
  The app delegate separately owns the reusable quick-terminal controller.
- Short-lived view details use SwiftUI State. Immutable values and services do not
  become observable just to conform to a common spelling.
- Observation streams may coalesce presentation changes. Clipboard requests and
  other commands must use explicit event delivery with cancellation and identity
  checks. They are not inferred from a coalesced UI snapshot.
- Internal window, tab and split commands resolve the surface's current owner via
  `Ghostty.App.windowRegistry.owner(of:)` and invoke typed controller methods.
  The surface-owner index has weak keys and values, is scoped to the creating app
  and never scans AppKit windows. Views retain that index without retaining the app
  through it. Normal and quick-window enumeration filters AppKit's order by weak
  registered membership, including inactive tabs. UUID lookup uses the same index. Last-main selection and cascade
  state are app-local; closing unregisters immediately, even if undo retains the
  controller. Loaded-controller retention remains separate from lookup.
  Ownership follows split-tree changes even while a surface is detached from its
  AppKit window. These commands do not use global notification broadcasts or
  string-keyed payloads. Only AppKit system events use NotificationCenter. App configuration is published
  first, then delivered synchronously to that app's native controllers and delegate.
  Surface readonly, renderer health, key-sequence and key-table callbacks call
  typed view methods directly. Readonly stays synchronous; presentation updates
  retain their existing main-queue ordering to avoid callback reentrancy.
- Native UI, feature and helper files use `Ghostty.Surface` / `Ghostty.App` values
  and operations, without importing GhosttyKit. C calls, temporary strings,
  callback payload conversion and resource frees stay in the root Ghostty bridge
  files. Xcode directly links `zig-out/lib/libghostty-internal.a` and imports the
  module map in `include/`; there is no XCFramework packaging step. The bootstrap
  in `App/main.swift` is the only external C entry point.
  `scripts/check-bridge.py` enforces this boundary during scope checks.
- Fixed commands are typed; dynamic user-defined bindings remain strings. Input
  methods preserve the consumed result, and text reads return copied snapshots.
  Clipboard confirmations resolve a one-shot bridge request, with cancellation
  before view teardown releases its surface.
- Controller-owned asynchronous observation tasks use weak captures, cancel when
  changing targets, and end during teardown. Models never retain their controllers.

## Implementation

- `Ghostty.App` and `Ghostty.Config` expose application presentation state through
  Observation. SwiftUI receives the app through its typed environment.
  Config atomically replaces one generation containing a `ConfigHandle` and an
  immutable Sendable `ConfigSnapshot`. Native appearance projections accept the
  snapshot; retaining presentation values never retains the old C allocation.
  App-scoped configuration delivery follows App publication, while Surface callbacks keep
  their local scope. Dynamic shortcut queries still use the matching owned handle.
  The snapshot decoders read through generated `ConfigSchema.Key<Value>` entries.
  Zig field names and C storage types determine these entries; native code retains
  explicit presentation conversion, copied strings and unloaded fallbacks. Build
  and scope checks reject stale generated output or direct config-get calls outside
  the generated adapter.
- `TerminalWindowState` contains the split tree, command palette visibility and
  aggregate bell state. Structural edits go through `BaseTerminalController` so
  native ownership and pending clipboard requests stay consistent.
- `Ghostty.SurfaceState` contains terminal presentation values; `SurfaceView`
  remains the stable AppKit input/rendering endpoint. Its `SurfaceLifecycle` owns
  `Ghostty.Surface`, creation/final release and window-scoped event monitoring.
  Its computed properties route native callbacks into the same state, not a copy.
- AppKit detachment removes the event monitor and clears focus/visibility, but
  preserves the session for moves and undo. Reattachment refreshes display and
  visibility. Final view teardown cancels timers, search, clipboard and observers.
  A handle-owned callback context weakly references the view, so a pending
  operation can outlive the view without leaving dangling core userdata.
- `SurfaceRepresentable` dismantles its scroll wrapper explicitly. Old wrappers
  ignore layout/scroll callbacks and cannot detach a surface adopted by a new
  wrapper. Closing a split saves its prior focus for undo; restored tabs and
  splits receive input in the original shell, including its shell variables.
- `Ghostty.SearchState` owns the query, selection and result counts. The native
  surface attaches the search action and cancels it when closing or replacing
  search. Short queries retain their existing debounce behavior.
- `BaseTerminalController` applies literal-text editing rules to its window's
  field editor when AppKit begins editing. Search, command and title fields do
  not run automatic text checking or substitutions; terminal IME handling is separate.
- Titlebar, glass, secure-input and configuration-error models use Observation.
  About, configuration-error and clipboard windows host SwiftUI content in
  programmatic AppKit windows. Main-menu construction lives in `AppDelegate+MainMenu`;
  terminal controllers explicitly create their native window style and run a guarded
  lazy loading lifecycle. There are no XIB or IBOutlet connections. NSWindowController,
  first-responder menu dispatch, native tabs and configuration-driven shortcuts remain.
- Configurable menu actions register their binding alongside menu creation. A single
  list drives shortcut refresh; native responder dispatch and the system fullscreen
  equivalent stay intact. Menu state references exist only where later updates need them.
- Restoration archives contain `TerminalLayout<SurfaceSnapshot>` values rather than
  live views. The layout owns the existing version 1 wire format; runtime SplitTree
  and SurfaceView no longer conform to Codable. Normal window versions 5–7 and quick
  window version 1 remain supported. Controllers explicitly materialize sessions using
  their owning app and base configuration, including the quick-terminal environment.
  Saving or decoding a snapshot does not retain a native view or start a shell.
- Native titlebar tabs keep AppKit's tab bar and buttons. `NativeTitlebarTabLayout`
  owns only the constraints that position its accessory in the toolbar, reuses
  them during resize, and releases them before detachment or zero-size transitions.
  Frame events coalesce into a main-queue layout pass. Tab reordering uses
  `NSWindowTabGroup.insertWindow` without removing and rebuilding the tab group.
  The standalone split-zoom button is a toolbar item; native tabs keep their own
  button. Their content shares the same observable window state.
- Native consumers use cancellable `Observations` streams. There is no Combine or
  ObservableObject layer. Selection accessibility announcements use a cancellable
  debounce task; native title-field frame observers have explicit lifetimes.
  Window focus and the latest scrollbar value belong to SurfaceState. Search focus
  is an explicit command with overlay ownership, so a disappearing old overlay
  cannot unregister its replacement. Terminal leaves directly host SurfaceWrapper;
  there is no Inspector container or separate debug rendering/input lifecycle.
- `BaseTerminalController+Splits` centralizes split movement, resizing, zoom, removal,
  focus transfer and inverse undo registration. Empty-tree close/restore stays with
  the concrete window controller. The app owns its expiring undo manager; a cross-window
  move is one group. Deferred focus checks current ownership before acting.
- `IOSession`, `RenderSession` and `SearchSession` own the core workers. IO reserves
  stable storage before the renderer borrows its terminal; initialization and worker
  start are separate. Failed initialization unwinds only acquired resources, stop is
  idempotent, and Surface shuts down search, IO, render, then releases selection pins,
  terminal data and GPU/shared state. The renderer is a concrete Metal implementation
  with no backend factory, optional capability hooks or unused frame-export queue.
- SurfaceView+Input centralizes keyboard dispatch and NSTextInputClient while keeping
  input/IME ordering. SurfaceView owns native attachment. Accessibility/cached text
  and user notifications have dedicated native extensions; neither creates UI models
  or owns terminal sessions.

## Verification

Native tests cover read-dependent invalidation, stable terminal/core identity,
controller release, focused title changes, search cancellation and clipboard
completion/window content. Opt-in desktop tests exercise split/search/palette
flows and tab session state, plus titlebar geometry during fullscreen, tab moves,
cross-window dragging and merging. See `HACKING.md` for the test commands.
Lifecycle tests additionally cover attachment, stale-wrapper cleanup, late core
callbacks, owning-app configuration, and close/undo session and focus continuity.

Baseline logs and final acceptance evidence belong in VALIDATION.md. Building or
passing unit tests alone does not establish real input-method or UI acceptance.
Programmatic AppKit windows and menus preserve required system integration;
SwiftUI owns window content.

## IO failure presentation

`SurfaceState.fault` holds an immutable native `Ghostty.SurfaceFault`, including a
copied diagnostic code. The callback accepts it before window attachment, so
startup failures are visible as soon as the view is presented. `SurfaceFaultView`
shows the cause, error code and a close button within the affected pane. It does
not retain a core handle or retry a command automatically. Configuration reload
can prepare new terminals; it does not clear the failed session's explanation.
Ordinary child exit notices and synchronous surface-allocation failures remain
separate. If native presentation declines the fault, Surface owns the text
fallback and rendering wakeup; the IO worker owns neither native UI nor prose.

## Batch tab closing

`TerminalController+TabClose` selects an ordered target snapshot and shares one
confirmation, undo grouping, focus restoration and redo path for closing other
tabs or tabs to the right. A confirmation never includes tabs opened afterward;
targets that moved out of the group are ignored. Undo retains the existing split
trees and SurfaceViews, preserving shell sessions. Deferred focus restoration
requires the anchor controller to remain registered with its owning app.
