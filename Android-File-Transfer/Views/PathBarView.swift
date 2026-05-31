//
//  PathBarView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Clickable breadcrumb path, like Finder's path bar.
struct PathBarView: View {
    @Bindable var browser: BrowserViewModel

    var body: some View {
        HStack(spacing: 4) {
            crumb(label: browser.storage?.name ?? "根目錄", systemImage: "externaldrive") {
                browser.navigate(toDepth: 0)
            }
            ForEach(Array(browser.pathStack.enumerated()), id: \.element.id) { index, dir in
                Image(systemName: "chevron.compact.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                crumb(label: dir.name, systemImage: nil) {
                    browser.navigate(toDepth: index + 1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func crumb(label: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(label).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
