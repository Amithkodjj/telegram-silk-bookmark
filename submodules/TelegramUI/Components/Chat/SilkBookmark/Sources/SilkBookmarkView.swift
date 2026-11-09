import Foundation
import UIKit
import QuartzCore
import Metal
import simd

public struct SilkBookmarkMessage {
    public let key: Int64
    public let frame: CGRect

    public init(key: Int64, frame: CGRect) {
        self.key = key
        self.frame = frame
    }
}

private final class SilkDisplayLinkTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        self.action()
    }
}

private func vector(_ point: CGPoint) -> SIMD2<Float> {
    return SIMD2(Float(point.x), Float(point.y))
}

public final class SilkBookmarkView: UIView {
    private enum Mode {
        case docked
        case dragging(finger: CGPoint, offset: CGPoint, candidate: SilkBookmarkMessage?)
        case placed(SilkBookmarkMessage)
    }

    private struct Flight {
        let fromHead: SIMD3<Float>
        let fromAxis: SIMD2<Float>
        let duration: Float
        var progress: Float
    }

    public var messageAt: ((CGPoint) -> SilkBookmarkMessage?)?
    public var messageWithKey: ((Int64, Bool) -> SilkBookmarkMessage?)?
    public var visibleMessageFrames: ((Bool) -> [CGRect])?
    public var listProbe: (() -> (AnyHashable, CGFloat)?)?
    public var bookmarkChanged: ((Int64?) -> Void)?
    public var goToBookmark: ((Int64) -> Void)?

    private static let boxSide: CGFloat = 210.0
    private static let hangingGravity = SIMD3<Float>(0.0, 1500.0, 0.0)

    private let cloth = SilkCloth()
    private let metalLayer = CAMetalLayer()
    private let highlightLayer = CAShapeLayer()

    private var renderer: SilkRenderer?
    private var targets: SilkRenderTargets?
    private var link: CADisplayLink?

    private var mode: Mode = .docked
    private var flight: Flight?
    private var bookmark: Int64?
    private var hasEntered = false

    private var dockPoint: CGPoint = .zero
    private var visibleTop: CGFloat = 0.0
    private var visibleBottom: CGFloat = 0.0
    private var currentPose = SilkPose(head: .zero, axis: SIMD2(0.0, 1.0))

    private var lastTick: CFTimeInterval = 0.0
    private var lastListMove: CFTimeInterval = 0.0
    private var awakeUntil: CFTimeInterval = 0.0
    private var clock: Float = 0.0
    private var restFrames = 0
    private var needsDraw = true
    private var boxOrigin: CGPoint = .zero

    private var probe: (AnyHashable, CGFloat)?
    private var scrollSpeed: CGFloat = 0.0
    private var windLevel: Float = 0.0
    private var dragTilt: Float = 0.0
    private var dragTiltTarget: Float = 0.0
    private var clipRects: [CGRect] = []
    private var clipAmount: Float = 0.0
    private var clipRectsRelative: [CGRect] = []
    private var vividness: Float = 0.0

    private let grabFeedback = UIImpactFeedbackGenerator(style: .light)
    private let dropFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let targetFeedback = UISelectionFeedbackGenerator()

    public init() {
        super.init(frame: .zero)

        self.isOpaque = false
        self.layer.contents = UIGraphicsImageRenderer(size: CGSize(width: 1.0, height: 1.0)).image { _ in }.cgImage

        self.highlightLayer.fillColor = UIColor(red: 0.72, green: 0.07, blue: 0.17, alpha: 0.08).cgColor
        self.highlightLayer.strokeColor = UIColor(red: 0.72, green: 0.07, blue: 0.17, alpha: 0.85).cgColor
        self.highlightLayer.lineWidth = 2.0
        self.highlightLayer.opacity = 0.0
        self.layer.addSublayer(self.highlightLayer)

        let scale = UIScreen.main.scale
        let side = SilkBookmarkView.boxSide
        self.metalLayer.pixelFormat = .bgra8Unorm
        self.metalLayer.framebufferOnly = true
        self.metalLayer.isOpaque = false
        self.metalLayer.presentsWithTransaction = true
        self.metalLayer.contentsScale = scale
        self.metalLayer.drawableSize = CGSize(width: side * scale, height: side * scale)
        self.metalLayer.frame = CGRect(x: -1000.0, y: -1000.0, width: side, height: side)
        self.layer.addSublayer(self.metalLayer)

        self.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:))))
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.handleTap)))

        SilkRenderer.load { [weak self] renderer in
            guard let self else {
                return
            }
            let pixels = Int(side * scale)
            self.renderer = renderer
            self.metalLayer.device = renderer.device
            self.targets = SilkRenderTargets(device: renderer.device, width: pixels, height: pixels, sampleCount: renderer.sampleCount)
            self.needsDraw = true
            self.wake()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.link?.invalidate()
    }

    override public func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            self.link?.invalidate()
            self.link = nil
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil {
            self.wake()
        }
    }

    override public func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !self.isHidden, self.renderer != nil else {
            return false
        }
        if case .placed = self.mode, self.clipRects.contains(where: { $0.contains(point) }) {
            return false
        }
        return self.cloth.distance(to: vector(point)) < 19.0
    }

    public func update(size: CGSize, dock: CGPoint, visibleTop: CGFloat, visibleBottom: CGFloat) {
        self.frame = CGRect(origin: .zero, size: size)
        if self.hasEntered, case .docked = self.mode, abs(self.dockPoint.y - dock.y) > 1.0, self.flight == nil {
            self.dockPoint = dock
            self.startFlight(duration: 0.3)
        }
        self.dockPoint = dock
        self.visibleTop = visibleTop
        self.visibleBottom = visibleBottom

        if !self.hasEntered {
            self.hasEntered = true
            let start = SilkPose(head: SIMD3(Float(dock.x), Float(dock.y) - 150.0, 10.0), axis: SIMD2(0.0, 1.0))
            self.cloth.reset(pose: start)
            self.currentPose = start
            self.startFlight(duration: 0.55)
        }
        self.wake()
    }

    public func setBookmark(_ key: Int64?) {
        self.bookmark = key
        self.vividness = key == nil ? 0.0 : 1.0
        self.needsDraw = true
        self.wake()
    }

    public func setContentHidden(_ hidden: Bool) {
        if self.isHidden != hidden {
            self.isHidden = hidden
            if !hidden {
                self.wake()
            }
        }
    }

    public func listDidMove() {
        self.lastListMove = CACurrentMediaTime()
        if case .placed = self.mode, self.flight == nil {
            self.followMessage(usingPresentation: false)
        }
        self.wake(for: 0.2)
    }

    private func wake(for duration: CFTimeInterval = 0.0) {
        let now = CACurrentMediaTime()
        self.awakeUntil = max(self.awakeUntil, now + duration)
        guard self.window != nil, self.link == nil else {
            return
        }
        let link = CADisplayLink(target: SilkDisplayLinkTarget { [weak self] in
            self?.tick()
        }, selector: #selector(SilkDisplayLinkTarget.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60.0, maximum: 120.0, preferred: 120.0)
        link.add(to: .main, forMode: .common)
        self.link = link
        self.lastTick = now
        self.restFrames = 0
    }

    private func sideOf(_ frame: CGRect) -> Float {
        return frame.midX < self.bounds.midX ? 1.0 : -1.0
    }

    private func anchor(of frame: CGRect) -> CGPoint {
        let x = self.sideOf(frame) > 0.0 ? frame.maxX - 16.0 : frame.minX + 16.0
        return CGPoint(x: x, y: frame.minY + min(frame.height * 0.5, 18.0))
    }

    private func drapeShape(for frame: CGRect) -> (side: Float, theta0: Float, kappa: Float) {
        let side = self.sideOf(frame)
        let room = Float(side > 0.0 ? self.bounds.maxX - frame.maxX : frame.minX)
        let reach = room - 3.0
        let theta1: Float = 0.18
        var theta0: Float = 1.25
        while theta0 > 0.35, (cos(theta1) - cos(theta0)) * SilkCloth.length / (theta0 - theta1) > reach {
            theta0 -= 0.05
        }
        return (side, theta0, (theta1 - theta0) / SilkCloth.length)
    }

    private func restingPose() -> SilkPose {
        switch self.mode {
        case .docked:
            return SilkPose(head: SIMD3(Float(self.dockPoint.x), Float(self.dockPoint.y), 10.0), axis: SIMD2(0.0, 1.0))
        case let .dragging(finger, offset, _):
            return SilkPose(head: SIMD3(Float(finger.x + offset.x), Float(finger.y + offset.y), 26.0), axis: SIMD2(sin(self.dragTilt), cos(self.dragTilt)))
        case let .placed(message):
            let shape = self.drapeShape(for: message.frame)
            let point = self.anchor(of: message.frame)
            return SilkPose(head: SIMD3(Float(point.x), Float(point.y), 2.0), axis: SIMD2(sin(shape.theta0) * shape.side, cos(shape.theta0)))
        }
    }

    private func startFlight(duration: Float) {
        self.flight = Flight(fromHead: self.currentPose.head, fromAxis: self.currentPose.axis, duration: duration, progress: 0.0)
        self.restFrames = 0
    }

    private func flownPose() -> SilkPose {
        let target = self.restingPose()
        guard let flight = self.flight else {
            return target
        }
        let t = min(flight.progress, 1.0)
        let eased = t * t * (3.0 - 2.0 * t)
        return SilkPose(
            head: flight.fromHead + (target.head - flight.fromHead) * eased,
            axis: simd_normalize(flight.fromAxis + (target.axis - flight.fromAxis) * eased)
        )
    }

    private func inBand(_ frame: CGRect, margin: CGFloat) -> Bool {
        return frame.maxY > self.visibleTop + margin && frame.minY < self.visibleBottom - margin
    }

    private func followMessage(usingPresentation: Bool) {
        guard case let .placed(message) = self.mode else {
            return
        }
        guard let current = self.messageWithKey?(message.key, usingPresentation), self.inBand(current.frame, margin: 2.0) else {
            self.mode = .docked
            self.startFlight(duration: 0.45)
            return
        }
        if self.flight == nil {
            let delta = vector(self.anchor(of: current.frame)) - vector(self.anchor(of: message.frame))
            if delta != .zero {
                self.cloth.translate(by: delta)
                self.boxOrigin.x += CGFloat(delta.x)
                self.boxOrigin.y += CGFloat(delta.y)
                self.applyBoxFrame()
            }
        }
        self.mode = .placed(current)
        self.refreshClips(usingPresentation: usingPresentation, anchor: self.anchor(of: current.frame))
    }

    private func refreshClips(usingPresentation: Bool, anchor: CGPoint) {
        let bounds = self.cloth.bounds()
        let region = CGRect(x: CGFloat(bounds.min.x) - 12.0, y: CGFloat(bounds.min.y) - 12.0, width: CGFloat(bounds.max.x - bounds.min.x) + 24.0, height: CGFloat(bounds.max.y - bounds.min.y) + 24.0)
        let frames = Array((self.visibleMessageFrames?(usingPresentation) ?? []).filter { $0.intersects(region) }.prefix(6))
        let relative = frames.map { $0.offsetBy(dx: -anchor.x, dy: -anchor.y) }
        if relative != self.clipRectsRelative {
            self.clipRectsRelative = relative
            self.needsDraw = true
        }
        self.clipRects = frames
    }

    private func syncPlacement(now: CFTimeInterval) {
        switch self.mode {
        case .docked:
            if let key = self.bookmark, self.scrollSpeed < 700.0, let message = self.messageWithKey?(key, true), self.inBand(message.frame, margin: 20.0) {
                self.mode = .placed(message)
                self.startFlight(duration: 0.42)
            }
        case .placed:
            if now - self.lastListMove > 0.05 {
                self.followMessage(usingPresentation: true)
            }
        case .dragging:
            break
        }
    }

    private func measureScroll(dt: CGFloat) {
        guard let current = self.listProbe?() else {
            self.probe = nil
            self.scrollSpeed = 0.0
            return
        }
        if let previous = self.probe, previous.0 == current.0, dt > 0.0 {
            self.scrollSpeed = abs(current.1 - previous.1) / dt
        } else {
            self.scrollSpeed = 0.0
        }
        self.probe = current
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - self.lastTick, 1.0 / 20.0))
        self.lastTick = now
        self.clock += dt

        self.measureScroll(dt: CGFloat(dt))
        self.syncPlacement(now: now)

        if var flight = self.flight {
            flight.progress += dt / flight.duration
            self.flight = flight.progress >= 1.0 ? nil : flight
        }

        let motionAllowed = !UIAccessibility.isReduceMotionEnabled
        let gust = motionAllowed ? min(Float(self.scrollSpeed) / 2600.0, 1.0) : 0.0
        self.windLevel = max(self.windLevel - dt * 1.4, gust)

        let vividTarget: Float
        switch self.mode {
        case .docked:
            vividTarget = self.bookmark == nil ? 0.0 : 1.0
        case .dragging, .placed:
            vividTarget = 1.0
        }
        if self.vividness != vividTarget {
            let change = dt / 0.3
            self.vividness = vividTarget > self.vividness ? min(self.vividness + change, vividTarget) : max(self.vividness - change, vividTarget)
            self.needsDraw = true
        }

        self.dragTilt += (self.dragTiltTarget - self.dragTilt) * min(dt * 10.0, 1.0)

        var clipTarget: Float = 0.0
        if case .placed = self.mode, (self.flight?.progress ?? 1.0) > 0.55 {
            clipTarget = 1.0
        }
        if self.clipAmount != clipTarget {
            let change = dt / 0.22
            self.clipAmount = clipTarget > self.clipAmount ? min(self.clipAmount + change, clipTarget) : max(self.clipAmount - change, clipTarget)
            self.needsDraw = true
        }

        let pose = self.flownPose()
        self.currentPose = pose
        self.cloth.advance(dt: dt, pose: pose, forces: self.forces())

        if self.cloth.motion > 0.002 || self.flight != nil || self.windLevel > 0.0 {
            self.needsDraw = true
        }
        if case let .placed(message) = self.mode, self.flight != nil || self.clipRects.isEmpty {
            self.refreshClips(usingPresentation: true, anchor: self.anchor(of: message.frame))
        }
        if self.needsDraw, !self.isHidden {
            self.draw()
        }
        self.sleepIfSettled(now: now)
    }

    private func forces() -> SilkForces {
        switch self.mode {
        case .docked:
            return SilkForces(gravity: SilkBookmarkView.hangingGravity, damping: 0.985, wind: self.windLevel, time: self.clock, hang: 0.0, ripple: 240.0, drape: nil)
        case .dragging:
            return SilkForces(gravity: SilkBookmarkView.hangingGravity, damping: 0.955, wind: 0.0, time: self.clock, hang: 320.0, ripple: 240.0, drape: nil)
        case let .placed(message):
            let shape = self.drapeShape(for: message.frame)
            let progress = self.flight.map { $0.progress } ?? 1.0
            let strength = max(min((progress - 0.3) / 0.7, 1.0), 0.0)
            let drape = SilkDrape(strength: strength, side: shape.side, theta0: shape.theta0, kappa: shape.kappa)
            let gravity = SilkBookmarkView.hangingGravity * (1.0 - strength)
            return SilkForces(gravity: gravity, damping: 0.985 - 0.085 * strength, wind: 0.0, time: self.clock, hang: 0.0, ripple: 0.0, drape: drape)
        }
    }

    private func sleepIfSettled(now: CFTimeInterval) {
        var isDragging = false
        if case .dragging = self.mode {
            isDragging = true
        }
        if !isDragging, self.flight == nil, self.windLevel <= 0.0, self.cloth.motion < 0.002, self.clipAmount == 0.0 || self.clipAmount == 1.0, now > self.awakeUntil {
            self.restFrames += 1
        } else {
            self.restFrames = 0
        }
        if self.restFrames > 12 {
            self.link?.invalidate()
            self.link = nil
            self.probe = nil
        }
    }

    private func applyBoxFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.metalLayer.frame = CGRect(origin: self.boxOrigin, size: CGSize(width: SilkBookmarkView.boxSide, height: SilkBookmarkView.boxSide))
        CATransaction.commit()
    }

    private func draw() {
        guard let renderer = self.renderer, let targets = self.targets else {
            return
        }
        self.needsDraw = false

        let bounds = self.cloth.bounds()
        let center = (bounds.min + bounds.max) * 0.5
        let scale = UIScreen.main.scale
        let side = SilkBookmarkView.boxSide
        self.boxOrigin = CGPoint(
            x: ((CGFloat(center.x) - side * 0.5) * scale).rounded() / scale,
            y: ((CGFloat(center.y) - side * 0.5) * scale).rounded() / scale
        )
        self.applyBoxFrame()

        renderer.draw(
            cloth: self.cloth,
            layer: self.metalLayer,
            targets: targets,
            origin: vector(self.boxOrigin),
            size: SIMD2(repeating: Float(side)),
            vividness: self.vividness,
            clips: self.clipRects,
            clipAmount: self.clipAmount
        )
    }

    private func setHighlight(_ message: SilkBookmarkMessage?) {
        if let message {
            self.highlightLayer.path = UIBezierPath(roundedRect: message.frame.insetBy(dx: -2.0, dy: -2.0), cornerRadius: 18.0).cgPath
            self.highlightLayer.opacity = 1.0
        } else {
            self.highlightLayer.opacity = 0.0
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let finger = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            let head = CGPoint(x: CGFloat(self.currentPose.head.x), y: CGFloat(self.currentPose.head.y))
            self.flight = nil
            self.mode = .dragging(finger: finger, offset: CGPoint(x: head.x - finger.x, y: head.y - finger.y), candidate: nil)
            self.grabFeedback.impactOccurred()
            self.wake()
        case .changed:
            guard case let .dragging(_, offset, previous) = self.mode else {
                return
            }
            self.dragTiltTarget = max(min(-Float(recognizer.velocity(in: self).x) / 2200.0, 0.6), -0.6)
            let candidate = self.messageAt?(finger)
            if candidate?.key != previous?.key {
                self.setHighlight(candidate)
                if candidate != nil {
                    self.targetFeedback.selectionChanged()
                }
            }
            self.mode = .dragging(finger: finger, offset: offset, candidate: candidate)
        case .ended, .cancelled:
            guard case let .dragging(_, _, candidate) = self.mode else {
                return
            }
            self.setHighlight(nil)
            self.dragTiltTarget = 0.0
            if recognizer.state == .ended, let candidate {
                self.bookmark = candidate.key
                self.mode = .placed(candidate)
                self.startFlight(duration: 0.34)
                self.dropFeedback.impactOccurred()
                self.bookmarkChanged?(candidate.key)
            } else {
                if recognizer.state == .ended, self.bookmark != nil {
                    self.bookmark = nil
                    self.bookmarkChanged?(nil)
                }
                self.mode = .docked
                self.startFlight(duration: 0.45)
            }
            self.wake()
        default:
            break
        }
    }

    @objc private func handleTap() {
        self.windLevel = max(self.windLevel, 0.55)
        self.grabFeedback.impactOccurred()
        if case .docked = self.mode, let key = self.bookmark {
            self.goToBookmark?(key)
        }
        self.wake(for: 2.0)
    }
}
