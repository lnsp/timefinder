import Foundation

enum BackupError: LocalizedError {
    case needsPassword
    case needsFullDiskAccess
    case noVolumes
    case noSnapshots
    case closed

    var errorDescription: String? {
        switch self {
        case .needsPassword: "This backup is encrypted. Enter the backup password to open it."
        case .needsFullDiskAccess: "macOS only lets apps with Full Disk Access open Time Machine backups. Turn on TimeFinder in System Settings › Privacy & Security › Full Disk Access, then try again."
        case .noVolumes: "The disk image doesn't contain a mountable volume."
        case .noSnapshots: "No Time Machine backups were found in this disk image."
        case .closed: "The backup was closed."
        }
    }
}

/// An opened Time Machine backup: the image is attached read-only, its volume mounted
/// (nobrowse, so it stays out of Finder), and snapshots are mounted lazily on demand.
///
/// All methods block and must be called off the main thread. Thread-safe.
///
/// Note: while the image is attached, the bundle is locked, so the Mac that owns the backup
/// can't back up to it. Sessions should be closed when not in use.
final class BackupSession: @unchecked Sendable {
    let source: BackupSource
    let machineName: String
    /// Newest first.
    let snapshots: [Snapshot]

    private let lock = NSLock()
    private let mountBase: URL
    private let image: AttachedImage?
    /// Where each APFS volume (by device) is mounted; snapshots are mounted relative to it.
    private let volumeMountPoints: [String: String]
    private var ownedMountPoints: [String]     // volume mounts we're responsible for (unmounted last)
    private var snapshotRoots: [String: URL] = [:]
    private var ownedSnapshotMounts: [String] = []
    private var isClosed = false

    /// An image attachment this session is responsible for detaching.
    struct AttachedImage {
        let device: String
        /// Adopted leftovers are detached politely, never with `-force`.
        let adopted: Bool
    }

    private static let apfsVolumeHint = "41504653-0000-11AA-AA11-00306543ECAC"
    private static let hfsVolumeHints: Set<String> = ["48465300-0000-11AA-AA11-00306543ECAC", "Apple_HFS", "Apple_HFSX"]
    private static let snapshotPrefix = "com.apple.TimeMachine."

    /// All mount points this app creates live below this folder, in a per-session subfolder.
    /// Canonical (realpath) form, matching what the kernel reports for mounts: `/private/var/…`.
    /// (`resolvingSymlinksInPath()` would strip `/private` and never match the mount table.)
    static let mountRoot: URL = {
        let temp = FileManager.default.temporaryDirectory.path
        let real = realpath(temp, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? temp
        return URL(fileURLWithPath: real).appendingPathComponent("TimeFinder", isDirectory: true)
    }()

    /// Serialises opening and closing so a new session never races a closing one over the
    /// same image (e.g. Eject immediately followed by reopening).
    private static let lifecycleLock = NSLock()

    private init(source: BackupSource, machineName: String, snapshots: [Snapshot], mountBase: URL,
                 image: AttachedImage?, volumeMountPoints: [String: String], ownedMountPoints: [String],
                 ownedSnapshotMounts: [String]) {
        self.source = source
        self.machineName = machineName
        self.snapshots = snapshots
        self.mountBase = mountBase
        self.image = image
        self.volumeMountPoints = volumeMountPoints
        self.ownedMountPoints = ownedMountPoints
        self.ownedSnapshotMounts = ownedSnapshotMounts
    }

    // MARK: Opening

    static func open(_ source: BackupSource, password: String?, progress: @escaping @Sendable (String) -> Void) throws -> BackupSession {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let fm = FileManager.default
        // Sweep empty mount folders left by runs that crashed (rmdir only: never deletes content,
        // and fails harmlessly on anything still mounted).
        for leftover in (try? fm.contentsOfDirectory(atPath: mountRoot.path)) ?? [] {
            removeEmptyDirectories(mountRoot.appendingPathComponent(leftover))
        }
        let mountBase = mountRoot.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        try fm.createDirectory(at: mountBase, withIntermediateDirectories: true)

        progress("Attaching \(source.url.lastPathComponent)…")
        var image: AttachedImage?
        var ownedMounts: [String] = []
        var ownedSnapshotMounts: [String] = []
        let entities: [[String: Any]]
        if let existing = try attachedImage(at: source.url) {
            entities = existing.entities
            if let leftover = adoptableLeftover(existing) {
                // A read-only attachment that only our own (crashed) runs have mounted: take it over so
                // it gets cleaned up — a lingering attachment keeps the bundle locked.
                image = AttachedImage(device: leftover.device, adopted: true)
                ownedMounts = leftover.volumeMounts
                ownedSnapshotMounts = leftover.snapshotMounts
            }
        } else {
            entities = try attach(source.url.path, password: password)
            image = (entities.first?["dev-entry"] as? String).map { AttachedImage(device: $0, adopted: false) }
        }

        var cleanupOnFailure = true
        defer {
            if cleanupOnFailure {
                for mount in (ownedSnapshotMounts + ownedMounts).reversed() { unmount(mount) }
                if let image { detach(image) }
                removeEmptyDirectories(mountBase)
            }
        }

        let volumeDevices = entities.compactMap { entity -> (device: String, isAPFS: Bool)? in
            guard let device = entity["dev-entry"] as? String, let hint = entity["content-hint"] as? String else { return nil }
            if hint == apfsVolumeHint { return (device, true) }
            if hfsVolumeHints.contains(hint) { return (device, false) }
            return nil
        }
        guard !volumeDevices.isEmpty else { throw BackupError.noVolumes }

        progress("Reading backup history…")
        var best: (snapshots: [Snapshot], machine: String)?
        var volumeMountPoints: [String: String] = [:]
        for (device, isAPFS) in volumeDevices {
            let info = try Shell.plist("/usr/sbin/diskutil", ["info", "-plist", device], timeout: 60)
            var mountPoint = (info["MountPoint"] as? String) ?? ""
            if mountPoint.isEmpty {
                let dir = mountBase.appendingPathComponent("volume-\(URL(fileURLWithPath: device).lastPathComponent)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try mountVolume(isAPFS ? "/sbin/mount_apfs" : "/sbin/mount_hfs",
                          ["-o", "rdonly,nobrowse,noowners", device, dir.path])
                mountPoint = dir.path
                ownedMounts.append(dir.path)
            }
            volumeMountPoints[device] = mountPoint

            let volumeName = (info["VolumeName"] as? String).map(machineName(fromVolumeName:)) ?? source.name
            var candidates: [(snapshots: [Snapshot], machine: String)] = []
            if isAPFS {
                candidates.append((apfsSnapshots(device: device), volumeName))
            }
            candidates += try legacyMachines(volume: URL(fileURLWithPath: mountPoint))
            for candidate in candidates where candidate.snapshots.count > (best?.snapshots.count ?? 0) {
                best = candidate
            }
        }
        guard let best else { throw BackupError.noSnapshots }

        cleanupOnFailure = false
        return BackupSession(
            source: source,
            machineName: best.machine,
            snapshots: best.snapshots.sorted { $0.date > $1.date },
            mountBase: mountBase,
            image: image,
            volumeMountPoints: volumeMountPoints,
            ownedMountPoints: ownedMounts,
            ownedSnapshotMounts: ownedSnapshotMounts
        )
    }

    /// "Backups of MacBook Pro (2)" → "MacBook Pro".
    private static func machineName(fromVolumeName name: String) -> String {
        var name = name
        if name.hasPrefix("Backups of ") { name = String(name.dropFirst("Backups of ".count)) }
        if let range = name.range(of: #" \(\d+\)$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name
    }

    private struct ExistingImage {
        let entities: [[String: Any]]
        let writeable: Bool
    }

    /// Finds the image in `hdiutil info`, comparing files by identity (device + inode) rather than
    /// by path, so differences in case or symlinks don't make us attach a second time.
    private static func attachedImage(at url: URL) throws -> ExistingImage? {
        guard let wanted = fileIdentity(url.path) else { return nil }
        let info = try Shell.plist("/usr/bin/hdiutil", ["info", "-plist"], timeout: 60)
        let images = info["images"] as? [[String: Any]] ?? []
        guard let match = images.first(where: { ($0["image-path"] as? String).flatMap(fileIdentity) == wanted }) else { return nil }
        return ExistingImage(
            entities: match["system-entities"] as? [[String: Any]] ?? [],
            writeable: match["writeable"] as? Bool ?? true
        )
    }

    private static func fileIdentity(_ path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    /// An attachment counts as a leftover of ours only if it's read-only and nothing outside our
    /// own mount folder has any of its volumes or snapshots mounted. Anything else (Time Machine,
    /// Disk Utility, the user) is left alone.
    private static func adoptableLeftover(_ image: ExistingImage) -> (device: String, volumeMounts: [String], snapshotMounts: [String])? {
        guard !image.writeable, let device = image.entities.first?["dev-entry"] as? String else { return nil }
        let devices = Set(image.entities.compactMap { $0["dev-entry"] as? String })
        let rootPrefix = mountRoot.path + "/"
        var volumeMounts: [String] = []
        var snapshotMounts: [String] = []
        for entry in MountTable.entries() {
            let isSnapshot = entry.from.contains("@")
            let entryDevice = isSnapshot ? String(entry.from.split(separator: "@").last ?? "") : entry.from
            guard devices.contains(entryDevice) else { continue }
            guard entry.path.hasPrefix(rootPrefix) else { return nil }   // mounted by someone else
            if isSnapshot { snapshotMounts.append(entry.path) } else { volumeMounts.append(entry.path) }
        }
        return (device, volumeMounts, snapshotMounts)
    }

    private static func attach(_ path: String, password: String?) throws -> [[String: Any]] {
        var arguments = ["attach", "-plist", "-readonly", "-nomount", "-noverify", "-noautofsck"]
        var input: Data?
        if let password {
            arguments.append("-stdinpass")
            input = Data(password.utf8) + [0]
        }
        arguments.append(path)
        // Without a password, hdiutil uses the keychain or shows the system's password dialog, which
        // can sit there while the user decides — hence the long timeout. Reading the bundle over SMB
        // can also take a minute on its own.
        let result = try Shell.run("/usr/bin/hdiutil", arguments, input: input, check: false, timeout: 600)
        guard result.status == 0 else {
            // "Authentication error" is strerror(EAUTH), which isn't localized.
            if result.stderr.localizedCaseInsensitiveContains("authentication") { throw BackupError.needsPassword }
            throw ShellError(command: "hdiutil attach", result: result)
        }
        let plist = try Shell.parsePlist(result.stdout)
        return plist["system-entities"] as? [[String: Any]] ?? []
    }

    private static func apfsSnapshots(device: String) -> [Snapshot] {
        guard let plist = try? Shell.plist("/usr/sbin/diskutil", ["apfs", "listSnapshots", "-plist", device], timeout: 60) else { return [] }
        let entries = plist["Snapshots"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let name = entry["SnapshotName"] as? String,
                  name.hasPrefix(snapshotPrefix), name.hasSuffix(".backup"),
                  let date = Snapshot.date(fromName: name) else { return nil }
            return Snapshot(id: name, date: date, storage: .apfs(device: device, name: name))
        }
    }

    /// HFS+-era layout: `Backups.backupdb/<machine>/<yyyy-MM-dd-HHmmss>/`, possibly several machines.
    /// Each machine becomes its own candidate timeline.
    private static func legacyMachines(volume: URL) throws -> [(snapshots: [Snapshot], machine: String)] {
        let fm = FileManager.default
        let db = volume.appendingPathComponent("Backups.backupdb")
        guard fm.fileExists(atPath: db.path) else { return [] }
        let machines: [String]
        do {
            machines = try fm.contentsOfDirectory(atPath: db.path)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw BackupError.needsFullDiskAccess   // macOS protects backup folders behind Full Disk Access
        }
        return machines.filter { !$0.hasPrefix(".") }.map { machine in
            let dir = db.appendingPathComponent(machine)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let snapshots = names.compactMap { name -> Snapshot? in
                // Only exact `yyyy-MM-dd-HHmmss` folders: skips `Latest`, `*.inProgress`, `*.inprogress`.
                guard name.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil,
                      let date = Snapshot.date(fromName: name) else { return nil }
                return Snapshot(id: "\(machine)/\(name)", date: date, storage: .directory(dir.appendingPathComponent(name)))
            }
            return (snapshots, machine)
        }
    }

    // MARK: Snapshots

    /// Returns the browsable root of a snapshot, mounting it if needed.
    func root(for snapshot: Snapshot) throws -> URL {
        switch snapshot.storage {
        case .directory(let url):
            return url
        case .apfs(let device, let name):
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { throw BackupError.closed }
            let source = "\(name)@\(device)"

            if let cached = snapshotRoots[snapshot.id] {
                // Check it's still *mounted* — an empty mount-point folder would still "exist".
                if MountTable.source(of: cached.path) == source { return cached }
                snapshotRoots[snapshot.id] = nil
            }

            let mountPoint: URL
            if let existing = MountTable.entries().first(where: { $0.from == source }) {
                mountPoint = URL(fileURLWithPath: existing.path)
                // Ours (e.g. from a crashed earlier run) if it's under our folder; otherwise borrowed.
                if existing.path.hasPrefix(Self.mountRoot.path + "/"), !ownedSnapshotMounts.contains(existing.path) {
                    ownedSnapshotMounts.append(existing.path)
                }
            } else {
                mountPoint = mountBase.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
                // Documented form: `-s <snapshot> <mounted base volume> <directory>`.
                let base = volumeMountPoints[device] ?? device
                try Self.mountVolume("/sbin/mount_apfs", ["-o", "rdonly,nobrowse,noowners", "-s", name, base, mountPoint.path])
                if !ownedSnapshotMounts.contains(mountPoint.path) { ownedSnapshotMounts.append(mountPoint.path) }
            }

            // Inside the snapshot, the backup lives in `<yyyy-MM-dd-HHmmss>.backup/`.
            let inner = mountPoint.appendingPathComponent(String(name.dropFirst(Self.snapshotPrefix.count)))
            let root = FileManager.default.fileExists(atPath: inner.path) ? inner : mountPoint
            snapshotRoots[snapshot.id] = root
            return root
        }
    }

    /// True if `path` is inside one of this session's snapshot mounts (e.g. a URL on the pasteboard).
    func contains(_ path: String) -> Bool {
        path.hasPrefix(mountBase.path + "/")
    }

    // MARK: Closing

    /// Unmounts everything we mounted and detaches the image if we're responsible for it.
    func close() {
        Self.lifecycleLock.lock()
        defer { Self.lifecycleLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        // Fast path: detaching our image unmounts its volume and snapshots in one go, which also
        // keeps quitting quick. Otherwise (busy, or the image isn't ours) unmount one by one.
        if let image, (try? Shell.run("/usr/bin/hdiutil", ["detach", image.device], timeout: 60)) != nil {
            // done
        } else {
            for mount in ownedSnapshotMounts.reversed() { Self.unmount(mount) }
            for mount in ownedMountPoints.reversed() { Self.unmount(mount) }
            if let image { Self.detach(image) }
        }
        Self.removeEmptyDirectories(mountBase)
        ownedSnapshotMounts = []
        ownedMountPoints = []
        snapshotRoots = [:]
    }

    /// Runs mount_apfs / mount_hfs, translating the TCC denial (EPERM) into an actionable error:
    /// mounting a Time Machine volume requires Full Disk Access.
    private static func mountVolume(_ tool: String, _ arguments: [String]) throws {
        do {
            try Shell.run(tool, arguments, timeout: 90)
        } catch let error as ShellError where error.result.status == 77 || error.result.stderr.contains("Operation not permitted") {
            throw BackupError.needsFullDiskAccess
        }
    }

    private static func unmount(_ path: String) {
        if (try? Shell.run("/sbin/umount", [path], timeout: 30)) == nil {
            _ = try? Shell.run("/usr/sbin/diskutil", ["unmount", "force", path], timeout: 30)
        }
    }

    /// Removes our mount-point folders with rmdir only, so a mount that failed to
    /// unmount is never traversed and deleted.
    private static func removeEmptyDirectories(_ base: URL) {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for child in children { rmdir(base.appendingPathComponent(child).path) }
        rmdir(base.path)
    }

    private static func detach(_ image: AttachedImage) {
        if (try? Shell.run("/usr/bin/hdiutil", ["detach", image.device], timeout: 60)) == nil, !image.adopted {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", image.device], timeout: 60)
        }
    }
}
