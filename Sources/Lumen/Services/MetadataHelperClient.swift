import Foundation

/// Runs metadata reads in the `lumen-meta-bg` helper process.
///
/// The point is isolation, not speed. ImageIO opens arbitrary files off a NAS,
/// and a malformed one can abort the process; in-process that killed Lumen
/// mid-browse and lost the whole pass. Out of process, the helper dies, the
/// file that killed it is recorded by name, and the pass resumes at the next
/// photo — which is also the only way that file ever gets identified.
///
/// Falls back to in-process indexing when the helper isn't there (a dev build
/// run straight from `swift run`, or a damaged bundle): a missing helper must
/// degrade to the old behaviour, never to no metadata at all.
enum MetadataHelperClient {
    /// One photo's outcome, in the order the helper produced them.
    struct Chunk: Sendable {
        var info: [String: ExifInfo] = [:]
        var failures: [JobFailure] = []
    }

    /// Where the helper lives. Next to the app binary inside the bundle; in a
    /// dev build, next to the test/CLI binary in the build directory.
    static func executableURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(MetadataHelper.executableName)"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(MetadataHelper.executableName),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent(MetadataHelper.executableName)
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { executableURL() != nil }

    /// Index `urls`, reporting each result as it arrives.
    ///
    /// `onResult` is called on this (background) thread per photo. Returns once
    /// every path has an outcome — including the ones whose helper died, which
    /// come back as failures rather than silently missing.
    static func index(_ urls: [URL],
                      isCancelled: () -> Bool = { false },
                      onResult: (String, ExifInfo, String?) -> Void) {
        guard let helper = executableURL() else {
            // No helper: do the work here rather than skip it.
            for url in urls {
                if isCancelled() { return }
                let outcome = ExifIndexer.readOutcome(url)
                onResult(url.path, outcome.info, outcome.failure)
            }
            return
        }

        var remaining = urls.map { $0.path }
        // Each pass either finishes the list or loses exactly one file to a
        // crash; bounding the restarts stops a pathological run of bad files
        // from spawning processes forever.
        var restarts = 0
        while !remaining.isEmpty, !isCancelled(), restarts <= maxRestarts {
            let produced = runOnce(helper: helper, paths: remaining,
                                   isCancelled: isCancelled, onResult: onResult)
            guard produced < remaining.count else { return }
            if isCancelled() { return }
            // The helper stopped before finishing. The next path is the one it
            // was working on when it died — name it, skip it, carry on.
            let culprit = remaining[produced]
            onResult(culprit, ExifInfo(), "Reading this file crashed the metadata reader")
            remaining = Array(remaining.dropFirst(produced + 1))
            restarts += 1
        }
    }

    private static let maxRestarts = 200

    /// One helper invocation. Returns how many replies it produced.
    private static func runOnce(helper: URL, paths: [String],
                                isCancelled: () -> Bool,
                                onResult: (String, ExifInfo, String?) -> Void) -> Int {
        let process = Process()
        process.executableURL = helper
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            NSLog("Lumen: could not start \(MetadataHelper.executableName): \(error.localizedDescription)")
            return 0
        }

        // Feed the request from another thread: the helper starts replying long
        // before the whole list is written, and a big list would otherwise fill
        // the pipe and deadlock both sides.
        let request = MetadataHelper.encodeRequest(paths)
        DispatchQueue.global(qos: .utility).async {
            stdin.fileHandleForWriting.write(request)
            try? stdin.fileHandleForWriting.close()
        }

        var buffer = Data()
        var produced = 0
        let handle = stdout.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            if isCancelled() { process.terminate(); break }
            buffer.append(chunk)
            for line in MetadataHelper.lines(from: &buffer) {
                guard let reply = MetadataHelper.decode(line: line) else { continue }
                produced += 1
                onResult(reply.p, reply.info, reply.e)
            }
        }
        process.waitUntilExit()
        return produced
    }
}
