import SwiftUI

private enum Handle: Equatable {
    case cornerNW, cornerNE, cornerSW, cornerSE
    case edgeN, edgeS, edgeE, edgeW
}

private enum DragAction: Equatable {
    case create
    case move
    case resize(Handle)
    case pan
}

struct CroppableImageView: View {
    let image: NSImage
    var onConfirm: (_ croppedImage: NSImage) -> Void
    var onRequestNewImage: () -> Void = {}

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var imageFrame: CGRect = .zero
    @State private var imagePixelSize: CGSize = .zero
    @State private var measuredBaseFrame: CGRect = .zero
    @State private var isSelectionMode = false

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0
    private let zoomStep: CGFloat = 0.25

    @State private var panOffset: CGPoint = .zero
    @State private var lastPanOffset: CGPoint = .zero

    @State private var dragAction: DragAction?
    @State private var moveStartLocation: CGPoint = .zero
    @State private var moveOriginStart: CGPoint = .zero
    @State private var moveOriginEnd: CGPoint = .zero

    @State private var hoverHandle: Handle?
    @State private var mouseInView = false

    private let handleHitRadius: CGFloat = 8
    private let minimumSelectionSize: CGFloat = 10
    private let panBoundaryMargin: CGFloat = 80

    private var scaledImageFrame: CGRect {
        let w = imageFrame.width * scale
        let h = imageFrame.height * scale
        let centerX = imageFrame.midX + panOffset.x
        let centerY = imageFrame.midY + panOffset.y
        return CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
    }

    private var selectionRect: CGRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        let origin = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let size = CGSize(width: abs(end.x - start.x), height: abs(end.y - start.y))
        let rect = CGRect(origin: origin, size: size)
        return rect.size.width > minimumSelectionSize && rect.size.height > minimumSelectionSize ? rect : nil
    }

    private var hasSelection: Bool { selectionRect != nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(x: panOffset.x, y: panOffset.y)
                        .background(
                            GeometryReader { imgGeo in
                                Color.clear
                                    .onAppear {
                                        if measuredBaseFrame == .zero {
                                            measuredBaseFrame = imgGeo.frame(in: .named("zstackSpace"))
                                        }
                                    }
                            }
                        )
                        .onAppear {
                            imageFrame = computeImageFrame(in: geometry.size)
                            setupMonitor()
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            imageFrame = computeImageFrame(in: newSize)
                        }
                }

                if let sel = selectionRect {
                    cropOverlay(selection: sel)
                }
            }
            .coordinateSpace(name: "zstackSpace")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .overlay {
                CursorTracker(onMouseMoved: { loc, inView in
                    mouseInView = inView
                    mouseLocationView = inView ? loc : nil
                    if inView {
                        hoverHandle = detectHandle(at: loc)
                    }
                    pickCursor()
                })
                .allowsHitTesting(false)
            }
            .background(FrameReader { viewFrameInWindow = $0 })
            .clipToBounds()
            .gesture(
                SimultaneousGesture(magnifyGesture, dragGesture)
            )
            .onDisappear { teardownMonitor() }

            zoomToolbar
            selectionToolbar
        }
    }

    // MARK: - Cursor

    @State private var currentCursorTag: Int = 0
    @State private var mouseLocationView: CGPoint?

    // SF Symbol 对角光标 (方案 C)
    private let diagNWSE = CroppableImageView.cursorFromSymbol("arrow.up.left.and.arrow.down.right")
    private let diagNESW = CroppableImageView.cursorFromSymbol("arrow.up.right.and.arrow.down.left")

    private static func cursorFromSymbol(_ name: String) -> NSCursor {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return .crosshair
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            .applying(.init(paletteColors: [.black]))
        let sized = img.withSymbolConfiguration(cfg) ?? img
        return NSCursor(image: sized, hotSpot: NSPoint(x: 9, y: 9))
    }

    private func pickCursor() {
        let tag: Int
        let cursor: NSCursor

        if let h = hoverHandle, dragAction == nil {
            switch h {
            case .cornerNW, .cornerSE:
                tag = 1; cursor = diagNWSE
            case .cornerNE, .cornerSW:
                tag = 2; cursor = diagNESW
            case .edgeN, .edgeS:
                tag = 3; cursor = .resizeUpDown
            case .edgeE, .edgeW:
                tag = 4; cursor = .resizeLeftRight
            }
        } else if let sel = selectionRect, let loc = mouseLocationView, sel.contains(loc), dragAction == nil {
            tag = 5; cursor = .openHand
        } else if isSelectionMode {
            tag = 6; cursor = .crosshair
        } else {
            tag = 0; cursor = .arrow
        }

        if tag != currentCursorTag {
            if currentCursorTag != 0 { NSCursor.pop() }
            currentCursorTag = tag
            if tag != 0 { cursor.push() }
        }
    }

    private func detectHandle(at loc: CGPoint) -> Handle? {
        guard let sel = selectionRect else { return nil }
        let r = handleHitRadius

        let corners: [(CGPoint, Handle)] = [
            (CGPoint(x: sel.minX, y: sel.minY), .cornerNW),
            (CGPoint(x: sel.maxX, y: sel.minY), .cornerNE),
            (CGPoint(x: sel.minX, y: sel.maxY), .cornerSW),
            (CGPoint(x: sel.maxX, y: sel.maxY), .cornerSE),
        ]
        for (pt, h) in corners {
            if abs(loc.x - pt.x) <= r && abs(loc.y - pt.y) <= r { return h }
        }
        if abs(loc.x - sel.midX) <= r && abs(loc.y - sel.minY) <= r { return .edgeN }
        if abs(loc.x - sel.midX) <= r && abs(loc.y - sel.maxY) <= r { return .edgeS }
        if abs(loc.y - sel.midY) <= r && abs(loc.x - sel.minX) <= r { return .edgeW }
        if abs(loc.y - sel.midY) <= r && abs(loc.x - sel.maxX) <= r { return .edgeE }
        return nil
    }

    // MARK: - Scroll Monitor

    @State private var viewFrameInWindow: CGRect = .zero
    @State private var scrollMonitorToken: Any?

    private func setupMonitor() {
        scrollMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard NSApp.isActive,
                  event.window === NSApp.mainWindow else { return event }
            let loc = event.locationInWindow
            guard self.viewFrameInWindow.contains(loc) else { return event }

            if event.hasPreciseScrollingDeltas {
                DispatchQueue.main.async {
                    let proposed = CGPoint(
                        x: self.panOffset.x + event.scrollingDeltaX,
                        y: self.panOffset.y + event.scrollingDeltaY
                    )
                    self.panOffset = self.clampPan(proposed)
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

    private func clampPan(_ offset: CGPoint) -> CGPoint {
        let frame = scaledImageFrame
        guard frame.width > 0, frame.height > 0 else { return offset }
        guard let viewSize = NSApp.keyWindow?.contentView?.bounds.size else { return offset }
        return CGPoint(
            x: max(-(frame.maxX - panBoundaryMargin),
                   min(offset.x, viewSize.width - panBoundaryMargin)),
            y: max(-(frame.maxY - panBoundaryMargin),
                   min(offset.y, viewSize.height - panBoundaryMargin))
        )
    }

    // MARK: - Magnify

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                applyZoom(lastScale * value.magnification)
            }
            .onEnded { _ in lastScale = scale }
    }

    private func applyZoom(_ newScale: CGFloat) {
        let clamped = min(max(newScale, minScale), maxScale)
        if clamped == 1.0 {
            panOffset = .zero
            lastPanOffset = .zero
        }
        scale = clamped
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let loc = value.location

                if dragAction == nil {
                    if isSelectionMode {
                        let handle = detectHandle(at: loc)
                        if let h = handle {
                            dragAction = .resize(h)
                            moveStartLocation = loc
                            moveOriginStart = dragStart ?? .zero
                            moveOriginEnd = dragEnd ?? .zero
                            return
                        }
                        if let sel = selectionRect, sel.contains(loc) {
                            dragAction = .move
                            moveStartLocation = loc
                            moveOriginStart = CGPoint(x: sel.minX, y: sel.minY)
                            moveOriginEnd = CGPoint(x: sel.maxX, y: sel.maxY)
                            return
                        }
                        dragAction = .create
                        dragStart = nil
                        dragEnd = nil
                    } else {
                        dragAction = .pan
                        lastPanOffset = panOffset
                    }
                }

                switch dragAction {
                case .create:
                    let c = clampToImage(loc)
                    if dragStart == nil { dragStart = c }
                    dragEnd = c

                case .move:
                    let dx = loc.x - moveStartLocation.x
                    let dy = loc.y - moveStartLocation.y
                    applyMove(dx: dx, dy: dy)

                case .resize(let h):
                    applyResize(handle: h, loc: loc)

                case .pan:
                    withTransaction(Transaction(animation: .none)) {
                        panOffset = clampPan(CGPoint(
                            x: lastPanOffset.x + value.translation.width,
                            y: lastPanOffset.y + value.translation.height
                        ))
                    }

                case .none:
                    break
                }
            }
            .onEnded { _ in
                if dragAction == .pan { lastPanOffset = panOffset }
                dragAction = nil
            }
    }

    private func clampToImage(_ pt: CGPoint) -> CGPoint {
        let f = scaledImageFrame
        return CGPoint(x: max(f.minX, min(pt.x, f.maxX)),
                       y: max(f.minY, min(pt.y, f.maxY)))
    }

    private func applyMove(dx: CGFloat, dy: CGFloat) {
        var s = CGPoint(x: moveOriginStart.x + dx, y: moveOriginStart.y + dy)
        var e = CGPoint(x: moveOriginEnd.x + dx,   y: moveOriginEnd.y + dy)
        let f = scaledImageFrame
        let w = e.x - s.x
        let h = e.y - s.y
        if s.x < f.minX { s.x = f.minX; e.x = s.x + w }
        if s.y < f.minY { s.y = f.minY; e.y = s.y + h }
        if e.x > f.maxX { e.x = f.maxX; s.x = e.x - w }
        if e.y > f.maxY { e.y = f.maxY; s.y = e.y - h }
        dragStart = s; dragEnd = e
    }

    private func applyResize(handle: Handle, loc: CGPoint) {
        guard var s = dragStart, var e = dragEnd else { return }
        let c = clampToImage(loc)
        switch handle {
        case .cornerNW: s = c
        case .cornerNE: s.y = c.y; e.x = c.x
        case .cornerSW: s.x = c.x; e.y = c.y
        case .cornerSE: e = c
        case .edgeN:    s.y = c.y
        case .edgeS:    e.y = c.y
        case .edgeW:    s.x = c.x
        case .edgeE:    e.x = c.x
        }
        guard abs(e.x - s.x) > minimumSelectionSize,
              abs(e.y - s.y) > minimumSelectionSize else { return }
        dragStart = s; dragEnd = e
    }

    // MARK: - Crop Overlay

    private func cropOverlay(selection: CGRect) -> some View {
        Canvas { context, _ in
            let full = CGRect(origin: .zero, size: context.clipBoundingRect.size)
            context.fill(Path(full), with: .color(.black.opacity(0.4)))
            context.blendMode = .destinationOut
            context.fill(Path(selection), with: .color(.white))
            context.blendMode = .normal

            let color: Color = dragAction != nil ? .orange : .blue
            context.stroke(Path(selection), with: .color(color), lineWidth: 2)

            let r: CGFloat = 4
            for corner in [selection.origin,
                           CGPoint(x: selection.maxX, y: selection.minY),
                           CGPoint(x: selection.minX, y: selection.maxY),
                           CGPoint(x: selection.maxX, y: selection.maxY)] {
                let h = CGRect(x: corner.x - r, y: corner.y - r, width: r * 2, height: r * 2)
                context.fill(Path(roundedRect: h, cornerRadius: 2), with: .color(.white))
                context.stroke(Path(roundedRect: h, cornerRadius: 2), with: .color(color), lineWidth: 1.5)
            }
            let mx = selection.midX, my = selection.midY
            for pt in [CGPoint(x: mx, y: selection.minY),
                       CGPoint(x: mx, y: selection.maxY),
                       CGPoint(x: selection.minX, y: my),
                       CGPoint(x: selection.maxX, y: my)] {
                let h = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: h), with: .color(.white.opacity(0.8)))
                context.stroke(Path(ellipseIn: h), with: .color(color), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Toolbars

    private var zoomToolbar: some View {
        HStack(spacing: 8) {
            Button(action: onRequestNewImage) {
                Label("上传图片", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            if scale != 1.0 {
                Button("1:1") { applyZoom(1.0) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("重置缩放")
            }

            Button(action: { applyZoom(scale - zoomStep) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .disabled(scale <= minScale)
            .help("缩小")

            Text("\(Int(scale * 100))%")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .center)

            Button(action: { applyZoom(scale + zoomStep) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .disabled(scale >= maxScale)
            .help("放大")
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
        .background(.bar.opacity(0.5))
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            toolbarHint
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()

            if hasSelection {
                Button {
                    dragStart = nil
                    dragEnd = nil
                } label: {
                    Label("清除选区", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.orange)
            }

            Button(action: confirmFullImage) {
                Label("全图识别", systemImage: "rectangle.dashed")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            dynamicActionButton
        }
        .frame(height: 40)
        .padding(.horizontal, 12)
        .background(.bar)
    }

    private var toolbarHint: some View {
        Group {
            if dragAction != nil { hint("调整中…", color: .orange) }
            else if hasSelection { hint("拖手柄调整 · 拖内部移动") }
            else if isSelectionMode { hint("拖拽框选", color: .blue) }
            else { hint("滑动平移 · 滚轮缩放") }
        }
    }

    private func hint(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.body).foregroundStyle(color).truncationMode(.tail)
    }

    private var dynamicActionButton: some View {
        Group {
            if hasSelection {
                Button(action: confirmSelection) {
                    Label("确认", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if isSelectionMode {
                Button(action: exitSelectionMode) {
                    Label("取消", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            } else {
                Button(action: enterSelectionMode) {
                    Label("选区识别", systemImage: "rectangle.dashed.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Helpers

    private func resolveCGImage() -> CGImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        guard let tiff = image.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let cg = bmp.cgImage else { return nil }
        return cg
    }

    private func computeImageFrame(in vs: CGSize) -> CGRect {
        guard let cg = resolveCGImage() else { return .zero }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        guard iw > 0, ih > 0, vs.width > 0, vs.height > 0 else { return .zero }
        imagePixelSize = CGSize(width: iw, height: ih)
        let ia = iw / ih, va = vs.width / vs.height
        let dw, dh: CGFloat
        if ia > va { dw = vs.width;  dh = vs.width / ia }
        else       { dh = vs.height; dw = vs.height * ia }
        return CGRect(x: (vs.width - dw) / 2, y: (vs.height - dh) / 2, width: dw, height: dh)
    }

    private func cropImage(with selection: CGRect) -> NSImage? {
        // Use measured base frame for accurate pixel mapping, fallback to computed
        let bf = measuredBaseFrame != .zero ? measuredBaseFrame : imageFrame
        let fw = bf.width * scale
        let fh = bf.height * scale
        let fx = bf.midX + panOffset.x - fw / 2
        let fy = bf.midY + panOffset.y - fh / 2

        guard fw > 0, fh > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0,
              let cg = resolveCGImage() else { return nil }
        let px = (selection.origin.x - fx) / fw * imagePixelSize.width
        let py = (selection.origin.y - fy) / fh * imagePixelSize.height
        let pw = selection.size.width / fw * imagePixelSize.width
        let ph = selection.size.height / fh * imagePixelSize.height
        let r = CGRect(x: max(0, round(px)), y: max(0, round(py)),
                        width: min(round(pw), imagePixelSize.width - round(px)),
                        height: min(round(ph), imagePixelSize.height - round(py)))
        guard r.width > 0, r.height > 0, let crop = cg.cropping(to: r) else { return nil }
        return NSImage(cgImage: crop, size: r.size)
    }

    private func enterSelectionMode() { isSelectionMode = true; dragStart = nil; dragEnd = nil }
    private func exitSelectionMode()  { isSelectionMode = false; dragStart = nil; dragEnd = nil; applyZoom(1.0) }
    private func confirmSelection() {
        guard let s = selectionRect, let c = cropImage(with: s) else { return }
        isSelectionMode = false; dragStart = nil; dragEnd = nil; applyZoom(1.0)
        onConfirm(c)
    }
    private func confirmFullImage() {
        isSelectionMode = false; dragStart = nil; dragEnd = nil; applyZoom(1.0)
        onConfirm(image)
    }
}

// MARK: - NSTrackingArea wrapper (cursor updates)

private struct CursorTracker: NSViewRepresentable {
    var onMouseMoved: (CGPoint, Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        TrackerView(onMouseMoved: onMouseMoved)
    }

    func updateNSView(_ v: TrackerView, context: Context) {
        v.onMouseMoved = onMouseMoved
    }

    final class TrackerView: NSView {
        fileprivate var onMouseMoved: (CGPoint, Bool) -> Void
        private var trackingArea: NSTrackingArea?

        init(onMouseMoved: @escaping (CGPoint, Bool) -> Void) {
            self.onMouseMoved = onMouseMoved
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let old = trackingArea { removeTrackingArea(old) }
            let opts: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited,
                                                 .cursorUpdate, .activeInKeyWindow]
            let ta = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
            addTrackingArea(ta)
            trackingArea = ta
        }

        override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let yFlipped = CGPoint(x: loc.x, y: bounds.height - loc.y)
            onMouseMoved(yFlipped, true)
        }

        override func mouseEntered(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            onMouseMoved(CGPoint(x: loc.x, y: bounds.height - loc.y), true)
        }

        override func mouseExited(with event: NSEvent) {
            onMouseMoved(.zero, false)
        }

        override func cursorUpdate(with event: NSEvent) {
            // Triggered by system; cursor pick is handled in SwiftUI callback
        }
    }
}

// MARK: - View frame in window coords (for hit-testing scroll)

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
        func report() {
            guard window != nil else { return }
            onFrame(convert(bounds, to: nil))
        }
    }
}

// MARK: - Clip

extension View {
    func clipToBounds() -> some View { clipped() }
}
