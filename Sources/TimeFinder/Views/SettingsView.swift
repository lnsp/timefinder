import SwiftUI

struct SettingsView: View {
    @Environment(BrowserModel.self) private var model
    @AppStorage(SnapshotCache.enabledKey) private var cacheEnabled = true
    @State private var cacheSize: Int64?

    var body: some View {
        Form {
            Section {
                Toggle("Cache backup listings", isOn: $cacheEnabled)
                Text("Remembers folder listings and version fingerprints of backups you’ve browsed, so they show up instantly next time — even while the backup is still connecting. Only names and attributes are stored, never file contents. Cached data is checked against the live backup and is never shown as current.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The cache contains file names from your backups, including encrypted ones, and is stored in your Library’s Caches folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Cache size") {
                    Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        .monospacedDigit()
                }
                Button("Clear Cache") {
                    model.clearCache()
                    cacheSize = SnapshotCache.totalSize()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { cacheSize = await Task.detached { SnapshotCache.totalSize() }.value }
        .onChange(of: cacheEnabled) { _, enabled in
            if !enabled {
                model.clearCache()
                cacheSize = SnapshotCache.totalSize()
            }
        }
    }
}
