import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Loads and caches downsampled thumbnails. Two tiers: an in-memory NSCache and
/// a persistent on-disk cache, so thumbnails survive relaunches. A bounded
/// prefetch queue warms thumbnails ahead of scrolling.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Disk-cache decode resolution (crisp at the largest grid size). The disk
    /// cache always stores this size; smaller display tiers derive from it.
    static let gridMaxPixel = 512

    /// Memory-cache tier for a given cell point size (assumes Retina 2×).
    /// Small cells decode to 256px so the byte-bounded memory cache holds ~4×
    /// more of them — a 90pt grid on a big display shows 400+ cells at once.
    /// Display and prefetch must use the same tier so cache keys match.
    static func tier(forPointSize size: CGFloat) -> Int {
        size <= 128 ? 256 : gridMaxPixel
    }

    private let memory = NSCache<NSString, NSImage>()
    // Bounded so a fast scroll can't spawn hundreds of simultaneous decodes.
    private let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        q.qualityOfService = .userInitiated
        return q
    }()
    private let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        q.qualityOfService = .utility
        return q
    }()
    private let diskDir: URL

    private init() {
        // Cap by bytes, not count, so memory use is bounded regardless of size.
        memory.totalCostLimit = 180 * 1024 * 1024   // ~180 MB (disk cache backs the rest)
        // Application Support, NOT ~/Library/Caches: macOS (and cleaner apps)
        // purge Caches under storage pressure, and rebuilding 60k+ thumbnails
        // over a NAS/HDD takes hours — this store is expensive derived data,
        // not a cheaply-regenerated cache. (Observed twice on the reference
        // machine: the whole warm was wiped and restarted from zero.)
        diskDir = AppDirectories.lumenSupport().appendingPathComponent("Thumbnails", isDirectory: true)
        Self.relocateLegacyStore(
            from: AppDirectories.caches().appendingPathComponent("Lumen/Thumbnails", isDirectory: true),
            to: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        // Derived data — keep it out of Time Machine backups.
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        var dir = diskDir
        try? dir.setResourceValues(noBackup)
        migrateFlatCacheIfNeeded()
    }

    /// One-time move of the legacy ~/Library/Caches store into the new
    /// location. The common case (new store absent) is a single O(1) rename;
    /// if both exist (builds interleaved), the slower per-file merge runs off
    /// the calling thread. Present-day misses during that window just re-decode.
    static func relocateLegacyStore(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: old, to: new)) != nil { return }
        }
        DispatchQueue.global(qos: .utility).async { mergeLegacyStore(from: old, to: new) }
    }

    /// Per-file merge for the both-stores-exist case: entries already in the
    /// new store win (they're fresher); everything else moves over. The legacy
    /// directory is removed at the end.
    static func mergeLegacyStore(from old: URL, to new: URL) {
        let fm = FileManager.default
        let shards = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? []
        for shard in shards {
            let files = (try? fm.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            let newShard = new.appendingPathComponent(shard.lastPathComponent, isDirectory: true)
            try? fm.createDirectory(at: newShard, withIntermediateDirectories: true)
            for file in files {
                let target = newShard.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: file, to: target)
                }
            }
        }
        try? fm.removeItem(at: old)
    }

    /// Older builds wrote all thumbnails flat into one directory. MOVE those
    /// loose files into their shard subdirectory — never delete, so an existing
    /// warmed cache is preserved.
    private func migrateFlatCacheIfNeeded() {
        let dir = diskDir
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for entry in entries where entry.pathExtension == "jpg" {
                let name = entry.deletingPathExtension().lastPathComponent
                guard name.count >= 2 else { continue }
                let shard = dir.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
                try? fm.createDirectory(at: shard, withIntermediateDirectories: true)
                try? fm.moveItem(at: entry, to: shard.appendingPathComponent(entry.lastPathComponent))
            }
        }
    }

    private func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height) * 4   // ~RGBA bytes
    }

    private func memKey(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)|\(maxPixel)" as NSString
    }

    /// The disk-cache filename (sans extension) for one photo — pure, so the
    /// stale-entry sweep can compute the CURRENT library's valid-name set.
    static func diskName(path: String, maxPixel: Int, mtime: TimeInterval) -> String {
        let raw = "\(path)|\(maxPixel)|\(Int(mtime))"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(_ url: URL, _ maxPixel: Int, mtime: TimeInterval) -> URL {
        let name = Self.diskName(path: url.path, maxPixel: maxPixel, mtime: mtime)
        // Shard into 256 subdirs by the first 2 hex chars so no single directory
        // ever holds tens of thousands of files.
        let shard = String(name.prefix(2))
        return diskDir.appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(name).appendingPathExtension("jpg")
    }

    private func statMtime(_ url: URL) -> TimeInterval {
        // Stat the file for its mtime (one local/NAS call) — fallback for
        // callers that don't already know it from the library scan.
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    func cached(for url: URL, maxPixel: Int) -> NSImage? {
        memory.object(forKey: memKey(url, maxPixel))
    }

    /// `mtime` is the scan-time modification date used in the disk-cache key.
    /// Passing it avoids a per-thumbnail stat (a NAS roundtrip); nil falls back
    /// to statting the file.
    ///
    /// Returns a cancellable Operation for the realized-cell display lane (nil for
    /// a cache hit or a Photos asset). The prefetch lane was already cancellable
    /// via `itemOps`; the on-demand lane was not, so a fast scroll left stale NAS
    /// decodes head-of-line blocking the cells the user lands on. The cell cancels
    /// this on reuse. `completion` is ALWAYS called (nil on cancel/failure), so the
    /// `async` wrapper below can never leak its continuation.
    /// Fast-first-paint lane: reads a photo's EMBEDDED thumbnail (a few-KB
    /// header read, no full decode) so a cold cell shows a slightly-soft image
    /// immediately while the sharp tier decodes behind it. Cheap ops, so the
    /// lane is wide and never touches the warm/decode gates.
    private let previewQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The embedded (EXIF/HEIF) preview only — returns nil rather than ever
    /// falling back to a full-image decode; the caller's slow lane does that.
    static func embeddedThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// `preview`, when provided, may fire once on the main thread with the
    /// embedded low-res thumbnail BEFORE `completion` — never after it.
    @discardableResult
    func thumbnail(for url: URL, maxPixel: Int, mtime: TimeInterval? = nil,
                   preview: ((NSImage) -> Void)? = nil,
                   completion: @escaping (NSImage?) -> Void) -> Operation? {
        let key = memKey(url, maxPixel)
        if let hit = memory.object(forKey: key) {
            completion(hit)
            return nil
        }
        // Photos-library assets have no file to decode — route to PhotoKit.
        // (Asset thumbnails aren't written to the disk cache; PhotoKit caches.)
        if url.scheme == Photo.assetScheme {
            Task { [weak self] in
                let image = await PhotosImageLoader.shared.thumbnail(for: url, maxPixel: maxPixel)
                if let self, let image { self.memory.setObject(image, forKey: key, cost: self.cost(of: image)) }
                await MainActor.run { completion(image) }
            }
            return nil
        }
        // Main-thread confined: set by the final delivery, checked by the
        // preview delivery, so a late preview can never paint over the sharp
        // final image.
        var finished = false
        let deliver: (NSImage?) -> Void = { image in
            finished = true
            completion(image)
        }
        if let preview, let mtime {
            previewQueue.addOperation { [weak self] in
                guard let self else { return }
                // The disk cache serves the sharp tier in milliseconds — a
                // preview only helps when the slow original decode is coming.
                let disk = self.diskURL(url, Self.gridMaxPixel, mtime: mtime)
                guard !FileManager.default.fileExists(atPath: disk.path),
                      let quick = Self.embeddedThumbnail(url: url, maxPixel: maxPixel) else { return }
                DispatchQueue.main.async { if !finished { preview(quick) } }
            }
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            // Cancelled while still queued (cell scrolled away): skip the multi-MB
            // NAS read entirely, but still resume the caller with nil.
            guard let self, op?.isCancelled == false else {
                DispatchQueue.main.async { deliver(nil) }
                return
            }
            let image = self.loadAndCache(url: url, maxPixel: maxPixel, mtime: mtime, key: key)
            DispatchQueue.main.async { deliver(image) }
        }
        // Display decodes suspend warming for their whole lifetime (not a fixed
        // window) so a cold visible fill never fights warming for disk I/O.
        browsingGate.begin()
        op.completionBlock = { [weak self] in self?.browsingGate.end() }
        decodeQueue.addOperation(op)
        return op
    }

    func thumbnail(for url: URL, maxPixel: Int, mtime: TimeInterval? = nil) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnail(for: url, maxPixel: maxPixel, mtime: mtime) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Prefetch

    typealias Entry = (url: URL, mtime: TimeInterval)

    /// Warm thumbnails for the first screens of a freshly opened list. Cancels
    /// any prior prefetch batch (including viewport ops — the list changed).
    /// Skips Photos-library assets: the file decode path (loadAndCache →
    /// QuickLook) would return the generic document icon for a synthetic asset
    /// URL and poison the cache; assets load via PhotoKit in `thumbnail(...)`.
    func prefetch(_ entries: [Entry], maxPixel: Int = gridMaxPixel, limit: Int = 200) {
        prefetchQueue.cancelAllOperations()
        itemOpsLock.lock(); itemOps.removeAll(); itemOpsLock.unlock()
        for entry in entries.prefix(limit) where entry.url.scheme != Photo.assetScheme {
            let key = memKey(entry.url, maxPixel)
            if memory.object(forKey: key) != nil { continue }
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self, op?.isCancelled == false else { return }
                _ = self.loadAndCache(url: entry.url, maxPixel: maxPixel, mtime: entry.mtime, key: key)
            }
            browsingGate.begin()
            op.completionBlock = { [weak self] in self?.browsingGate.end() }
            prefetchQueue.addOperation(op)
        }
    }

    // Viewport prefetch: one cancellable operation per cell, driven by
    // NSCollectionView's prefetch data source, so scroll-ahead work tracks the
    // actual viewport instead of decoding the whole list up front.
    private var itemOps: [NSString: Operation] = [:]
    private let itemOpsLock = NSLock()

    func prefetchItems(_ entries: [Entry], maxPixel: Int) {
        for entry in entries where entry.url.scheme != Photo.assetScheme {
            let key = memKey(entry.url, maxPixel)
            if memory.object(forKey: key) != nil { continue }
            itemOpsLock.lock()
            if itemOps[key] != nil { itemOpsLock.unlock(); continue }
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self, op?.isCancelled == false else { return }
                _ = self.loadAndCache(url: entry.url, maxPixel: maxPixel, mtime: entry.mtime, key: key)
            }
            browsingGate.begin()
            op.completionBlock = { [weak self] in
                guard let self else { return }
                self.itemOpsLock.lock(); self.itemOps[key] = nil; self.itemOpsLock.unlock()
                self.browsingGate.end()
            }
            itemOps[key] = op
            itemOpsLock.unlock()
            prefetchQueue.addOperation(op)
        }
    }

    /// Cancel viewport prefetches for cells that scrolled out of range.
    func cancelPrefetchItems(_ urls: [URL], maxPixel: Int) {
        itemOpsLock.lock()
        for url in urls { itemOps[memKey(url, maxPixel)]?.cancel() }
        itemOpsLock.unlock()
    }

    func cancelPrefetch() {
        prefetchQueue.cancelAllOperations()
        itemOpsLock.lock(); itemOps.removeAll(); itemOpsLock.unlock()
    }

    // MARK: - Full-library disk warming

    private let warmQueue: OperationQueue = {
        let q = OperationQueue()
        // Keep warming gentle (few parallel reads, background priority) so it
        // yields NAS bandwidth + CPU to thumbnails the user is actively viewing.
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .background
        return q
    }()

    /// Trickle mode: the app's window is closed but the app is still running —
    /// keep warming alive at well under 1% CPU (one decode every few seconds,
    /// single lane). Reopening a window restores full pace; queued operations
    /// read the live flag, so the switch applies immediately either way.
    private var trickleMode = false   // benign race: ops only read it
    private let trickleDelay: TimeInterval = 5

    func setTrickleMode(_ on: Bool) {
        guard trickleMode != on else { return }
        trickleMode = on
        warmQueue.maxConcurrentOperationCount = on ? 1 : 3
    }

    /// Decode + persist a thumbnail to disk for every photo whose disk cache is
    /// missing, so any folder opens instantly later. `entries` carries each
    /// file's known mtime so we don't stat the NAS just to check the cache key.
    /// `progress(remaining, currentFolder)` is reported on the main thread,
    /// time-throttled (~3×/sec) so the count is seen moving.
    // Generation guard: a newer warmDiskCache call invalidates the off-thread
    // todo-filter of an older one, so stale entries are never enqueued.
    private let warmGeneration = Counter(0)

    func warmDiskCache(_ entries: [(url: URL, mtime: TimeInterval)],
                       maxPixel: Int = gridMaxPixel,
                       progress: @escaping (Int, String?) -> Void) {
        warmQueue.cancelAllOperations()
        let generation = warmGeneration.bump()

        // Filtering already-cached files means a SHA256 + stat per photo —
        // ~3s for 67k entries, measured as a main-thread freeze when this ran
        // on the caller. Do it off-thread, then enqueue the decode operations.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let todo = entries.filter { !FileManager.default.fileExists(atPath: self.diskURL($0.url, maxPixel, mtime: $0.mtime).path) }
            guard self.warmGeneration.value == generation else { return }   // superseded
            let total = todo.count
            guard total > 0 else { DispatchQueue.main.async { progress(0, nil) }; return }

            let counter = Counter(total)
            DispatchQueue.main.async { progress(total, todo.first?.url.deletingLastPathComponent().lastPathComponent) }

            // Enqueue in bounded chunks: a cold warm of ~66k photos used to hold
            // ~66k BlockOperations (closures + contexts) resident for hours. Each
            // chunk enqueues the next when its last operation completes.
            let chunks = Self.warmChunkRanges(total: total, chunkSize: Self.warmChunkSize)
            func enqueueChunk(_ index: Int) {
                guard self.warmGeneration.value == generation, index < chunks.count else { return }
                let pending = Counter(chunks[index].count)
                for entry in todo[chunks[index]] {
                    let disk = self.diskURL(entry.url, maxPixel, mtime: entry.mtime)
                    let op = BlockOperation()
                    op.queuePriority = .low
                    op.addExecutionBlock { [weak self, weak op] in
                        guard let self, op?.isCancelled == false,
                              self.warmGeneration.value == generation   // a newer warm pass owns the queue now
                        else { return }
                        if self.trickleMode {   // window closed — idle pace, sleep is 0% CPU
                            Thread.sleep(forTimeInterval: self.trickleDelay)
                            guard op?.isCancelled == false else { return }
                        }
                        if !FileManager.default.fileExists(atPath: disk.path) {
                            // Dedupe against the display/prefetch lanes: if one of
                            // them is decoding this file right now, wait it out and
                            // re-check instead of issuing a duplicate NAS read.
                            let owned = self.decodeGate.acquireOrWait(entry.url.path)
                            defer { if owned { self.decodeGate.release(entry.url.path) } }
                            if !FileManager.default.fileExists(atPath: disk.path) {
                                var image = Self.downsample(url: entry.url, maxPixel: maxPixel)
                                if image == nil { image = QuickLookThumbnailer.thumbnail(for: entry.url, maxPixel: maxPixel) }
                                if let image { self.writeDisk(image, to: disk) }   // disk only — don't evict memory
                            }
                        }
                        let (left, push) = counter.tick()
                        if push || left == 0 {
                            let folder = entry.url.deletingLastPathComponent().lastPathComponent
                            DispatchQueue.main.async { progress(left, left == 0 ? nil : folder) }
                        }
                    }
                    op.completionBlock = {
                        // Fires for cancelled ops too, so the chain can't stall;
                        // the generation guard above stops a dead pass instead.
                        let (left, _) = pending.tick()
                        if left == 0 {
                            DispatchQueue.global(qos: .utility).async { enqueueChunk(index + 1) }
                        }
                    }
                    guard self.warmGeneration.value == generation else { return }   // superseded mid-enqueue
                    self.warmQueue.addOperation(op)
                }
            }
            enqueueChunk(0)
        }
    }

    /// Warm-queue chunk size: enough depth that the 3 warm lanes never starve
    /// between chunk hand-offs, small enough that resident operations stay
    /// bounded (~400 instead of the whole library).
    private static let warmChunkSize = 400

    /// Chunk boundaries for a warm pass — pure helper, unit-tested.
    static func warmChunkRanges(total: Int, chunkSize: Int) -> [Range<Int>] {
        guard total > 0 else { return [] }
        guard chunkSize > 0 else { return [0..<total] }
        return stride(from: 0, to: total, by: chunkSize).map { $0..<min($0 + chunkSize, total) }
    }

    func cancelWarming() {
        _ = warmGeneration.bump()   // kills the chunk chain, not just queued ops
        warmQueue.cancelAllOperations()
    }

    // Warming yields to browsing for the entire time user-facing decodes are
    // in flight (display + viewport prefetch lanes), plus a trailing grace —
    // a fixed pause used to expire mid-fill on a cold cache and let warming
    // steal disk/NAS I/O back from the photos the user is looking at.
    private lazy var browsingGate = BrowsingActivityGate { [weak self] suspended in
        self?.warmQueue.isSuspended = suspended
    }

    /// "User opened a folder" nudge (kept for callers that have no matching
    /// end); bracketed decode work keeps the suspension alive on its own.
    func yieldWarmingToBrowsing() { browsingGate.touch() }

    /// Thread-safe countdown with a time-throttled "should I publish?" flag.
    /// Also doubles as a plain atomic counter (`bump`/`value`) for generations.
    private final class Counter: @unchecked Sendable {
        private var count: Int
        private var lastPush: CFAbsoluteTime = 0
        private let lock = NSLock()
        init(_ value: Int) { self.count = value }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        func tick() -> (remaining: Int, push: Bool) {
            lock.lock(); defer { lock.unlock() }
            count -= 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPush > 0.3 { lastPush = now; return (count, true) }
            return (count, false)
        }
    }

    // MARK: - Loading

    /// Disk → ImageIO downsample → QuickLook fallback, caching the result in
    /// memory and on disk. The single shared load path for display and prefetch.
    /// The disk cache always stores `gridMaxPixel`; a smaller requested tier is
    /// derived from the cached JPEG (local, cheap) so the NAS original is only
    /// ever decoded once per photo.
    /// One decode of any given original at a time, across all three lanes
    /// (display, viewport prefetch, warming). Losers wait for the owner, then
    /// serve themselves from the memory/disk cache the owner just filled —
    /// instead of issuing a duplicate multi-MB NAS/USB read.
    private let decodeGate = DecodeGate()

    @discardableResult
    private func loadAndCache(url: URL, maxPixel: Int, mtime: TimeInterval?, key: NSString) -> NSImage? {
        // Never run the file/QuickLook decode path on a Photos-library asset — it
        // would return the generic document icon. Assets only load via PhotoKit.
        if url.scheme == Photo.assetScheme { return nil }
        let owned = decodeGate.acquireOrWait(url.path)
        defer { if owned { decodeGate.release(url.path) } }
        if !owned, let hit = memory.object(forKey: key) { return hit }   // owner filled memory
        let disk = diskURL(url, Self.gridMaxPixel, mtime: mtime ?? statMtime(url))
        if let data = try? Data(contentsOf: disk), let image = Self.decode(data, maxPixel: maxPixel) {
            memory.setObject(image, forKey: key, cost: cost(of: image))
            return image
        }
        // A corrupt file (zero-filled — a failed copy) decodes to nothing, and
        // QuickLook hands back a generic filetype icon for it, poisoning the
        // cache with a plausible-looking "thumbnail". Bail early instead so the
        // cell can show a broken-file mark. (Only bails on a positive read of
        // 16 zero bytes — unreadable/dataless files still reach QuickLook.)
        if let handle = try? FileHandle(forReadingFrom: url) {
            let head = try? handle.read(upToCount: 16)
            try? handle.close()
            if let head, head.count == 16, head.allSatisfy({ $0 == 0 }) { return nil }
        }
        // ImageIO first; QuickLook fallback handles iCloud-dataless files and
        // formats ImageIO can't decode directly.
        var full = Self.downsample(url: url, maxPixel: Self.gridMaxPixel)
        if full == nil {
            full = QuickLookThumbnailer.thumbnail(for: url, maxPixel: Self.gridMaxPixel)
        }
        guard let full else { return nil }
        let jpeg = Self.encodeJPEG(full)
        if let jpeg { writeDisk(jpeg, to: disk) }
        var image = full
        if maxPixel < Self.gridMaxPixel, let jpeg, let small = Self.decode(jpeg, maxPixel: maxPixel) {
            image = small
        }
        memory.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    /// Decode cached JPEG data at the requested tier. Full tier decodes as-is;
    /// smaller tiers downsample (orientation was already baked at encode time).
    private static func decode(_ data: Data, maxPixel: Int) -> NSImage? {
        // ALL tiers (incl. the default 512 grid tier) decode the bitmap NOW via
        // shouldCacheImmediately, on this off-main lane. Previously the full tier
        // returned NSImage(data:), which defers the JPEG decode to AppKit's first
        // draw — i.e. on the main thread during scroll (~0.5-1.5ms per fresh cell).
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func encodeJPEG(_ image: NSImage) -> Data? {
        // Encode straight from the CGImage (skips the slow NSImage→TIFF→bitmap
        // round-trip) into in-memory data.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func writeDisk(_ image: NSImage, to url: URL) {
        guard let data = Self.encodeJPEG(image) else { return }
        writeDisk(data, to: url)
    }

    private func writeDisk(_ data: Data, to url: URL) {
        // Ensure the shard subdirectory exists (idempotent, cheap).
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func downsample(url: URL, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Stale-entry GC

    /// Delete disk-cache entries the current library can no longer reference.
    /// Filenames are opaque SHA256(path|tier|mtime) hashes, so entries orphaned
    /// by a library move (new volume → new paths) or re-copied files (new
    /// mtimes) are unreachable forever — gigabytes after a 60k-photo move.
    /// `valid` is the name set derived from the live photo list; entries
    /// younger than `minAge` are kept even when unknown, because photos added
    /// AFTER the valid-set snapshot write names the snapshot can't contain.
    /// Returns the number of files deleted.
    @discardableResult
    static func sweepStale(in dir: URL, valid: Set<String>,
                           olderThan minAge: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var deleted = 0
        for shard in shards {
            guard let files = try? fm.contentsOfDirectory(
                at: shard, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jpg" {
                let name = file.deletingPathExtension().lastPathComponent
                guard !valid.contains(name) else { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                guard now.timeIntervalSince(mtime) > minAge else { continue }
                if (try? fm.removeItem(at: file)) != nil { deleted += 1 }
            }
        }
        return deleted
    }

    /// Instance entry point: sweep this cache's directory against the live
    /// library's entries. Runs synchronously — call from a background task.
    @discardableResult
    func sweepStaleDiskEntries(validEntries: [Entry], olderThan minAge: TimeInterval = 86_400) -> Int {
        let valid = Set(validEntries.map {
            Self.diskName(path: $0.url.path, maxPixel: Self.gridMaxPixel, mtime: $0.mtime)
        })
        return Self.sweepStale(in: diskDir, valid: valid, olderThan: minAge)
    }

    func clear() {
        memory.removeAllObjects()
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }
}
