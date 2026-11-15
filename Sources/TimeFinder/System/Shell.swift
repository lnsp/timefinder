import Darwin
import Foundation

struct ShellResult {
    let status: Int32
    let stdout: Data
    let stderr: String
}

struct ShellError: LocalizedError {
    let command: String
    let result: ShellResult
    var timedOut = false

    var errorDescription: String? {
        if timedOut { return "\(command) didn’t respond in time. Is the network share still reachable?" }
        let message = result.stderr
            .split(separator: "\n")
            .filter { !$0.contains("is deprecated") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(command) failed (exit \(result.status))" + (message.isEmpty ? "" : ": \(message)")
    }
}

enum Shell {
    /// Set TIMEFINDER_DEBUG=1 to log every command and its stderr.
    static let debugLogging = ProcessInfo.processInfo.environment["TIMEFINDER_DEBUG"] != nil

    /// Runs a command synchronously and returns its output. Never call from the main thread.
    ///
    /// The process is terminated after `timeout` seconds, so a dead network share can't hang the
    /// app forever (e.g. `umount` or `hdiutil detach` blocking on I/O to an SMB server that's gone).
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, check: Bool = true,
                    timeout: TimeInterval = 120) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        if let inPipe, let input {
            // SIGPIPE is ignored app-wide, so a process that exits early surfaces as an error here.
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently so a chatty process can't block on a full pipe.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        // A helper that inherited our pipes could keep them open; don't wait for it forever.
        _ = group.wait(timeout: .now() + 5)

        let name = URL(fileURLWithPath: executable).lastPathComponent
        let result = ShellResult(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: outBox.data,
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
        if debugLogging {
            let line = "$ \(executable) \(arguments.joined(separator: " ")) -> \(timedOut ? "timed out" : String(result.status))\n\(result.stderr)"
            FileHandle.standardError.write(Data(line.utf8))
        }
        if timedOut { throw ShellError(command: name, result: result, timedOut: true) }
        if check && result.status != 0 { throw ShellError(command: name, result: result) }
        return result
    }

    static func plist(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 120) throws -> [String: Any] {
        let result = try run(executable, arguments, input: input, timeout: timeout)
        return try parsePlist(result.stdout)
    }

    static func parsePlist(_ data: Data) throws -> [String: Any] {
        // hdiutil occasionally prints noise before the plist; skip to the XML header.
        var data = data
        if let start = data.range(of: Data("<?xml".utf8)) {
            data = data.subdata(in: start.lowerBound..<data.endIndex)
        }
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dict
    }
}

/// Pipe output collected on a background thread; locked because a reader that outlives the
/// bounded wait could still be writing while the caller reads.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

extension MountTable {
    /// The mount that `path` lives on, e.g. to check a cached snapshot root is still mounted.
    static func source(of path: String) -> String? { entry(containing: path)?.from }
}

/// Reads the kernel mount table (like `mount` with no arguments).
enum MountTable {
    struct Entry {
        let from: String
        let path: String
        let fsType: String
    }

    static func entries() -> [Entry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { entry(from: buffer[$0]) }
    }

    static func entry(containing path: String) -> Entry? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return entry(from: info)
    }

    private static func entry(from info: statfs) -> Entry {
        var info = info
        return Entry(
            from: cString(&info.f_mntfromname),
            path: cString(&info.f_mntonname),
            fsType: cString(&info.f_fstypename)
        )
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}
