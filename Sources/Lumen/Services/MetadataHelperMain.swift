import Foundation

/// Body of the `lumen-meta-bg` executable — reads photo metadata in a process
/// of its own.
///
/// ImageIO is asked to open whatever the user happens to have on disk, and a
/// malformed file can abort the process. In-process that killed Lumen
/// mid-browse and lost the pass; out here it costs one photo, which the app
/// then records BY NAME — the only way that file ever gets identified.
///
/// Protocol: NUL-separated paths on stdin, one JSON reply per line on stdout.
/// Replies are written as they are produced, so a helper that dies partway
/// still leaves the parent everything it had finished.
public func runMetadataHelper() {
    let input = FileHandle.standardInput
    var request = Data()
    while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
        request.append(chunk)
    }

    let output = FileHandle.standardOutput
    var pending = Data()
    for path in MetadataHelper.decodeRequest(request) {
        let outcome = ExifIndexer.readOutcome(URL(fileURLWithPath: path))
        let reply = MetadataHelper.Reply(path: path, info: outcome.info, failure: outcome.failure)
        guard let encoded = MetadataHelper.encode(reply) else { continue }
        pending.append(encoded)
        // Batch the writes, but never hold much: the parent drives its progress
        // bar off these, and a crash must not discard a long backlog.
        if pending.count >= 1 << 14 {
            output.write(pending)
            pending.removeAll(keepingCapacity: true)
        }
    }
    if !pending.isEmpty { output.write(pending) }
    try? output.close()
}
