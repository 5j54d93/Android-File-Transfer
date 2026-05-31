//
//  Formatting.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MTPKit

/// Small formatting/icon helpers shared by the browser views.
enum Format {
    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : bytes.formatted(.byteCount(style: .file))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// e.g. "2.4 MB/s". Returns nil for negligible/zero rates.
    static func speed(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 1 else { return nil }
        return "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s"
    }

    /// Compact remaining-time string, e.g. "about 12s" / "約 12 秒".
    static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        if seconds < 60 { return String(format: NSLocalizedString("about %ds", comment: ""), Int(seconds)) }
        if seconds < 3600 { return String(format: NSLocalizedString("about %dm", comment: ""), Int(seconds / 60)) }
        return String(format: NSLocalizedString("about %dh", comment: ""), Int(seconds / 3600))
    }

    static func kind(for node: FileNode) -> String {
        if node.isDirectory { return NSLocalizedString("Folder", comment: "") }
        if let ext = node.fileExtension, let type = UTType(filenameExtension: ext) {
            return type.localizedDescription ?? String(format: NSLocalizedString("%@ File", comment: ""), ext.uppercased())
        }
        return NSLocalizedString("Document", comment: "")
    }

    static func utType(for node: FileNode) -> UTType {
        if node.isDirectory { return .folder }
        if let ext = node.fileExtension, let type = UTType(filenameExtension: ext) { return type }
        return .data
    }

    static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}

/// Renders the real Finder/system icon for a node so the list looks native.
struct FileIcon: View {
    let node: FileNode
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: Format.utType(for: node)))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}
