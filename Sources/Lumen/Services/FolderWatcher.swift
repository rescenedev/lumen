import Foundation

/// Watches a set of root folders for file-system changes using FSEvents and
/// invokes a (debounced) callback so the library can be re-scanned.
final class FolderWatcher {
    // FSEvents delivers on a background queue (`scheduleCallback`) while
    // `watch`/`stop` are called from the main thread, so every mutable field
    // below is guarded by this lock to avoid data races.
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let onChange: () -> Void
    private var debounceWork: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
        paths = urls.map { $0.path }
        guard !paths.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleCallback()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private func scheduleCallback() {
        lock.lock()
        // Ignore events that arrive after the stream was torn down.
        guard stream != nil else { lock.unlock(); return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    /// Tear down the stream and pending work. Caller must hold `lock`.
    private func stopLocked() {
        debounceWork?.cancel()
        debounceWork = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
