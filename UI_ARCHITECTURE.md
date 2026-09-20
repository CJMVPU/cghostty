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
  never create or destroy its terminal session.
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
  `BaseTerminalController.controller(owning:)` and invoke typed controller methods.
  Ownership follows split-tree changes even while a surface is detached from its
  AppKit window. These commands do not use global notification broadcasts or
  string-keyed payloads. System notifications and shared configuration events keep
  their existing notification delivery.
- Controller-owned asynchronous observation tasks use weak captures, cancel when
  changing targets, and end during teardown. Models never retain their controllers.

## Implementation

- `Ghostty.App` and `Ghostty.Config` expose application presentation state through
  Observation. SwiftUI receives the app through its typed environment.
- `TerminalWindowState` contains the split tree, command palette visibility and
  aggregate bell state. Structural edits go through `BaseTerminalController` so
  native ownership and pending clipboard requests stay consistent.
- `Ghostty.SurfaceState` contains terminal presentation values; `SurfaceView`
  remains the stable AppKit input/rendering endpoint and owns `Ghostty.Surface`.
  Its computed properties route native callbacks into the same state, not a copy.
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

Baseline logs and final acceptance evidence belong in VALIDATION.md. Building or
passing unit tests alone does not establish real input-method or UI acceptance.
Retain native window resources only where they still define a required AppKit
window or main-menu integration; SwiftUI owns their content.
