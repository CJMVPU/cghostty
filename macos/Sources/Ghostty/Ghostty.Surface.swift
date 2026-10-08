import Cocoa
import GhosttyKit
import Metal
import Synchronization
import ImageIO
import UniformTypeIdentifiers

extension Ghostty {
    /// Owns one core terminal handle and exposes native terminal operations.
    /// The AppKit SurfaceView's lifecycle owns this resource; its SurfaceState
    /// contains presentation values and does not extend the handle's lifetime.
    final class Surface: Sendable {
        /// A surface is sendable because it is just a reference type. Using the surface in parameters
        /// may be unsafe but the value itself is safe to send across threads.
        nonisolated(unsafe) private let surface: ghostty_surface_t

        /// The core app must outlive every surface, including handles retained
        /// briefly by queued work after a window or controller has closed.
        private let app: Ghostty.App
        let callbackContext: SurfaceCallbackContext
        nonisolated let compositorLatency: Float
        // The trace writer is created once for the lifetime of the core renderer.
        nonisolated let compositorTracing: Bool
        private let requestedCompositor = Mutex<WindowCompositorSignal?>(nil)
        private let compositorGate = NSLock()
        nonisolated(unsafe) private var activeCompositor: WindowCompositorSignal?

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t, app: Ghostty.App, callbackContext: SurfaceCallbackContext) {
            self.surface = cSurface
            let info = ghostty_surface_compositor_info(cSurface)
            compositorLatency = info.latency
            compositorTracing = info.trace_enabled
            self.app = app
            self.callbackContext = callbackContext
            callbackContext.surface = self
        }

        deinit {
            guard !Thread.isMainThread else {
                // The surface remains registered with the app and holds unretained
                // userdata until it is freed. When already on the main thread, free
                // it synchronously so teardown completes before we disappear.
                withExtendedLifetime((app, callbackContext)) { ghostty_surface_free(surface) }
                return
            }
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there so we capture the surface
            // value so we don't capture `self` and then we detach it in a task.
            // We can't wait for the task to succeed so this will happen sometime
            // but that's okay.
            let surface = self.surface
            let app = self.app
            let callbackContext = self.callbackContext
            Task.detached { @MainActor in
                withExtendedLifetime((app, callbackContext)) { ghostty_surface_free(surface) }
            }
        }

        /// Main only publishes ownership; GPU waits are confined to workers.
        nonisolated func requestCompositor(_ sink: WindowCompositorSignal) {
            requestedCompositor.withLock { $0 = sink }
        }

        nonisolated func removeCompositor(_ sink: WindowCompositorSignal) {
            requestedCompositor.withLock { if $0 === sink { $0 = nil } }
        }

        nonisolated func ownsCompositor(_ sink: WindowCompositorSignal) -> Bool {
            requestedCompositor.withLock { $0 === sink }
        }

        /// Only compositor workers enter this gate. A moving pane skips a tick
        /// while its previous worker finishes, rather than blocking another window.
        nonisolated func withCompositor<T>(_ sink: WindowCompositorSignal, _ body: () throws -> T) rethrows -> T? {
            guard compositorGate.try() else { return nil }
            defer { compositorGate.unlock() }
            guard ownsCompositor(sink) else { return nil }
            if activeCompositor !== sink {
                ghostty_surface_set_compositor(surface, Unmanaged.passUnretained(sink).toOpaque())
                activeCompositor = sink
            }
            return try body()
        }

        nonisolated func retireCompositor(_ sink: WindowCompositorSignal) {
            compositorGate.lock()
            defer { compositorGate.unlock() }
            // A newer window may already have installed its sink.
            guard activeCompositor === sink, !ownsCompositor(sink) else { return }
            ghostty_surface_set_compositor(surface, nil)
            activeCompositor = nil
        }

        nonisolated var compositorInfo: ghostty_compositor_info_s { ghostty_surface_compositor_info(surface) }

        nonisolated func renderCompositor(texture: AnyObject, queue: AnyObject, targetTime: Double, rect: CGRect, clip: CGRect, sequence: UInt64, snapshot: Bool = false) -> CompositorResult {
            let region = ghostty_compositor_region_s(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                clip_x: UInt(clip.minX), clip_y: UInt(clip.minY), clip_width: UInt(clip.width), clip_height: UInt(clip.height))
            return CompositorResult(rawValue: ghostty_surface_render_compositor(surface, Unmanaged.passUnretained(texture).toOpaque(),
                                             Unmanaged.passUnretained(queue).toOpaque(), targetTime, region, sequence, snapshot))
        }

        nonisolated func traceCompositor(stage: UInt32, sequence: UInt64, time: Double, prediction: Double = 0) {
            ghostty_surface_compositor_trace(surface, stage, sequence, time, prediction)
        }

        /// Stop native delivery before the view disappears, while outstanding
        /// operations may still retain the core handle and callback context.
        @MainActor func detachView() {
            callbackContext.view = nil
            setFocus(false)
            setVisible(false)
        }

        @MainActor func updateConfig(_ config: Ghostty.Config) {
            guard let value = config.config else { return }
            ghostty_surface_update_config(surface, value)
        }

        enum Command {
            case newTab
            case newWindow
            case toggleSplitZoom
            case toggleFullscreen
            case copy
            case paste
            case pasteSelection
            case selectAll
            case startSearch
            case searchSelection
            case scrollToSelection
            case toggleReadonly
            case reset
            case resetFontSize

            fileprivate var cValue: ghostty_surface_command_e {
                switch self {
                case .newTab: GHOSTTY_COMMAND_NEW_TAB
                case .newWindow: GHOSTTY_COMMAND_NEW_WINDOW
                case .toggleSplitZoom: GHOSTTY_COMMAND_TOGGLE_SPLIT_ZOOM
                case .toggleFullscreen: GHOSTTY_COMMAND_TOGGLE_FULLSCREEN
                case .copy: GHOSTTY_COMMAND_COPY_TO_CLIPBOARD
                case .paste: GHOSTTY_COMMAND_PASTE_FROM_CLIPBOARD
                case .pasteSelection: GHOSTTY_COMMAND_PASTE_FROM_SELECTION
                case .selectAll: GHOSTTY_COMMAND_SELECT_ALL
                case .startSearch: GHOSTTY_COMMAND_START_SEARCH
                case .searchSelection: GHOSTTY_COMMAND_SEARCH_SELECTION
                case .scrollToSelection: GHOSTTY_COMMAND_SCROLL_TO_SELECTION
                case .toggleReadonly: GHOSTTY_COMMAND_TOGGLE_READONLY
                case .reset: GHOSTTY_COMMAND_RESET
                case .resetFontSize: GHOSTTY_COMMAND_RESET_FONT_SIZE
                }
            }
        }

        @MainActor @discardableResult
        func perform(_ command: Command) -> Bool {
            ghostty_surface_command(surface, command.cValue)
        }

        @MainActor @discardableResult
        func changeFontSize(by delta: Float) -> Bool {
            ghostty_surface_change_font_size(surface, delta)
        }

        @MainActor @discardableResult
        func scroll(toRow row: Int) -> Bool {
            guard row >= 0 else { return false }
            return ghostty_surface_scroll_to_row(surface, UInt(row))
        }

        enum SplitDirection { case left, right, up, down }

        @MainActor func split(_ direction: SplitDirection) {
            let value: ghostty_action_split_direction_e = switch direction {
            case .left: GHOSTTY_SPLIT_DIRECTION_LEFT
            case .right: GHOSTTY_SPLIT_DIRECTION_RIGHT
            case .up: GHOSTTY_SPLIT_DIRECTION_UP
            case .down: GHOSTTY_SPLIT_DIRECTION_DOWN
            }
            ghostty_surface_split(surface, value)
        }

        @MainActor func moveSplitFocus(_ direction: SplitFocusDirection) {
            ghostty_surface_split_focus(surface, direction.toNative())
        }

        @MainActor func resizeSplit(_ direction: SplitResizeDirection, amount: UInt16) {
            ghostty_surface_split_resize(surface, direction.toNative(), amount)
        }

        @MainActor func equalizeSplits() { ghostty_surface_split_equalize(surface) }
        @MainActor func requestClose() { ghostty_surface_request_close(surface) }
        @MainActor func setFocus(_ focused: Bool) { ghostty_surface_set_focus(surface, focused) }
        @MainActor func setVisible(_ visible: Bool) { ghostty_surface_set_occlusion(surface, visible) }
        @MainActor func setSize(width: UInt32, height: UInt32) { ghostty_surface_set_size(surface, width, height) }
        struct Size: Equatable, Sendable {
            let columns: UInt16
            let rows: UInt16
            let pixels: CGSize
            let cellPixels: CGSize
        }
        @MainActor var size: Size {
            let value = ghostty_surface_size(surface)
            return Size(columns: value.columns, rows: value.rows,
                        pixels: CGSize(width: Int(value.width_px), height: Int(value.height_px)),
                        cellPixels: CGSize(width: Int(value.cell_width_px), height: Int(value.cell_height_px)))
        }
        @MainActor func setContentScale(x: Double, y: Double) { ghostty_surface_set_content_scale(surface, x, y) }
        @MainActor func setColorScheme(dark: Bool) {
            ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }
        @MainActor func sendPressure(stage: UInt32, pressure: Double) {
            ghostty_surface_mouse_pressure(surface, stage, pressure)
        }
        @MainActor func setPreedit(_ text: String?) {
            guard let text else {
                ghostty_surface_preedit(surface, nil, 0)
                return
            }
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        }
        @MainActor var hasSelection: Bool { ghostty_surface_has_selection(surface) }
        @MainActor var imePoint: NSRect {
            var x = 0.0, y = 0.0, width = 0.0, height = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            return NSRect(x: x, y: y, width: width, height: height)
        }

        @MainActor func compositionPoint(atUTF16Offset offset: Int?) -> NSRect {
            guard let offset, offset >= 0 else { return imePoint }
            var x = 0.0, y = 0.0, width = 0.0, height = 0.0
            ghostty_surface_ime_point_for_utf16(surface, UInt(offset), &x, &y, &width, &height)
            return NSRect(x: x, y: y, width: width, height: height)
        }

        /// A copied value; the core allocation never crosses the bridge.
        struct TextSnapshot {
            let text: String
            let viewportCellRange: NSRange
            let topLeft: NSPoint
        }

        @MainActor private func readText(
            _ read: (UnsafeMutablePointer<ghostty_text_s>) -> Bool
        ) -> TextSnapshot? {
            var value = ghostty_text_s()
            guard read(&value) else { return nil }
            defer { ghostty_surface_free_text(surface, &value) }
            let bytes = UnsafeRawBufferPointer(start: value.text, count: Int(value.text_len))
            return TextSnapshot(
                text: String(bytes: bytes, encoding: .utf8) ?? "",
                viewportCellRange: NSRange(location: Int(value.offset_start), length: Int(value.offset_len)),
                topLeft: NSPoint(x: value.tl_px_x, y: value.tl_px_y))
        }

        struct AccessibilitySnapshot {
            let text: String
            let cocoaText: NSString
            let visibleRange: NSRange
            let selectedRanges: [NSRange]
            let revision: UInt64
            let textRevision: UInt64
        }

        @MainActor private var accessibilitySnapshot: AccessibilitySnapshot?
        #if CGHOSTTY_TESTING
        @MainActor private(set) var accessibilityCaptureCount = 0
        #endif

        @MainActor func readAccessibility() -> AccessibilitySnapshot? {
            var value = ghostty_accessibility_s()
            let result = ghostty_surface_read_accessibility(surface, accessibilitySnapshot?.revision ?? 0, &value)
            if result == 0 { return accessibilitySnapshot }
            guard result == 1 else { return nil }
            defer { ghostty_surface_free_accessibility(&value) }
            let text: String
            let cocoaText: NSString
            if let pointer = value.text {
                let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(value.text_len))
                guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
                text = decoded
                cocoaText = decoded as NSString
                #if CGHOSTTY_TESTING
                accessibilityCaptureCount += 1
                #endif
            } else {
                guard let previous = accessibilitySnapshot, previous.textRevision == value.text_revision else { return nil }
                text = previous.text
                cocoaText = previous.cocoaText
            }
            let snapshot = AccessibilitySnapshot(
                text: text,
                cocoaText: cocoaText,
                visibleRange: NSRange(location: Int(value.visible.location), length: Int(value.visible.length)),
                selectedRanges: UnsafeBufferPointer(start: value.selected, count: Int(value.selected_len)).map {
                    NSRange(location: Int($0.location), length: Int($0.length))
                },
                revision: value.revision,
                textRevision: value.text_revision)
            accessibilitySnapshot = snapshot
            return snapshot
        }

        /// The normal input caret has no terminal selection. Avoid serializing
        /// history just to report NSNotFound while output continues to change.
        @MainActor var inputSelectedRange: NSRange {
            guard hasSelection else { return NSRange(location: NSNotFound, length: 0) }
            return inputText?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
        }

        /// Input uses document-relative UTF-16 ranges from the same snapshot.
        @MainActor var inputText: InputText? {
            guard let snapshot = readAccessibility() else { return nil }
            return InputText(document: snapshot.cocoaText, selectedRanges: snapshot.selectedRanges)
        }

        @MainActor var renderRevision: UInt64 { ghostty_surface_render_revision(surface) }

        /// Selected resources owned by the renderer, not total process memory.
        /// Multiple surfaces can share gridID and the CPU buffers it identifies.
        nonisolated struct RendererResources: Sendable, Codable {
            let gridID: UInt64
            let cpuGrayscaleBytes: UInt64
            let cpuColorBytes: UInt64
            let cpuNodeBytes: UInt64
            let codepointEntries: UInt64
            let codepointCapacity: UInt64
            let glyphEntries: UInt64
            let glyphCapacity: UInt64
            let gpuTexelBytes: UInt64
            let gpuAllocatedBytes: UInt64
            let gpuTextureCount: UInt64
            let gpuQueueCount: UInt64
            let cpuImagePendingBytes: UInt64
            let cpuBackgroundPendingBytes: UInt64
            let gpuImageTexelBytes: UInt64
            let gpuImageAllocatedBytes: UInt64
            let gpuImageTextureCount: UInt64
            let gpuBackgroundAllocatedBytes: UInt64
            let gpuScrollAllocatedBytes: UInt64
            let gpuScrollTextureCount: UInt64
        }

        /// Retain this surface and call from a background task; the core
        /// serializes with drawing and font-grid replacement without allocating.
        nonisolated func rendererResources() -> RendererResources {
            let value = ghostty_surface_renderer_resources(surface)
            return RendererResources(gridID: value.grid_id,
                cpuGrayscaleBytes: value.cpu_grayscale_bytes, cpuColorBytes: value.cpu_color_bytes,
                cpuNodeBytes: value.cpu_node_bytes, codepointEntries: value.codepoint_entries,
                codepointCapacity: value.codepoint_capacity, glyphEntries: value.glyph_entries,
                glyphCapacity: value.glyph_capacity, gpuTexelBytes: value.gpu_texel_bytes,
                gpuAllocatedBytes: value.gpu_allocated_bytes, gpuTextureCount: value.gpu_texture_count,
                gpuQueueCount: value.gpu_queue_count,
                cpuImagePendingBytes: value.cpu_image_pending_bytes,
                cpuBackgroundPendingBytes: value.cpu_background_pending_bytes,
                gpuImageTexelBytes: value.gpu_image_texel_bytes,
                gpuImageAllocatedBytes: value.gpu_image_allocated_bytes,
                gpuImageTextureCount: value.gpu_image_texture_count,
                gpuBackgroundAllocatedBytes: value.gpu_background_allocated_bytes,
                gpuScrollAllocatedBytes: value.gpu_scroll_allocated_bytes,
                gpuScrollTextureCount: value.gpu_scroll_texture_count)
        }

        /// Terminal image storage across primary and alternate screens. Capture
        /// bytes count references and may share pixels; do not add them to RSS.
        nonisolated struct ImageResources: Sendable, Codable {
            let screenCount: UInt64
            let storageReservedBytes: UInt64
            let storagePixelBytes: UInt64
            let pendingReservedBytes: UInt64
            let loadingBytes: UInt64
            let loadingCapacity: UInt64
            let completionPeakBytes: UInt64
            let capturePendingReferenceBytes: UInt64
            let captureCacheReferenceBytes: UInt64
        }

        /// Retain this surface and call off the main thread; the terminal mutex
        /// serializes this allocation-free scan with PTY parsing and capture.
        nonisolated func imageResources() -> ImageResources {
            let value = ghostty_surface_image_resources(surface)
            return ImageResources(screenCount: value.screen_count,
                storageReservedBytes: value.storage_reserved_bytes, storagePixelBytes: value.storage_pixel_bytes,
                pendingReservedBytes: value.pending_reserved_bytes, loadingBytes: value.loading_bytes,
                loadingCapacity: value.loading_capacity, completionPeakBytes: value.completion_peak_bytes,
                capturePendingReferenceBytes: value.capture_pending_reference_bytes,
                captureCacheReferenceBytes: value.capture_cache_reference_bytes)
        }

        /// Explicit readback from an independent Metal texture; no window drawable is retained.
        nonisolated func copySnapshot(maxDimension: Int = 0) -> CGImage? {
            guard let limit = UInt32(exactly: maxDimension),
                  let value = ghostty_surface_copy_snapshot(surface, limit),
                  let texture = Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue() as? any MTLTexture,
                  let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
            let rowBytes = texture.width * 4
            var pixels = Data(count: rowBytes * texture.height)
            pixels.withUnsafeMutableBytes { buffer in
                texture.getBytes(buffer.baseAddress!, bytesPerRow: rowBytes,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
            return CGImage(width: texture.width, height: texture.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little), provider: provider, decode: nil,
                shouldInterpolate: true, intent: .relativeColorimetric)
        }

        /// GPU waits and PNG conversion run on the serial thumbnail executor.
        /// Core snapshot state is protected by draw_mutex and this owner retains it.
        nonisolated func snapshotPNG(maxDimension: Int = 256) -> Data? {
            autoreleasepool {
                guard let image = copySnapshot(maxDimension: maxDimension),
                      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.setRenderingIntent(.relativeColorimetric)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let converted = context.makeImage() else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, converted, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }
                return data as Data
            }
        }

        @MainActor var selection: TextSnapshot? {
            readText { ghostty_surface_read_selection(surface, $0) }
        }
        @MainActor var quickLookWord: TextSnapshot? {
            readText { ghostty_surface_quicklook_word(surface, $0) }
        }
        @MainActor func readContents(viewport: Bool) -> String {
            let tag = viewport ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                rectangle: false)
            return readText { ghostty_surface_read_text(surface, selection, $0) }?.text ?? ""
        }
        @MainActor var font: CTFont? {
            guard let value = ghostty_surface_quicklook_font(surface) else { return nil }
            return Unmanaged<CTFont>.fromOpaque(value).takeRetainedValue()
        }

        enum SearchDirection {
            case next
            case previous
        }

        /// The core copies query bytes before returning; no C pointer escapes.
        /// Empty text clears matches while the native search UI stays open.
        @MainActor @discardableResult
        func search(_ query: String) -> Bool {
            query.withCString { ghostty_surface_search(surface, $0, UInt(query.utf8.count)) }
        }

        /// Also notifies native UI to close even when no search is active.
        @MainActor @discardableResult
        func endSearch() -> Bool {
            ghostty_surface_end_search(surface)
        }

        @MainActor @discardableResult
        func navigateSearch(_ direction: SearchDirection) -> Bool {
            ghostty_surface_navigate_search(surface, direction == .next ? GHOSTTY_SEARCH_NEXT : GHOSTTY_SEARCH_PREVIOUS)
        }

        @MainActor
        var needsQuitConfirmation: Bool { ghostty_surface_needs_confirm_quit(surface) }

        @MainActor
        var processExited: Bool { ghostty_surface_process_exited(surface) }

        /// Send text to the terminal using paste semantics. This doesn't send key events, so keyboard
        /// shortcuts and other encodings do not take effect. Bracketed paste framing is applied when
        /// the terminal has enabled it.
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if len == 0 { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Returns the modifiers that participate in text translation for key
        /// events on this surface. This honors configuration such as
        /// `macos-option-as-alt`, which may exclude option from translation.
        ///
        /// - Parameter mods: The full set of modifiers for the key event.
        /// - Returns: The subset of `mods` to use for keyboard layout translation.
        @MainActor
        func keyTranslationMods(_ mods: Input.Mods) -> Input.Mods {
            Input.Mods(cMods: ghostty_surface_key_translation_mods(surface, mods.cMods))
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor @discardableResult
        func sendKeyEvent(_ event: Input.KeyEvent) -> Bool {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Check if a key event matches a keybinding.
        ///
        /// This checks whether the given key event would trigger a keybinding in the terminal.
        /// If it matches, returns the binding flags indicating properties of the matched binding.
        ///
        /// - Parameter event: The key event to check
        /// - Returns: The binding flags if a binding matches, or nil if no binding matches
        @MainActor
        private func keyIsBinding(_ event: ghostty_input_key_s) -> Input.BindingFlags? {
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, event, &flags) else { return nil }
            return Input.BindingFlags(cFlags: flags)
        }

        /// See `keyIsBinding(_ event: ghostty_input_key_s)`.
        @MainActor
        func keyIsBinding(_ event: Input.KeyEvent) -> Input.BindingFlags? {
            event.withCValue { keyIsBinding($0) }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// The PID of the foreground process group attached to the PTY.
        @MainActor
        var foregroundPID: Int? {
            let pid = ghostty_surface_foreground_pid(surface)
            guard pid != 0 else { return nil }
            return Int(exactly: pid)
        }

        /// The PTY device name for this surface.
        @MainActor
        var ttyName: String? {
            let ttyName = AllocatedString(ghostty_surface_tty_name(surface)).string
            return ttyName.isEmpty ? nil : ttyName
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor @discardableResult
        func sendMouseButton(_ event: Input.MouseButtonEvent) -> Bool {
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if len == 0 { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }
    }
}
