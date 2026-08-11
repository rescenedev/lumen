import Foundation

/// Body of the `lumen-thumb-bg` executable — builds thumbnails in a process of
/// its own.
///
/// Worth more isolation than metadata: the thumbnail path falls back to
/// QuickLook, which can block indefinitely on a wedged network mount. In
/// process that pinned a warm lane forever with no way to recover; out here the
/// parent can simply kill a helper that has stopped answering.
///
/// Protocol: `path\0mtime\0` pairs on stdin, one JSON reply per line on stdout.
/// The first two arguments are the decode size and, optionally, nothing else —
/// the cache location comes from the same Application Support lookup the app
/// uses, so the two can never disagree about where thumbnails live.
public func runThumbnailHelper(arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
    let maxPixel = arguments.first.flatMap(Int.init) ?? ThumbnailCache.gridMaxPixel

    var request = Data()
    let input = FileHandle.standardInput
    while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
        request.append(chunk)
    }

    // Decode OFF the main thread: QuickLook refuses to run there (it waits on a
    // semaphore and asserts against the main queue), and this executable's
    // entry point is the main thread.
    let output = FileHandle.standardOutput
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        for item in ThumbnailHelper.decodeRequest(request) {
            let failure = ThumbnailCache.shared.buildThumbnail(
                path: item.path, mtime: item.mtime, maxPixel: maxPixel)
            let reply = ThumbnailHelper.Reply(p: item.path, e: failure)
            // One write per photo, unbatched: this is the parent's progress
            // signal, and a decode that hangs after it must still have reported
            // the ones before it.
            if let data = ThumbnailHelper.encode(reply) { output.write(data) }
        }
        done.signal()
    }
    done.wait()
    try? output.close()
}
