import Foundation
import UniformTypeIdentifiers

/// A Time Machine destination image (sparsebundle / backupbundle) on some volume.
struct BackupSource: Identifiable, Hashable, Codable {
    var path: String
    /// e.g. `smb://user@server/share` — used to reconnect when the share isn't mounted.
    var serverURL: String?
    var modelID: String?
    /// The disk image's UUID (bundle Info.plist), remembered so the cache can be used even
    /// before the share holding the bundle is mounted.
    var imageUUID: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isReachable: Bool { FileManager.default.fileExists(atPath: path) }

    var symbolName: String {
        guard let modelID else { return "externaldrive.badge.timemachine" }
        if modelID.contains("Book") { return "laptopcomputer" }
        if modelID.hasPrefix("iMac") { return "desktopcomputer" }
        if modelID.hasPrefix("Macmini") { return "macmini" }
        if modelID.hasPrefix("MacPro") { return "macpro.gen3" }
        if modelID.hasPrefix("Mac") { return "macstudio" }
        return "desktopcomputer"
    }
}

struct Snapshot: Identifiable, Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        /// An APFS snapshot (macOS 11+ Time Machine) on the given volume device.
        case apfs(device: String, name: String)
        /// A dated folder inside a legacy HFS+ `Backups.backupdb`.
        case directory(URL)
    }

    let id: String
    let date: Date
    let storage: Storage
    /// Immutable identity for caching: "<APFS snapshot UUID>-<transaction id>". A snapshot's
    /// contents can never change, so data cached under this key never goes stale. Nil for legacy
    /// HFS+ backups, which aren't cached.
    var cacheKey: String?

    /// Parses `2026-01-18-112734` out of `com.apple.TimeMachine.2026-01-18-112734.backup`.
    ///
    /// Time Machine names backups in the backed-up Mac's local time. We interpret that in this Mac's
    /// time zone (usually the same) via `Calendar`, which — unlike `DateFormatter` — still yields a
    /// date for wall-clock times skipped by a daylight-saving change instead of dropping the backup.
    static func date(fromName name: String) -> Date? {
        guard let match = name.firstMatch(of: #/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})/#) else { return nil }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = Int(match.4)
        components.minute = Int(match.5)
        components.second = Int(match.6)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

struct FileItem: Identifiable, Hashable {
    /// The path relative to the snapshot root, joined with "/". Stable across snapshots.
    let id: String
    let url: URL
    let relativePath: [String]
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?
    let contentType: UTType?
    /// The file's inode; used to cross-check cached listings against live ones.
    let inode: UInt64?
    let isHidden: Bool

    var isFolderLike: Bool { isDirectory && !isPackage }
    var kind: String {
        if isSymlink { return "Alias" }
        if isFolderLike { return "Folder" }
        return contentType?.localizedDescription ?? "Document"
    }
    var parentPath: String { relativePath.dropLast().joined(separator: "/") }

    // Non-optional sort keys for Table.
    var sizeKey: Int64 { isFolderLike ? -1 : (size ?? -1) }
    var dateKey: Date { modified ?? .distantPast }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .contentTypeKey, .fileIdentifierKey,
    ]

    init(url: URL, relativePath: [String]) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.id = relativePath.joined(separator: "/")
        self.url = url
        self.relativePath = relativePath
        self.name = relativePath.last ?? url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.isPackage = values?.isPackage ?? false
        self.isSymlink = values?.isSymbolicLink ?? false
        self.size = values?.fileSize.map(Int64.init)
        self.modified = values?.contentModificationDate
        self.contentType = values?.contentType
        self.inode = values?.fileIdentifier
        self.isHidden = values?.isHidden ?? relativePath.last?.hasPrefix(".") ?? false
    }

    /// Rebuilds an item from the cache. `root` is the live snapshot root if connected, else a
    /// placeholder — file access is disabled while only cached data is shown.
    init(cached: SnapshotCache.Item, parent: [String], root: URL) {
        let relativePath = parent + [cached.name]
        self.id = relativePath.joined(separator: "/")
        self.url = relativePath.reduce(root) { $0.appendingPathComponent($1) }
        self.relativePath = relativePath
        self.name = cached.name
        self.isDirectory = cached.isDirectory
        self.isPackage = cached.isPackage
        self.isSymlink = cached.isSymlink
        self.size = cached.size
        self.modified = cached.modified
        self.contentType = cached.contentType.flatMap { UTType($0) }
        self.inode = cached.inode
        self.isHidden = cached.isHidden
    }

    /// Lists a directory. Blocking; call off the main thread.
    static func list(directory: URL, relativePath: [String], showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.map { FileItem(url: $0, relativePath: relativePath + [$0.lastPathComponent]) }
    }
}

/// A sidebar shortcut into the backup ("Favorites" in Finder terms).
struct Location: Identifiable, Hashable {
    let name: String
    let symbol: String
    let path: [String]
    var id: String { path.joined(separator: "/") }

    /// Finds the interesting places inside a snapshot root (`…/2026-01-18-112734.backup`).
    static func discover(in root: URL, machineName: String) -> [Location] {
        let fm = FileManager.default
        func subdirectories(_ url: URL) -> [String] {
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return names
                .filter { !$0.hasPrefix(".") }
                .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: url.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        var homes: [Location] = []
        var volumes: [Location] = []
        for volume in subdirectories(root) {
            let volumeURL = root.appendingPathComponent(volume)
            volumes.append(Location(name: volume, symbol: "internaldrive", path: [volume]))
            for user in subdirectories(volumeURL.appendingPathComponent("Users")) where user != "Shared" && user != "Guest" {
                let home = [volume, "Users", user]
                homes.append(Location(name: user, symbol: "house", path: home))
                let homeURL = volumeURL.appendingPathComponent("Users").appendingPathComponent(user)
                for (folder, symbol) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"), ("Pictures", "photo")]
                where fm.fileExists(atPath: homeURL.appendingPathComponent(folder).path) {
                    homes.append(Location(name: folder, symbol: symbol, path: home + [folder]))
                }
            }
            if fm.fileExists(atPath: volumeURL.appendingPathComponent("Applications").path) {
                volumes.append(Location(name: "Applications", symbol: "square.grid.2x2", path: [volume, "Applications"]))
            }
        }
        return [Location(name: machineName, symbol: "clock.arrow.circlepath", path: [])] + homes + volumes
    }
}

/// How the selected item in a given snapshot relates to the next-older snapshot.
enum VersionMark: Equatable {
    case absent
    case newVersion
    case unchanged
    /// The snapshot couldn't be read (e.g. it failed to mount), so we don't know.
    case unknown
}
