//
//  AppAlerts.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI

/// App-wide, transient error/notice banner shown at the top of the window. Operations
/// that previously failed silently (delete/rename/upload errors, connection issues)
/// post here so the user actually sees what went wrong.
@MainActor
@Observable
final class AppAlerts {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var kind: Kind
        enum Kind { case error, info }
    }

    private(set) var current: Notice?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func error(_ message: String) { show(Notice(message: message, kind: .error)) }
    func info(_ message: String) { show(Notice(message: message, kind: .info)) }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func show(_ notice: Notice) {
        current = notice
        dismissTask?.cancel()
        // Errors linger longer than info; both can be dismissed manually.
        let seconds: UInt64 = notice.kind == .error ? 6 : 3
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// The banner view, overlaid at the top of the detail pane.
struct AlertBanner: View {
    let notice: AppAlerts.Notice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.kind == .error ? .white : .white)
            Text(notice.message)
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark").foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(notice.kind == .error ? Color.red.opacity(0.92) : Color.accentColor.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
