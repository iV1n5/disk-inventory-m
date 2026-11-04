import AppKit
import DiskCore
import Metal
import QuartzCore
import TreemapMetal

@MainActor
protocol TreemapViewDelegate: AnyObject {
    func treemapView(_ view: TreemapView, didHover node: NodeID?)
    func treemapView(_ view: TreemapView, didSelect node: NodeID?)
    func treemapView(_ view: TreemapView, didDoubleClick node: NodeID)
    func treemapViewMenu(_ view: TreemapView) -> NSMenu?
}

/// Shows a treemap, drawn by Metal, with selection and hover outlines on top.
final class TreemapView: NSView {
    enum Transition {
        case none
        case zoomIn
        case zoomOut
    }

    /// What to draw. Layouts are computed from this on `queue`, away from the main thread.
    private struct Content {
        let tree: FileTree
        let root: NodeID
        let options: DisplayOptions
    }

    /// A zoom in progress, drawn as `inner` growing out of the place it occupies in `outer`.
    private struct ZoomAnimation {
        let outer: TreemapRenderer.Scene
        let inner: TreemapRenderer.Scene
        let rect: PixelRect
        let zoomingIn: Bool
        let start: CFTimeInterval
        static let duration: CFTimeInterval = 0.28
    }

    weak var delegate: TreemapViewDelegate?
    var animatesZooming = true

    private let queue: DispatchQueue
    private let renderer = Graphics.renderer
    private let metalLayer = CAMetalLayer()
    private let selectionLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let emptyLabel = NSTextField.label(font: .systemFont(ofSize: 15), color: .secondaryLabelColor)

    private var content: Content?
    private var layoutInProgress = false
    private var layoutPending = false
    private var pendingTransition = Transition.none

    private(set) var treemapLayout: TreemapLayout?
    private var scene: TreemapRenderer.Scene?
    private var palette: MTLBuffer?
    private var colors: [SIMD4<Float>] = []
    private var zoomAnimation: ZoomAnimation?
    private var displayLink: CADisplayLink?

    private var hoveredNode: NodeID?
    private var trackingArea: NSTrackingArea?

    var selectedNode: NodeID? {
        didSet { updateSelectionOutline() }
    }

    /// When set, everything of any other kind is dimmed.
    var highlightedKind: KindID? {
        didSet {
            guard highlightedKind != oldValue else { return }
            updatePalette()
            draw()
        }
    }

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init(frame: .zero)

        // This view owns its layer tree, so that Core Animation composites the Metal output with
        // the outlines without AppKit getting involved.
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        // Match the view: pixels, tiles and outlines all count from the top left.
        host.isGeometryFlipped = true
        layer = host
        wantsLayer = true

        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = renderer?.pixelFormat ?? .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Until a new layout is ready, stretch the previous picture to fit.
        metalLayer.contentsGravity = .resize
        host.addSublayer(metalLayer)

        for outline in [hoverLayer, selectionLayer] {
            outline.fillColor = nil
            outline.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
            host.addSublayer(outline)
        }
        selectionLayer.strokeColor = NSColor.systemYellow.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.shadowColor = NSColor.black.cgColor
        selectionLayer.shadowOpacity = 0.8
        selectionLayer.shadowRadius = 1
        selectionLayer.shadowOffset = .zero
        hoverLayer.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        hoverLayer.lineWidth = 1

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.image)
        setAccessibilityLabel("Treemap")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    func show(tree: FileTree, root: NodeID, options: DisplayOptions, transition: Transition = .none) {
        content = Content(tree: tree, root: root, options: options)
        if transition != .none { pendingTransition = transition }
        requestLayout()
    }

    func setColors(_ colors: [SIMD4<Float>]) {
        self.colors = colors
        updatePalette()
        draw()
    }

    private func updatePalette() {
        guard let renderer else { return }
        guard let highlighted = highlightedKind, Int(highlighted) < colors.count else {
            palette = renderer.makePaletteBuffer(colors)
            return
        }
        // Grey out the rest, keeping just enough of its colour to stay recognisable.
        let dimmed = colors.enumerated().map { index, color -> SIMD4<Float> in
            if index == Int(highlighted) { return color }
            let grey = (color.x + color.y + color.z) / 3
            let faded = SIMD3(color.x, color.y, color.z) * 0.15 + SIMD3(repeating: grey) * 0.2
            return SIMD4(faded, 1)
        }
        palette = renderer.makePaletteBuffer(dimmed)
    }

    // MARK: Layout

    private var pixelScale: CGFloat {
        window?.backingScaleFactor ?? 2
    }

    private var pixelSize: (width: Int, height: Int) {
        (Int((bounds.width * pixelScale).rounded()), Int((bounds.height * pixelScale).rounded()))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [metalLayer, selectionLayer, hoverLayer] {
            sublayer.frame = bounds
            sublayer.contentsScale = pixelScale
        }
        CATransaction.commit()
        requestLayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Computes a layout in the background. While one is running, further requests merge into a
    /// single follow-up, so that a window resize never queues work faster than it gets done.
    private func requestLayout() {
        guard content != nil else { return }
        guard !layoutInProgress else {
            layoutPending = true
            return
        }
        let (width, height) = pixelSize
        guard let content, width > 0, height > 0 else { return }

        guard needsNewLayout(width: width, height: height) else { return }

        layoutInProgress = true
        needsFreshLayout = false
        let transition = pendingTransition
        pendingTransition = .none
        queue.async { [weak self] in
            let layout = TreemapLayout(
                tree: content.tree, root: content.root, options: content.options,
                width: width, height: height
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.layoutInProgress = false
                self.install(layout, transition: transition)
                if self.layoutPending {
                    self.layoutPending = false
                    self.requestLayout()
                }
            }
        }
    }

    /// Whether what is on screen differs from what is wanted.
    private func needsNewLayout(width: Int, height: Int) -> Bool {
        guard let current = treemapLayout, let content, pendingTransition == .none else { return true }
        let unchanged = current.width == width && current.height == height
            && current.root == content.root && current.options == content.options
            && current.tree === content.tree
        return !unchanged || needsFreshLayout
    }

    /// Set when the tree's contents changed, which a comparison of the settings can't reveal.
    private var needsFreshLayout = false

    func invalidateLayout() {
        needsFreshLayout = true
        requestLayout()
    }

    private func install(_ layout: TreemapLayout, transition: Transition) {
        guard let renderer else { return }
        let previousLayout = treemapLayout
        let previousScene = scene
        let newScene = renderer.makeScene(layout)
        treemapLayout = layout
        scene = newScene

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.drawableSize = CGSize(width: layout.width, height: layout.height)
        CATransaction.commit()

        emptyLabel.stringValue = "This folder is empty"
        emptyLabel.isHidden = !layout.tiles.isEmpty

        startAnimation(transition, from: previousLayout, scene: previousScene, to: layout, scene: newScene)
        draw()
        updateSelectionOutline()
        hoverLayer.path = nil
    }

    // MARK: Drawing

    private func draw() {
        guard let renderer, let palette else { return }
        guard
            let drawable = metalLayer.nextDrawable(),
            let commandBuffer = renderer.makeCommandBuffer()
        else { return }

        var layers: [(scene: TreemapRenderer.Scene, placement: TreemapRenderer.Placement)] = []
        if let zoomAnimation {
            layers = animationLayers(zoomAnimation, width: drawable.texture.width, height: drawable.texture.height)
        } else if let scene {
            layers = [(scene, TreemapRenderer.Placement())]
        }
        renderer.encode(
            layers, palette: palette, into: commandBuffer, target: drawable.texture,
            background: MTLClearColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Zoom animation

    private func startAnimation(
        _ transition: Transition,
        from oldLayout: TreemapLayout?,
        scene oldScene: TreemapRenderer.Scene?,
        to newLayout: TreemapLayout,
        scene newScene: TreemapRenderer.Scene
    ) {
        stopAnimation()
        guard
            animatesZooming, transition != .none, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let oldLayout, let oldScene
        else { return }

        // Find the folder of the smaller picture inside the larger one.
        let zoomingIn = transition == .zoomIn
        let outerLayout = zoomingIn ? oldLayout : newLayout
        let innerRoot = zoomingIn ? newLayout.root : oldLayout.root
        guard
            let found = outerLayout.rect(of: innerRoot), found.node == innerRoot,
            oldLayout.width == newLayout.width, oldLayout.height == newLayout.height
        else { return }

        zoomAnimation = ZoomAnimation(
            outer: zoomingIn ? oldScene : newScene,
            inner: zoomingIn ? newScene : oldScene,
            rect: found.rect,
            zoomingIn: zoomingIn,
            start: CACurrentMediaTime()
        )
        selectionLayer.isHidden = true
        let link = displayLink(target: self, selector: #selector(stepAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        zoomAnimation = nil
        selectionLayer.isHidden = false
    }

    @objc private func stepAnimation() {
        guard let animation = zoomAnimation else { return }
        if CACurrentMediaTime() - animation.start >= ZoomAnimation.duration {
            stopAnimation()
        }
        draw()
    }

    private func animationLayers(
        _ animation: ZoomAnimation,
        width: Int,
        height: Int
    ) -> [(scene: TreemapRenderer.Scene, placement: TreemapRenderer.Placement)] {
        let elapsed = (CACurrentMediaTime() - animation.start) / ZoomAnimation.duration
        let time = Float(min(max(elapsed, 0), 1))
        let eased = time * time * (3 - 2 * time)
        // 0 shows the outer picture, 1 the inner one.
        let progress = animation.zoomingIn ? eased : 1 - eased

        let full = SIMD2(Float(width), Float(height))
        let rectOrigin = SIMD2(Float(animation.rect.x0), Float(animation.rect.y0))
        let rectSize = SIMD2(Float(animation.rect.width), Float(animation.rect.height))

        // The part of the outer picture currently filling the view.
        let viewOrigin = rectOrigin * progress
        let viewSize = full + (rectSize - full) * progress

        var outer = TreemapRenderer.Placement()
        outer.scale = full / viewSize
        outer.offset = -viewOrigin * outer.scale

        var inner = TreemapRenderer.Placement()
        inner.scale = rectSize / full * outer.scale
        inner.offset = (rectOrigin - viewOrigin) * outer.scale
        inner.opacity = min(max((progress - 0.15) / 0.6, 0), 1)

        return [(animation.outer, outer), (animation.inner, inner)]
    }

    // MARK: Outlines

    private func path(for rect: PixelRect, inset: CGFloat) -> CGPath {
        let scale = pixelScale
        let frame = CGRect(
            x: CGFloat(rect.x0) / scale, y: CGFloat(rect.y0) / scale,
            width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale
        )
        return CGPath(rect: frame.insetBy(dx: inset, dy: inset), transform: nil)
    }

    private func updateSelectionOutline() {
        guard let selectedNode, let layout = treemapLayout, let found = layout.rect(of: selectedNode) else {
            selectionLayer.path = nil
            return
        }
        selectionLayer.path = path(for: found.rect, inset: 1)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func hit(_ event: NSEvent) -> (node: NodeID, rect: PixelRect)? {
        let point = convert(event.locationInWindow, from: nil)
        let scale = pixelScale
        return treemapLayout?.hit(x: Int(point.x * scale), y: Int(point.y * scale))
    }

    override func mouseMoved(with event: NSEvent) {
        let found = hit(event)
        hoverLayer.path = found.map { path(for: $0.rect, inset: 0.5) }
        guard found?.node != hoveredNode else { return }
        hoveredNode = found?.node
        delegate?.treemapView(self, didHover: found?.node)
    }

    override func mouseExited(with event: NSEvent) {
        hoverLayer.path = nil
        hoveredNode = nil
        delegate?.treemapView(self, didHover: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let node = hit(event)?.node
        if event.clickCount >= 2, let node {
            delegate?.treemapView(self, didDoubleClick: node)
        } else {
            delegate?.treemapView(self, didSelect: node)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node = hit(event)?.node else { return nil }
        delegate?.treemapView(self, didSelect: node)
        return delegate?.treemapViewMenu(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            NSApp.sendAction(#selector(ScanWindowController.toggleQuickLook(_:)), to: nil, from: self)
        } else {
            super.keyDown(with: event)
        }
    }
}
