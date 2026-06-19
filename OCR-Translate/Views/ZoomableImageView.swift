import SwiftUI

struct ZoomableImageView: View {
    let image: NSImage

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var lastPanOffset: CGPoint = .zero
    @State private var dragAction: PanAction?
    @State private var viewFrameInWindow: CGRect = .zero
    @State private var scrollMonitorToken: Any?

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0
    private let zoomStep: CGFloat = 0.25

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { _ in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(x: panOffset.x, y: panOffset.y)
                    .onAppear { setupMonitor() }
                    .onDisappear { teardownMonitor() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .background(FrameReader { viewFrameInWindow = $0 })
            .clipToBounds()
            .gesture(
                SimultaneousGesture(magnifyGesture, dragGesture)
            )

            // Zoom toolbar
            HStack(spacing: 6) {
                Spacer()
                if scale != 1.0 {
                    Button("1:1") { applyZoom(1.0) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button(action: { applyZoom(scale - zoomStep) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless).controlSize(.regular)
                .disabled(scale <= minScale)
                Text("\(Int(scale * 100))%")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .center)
                Button(action: { applyZoom(scale + zoomStep) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless).controlSize(.regular)
                .disabled(scale >= maxScale)
            }
            .frame(height: 32).padding(.horizontal, 12)
            .background(.bar.opacity(0.5))
        }
    }

    // MARK: - Zoom

    private func applyZoom(_ newScale: CGFloat) {
        let clamped = min(max(newScale, minScale), maxScale)
        if clamped == 1.0 {
            panOffset = .zero; lastPanOffset = .zero
        }
        scale = clamped
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                applyZoom(lastScale * value.magnification)
            }
            .onEnded { _ in lastScale = scale }
    }

    // MARK: - Drag (pan only)

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragAction == nil {
                    dragAction = .pan
                    lastPanOffset = panOffset
                }
                let proposed = CGPoint(
                    x: lastPanOffset.x + value.translation.width,
                    y: lastPanOffset.y + value.translation.height
                )
                panOffset = proposed
                lastPanOffset = proposed
            }
            .onEnded { _ in dragAction = nil }
    }

    // MARK: - Scroll monitor

    private func setupMonitor() {
        scrollMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard NSApp.isActive,
                  event.window === NSApp.mainWindow else { return event }
            let loc = event.locationInWindow
            guard self.viewFrameInWindow.contains(loc) else { return event }

            if event.hasPreciseScrollingDeltas {
                DispatchQueue.main.async {
                    self.panOffset = CGPoint(
                        x: self.panOffset.x + event.scrollingDeltaX,
                        y: self.panOffset.y + event.scrollingDeltaY
                    )
                    self.lastPanOffset = self.panOffset
                }
            } else {
                DispatchQueue.main.async {
                    self.applyZoom(self.scale + event.scrollingDeltaY * 0.008)
                }
            }
            return event
        }
    }

    private func teardownMonitor() {
        if let token = scrollMonitorToken {
            NSEvent.removeMonitor(token)
            scrollMonitorToken = nil
        }
    }
}

// MARK: - Frame tracker (copied from CroppableImageView)

private struct FrameReader: NSViewRepresentable {
    var onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> Reader {
        Reader(onFrame: onFrame)
    }

    func updateNSView(_ v: Reader, context: Context) {
        v.onFrame = onFrame
        v.report()
    }

    final class Reader: NSView {
        fileprivate var onFrame: (CGRect) -> Void
        init(onFrame: @escaping (CGRect) -> Void) { self.onFrame = onFrame; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        func report() { guard window != nil else { return }; onFrame(convert(bounds, to: nil)) }
    }
}

private enum PanAction: Equatable {
    case none, pan
}
