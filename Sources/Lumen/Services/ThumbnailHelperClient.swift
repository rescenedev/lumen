import Foundation

/// Drives `lumen-thumb-bg` workers for the full-library warm pass.
///
/// Two things in-process code could not do:
///   • survive a decoder that aborts — one photo instead of the app
///   • survive a decoder that never returns. The thumbnail path falls back to
///     QuickLook, which can block indefinitely on a wedged network mount; a
///     warm lane pinned that way never came back. Here the worker is simply
///     killed and the file recorded.
///
/// Falls back to in-process building when the helper isn't present, so a dev
/// build (or a damaged bundle) still warms, just without the isolation.
final class ThumbnailHelperClient: @unchecked Sendable {
    /// How long one photo may take before its worker is considered wedged.
    /// Generous: a 60MP RAW off a slow share legitimately takes seconds, and
    /// killing a worker that was making progress costs a decode.
    static let perItemTimeout: TimeInterval = 45

    static func executableURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(ThumbnailHelper.executableName)"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(ThumbnailHelper.executableName),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent(ThumbnailHelper.executableName)
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { executableURL() != nil }

    /// Build thumbnails for `items`, reporting each as it completes.
    /// `onResult(path, failureReason)` — reason nil means the thumbnail landed.
    /// Runs synchronously; call from a background context.
    static func build(_ items: [ThumbnailHelper.Item], maxPixel: Int,
                      isCancelled: @escaping () -> Bool,
                      onResult: (String, String?) -> Void) {
        guard let helper = executableURL() else {
            for item in items {
                if isCancelled() { return }
                let failure = ThumbnailCache.shared.buildThumbnail(
                    path: item.path, mtime: item.mtime, maxPixel: maxPixel)
                onResult(item.path, failure)
            }
            return
        }

        var remaining = items
        var restarts = 0
        while !remaining.isEmpty, !isCancelled(), restarts <= maxRestarts {
            let produced = runOnce(helper: helper, items: remaining, maxPixel: maxPixel,
                                   isCancelled: isCancelled, onResult: onResult)
            guard produced < remaining.count else { return }
            if isCancelled() { return }
            // Stopped early: the next unanswered item is the one that killed or
            // hung the worker. Name it, skip it, carry on — that attribution is
            // the whole reason this runs out of process.
            onResult(remaining[produced].path,
                     "This photo hung or crashed the thumbnail builder")
            remaining = Array(remaining.dropFirst(produced + 1))
            restarts += 1
        }
    }

    private static let maxRestarts = 500

    /// One worker. Returns how many replies it produced before finishing,
    /// dying, or being killed for going quiet.
    private static func runOnce(helper: URL, items: [ThumbnailHelper.Item], maxPixel: Int,
                                isCancelled: @escaping () -> Bool,
                                onResult: (String, String?) -> Void) -> Int {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["\(maxPixel)"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            NSLog("Lumen: could not start \(ThumbnailHelper.executableName): \(error.localizedDescription)")
            return 0
        }

        // Write from another thread: the worker replies long before the whole
        // list is written, and a large list would fill the pipe and deadlock.
        let request = ThumbnailHelper.encodeRequest(items)
        DispatchQueue.global(qos: .utility).async {
            stdin.fileHandleForWriting.write(request)
            try? stdin.fileHandleForWriting.close()
        }

        // A watchdog is the point of the whole exercise: a QuickLook call that
        // never returns produces no output and no exit, so only an outside
        // observer can end it.
        let lastReply = Timestamp()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler {
            guard process.isRunning else { return }
            if isCancelled() || lastReply.secondsSince() > perItemTimeout {
                process.terminate()
                // terminate() is SIGTERM; a process wedged in a kernel read may
                // ignore it, so follow up.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        var buffer = Data()
        var produced = 0
        let handle = stdout.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            buffer.append(chunk)
            for line in ThumbnailHelper.lines(from: &buffer) {
                guard let reply = ThumbnailHelper.decode(line: line) else { continue }
                produced += 1
                lastReply.touch()
                onResult(reply.p, reply.e)
            }
        }
        process.waitUntilExit()
        return produced
    }

    /// Thread-safe "when did we last hear from it", read by the watchdog while
    /// the reader thread updates it.
    private final class Timestamp: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        func touch() { lock.lock(); value = Date(); lock.unlock() }
        func secondsSince() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return -value.timeIntervalSinceNow
        }
    }
}

extension ThumbnailHelper {
    /// Same partial-frame handling as the metadata helper: a pipe read can land
    /// mid-object, and treating the tail as a frame would drop that photo.
    static func lines(from buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            out.append(buffer[buffer.startIndex..<index])
            buffer = buffer[(index + 1)...]
        }
        return out
    }
}
