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
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = base.appendingPathComponent("Lumen/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        migrateFlatCacheIfNeeded()
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

    private func diskURL(_ url: URL, _ maxPixel: Int, mtime: TimeInterval) -> URL {
        let raw = "\(url.path)|\(maxPixel)|\(Int(mtime))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
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
    func thumbnail(for url: URL, maxPixel: Int, mtime: TimeInterval? = nil,
                   completion: @escaping (NSImage?) -> Void) {
        let key = memKey(url, maxPixel)
        if let hit = memory.object(forKey: key) {
            completion(hit)
            return
        }
        // Photos-library assets have no file to decode — route to PhotoKit.
        // (Asset thumbnails aren't written to the disk cache; PhotoKit caches.)
        if url.scheme == Photo.assetScheme {
            Task { [weak self] in
                let image = await PhotosImageLoader.shared.thumbnail(for: url, maxPixel: maxPixel)
                if let self, let image { self.memory.setObject(image, forKey: key, cost: self.cost(of: image)) }
                await MainActor.run { completion(image) }
            }
            return
        }
        decodeQueue.addOperation { [weak self] in
            let image = self?.loadAndCache(url: url, maxPixel: maxPixel, mtime: mtime, key: key)
            DispatchQueue.main.async { completion(image) }
        }
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
            op.completionBlock = { [weak self] in
                guard let self else { return }
                self.itemOpsLock.lock(); self.itemOps[key] = nil; self.itemOpsLock.unlock()
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

    /// Decode + persist a thumbnail to disk for every photo whose disk cache is
    /// missing, so any folder opens instantly later. `entries` carries each
    /// file's known mtime so we don't stat the NAS just to check the cache key.
    /// `progress(remaining, currentFolder)` is reported on the main thread,
    /// time-throttled (~3×/sec) so the count is seen moving.
    func warmDiskCache(_ entries: [(url: URL, mtime: TimeInterval)],
                       maxPixel: Int = gridMaxPixel,
                       progress: @escaping (Int, String?) -> Void) {
        warmQueue.cancelAllOperations()

        // Skip files already on disk (cheap local stat, no NAS read).
        let todo = entries.filter { !FileManager.default.fileExists(atPath: diskURL($0.url, maxPixel, mtime: $0.mtime).path) }
        let total = todo.count
        guard total > 0 else { DispatchQueue.main.async { progress(0, nil) }; return }

        let counter = Counter(total)
        DispatchQueue.main.async { progress(total, todo.first?.url.deletingLastPathComponent().lastPathComponent) }

        for entry in todo {
            let disk = diskURL(entry.url, maxPixel, mtime: entry.mtime)
            let op = BlockOperation()
            op.queuePriority = .low
            op.addExecutionBlock { [weak self, weak op] in
                guard let self, op?.isCancelled == false else { return }
                if !FileManager.default.fileExists(atPath: disk.path) {
                    var image = Self.downsample(url: entry.url, maxPixel: maxPixel)
                    if image == nil { image = QuickLookThumbnailer.thumbnail(for: entry.url, maxPixel: maxPixel) }
                    if let image { self.writeDisk(image, to: disk) }   // disk only — don't evict memory
                }
                let (left, push) = counter.tick()
                if push || left == 0 {
                    let folder = entry.url.deletingLastPathComponent().lastPathComponent
                    DispatchQueue.main.async { progress(left, left == 0 ? nil : folder) }
                }
            }
            warmQueue.addOperation(op)
        }
    }

    func cancelWarming() { warmQueue.cancelAllOperations() }

    // Pause warming briefly while the user is actively browsing, so the folder
    // they're looking at gets the full decode throughput. Resumes after idle.
    private var resumeWork: DispatchWorkItem?
    func yieldWarmingToBrowsing() {
        warmQueue.isSuspended = true
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.warmQueue.isSuspended = false }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Thread-safe countdown with a time-throttled "should I publish?" flag.
    private final class Counter: @unchecked Sendable {
        private var value: Int
        private var lastPush: CFAbsoluteTime = 0
        private let lock = NSLock()
        init(_ value: Int) { self.value = value }
        func tick() -> (remaining: Int, push: Bool) {
            lock.lock(); defer { lock.unlock() }
            value -= 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPush > 0.3 { lastPush = now; return (value, true) }
            return (value, false)
        }
    }

    // MARK: - Loading

    /// Disk → ImageIO downsample → QuickLook fallback, caching the result in
    /// memory and on disk. The single shared load path for display and prefetch.
    /// The disk cache always stores `gridMaxPixel`; a smaller requested tier is
    /// derived from the cached JPEG (local, cheap) so the NAS original is only
    /// ever decoded once per photo.
    @discardableResult
    private func loadAndCache(url: URL, maxPixel: Int, mtime: TimeInterval?, key: NSString) -> NSImage? {
        // Never run the file/QuickLook decode path on a Photos-library asset — it
        // would return the generic document icon. Assets only load via PhotoKit.
        if url.scheme == Photo.assetScheme { return nil }
        let disk = diskURL(url, Self.gridMaxPixel, mtime: mtime ?? statMtime(url))
        if let data = try? Data(contentsOf: disk), let image = Self.decode(data, maxPixel: maxPixel) {
            memory.setObject(image, forKey: key, cost: cost(of: image))
            return image
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
        if maxPixel >= gridMaxPixel { return NSImage(data: data) }
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

    func clear() {
        memory.removeAllObjects()
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }
}
