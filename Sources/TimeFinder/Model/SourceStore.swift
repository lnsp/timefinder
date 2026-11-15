import Foundation
import NetFS

/// Finds Time Machine images on mounted volumes and remembers them (with their server
/// URL) so they can be reconnected later when the share isn't mounted.
enum SourceStore {
    private static let defaultsKey = "rememberedSources"
    private static let imageExtensions: Set<String> = ["sparsebundle", "backupbundle"]

    static func remembered() -> [BackupSource] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let sources = try? JSONDecoder().decode([BackupSource].self, from: data) else { return [] }
        return sources
    }

    static func save(_ sources: [BackupSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Scans the top level of every mounted volume (`/Volumes/*/*.sparsebundle`) for backup images. Blocking.
    static func discover() -> [BackupSource] {
        let fm = FileManager.default
        let volumesDir = URL(fileURLWithPath: "/Volumes")
        var found: [BackupSource] = []
        let volumes = (try? fm.contentsOfDirectory(at: volumesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for volume in volumes {
            let children = (try? fm.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children where imageExtensions.contains(child.pathExtension.lowercased()) {
                found.append(makeSource(at: child))
            }
        }
        return found
    }

    static func makeSource(at url: URL) -> BackupSource {
        BackupSource(path: url.path, serverURL: serverURL(for: url), modelID: modelID(for: url))
    }

    private static func modelID(for bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("com.apple.TimeMachine.MachineID.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["com.apple.backupd.ModelID"] as? String
    }

    /// `//user@host/share` on smbfs → `smb://user@host/share`.
    private static func serverURL(for url: URL) -> String? {
        guard let entry = MountTable.entry(containing: url.path), entry.from.hasPrefix("//") else { return nil }
        let scheme: String
        switch entry.fsType {
        case "smbfs": scheme = "smb"
        case "afpfs": scheme = "afp"
        default: return nil
        }
        return "\(scheme):\(entry.from)"
    }

    /// Mounts a network share via NetFS (uses the keychain, may show the system login UI) and
    /// returns where it was mounted (e.g. `/Volumes/backup` or `/Volumes/backup-1`). Blocking.
    static func connect(_ serverURL: String) throws -> [String] {
        guard let url = URL(string: serverURL) else { throw URLError(.badURL) }
        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountPoints)
        let paths = (mountPoints?.takeRetainedValue() as? [String]) ?? []
        switch status {
        case 0, EEXIST:   // EEXIST: already mounted
            return paths
        case ECANCELED, Int32(-128):   // the user cancelled the login dialog (-128 = userCanceledErr)
            throw CocoaError(.userCancelled)
        default:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t connect to \(url.host ?? serverURL) (error \(status)).",
            ])
        }
    }

    /// After reconnecting, the share may be mounted under a different name (`/Volumes/backup-1`).
    /// Maps `/Volumes/<old>/rest` onto each new mount point and returns the first that exists.
    static func relocate(_ source: BackupSource, to mountPoints: [String]) -> BackupSource? {
        let components = source.url.pathComponents   // ["/", "Volumes", "<share>", ...rest]
        guard components.count > 3, components[1] == "Volumes" else { return nil }
        let rest = components.dropFirst(3).joined(separator: "/")
        for mountPoint in mountPoints {
            let candidate = URL(fileURLWithPath: mountPoint).appendingPathComponent(rest)
            if FileManager.default.fileExists(atPath: candidate.path) {
                var moved = source
                moved.path = candidate.path
                return moved
            }
        }
        return nil
    }
}
