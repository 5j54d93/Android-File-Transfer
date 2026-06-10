//
//  FullWindowOverlay.swift
//  Android-File-Transfer
//
//  Presents an overlay as a subview of the window's frame view — ABOVE the titlebar and
//  toolbar. AppKit draws the toolbar on top of the content view, so no in-content overlay
//  (`.overlay` / ZStack) can ever cover it; attaching to the frame view is what lets the
//  transfer/alert scrim dim the whole window, toolbar included.
//

import AppKit
import SwiftUI

/// Invisible SwiftUI shim: drop it in `.background(...)` and it mirrors `isPresented` into an
/// AppKit overlay attached to the window frame. Content stays live (re-rendered on each update).
struct FullWindowOverlayHost<Overlay: View>: NSViewRepresentable {
    var isPresented: Bool
    @ViewBuilder var overlay: () -> Overlay

    func makeNSView(context: Context) -> OverlayAnchorView {
        OverlayAnchorView()
    }

    func updateNSView(_ anchor: OverlayAnchorView, context: Context) {
        anchor.setOverlay(isPresented ? AnyView(overlay()) : nil)
    }
}

/// Lives (invisibly) in the view hierarchy just to reach the hosting NSWindow, and manages the
/// overlay's lifecycle: fade in on present, fade out + remove on dismiss.
final class OverlayAnchorView: NSView {
    private var hosting: PassThroughHostingView?
    /// Content that arrived before the view was attached to a window (first render).
    private var pending: AnyView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pending {
            self.pending = nil
            setOverlay(pending)
        }
    }

    func setOverlay(_ content: AnyView?) {
        guard let content else {
            pending = nil
            dismiss()
            return
        }
        guard let frameView = window?.contentView?.superview else {
            pending = content
            return
        }
        if let hosting {
            hosting.rootView = content
            return
        }
        let view = PassThroughHostingView(rootView: content)
        view.frame = frameView.bounds
        view.autoresizingMask = [.width, .height]
        view.alphaValue = 0
        frameView.addSubview(view, positioned: .above, relativeTo: nil)
        hosting = view
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            view.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard let view = hosting else { return }
        hosting = nil
        // Stop intercepting clicks the moment dismissal starts — otherwise the scrim keeps
        // swallowing events for the whole fade and the window feels briefly dead.
        view.isPassThrough = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            view.animator().alphaValue = 0
        }, completionHandler: {
            view.removeFromSuperview()
        })
    }
}

/// Hosting view that can stop intercepting events (used during its fade-out).
final class PassThroughHostingView: NSHostingView<AnyView> {
    var isPassThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        isPassThrough ? nil : super.hitTest(point)
    }
}
