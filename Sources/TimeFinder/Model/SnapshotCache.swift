import Foundation
import UniformTypeIdentifiers

/// A persistent cache of metadata read from Time Machine snapshots: folder listings and the
/// fingerprints used for version history. Never file contents.
///
/// Correctness rests on one fact: an APFS snapshot never changes. Every entry is keyed by the
/// snapshot's UUID *and* transaction ID (`Snapshot.cacheKey`), so an entry is either exactly what
/// the snapshot contains or — if something went wrong — gets caught by the live cross-checks in
/// `BrowserModel` and thrown away. The only mutable fact, *which* snapshots exist, is stored in the
/// index purely as a provisional hint and is always replaced by the live list once connected.
///
/// Layout: `~/Library/Caches/<bundle id>/Backups/<image uuid>/index.json` and `<cacheKey>.json`,
/// created with user-only permissions. Files carry a schema version; anything unreadable is ignored.
final class SnapshotCache: @unchecked Sendable {
    static let schema = 1
    static let enabledKey = "cacheEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var rootDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TimeFinder", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// Deletes every cached backup.
    static func clearAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    static func totalSize() -> Int64 {
        let files = FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Stored types

    struct Item: Codable, Hashable {
        let name: String
        let isDirectory: Bool
        let isPackage: Bool
        let isSymlink: Bool
        let size: Int64?
        let modified: Date?
        let contentType: String?
        let inode: UInt64?
        let isHidden: Bool
    }

    /// What a path looked like in one snapshot (for version history).
    enum Probe: Codable, Equatable {
        case present(inode: UInt64, size: Int64, modified: Date?)
        case missing
    }

    /// The last-known shape of a backup, shown provisionally while connecting.
    struct Index: Codable {
        struct Entry: Codable {
            let id: String
            let date: Date
            let cacheKey: String
        }
        var schema = SnapshotCache.schema
        /// The bundle this index was written for; a copied bundle (same UUID) doesn't use it.
        let bundlePath: String
        let machineName: String
        let verifiedAt: Date
        let snapshots: [Entry]
        let locations: [CodableLocation]
    }

    struct CodableLocation: Codable {
        let name: String
        let symbol: String
        let path: [String]
    }

    private struct Record: Codable {
        var schema = SnapshotCache.schema
        var listings: [String: [Item]] = [:]
        var probes: [String: Probe] = [:]
    }

    // MARK: Instance

    private let directory: URL
    private let lock = NSLock()
    /// Serialises file writes with deletions, so a flush can't write a record back after it
    /// was invalidated, pruned or cleared.
    private let ioLock = NSLock()
    private var records: [String: Record] = [:]
    private var dirty: Set<String> = []
    /// Bumped whenever a key's record is discarded; a flush only writes the generation it read.
    private var generations: [String: Int] = [:]
    private var flushScheduled = false
    /// Set by "Clear Cache": this instance must never write again.
    private var isRetired = false

    func retire() {
        lock.lock()
        isRetired = true
        records = [:]
        dirty = []
        lock.unlock()
    }
    private let writer = DispatchQueue(label: "TimeFinder.SnapshotCache", qos: .utility)

    /// A cache for one backup image, identified by the image's own UUID (from the bundle's
    /// Info.plist; see `imageUUID(of:)`). Nil if caching is off.
    init?(imageUUID: String?) {
        guard Self.isEnabled, let uuid = imageUUID?.lowercased(),
              uuid.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil else { return nil }
        directory = Self.rootDirectory.appendingPathComponent(uuid, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Reads the image UUID from the bundle (blocking — over SMB this is a network read).
    static func imageUUID(of bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let uuid = plist["uuid"] as? String,
              uuid.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil else { return nil }
        return uuid.lowercased()
    }

    // MARK: Index

    func index() -> Index? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let index = try? Self.decoder.decode(Index.self, from: data),
              index.schema == Self.schema else { return nil }
        return index
    }

    func storeIndex(_ index: Index) {
        write(index, to: directory.appendingPathComponent("index.json"))
    }

    /// Drops records of snapshots that no longer exist (Time Machine thinned them out).
    func prune(keeping keys: Set<String>) {
        ioLock.lock()
        defer { ioLock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        lock.lock()
        defer { lock.unlock() }
        for file in files where file.hasSuffix(".json") && file != "index.json" {
            let key = String(file.dropLast(".json".count))
            guard !keys.contains(key) else { continue }
            records[key] = nil
            dirty.remove(key)
            generations[key, default: 0] += 1
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    // MARK: Listings and probes

    func listing(_ key: String, path: [String]) -> [Item]? {
        lock.lock()
        defer { lock.unlock() }
        return record(key).listings[Self.pathKey(path)]
    }

    func storeListing(_ items: [Item], _ key: String, path: [String]) {
        update(key) { record in
            guard record.listings[Self.pathKey(path)] != items else { return false }
            record.listings[Self.pathKey(path)] = items
            return true
        }
    }

    func probe(_ key: String, path: [String]) -> Probe? {
        lock.lock()
        defer { lock.unlock() }
        return record(key).probes[Self.pathKey(path)]
    }

    func storeProbe(_ probe: Probe, _ key: String, path: [String]) {
        update(key) { record in
            guard record.probes[Self.pathKey(path)] != probe else { return false }
            record.probes[Self.pathKey(path)] = probe
            return true
        }
    }

    /// Forgets everything about one snapshot — used when a live cross-check disagrees with the cache.
    func invalidate(_ key: String) {
        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock()
        records[key] = Record()
        dirty.remove(key)
        generations[key, default: 0] += 1
        lock.unlock()
        try? FileManager.default.removeItem(at: file(for: key))
    }

    // MARK: Storage

    private static func pathKey(_ path: [String]) -> String { path.joined(separator: "/") }

    private func file(for key: String) -> URL {
        // Keys are "<UUID>-<xid>"; keep file names safe regardless.
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent(safe + ".json")
    }

    /// Must be called with `lock` held.
    private func record(_ key: String) -> Record {
        if let cached = records[key] { return cached }
        var loaded = Record()
        if let data = try? Data(contentsOf: file(for: key)),
           let decoded = try? Self.decoder.decode(Record.self, from: data), decoded.schema == Self.schema {
            loaded = decoded
        }
        records[key] = loaded
        return loaded
    }

    /// Applies `change` (which returns whether it changed anything) and schedules a write.
    private func update(_ key: String, _ change: (inout Record) -> Bool) {
        lock.lock()
        guard !isRetired else { lock.unlock(); return }
        var record = record(key)
        guard change(&record) else { lock.unlock(); return }
        records[key] = record
        dirty.insert(key)
        let shouldSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if shouldSchedule {
            // Strong self: pending writes must not be lost if the model lets go of us first.
            writer.asyncAfter(deadline: .now() + 2) { self.flush() }
        }
    }

    /// Writes changed records to disk (debounced). Also called when a session closes.
    func flush() {
        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock()
        let pending = dirty.compactMap { key in records[key].map { (key, $0, generations[key, default: 0]) } }
        dirty.removeAll()
        flushScheduled = false
        lock.unlock()
        for (key, record, generation) in pending {
            lock.lock()
            let current = !isRetired && generations[key, default: 0] == generation
            lock.unlock()
            if current { write(record, to: file(for: key)) }
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

extension SnapshotCache.Item {
    init(_ item: FileItem) {
        self.init(name: item.name, isDirectory: item.isDirectory, isPackage: item.isPackage, isSymlink: item.isSymlink,
                  size: item.size, modified: item.modified, contentType: item.contentType?.identifier, inode: item.inode,
                  isHidden: item.isHidden)
    }
}
