import AppKit
import SwiftUI

// MARK: - Panel factory

@MainActor private func makePanel(frame: NSRect) -> NSPanel {
    let panel = NSPanel(
        contentRect: frame,
        styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovableByWindowBackground = true
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    // Hide traffic lights
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    return panel
}

// Hosting view with size constraints removed so the window can resize freely
@MainActor private func hostingView<V: View>(_ view: V) -> NSHostingView<V> {
    let hv = NSHostingView(rootView: view)
    hv.sizingOptions = []   // don't lock window to SwiftUI ideal size
    return hv
}

// MARK: - Manual window drag
//
// macOS 27 regression: AppKit no longer initiates a background window drag
// (`isMovableByWindowBackground`) when the hit view is a SwiftUI `NSHostingView`
// (confirmed on 27.0 / 26A428; works fine on macOS 13–26). `panel.isMovableByWindowBackground`
// is kept for older systems, but the visible grip below drives the move manually by
// tracking mouse deltas and calling `setFrameOrigin` directly, which is unaffected by the regression.

@MainActor
private final class WindowDragTracker {
    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?

    func mouseDown(in view: NSView) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = view.window?.frame.origin
    }

    func mouseDragged(in view: NSView) {
        guard let startMouse = initialMouseLocation,
              let startOrigin = initialWindowOrigin,
              let window = view.window else { return }
        let current = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: startOrigin.x + (current.x - startMouse.x),
            y: startOrigin.y + (current.y - startMouse.y)
        ))
    }

    func mouseUp() {
        initialMouseLocation = nil
        initialWindowOrigin = nil
    }
}

@MainActor
private final class DragHandleNSView: NSView {
    private let tracker = WindowDragTracker()

    override func mouseDown(with event: NSEvent) { tracker.mouseDown(in: self) }
    override func mouseDragged(with event: NSEvent) { tracker.mouseDragged(in: self) }
    override func mouseUp(with event: NSEvent) { tracker.mouseUp() }
}

/// Visible grip bar: drag anywhere on it to move the panel.
struct WindowDragHandle: View {
    var body: some View {
        DragHandleRepresentable()
            .frame(height: 16)
            .overlay {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 36, height: 4)
                    .allowsHitTesting(false)
            }
    }
}

private struct DragHandleRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Panel factories used by AppDelegate

@MainActor func makeOriginalPanel(above referenceFrame: NSRect) -> NSPanel {
    let frame = NSRect(
        x: referenceFrame.minX,
        y: referenceFrame.maxY + 8,
        width: referenceFrame.width,
        height: 72
    )
    let panel = makePanel(frame: frame)
    panel.minSize = NSSize(width: 200, height: 44)
    panel.contentView = hostingView(OriginalTextView())
    return panel
}

@MainActor func makeTranslationPanel() -> NSPanel {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let sf = screen.visibleFrame
    let width: CGFloat = min(sf.width * 0.75, 920)
    let height: CGFloat = 120
    let x = sf.minX + (sf.width - width) / 2
    let y = sf.minY + 56
    let panel = makePanel(frame: NSRect(x: x, y: y, width: width, height: height))
    panel.minSize = NSSize(width: 200, height: 50)
    panel.contentView = hostingView(TranslationTextView())
    panel.orderFront(nil)
    return panel
}

// MARK: - SwiftUI: Original text

struct OriginalTextView: View {
    @StateObject private var engine = TranslationEngine.shared

    private var hasContent: Bool { !engine.subtitleLines.isEmpty || !engine.originalPartial.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle()
            originalScrollView
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.65))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
        }
        .padding(8)
    }

    private var originalScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !hasContent {
                        if engine.isRunning {
                            Text("Listening…")
                                .font(.system(size: engine.translationFontSize))
                                .foregroundStyle(.white.opacity(0.3))
                        } else {
                            Text("Original")
                                .font(.system(size: engine.translationFontSize))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    ForEach(engine.subtitleLines) { line in
                        Text(line.original)
                            .font(.system(size: engine.translationFontSize))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("or-\(line.id)")
                    }
                    if !engine.originalPartial.isEmpty {
                        Text(engine.originalPartial)
                            .font(.system(size: engine.translationFontSize))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("partial")
                    } else if engine.isRunning && engine.isASRSilent && !engine.subtitleLines.isEmpty {
                        Text("⟳ Listening")
                            .font(.system(size: engine.translationFontSize * 0.7))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("silent")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 44)
            .onChange(of: engine.originalPartial) { _, _ in
                guard !engine.allowUserScroll else { return }
                if !engine.originalPartial.isEmpty {
                    withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
                } else if let lastID = engine.subtitleLines.last?.id {
                    withAnimation { proxy.scrollTo("or-\(lastID)", anchor: .bottom) }
                }
            }
            .onChange(of: engine.subtitleLines.count) { _, _ in
                guard !engine.allowUserScroll, let lastID = engine.subtitleLines.last?.id else { return }
                withAnimation { proxy.scrollTo("or-\(lastID)", anchor: .bottom) }
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offsetY: geometry.contentOffset.y,
                              containerHeight: geometry.containerSize.height,
                              contentHeight: geometry.contentSize.height)
            } action: { _, metrics in
                engine.originalScrollMetrics = metrics
            }
            .scrollDisabled(!engine.allowUserScroll)
        }
    }
}

// MARK: - SwiftUI: Translation

struct TranslationTextView: View {
    @StateObject private var engine = TranslationEngine.shared

    private var isIdle: Bool { !engine.isRunning && engine.subtitleLines.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle()
            translationScrollView
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(isIdle ? 0.55 : 0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(isIdle ? 0.08 : 0), lineWidth: 1)
                }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.2), value: isIdle)
    }

    private var translationScrollView: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if isIdle {
                    Text("JaSub · Click the menu bar icon to start")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.35))
                } else if engine.subtitleLines.isEmpty {
                    Text("Translating…")
                        .font(.system(size: engine.translationFontSize, weight: .semibold))
                        .foregroundStyle(.yellow.opacity(0.6))
                } else {
                    ForEach(engine.subtitleLines) { line in
                        Text(line.translated ?? "…")
                            .font(.system(size: engine.translationFontSize, weight: .semibold))
                            .foregroundStyle(line.id == engine.subtitleLines.last?.id
                                             ? .yellow : .yellow.opacity(0.55))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("tl-\(line.id)")
                    }
                }
                Color.clear.frame(height: 1).id("tl-bottom")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 56)
        .onChange(of: engine.subtitleLines.count) { _, _ in
            guard !engine.allowUserScroll else { return }
            withAnimation { proxy.scrollTo("tl-bottom", anchor: .bottom) }
        }
        // The translated text for the last line arrives *after* it's appended
        // (subtitleLines[idx].translated = result, mutating in place) — that
        // doesn't change `.count`, so without this the view never re-scrolls
        // when the (often much longer) translation fills in, leaving it
        // clipped below the visible window until scrolled manually.
        .onChange(of: engine.subtitleLines.last?.translated) { _, _ in
            guard !engine.allowUserScroll else { return }
            withAnimation { proxy.scrollTo("tl-bottom", anchor: .bottom) }
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(offsetY: geometry.contentOffset.y,
                          containerHeight: geometry.containerSize.height,
                          contentHeight: geometry.contentSize.height)
        } action: { _, metrics in
            engine.translationScrollMetrics = metrics
        }
        } // ScrollViewReader
    }
}
