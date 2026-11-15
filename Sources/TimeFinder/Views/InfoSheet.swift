import AppKit
import SwiftUI

/// Finder's Get Info (⌘I), for an item as it was in the current backup.
struct InfoSheet: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: FileItem

    @State private var created: Date?
    @State private var folderTotal: FolderTotal?
    @State private var isCalculating = false

    struct FolderTotal: Sendable {
        var bytes: Int64 = 0
        var items = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                // Type-based icon: icon services can't read inside Time Machine snapshots.
                Image(nsImage: IconCache.shared.icon(for: item))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(sizeSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 7) {
                row("Kind:", item.relativePath.isEmpty ? "Backup" : item.kind)
                row("Size:", sizeDetail)
                row("Where:", whereText)
                row("Created:", created.map(Self.format) ?? "--")
                row("Modified:", item.modified.map(Self.format) ?? "--")
                if let snapshot = model.currentSnapshot {
                    row("Backed up:", Self.format(snapshot.date))
                }
                if model.versionsFor == item.relativePath, !model.isScanningVersions, model.versionCount > 0 {
                    row("Versions:", "\(model.versionCount) in \(model.snapshots.count) backups")
                }
            }
            .font(.callout)

            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer()
                if !item.relativePath.isEmpty {
                    Button("Restore To…") {
                        dismiss()
                        model.chooseRestoreDestination(for: [item.id])
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: item.id) { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayName: String {
        item.relativePath.isEmpty ? model.machineName : item.name
    }

    private var whereText: String {
        ([model.machineName] + item.relativePath.dropLast()).joined(separator: " › ")
    }

    private var sizeSummary: String {
        if item.isFolderLike || item.isPackage {
            guard let folderTotal else { return "Calculating size…" }
            return "\(Self.bytes(folderTotal.bytes)) · \(folderTotal.items.formatted()) items" + (isCalculating ? "…" : "")
        }
        return Self.bytes(item.size ?? 0)
    }

    private var sizeDetail: String {
        if item.isFolderLike || item.isPackage {
            guard let folderTotal else { return "Calculating…" }
            let detail = "\(Self.bytes(folderTotal.bytes)) (\(folderTotal.bytes.formatted()) bytes) for \(folderTotal.items.formatted()) items"
            return isCalculating ? detail + " so far…" : detail
        }
        let size = item.size ?? 0
        return "\(Self.bytes(size)) (\(size.formatted()) bytes)"
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    // MARK: Loading

    private func load() async {
        let url = item.url
        created = await Task.detached { (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate }.value
        guard item.isFolderLike || item.isPackage else { return }

        isCalculating = true
        for await total in Self.measure(url) {
            folderTotal = total
        }
        isCalculating = false
    }

    /// Totals a folder's contents, yielding running totals so big folders show progress.
    /// Cancelled automatically when the sheet closes.
    private static func measure(_ url: URL) -> AsyncStream<FolderTotal> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .utility) {
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                var total = FolderTotal()
                var lastYield = Date()
                continuation.yield(total)
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
                while let file = enumerator?.nextObject() as? URL {
                    if Task.isCancelled { break }
                    total.items += 1
                    if let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                        total.bytes += Int64(values.fileSize ?? 0)
                    }
                    if Date().timeIntervalSince(lastYield) > 0.2 {
                        continuation.yield(total)
                        lastYield = Date()
                    }
                }
                continuation.yield(total)
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}

/// Finder's Go to Folder (⇧⌘G).
struct GoToFolderSheet: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastGoToFolder") private var text = ""
    @State private var notFound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder")
                .font(.headline)
            TextField("Path", text: $text, prompt: Text("~/Documents or /Users/name/Desktop"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
                .onChange(of: text) { notFound = false }
            Text(notFound ? "The folder can’t be found in this backup." : "Paths are as they were on \(model.machineName). Case doesn’t matter.")
                .font(.caption)
                .foregroundStyle(notFound ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func go() {
        if model.goToFolder(text) {
            dismiss()
        } else {
            notFound = true
            NSSound.beep()
        }
    }
}
