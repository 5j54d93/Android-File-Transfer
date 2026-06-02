//
//  FilePromiseDragSource.swift
//  Android-File-Transfer
//
//  Drag a device file out to Finder using a file promise. Unlike SwiftUI's
//  FileRepresentation (which blocks the drop while the whole file downloads and times out
//  on slow/large MTP/ADB transfers), NSFilePromiseProvider completes the drag gesture
//  instantly and fulfils the file in the background at the drop location.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MTPKit

/// Hosts an invisible AppKit view over a row's name cell that starts a file-promise drag.
struct FilePromiseDragView: NSViewRepresentable {
    let node: FileNode
    let transport: any DeviceTransport
    let transfers: TransferManager
    /// Called when the gesture turns out to be a plain click (not a drag), so SwiftUI can
    /// update the Table selection that we suppressed while watching for a drag.
    var onClick: (Bool) -> Void   // Bool = command/extend selection
    var onDoubleClick: () -> Void
    /// Resolves which nodes a drag carries, evaluated at drag-start. Lets a drag that begins
    /// on a selected row carry the whole (multi-file) selection rather than just this cell.
    var nodesToDrag: () -> [FileNode]

    func makeNSView(context: Context) -> NSView {
        let v = PromiseDragSourceView()
        v.configure(node: node, transport: transport, transfers: transfers,
                    onClick: onClick, onDoubleClick: onDoubleClick, nodesToDrag: nodesToDrag)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PromiseDragSourceView)?.configure(node: node, transport: transport, transfers: transfers,
                                                      onClick: onClick, onDoubleClick: onDoubleClick,
                                                      nodesToDrag: nodesToDrag)
    }
}

/// Transparent view that begins a file-promise dragging session on drag, while letting
/// clicks/double-clicks fall through to the SwiftUI Table underneath.
private final class PromiseDragSourceView: NSView, NSDraggingSource {
    private var node: FileNode?
    private var transport: (any DeviceTransport)?
    private weak var transfers: TransferManager?
    private var onClick: ((Bool) -> Void)?
    private var onDoubleClick: (() -> Void)?
    private var nodesToDrag: (() -> [FileNode])?
    private var mouseDownEvent: NSEvent?
    private var didBeginDrag = false
    /// Held strongly for the duration of the latest drag (one per dragged file).
    /// `NSFilePromiseProvider.delegate` is a *weak* reference, but the promise is fulfilled
    /// only after the drag begins (at drop time). Without this the delegates would deallocate
    /// immediately and Finder would accept the drop yet get no files. The view outlives the
    /// drop, by which point each download has been handed off to TransferManager.
    private var activePromiseDelegates: [FilePromiseDelegate] = []

    func configure(node: FileNode, transport: any DeviceTransport, transfers: TransferManager,
                   onClick: @escaping (Bool) -> Void, onDoubleClick: @escaping () -> Void,
                   nodesToDrag: @escaping () -> [FileNode]) {
        self.node = node
        self.transport = transport
        self.transfers = transfers
        self.onClick = onClick
        self.onDoubleClick = onDoubleClick
        self.nodesToDrag = nodesToDrag
    }

    /// Begin a drag even when the window isn't key, so the user can grab a file in one motion.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// We fully own the gesture. Crucially we do NOT call `super.mouseDown`, which would hand
    /// the whole mouse session to the Table's own modal tracking and swallow our drag. AppKit
    /// still delivers the matching `mouseDragged`/`mouseUp` to us because we claimed the
    /// mouse-down. We decide drag-vs-click in those, NOT here — so a row that was *just*
    /// clicked (and is now selected/blue, hence a high `clickCount`) can still be dragged.
    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didBeginDrag, let start = mouseDownEvent?.locationInWindow else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 4 {
            didBeginDrag = true
            beginPromiseDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !didBeginDrag else { return }   // it became a drag, not a click
        let isExtend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?(isExtend)
        }
    }

    private func beginPromiseDrag(with event: NSEvent) {
        guard let transport, let transfers else { return }
        // Resolve which files to drag: the whole selection if the grabbed row is part of it,
        // otherwise just this row. Folders can't be promised, so they're filtered out.
        let fallback = node.map { [$0] } ?? []
        let files = (nodesToDrag?() ?? fallback).filter { !$0.isDirectory }
        guard !files.isEmpty else { return }

        let origin = convert(event.locationInWindow, from: nil)
        let multiple = files.count > 1
        var delegates: [FilePromiseDelegate] = []
        var items: [NSDraggingItem] = []
        for (index, file) in files.enumerated() {
            let type = Format.utType(for: file)
            let delegate = FilePromiseDelegate(node: file, transport: transport, transfers: transfers)
            delegates.append(delegate)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
            let item = NSDraggingItem(pasteboardWriter: provider)

            // Drag image: a Finder-style icon+name pill for one file; cascaded plain icons for
            // several (the system adds the count badge automatically).
            let icon = NSWorkspace.shared.icon(for: type)
            let image: NSImage
            if multiple {
                image = (icon.copy() as? NSImage) ?? icon
                image.size = NSSize(width: 32, height: 32)
            } else {
                image = Self.makeDragImage(icon: icon, name: file.name)
            }
            let d = CGFloat(min(index, 4)) * 4
            let frame = NSRect(x: origin.x - 10 + d, y: origin.y - image.size.height / 2 - d,
                               width: image.size.width, height: image.size.height)
            item.setDraggingFrame(frame, contents: image)
            items.append(item)
        }
        activePromiseDelegates = delegates
        beginDraggingSession(with: items, event: event, source: self)
    }

    /// Compose a Finder-style drag image: the file icon with its name beside it on a subtle
    /// rounded background. The system softens it to translucent during the drag.
    private static func makeDragImage(icon: NSImage, name: String) -> NSImage {
        let iconSize: CGFloat = 16
        let gap: CGFloat = 5
        let padH: CGFloat = 6
        let padV: CGFloat = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let label = NSAttributedString(string: name, attributes: attrs)
        let textSize = label.size()
        let width = padH + iconSize + gap + ceil(textSize.width) + padH
        let height = padV + max(iconSize, ceil(textSize.height)) + padV

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                     xRadius: 6, yRadius: 6).fill()
        icon.draw(in: NSRect(x: padH, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        label.draw(at: NSPoint(x: padH + iconSize + gap, y: (height - textSize.height) / 2))
        image.unlockFocus()
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        if operation == [] {
            activePromiseDelegates = []
        }
    }
}

/// Fulfils the promise: when Finder gives us the destination URL, download the device file
/// there via the shared TransferManager (so it shows in the transfer queue) and signal
/// completion when done.
private final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let node: FileNode
    private let transport: any DeviceTransport
    private let transfers: TransferManager
    private let workQueue: OperationQueue

    init(node: FileNode, transport: any DeviceTransport, transfers: TransferManager) {
        self.node = node
        self.transport = transport
        self.transfers = transfers
        self.workQueue = OperationQueue()
        self.workQueue.qualityOfService = .userInitiated
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        node.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        workQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // Called on workQueue (background). Drive the download on the main actor through
        // TransferManager, then report back to Finder.
        let node = self.node
        let transport = self.transport
        let transfers = self.transfers
        Task { @MainActor in
            transfers.downloadToURL(node, from: transport, to: url) { error in
                completionHandler(error)
            }
        }
    }
}
