//
//  FileBrowserView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit
import CoreTransferable
import UniformTypeIdentifiers

/// The Finder-like detail pane: breadcrumb + multi-column file table + toolbar.
/// Drag files from Finder onto it to upload; drag files out to Finder to download.
struct FileBrowserView: View {
    @Bindable var browser: BrowserViewModel
    @Bindable var transfers: TransferManager

    @State private var showTransfers = false
    @State private var newFolderPresented = false
    @State private var newFolderName = String(localized: "untitled folder")
    @State private var renameTarget: FileNode?
    @State private var renameName = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PathBarView(browser: browser)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $newFolderPresented) {
            NameSheet(title: "New Folder", label: "Name", text: $newFolderName, confirmTitle: "Create") {
                browser.createFolder(named: newFolderName)
            }
        }
        .sheet(item: $renameTarget) { target in
            NameSheet(title: "Rename", label: "New Name", text: $renameName, confirmTitle: "Rename") {
                browser.rename(target.id, to: renameName)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if browser.entries.isEmpty && !browser.isLoading {
            ContentUnavailableView("This Folder Is Empty", systemImage: "folder",
                                   description: Text("Drag files here to upload."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fileTable
                .overlay { if browser.isLoading { ProgressView() } }
        }
    }

    private var fileTable: some View {
        Table(browser.entries, selection: $browser.selection) {
            TableColumn("Name") { node in
                let row = HStack(spacing: 6) {
                    FileIcon(node: node).frame(width: 18, height: 18)
                    Text(node.name).lineLimit(1)
                }
                // Files are draggable out to Finder (= download); folders are not.
                if !node.isDirectory, let transport = browser.transport {
                    row.draggable(FileDrag(node: node, transport: transport))
                } else {
                    row
                }
            }
            TableColumn("Size") { node in
                Text(node.isDirectory ? "—" : Format.size(node.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Kind") { node in
                Text(Format.kind(for: node)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Date Modified") { node in
                Text(Format.date(node.modifiedDate)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menuItems(for: ids)
        } primaryAction: { ids in
            performPrimaryAction(for: ids)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if browser.canGoUp {
            ToolbarItem(placement: .navigation) {
                Button { browser.goUp() } label: { Image(systemName: "chevron.backward") }
                    .help("Back")
            }
        }
        ToolbarItemGroup {
            Button { newFolderName = String(localized: "untitled folder"); newFolderPresented = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder")

            Button(role: .destructive) { browser.delete(browser.selection) } label: {
                Image(systemName: "trash")
            }
            .disabled(browser.selection.isEmpty)
            .help("Delete Selected")

            if !transfers.items.isEmpty {
                Button { showTransfers.toggle() } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .symbolVariant(transfers.activeCount > 0 ? .fill : .none)
                }
                .help("Transfers")
                .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                    TransferQueueView(transfers: transfers)
                }
            }
        }
    }

    // MARK: Menu / actions

    @ViewBuilder
    private func menuItems(for ids: Set<String>) -> some View {
        let nodes = browser.entries.filter { ids.contains($0.id) }
        if nodes.count == 1, let node = nodes.first, node.isDirectory {
            Button("Open") { browser.enter(node) }
        }
        let files = nodes.filter { !$0.isDirectory }
        if !files.isEmpty {
            Button("Download to Downloads") { download(nodes: files) }
        }
        if nodes.count == 1, let node = nodes.first {
            Button("Rename…") { renameName = node.name; renameTarget = node }
        }
        if !nodes.isEmpty {
            Divider()
            Button("Delete", role: .destructive) { browser.delete(Set(nodes.map(\.id))) }
        }
    }

    private func performPrimaryAction(for ids: Set<String>) {
        guard ids.count == 1, let node = browser.entries.first(where: { $0.id == ids.first }) else { return }
        if node.isDirectory {
            browser.enter(node)
        } else {
            download(nodes: [node])
        }
    }

    private func download(nodes: [FileNode]) {
        guard let transport = browser.transport, !nodes.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        for node in nodes {
            transfers.download(node, from: transport, to: downloads)
        }
        showTransfers = true
    }

    private func handleDrop(_ urls: [URL]) {
        guard let transport = browser.transport, let storageID = browser.storageID else { return }
        for url in urls where !url.hasDirectoryPath {
            transfers.upload(url, toParent: browser.currentParentID, storage: storageID, via: transport)
        }
        if !urls.isEmpty { showTransfers = true }
    }
}

/// A device file made draggable to Finder. The export handler streams the file from the
/// device into a temp location on demand, so dropping it into Finder downloads it there.
struct FileDrag: Transferable {
    let node: FileNode
    let transport: any DeviceTransport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { drag in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(drag.node.name)
            try await drag.transport.download(drag.node.id, to: url) { _ in }
            return SentTransferredFile(url)
        }
    }
}

/// Small reusable sheet for entering a single name (new folder / rename).
private struct NameSheet: View {
    let title: LocalizedStringKey
    let label: LocalizedStringKey
    @Binding var text: String
    let confirmTitle: LocalizedStringKey
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func confirm() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm()
        dismiss()
    }
}
