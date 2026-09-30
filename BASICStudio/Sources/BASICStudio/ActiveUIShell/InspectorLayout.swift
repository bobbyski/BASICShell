//
//  InspectorLayout.swift
//  BASICStudio
//
//  The main pane, a drag handle, and the inspector, side by side.
//

import ActiveUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation

/// The window's body in the ActiveUI shell: the main pane on the left, the
/// inspector on the right, and a 12-point handle between them that drags.
///
/// ```text
///   ┌──────── main (≥ 420) ────────┐┃┌── inspector (≥ 260) ──┐
///   │                              │┃│                       │
///   └──────────────────────────────┘┃└───────────────────────┘
///                                   └ handle, 12 pt: drags the width
/// ```
///
/// The width rules are ``StudioShellModel``'s, the same two functions the
/// SwiftUI shell's `InspectorDivider` calls, so the two shells clamp alike.
/// With no inspector showing, the main pane takes the whole width.
@MainActor
final class InspectorLayout: AUIView {
    let main: AUIView
    let inspector: AUIView
    let handle: AUINativeHost
    /// The inspector's width as dragged; drawn clamped to the room there is.
    private(set) var inspectorWidth = StudioShellModel.defaultInspectorWidth

    /// Whether the inspector and its handle show.
    var showsInspector = false {
        didSet {
            guard showsInspector != oldValue else { return }
            inspector.isHidden = !showsInspector
            handle.isHidden = !showsInspector
            invalidateLayout()
        }
    }

    init(main: AUIView, inspector: AUIView) {
        self.main = main
        self.inspector = inspector
        let grip = DragHandleView(axis: .horizontal)
        handle = AUINativeHost(grip, sizing: .fixed(CGSize(width: 12, height: 44)))
        super.init(nativeView: AUIView.makeContainerBacking())
        addChild(main)
        addChild(handle)
        addChild(inspector)
        inspector.isHidden = true
        handle.isHidden = true
        flexibility = .both()
        var dragStart: CGFloat?
        grip.toolTip = "Resize side pane"
        grip.onDrag = { [weak self] translation, phase in
            guard let self else { return }
            switch phase {
            case .began:
                dragStart = self.inspectorWidth
            case .changed:
                self.inspectorWidth = StudioShellModel.draggedInspectorWidth(
                    startWidth: dragStart ?? self.inspectorWidth,
                    translation: translation,
                    availableWidth: self.nativeView.bounds.width
                )
                self.invalidateLayout()
            case .ended:
                dragStart = nil
            }
        }
    }

    override func preferredSize(fitting available: CGSize) -> CGSize {
        available
    }

    override func layoutChildren(in bounds: CGRect) {
        guard showsInspector else {
            main.place(in: bounds)
            return
        }
        let width = StudioShellModel.clampedInspectorWidth(inspectorWidth, availableWidth: bounds.width)
        let handleWidth: CGFloat = 12
        let mainWidth = max(0, bounds.width - width - handleWidth)
        main.place(in: CGRect(x: bounds.minX, y: bounds.minY, width: mainWidth, height: bounds.height))
        handle.place(in: CGRect(x: bounds.minX + mainWidth, y: bounds.minY, width: handleWidth, height: bounds.height))
        inspector.place(in: CGRect(x: bounds.minX + mainWidth + handleWidth, y: bounds.minY, width: width, height: bounds.height))
    }
}

#if canImport(AppKit)
/// A divider that drags: a one-point rule with a small grip, reporting how
/// far the pointer has moved since the drag began. Used across the window
/// (the inspector's width) and down the Debug pane (the code view's height).
final class DragHandleView: NSView {
    enum Axis { case horizontal, vertical }
    enum Phase { case began, changed, ended }

    /// Called with the pointer's travel along the axis since mouse-down:
    /// rightward or downward is positive.
    var onDrag: ((CGFloat, Phase) -> Void)?
    let axis: Axis
    private var startPoint: NSPoint?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DragHandleView is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSColor.tertiaryLabelColor.setStroke()
        switch axis {
        case .horizontal:
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
            let grip = NSRect(x: bounds.midX - 1.5, y: bounds.midY - 22, width: 3, height: 44)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
        case .vertical:
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
            let grip = NSRect(x: bounds.midX - 22, y: bounds.midY - 1.5, width: 44, height: 3)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        onDrag?(0, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = event.locationInWindow
        // Window coordinates run upward; a downward drag is positive here.
        let travel = axis == .horizontal ? point.x - startPoint.x : startPoint.y - point.y
        onDrag?(travel, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        startPoint = nil
        onDrag?(0, .ended)
    }
}
#else
/// The same divider on iPhone and iPad, dragged by a pan instead of a pointer.
final class DragHandleView: UIView {
    enum Axis { case horizontal, vertical }
    enum Phase { case began, changed, ended }

    /// Called with the finger's travel along the axis since it went down:
    /// rightward or downward is positive.
    var onDrag: ((CGFloat, Phase) -> Void)?
    let axis: Axis
    /// The Mac's tooltip; kept so a caller sets it the same way on both.
    var toolTip: String?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DragHandleView is built in code")
    }

    override func draw(_ rect: CGRect) {
        UIColor.separator.setFill()
        let grip: CGRect
        switch axis {
        case .horizontal:
            UIRectFill(CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height))
            grip = CGRect(x: bounds.midX - 1.5, y: bounds.midY - 22, width: 3, height: 44)
        case .vertical:
            UIRectFill(CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1))
            grip = CGRect(x: bounds.midX - 22, y: bounds.midY - 1.5, width: 44, height: 3)
        }
        UIColor.tertiaryLabel.setFill()
        UIBezierPath(roundedRect: grip, cornerRadius: 2).fill()
    }

    // UIKit's y already runs downward, so a downward drag is positive as is.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let travel = pan.translation(in: self)
        switch pan.state {
        case .began: onDrag?(0, .began)
        case .changed: onDrag?(axis == .horizontal ? travel.x : travel.y, .changed)
        default: onDrag?(0, .ended)
        }
    }
}
#endif
