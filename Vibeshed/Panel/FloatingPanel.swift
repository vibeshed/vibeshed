import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

final class FloatingPanel: NSPanel {
    /// Called on Escape. Return `true` if handled (e.g. mode popped), `false` to close the panel.
    /// ⌘Escape closes it from any level without asking.
    var onEscape: (() -> Bool)?

    /// Called before animated hide/dismiss begins. Used so PanelController can update state.
    var onWillHide: (() -> Void)?

    /// Called when the show animation finishes. Used to defer heavy work.
    var onShowAnimationComplete: (() -> Void)?

    /// Called with `true` when the panel becomes key and `false` when it resigns key.
    var onKeyStatusChange: ((Bool) -> Void)?

    /// Whether we're currently running a hide/dismiss animation (prevents re-entrancy).
    private var isHiding = false

    /// Whether the show animation is currently in flight.
    private(set) var isAnimatingShow = false

    /// Bumped by every show/hide so a superseded animation's completion does nothing —
    /// otherwise a hide cut short by a quick re-show would still order the panel out.
    private var animationGeneration = 0

    /// When true, losing key focus does not auto-hide the panel.
    /// Used for externally-triggered shows (e.g. browser chooser on URL open)
    /// where focus may briefly bounce back to the source app.
    var staysOpenOnResignKey: Bool = false

    /// When true, losing key focus to another app the user didn't switch to (one a
    /// Shift run launched or focused) takes focus back instead of hiding.
    /// Reset when the panel hides.
    var holdsKeyFocus: Bool = false

    private let keyFocusReclaimer = KeyFocusReclaimer()

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .picker
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        contentView?.wantsLayer = true
        keyFocusReclaimer.start()
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func becomeKey() {
        super.becomeKey()
        onKeyStatusChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyStatusChange?(false)
        if staysOpenOnResignKey { return }
        if holdsKeyFocus, !isHiding, keyFocusReclaimer.shouldReclaim() {
            // Once the new key window has settled. Vibeshed's own windows (an alert) keep it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, !self.isHiding else { return }
                if NSApp.keyWindow == nil {
                    self.makeKey()
                } else {
                    self.animateHide()
                }
            }
            return
        }
        animateHide()
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape, onEscape() {
            return
        }
        animateHide()
    }

    /// The modifiers that make up a chord. Lock and key-type state (Caps Lock on,
    /// `.numericPad`, `.function`) is in `deviceIndependentFlagsMask` too, and must not
    /// stop ⌘Escape from matching.
    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection(Self.chordModifiers) == .command
        {
            animateHide()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func setSwiftUIContent(_ view: some View) {
        contentView = NSHostingView(rootView: view.ignoresSafeArea())
        contentView?.wantsLayer = true
    }

    // MARK: - Show animation (called by PanelController)

    func animateShow() {
        isHiding = false
        isAnimatingShow = true
        animationGeneration += 1
        let generation = animationGeneration

        guard let layer = contentView?.layer else {
            alphaValue = 1
            isAnimatingShow = false
            onShowAnimationComplete?()
            return
        }

        // Suppress implicit animations from any pending property changes
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // An interrupted hide: drop it (its completion sees the stale generation).
        layer.removeAnimation(forKey: "hideGroup")

        // Window surface fully visible — layer opacity handles the visual fade
        alphaValue = 1
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        repositionLayerAnchor(layer)
        layer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        layer.opacity = 0

        CATransaction.commit()

        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        // Unified animation group: scale + opacity in one CA commit
        let timing = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.94
        scaleAnim.toValue = 1.0

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 0.0
        fadeAnim.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = 0.3
        group.timingFunction = timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.isAnimatingShow = false
            self.onShowAnimationComplete?()
        }

        layer.add(group, forKey: "showGroup")

        CATransaction.commit()

        // Set model values to final state
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
    }

    // MARK: - Hide animation (orderOut – keeps panel in memory)

    func animateHide() {
        guard !isHiding else { return }
        isHiding = true
        isAnimatingShow = false
        staysOpenOnResignKey = false
        holdsKeyFocus = false
        keyFocusReclaimer.reset()
        animationGeneration += 1
        let generation = animationGeneration

        onWillHide?()

        guard let layer = contentView?.layer else {
            orderOut(nil)
            isHiding = false
            return
        }

        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        repositionLayerAnchor(layer)

        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 0.96

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = 0.15
        group.timingFunction = timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.orderOut(nil)
            layer.removeAllAnimations()
            layer.transform = CATransform3DIdentity
            layer.opacity = 0
            self.alphaValue = 0
            self.isHiding = false
        }

        layer.add(group, forKey: "hideGroup")

        CATransaction.commit()
    }

    // MARK: - Dismiss (close – destroys panel, used for app quit)

    func animateDismiss() {
        guard !isHiding else { return }
        isHiding = true
        isAnimatingShow = false
        animationGeneration += 1
        let generation = animationGeneration

        onWillHide?()

        guard let layer = contentView?.layer else {
            close()
            isHiding = false
            return
        }

        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        repositionLayerAnchor(layer)

        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 0.96

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = 0.15
        group.timingFunction = timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.close()
            layer.removeAllAnimations()
            layer.transform = CATransform3DIdentity
            layer.opacity = 0
            self.alphaValue = 0
            self.isHiding = false
        }

        layer.add(group, forKey: "hideGroup")

        CATransaction.commit()
    }

    // MARK: - Helpers

    /// Reposition the layer's position after changing anchorPoint so the visual placement doesn't shift.
    private func repositionLayerAnchor(_ layer: CALayer) {
        let bounds = layer.bounds
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
