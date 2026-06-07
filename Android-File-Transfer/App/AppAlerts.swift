//
//  AppAlerts.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI

/// App-wide error/notice presented as a centred modal card (in the spirit of the transfer
/// overlay), so failures the user must acknowledge — connection drops, failed folder reads —
/// are clear and dismissible, rather than a banner that slides away on its own.
@MainActor
@Observable
final class AppAlerts {
    struct Notice: Identifiable {
        let id = UUID()
        var message: String
        var kind: Kind
        /// Optional primary action (e.g. "Reconnect"). When nil the card shows only a dismiss button.
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
        enum Kind { case error, info }
    }

    private(set) var current: Notice?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// A plain error the user dismisses with "Got it".
    func error(_ message: String) {
        show(Notice(message: message, kind: .error), autoDismiss: false)
    }

    /// An error offering a recovery action (e.g. reconnect) alongside "Got it".
    func error(_ message: String, actionTitle: String, action: @escaping @MainActor () -> Void) {
        show(Notice(message: message, kind: .error, actionTitle: actionTitle, action: action), autoDismiss: false)
    }

    /// A transient informational notice that fades on its own.
    func info(_ message: String) {
        show(Notice(message: message, kind: .info), autoDismiss: true)
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func show(_ notice: Notice, autoDismiss: Bool) {
        current = notice
        dismissTask?.cancel()
        guard autoDismiss else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// Centred modal alert card shown over the whole window. A flat panel (no Liquid Glass / big
/// shadow) for the same reason as the transfer overlay — heavy offscreen renders stall the
/// CoreAnimation commit.
struct AlertOverlay: View {
    let notice: AppAlerts.Notice
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Scrim. Tapping it dismisses simple alerts; alerts with an action require an explicit
            // choice, so the scrim is inert for those.
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if notice.action == nil { onDismiss() } }

            VStack(spacing: 16) {
                Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(notice.kind == .error ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tint))

                Text(notice.message)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = notice.actionTitle, let action = notice.action {
                    HStack {
                        Button("Got It") { onDismiss() }
                            .controlSize(.large)
                        Spacer()
                        Button(actionTitle) { action(); onDismiss() }
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Got It") { onDismiss() }
                        .frame(maxWidth: .infinity)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 360)
            .padding(28)
            .background(.background, in: .rect(cornerRadius: 16))
        }
    }
}
