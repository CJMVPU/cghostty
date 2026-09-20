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
  through it. Normal-window enumeration separately filters AppKit's order by weak
  registered membership, including inactive tabs. Last-main selection and cascade
  state are app-local; closing unregisters immediately, even if undo retains the
  controller. Loaded-controller retention remains separate from lookup.
  Ownership follows split-tree changes even while a surface is detached from its
  AppKit window. These commands do not use global notification broadcasts or
  string-keyed payloads. System notifications and shared configuration events keep
  their existing notification delivery.
- Native UI, feature and helper files use `Ghostty.Surface` / `Ghostty.App` values
  and operations, without importing GhosttyKit. C calls, temporary strings,
  callback payload conversion and resource frees stay in the root Ghostty bridge
  files. The bootstrap in `App/main.swift` is the only external C entry point.
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
  Global config notifications follow App publication, while Surface callbacks keep
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
- Titlebar, glass, secure-input and configuration-error models use Observation.
  About, configuration-error and clipboard windows host SwiftUI content in
  programmatic AppKit windows. Main-menu and terminal-window XIBs still supply
  native window/menu configuration.
- Native titlebar tabs keep AppKit's tab bar and buttons. `NativeTitlebarTabLayout`
  owns only the constraints that position its accessory in the toolbar, reuses
  them during resize, and releases them before detachment or zero-size transitions.
  Frame events coalesce into a main-queue layout pass. Tab reordering uses
  `NSWindowTabGroup.insertWindow` without removing and rebuilding the tab group.
  The standalone split-zoom button is a toolbar item; native tabs keep their own
  button. Their content shares the same observable window state.
- Native consumers use cancellable `Observations` streams. Combine remains for
  native event streams such as debounced accessibility notifications; there is
  no `ObservableObject` presentation layer or parallel state synchronization.

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
Retain native window resources only where they still define a required AppKit
window or main-menu integration; SwiftUI owns their content.

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
