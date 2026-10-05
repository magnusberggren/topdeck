import AppKit
import SwiftUI

/// Hover, click, right-click and file dragging, done in AppKit.
///
/// SwiftUI's own hover and gesture handling only works reliably in an active
/// app, and the island never activates QuickFolder, so every interactive
/// element overlays one of these.
struct MouseInteraction: NSViewRepresentable {
    let target: HoverTarget
    let model: IslandModel
    var dragFile: URL? = nil
    var dragImage: NSImage? = nil
    var onClick: () -> Void
    var onRightClick: (() -> Void)? = nil
    /// Replaces the shared `model.hovered` tracking, for controls that sit on
    /// top of another hoverable view.
    var onHover: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.configuration = self
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.configuration = self
    }

    static func dismantleNSView(_ view: InteractionView, coordinator: ()) {
        view.clearHover()
    }
}

final class InteractionView: NSView {
    var configuration: MouseInteraction?

    private var trackingArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func clearHover() {
        guard let configuration else { return }
        if let onHover = configuration.onHover {
            onHover(false)
            return
        }
        if configuration.model.hovered == configuration.target { configuration.model.hovered = nil }
        if configuration.model.pressed == configuration.target { configuration.model.pressed = nil }
    }

    override func mouseEntered(with event: NSEvent) {
        if let onHover = configuration?.onHover {
            Haptics.perform(.alignment)
            onHover(true)
            return
        }
        guard let configuration, !configuration.model.isDraggingFile,
              configuration.model.hovered != configuration.target else { return }
        // A light tick for each thing the pointer lands on, like a detent.
        Haptics.perform(.alignment)
        configuration.model.hovered = configuration.target
    }

    override func mouseExited(with event: NSEvent) {
        if let onHover = configuration?.onHover {
            onHover(false)
            return
        }
        guard let configuration, configuration.model.hovered == configuration.target else { return }
        configuration.model.hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let configuration else { return }
        if event.modifierFlags.contains(.control), let onRightClick = configuration.onRightClick {
            onRightClick()
            return
        }
        mouseDownEvent = event
        didStartDrag = false
        configuration.model.pressed = configuration.target
    }

    override func mouseDragged(with event: NSEvent) {
        guard let configuration, let down = mouseDownEvent, !didStartDrag, let url = configuration.dragFile else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard distance > 4 else { return }

        didStartDrag = true
        configuration.model.pressed = nil

        let image = configuration.dragImage ?? NSWorkspace.shared.icon(forFile: url.path)
        let size = Self.fit(image.size, in: CGSize(width: 64, height: 64))
        let point = convert(down.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: image
        )

        let session = beginDraggingSession(with: [item], event: down, source: FileDragSource.shared)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard let configuration else { return }
        if configuration.model.pressed == configuration.target { configuration.model.pressed = nil }
        guard mouseDownEvent != nil, !didStartDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        configuration.onClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick = configuration?.onRightClick else {
            super.rightMouseDown(with: event)
            return
        }
        onRightClick()
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Owns file drags so they survive the island collapsing mid-drag.
final class FileDragSource: NSObject, NSDraggingSource {
    static let shared = FileDragSource()

    var onBegin: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((NSDragOperation) -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Same as dragging out of Finder: move by default, Option copies.
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onBegin?()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onMove?(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?(operation)
    }
}
