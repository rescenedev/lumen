import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Loads and caches downsampled thumbnails. Two tiers: an in-memory NSCache and
/// a persistent on-disk cache, so thumbnails survive relaunches. A bounded
/// prefetch queue warms thumbnails ahead of scrolling.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Fixed decode resolution for grid/list thumbnails (crisp at the largest
    /// grid size, cheap to cache). Used by both display and prefetch so keys match.
    static let gridMaxPixel = 512

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

    private func diskURL(_ url: URL, _ maxPixel: Int) -> URL {
        // Stat the file for its mtime (one local/NAS call) — used on the display path.
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return diskURL(url, maxPixel, mtime: mtime)
    }

    func cached(for url: URL, maxPixel: Int) -> NSImage? {
        memory.object(forKey: memKey(url, maxPixel))
    }

    func thumbnail(for url: URL, maxPixel: Int, completion: @escaping (NSImage?) -> Void) {
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
            let image = self?.loadAndCache(url: url, maxPixel: maxPixel, key: key)
            DispatchQueue.main.async { completion(image) }
        }
    }

    func thumbnail(for url: URL, maxPixel: Int) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnail(for: url, maxPixel: maxPixel) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Prefetch

    /// Warm thumbnails for an ordered list of URLs ahead of scrolling. Cancels
    /// any prior prefetch batch so we don't chase a stale viewport.
    func prefetch(_ urls: [URL], maxPixel: Int = gridMaxPixel) {
        prefetchQueue.cancelAllOperations()
        // Skip Photos-library assets: prefetch uses the file decode path
        // (loadAndCache → QuickLook), which for a synthetic asset URL returns the
        // generic document ICON and poisons the cache. Assets load via PhotoKit
        // in `thumbnail(...)`; warming them here isn't needed.
        for url in urls.prefix(1000) where url.scheme != Photo.assetScheme {
            let key = memKey(url, maxPixel)
            if memory.object(forKey: key) != nil { continue }
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self, op?.isCancelled == false else { return }
                _ = self.loadAndCache(url: url, maxPixel: maxPixel, key: key)
            }
            prefetchQueue.addOperation(op)
        }
    }

    func cancelPrefetch() { prefetchQueue.cancelAllOperations() }

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
    @discardableResult
    private func loadAndCache(url: URL, maxPixel: Int, key: NSString) -> NSImage? {
        // Never run the file/QuickLook decode path on a Photos-library asset — it
        // would return the generic document icon. Assets only load via PhotoKit.
        if url.scheme == Photo.assetScheme { return nil }
        let disk = diskURL(url, maxPixel)
        if let data = try? Data(contentsOf: disk), let image = NSImage(data: data) {
            memory.setObject(image, forKey: key, cost: cost(of: image))
            return image
        }
        // ImageIO first; QuickLook fallback handles iCloud-dataless files and
        // formats ImageIO can't decode directly.
        var image = Self.downsample(url: url, maxPixel: maxPixel)
        if image == nil {
            image = QuickLookThumbnailer.thumbnail(for: url, maxPixel: maxPixel)
        }
        if let image {
            memory.setObject(image, forKey: key, cost: cost(of: image))
            writeDisk(image, to: disk)
        }
        return image
    }

    private func writeDisk(_ image: NSImage, to url: URL) {
        // Encode straight from the CGImage (skips the slow NSImage→TIFF→bitmap
        // round-trip) into in-memory data, then write atomically. Same JPEG output.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        // Ensure the shard subdirectory exists (idempotent, cheap).
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? (data as Data).write(to: url, options: .atomic)
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
