import Foundation

/// One photo a background job could not process.
struct JobFailure: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case metadata
        case thumbnail

        var label: String {
            switch self {
            case .metadata: return "Metadata"
            case .thumbnail: return "Thumbnails"
            }
        }
    }

    var kind: Kind
    var path: String
    /// Short, user-facing cause ("unreadable", "not in iCloud yet", …).
    var reason: String
    var date: Date

    var id: String { "\(kind.rawValue)|\(path)" }
    var filename: String { (path as NSString).lastPathComponent }
    var folder: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

/// Remembers which photos a background pass failed on, so the status popover
/// can say what went wrong and offer a retry — instead of the old behavior,
/// where an unreadable file was cached as an empty result and silently never
/// looked at again.
///
/// Written from the indexing and warming worker threads and read on the main
/// actor, so the store is lock-guarded rather than actor-isolated (the writers
/// are synchronous, non-async contexts).
final class JobFailureLog: @unchecked Sendable {
    static let shared = JobFailureLog()

    /// Keep the log small and bounded: it exists to be read by a human, and a
    /// wholesale failure (NAS offline mid-pass) must not write a 60k-entry file.
    static let maxPerKind = 300

    /// Test seam — nil uses the real Application Support location.
    static var directoryOverride: URL?
    private static var fileURL: URL {
        (directoryOverride ?? AppDirectories.lumenSupport())
            .appendingPathComponent("job-failures.json")
    }

    private let lock = NSLock()
    private var failures: [JobFailure] = []
    private var dirty = false
    private let saveQueue = DispatchQueue(label: "lumen.jobfailures.save", qos: .utility)

    private init() { failures = Self.load() }

    /// Test seam: build an isolated instance instead of touching the singleton.
    init(loading: Bool) { failures = loading ? Self.load() : [] }

    // MARK: Reading

    func all() -> [JobFailure] {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    func all(kind: JobFailure.Kind) -> [JobFailure] {
        lock.lock(); defer { lock.unlock() }
        return failures.filter { $0.kind == kind }
    }

    func count(kind: JobFailure.Kind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return failures.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    // MARK: Writing

    func record(kind: JobFailure.Kind, path: String, reason: String, date: Date = Date()) {
        record([JobFailure(kind: kind, path: path, reason: reason, date: date)])
    }

    func record(_ new: [JobFailure]) {
        guard !new.isEmpty else { return }
        lock.lock()
        failures = Self.merged(failures, adding: new, maxPerKind: Self.maxPerKind)
        dirty = true
        lock.unlock()
        scheduleSave()
    }

    /// A retry succeeded (or the user dismissed these) — drop them.
    func clear(kind: JobFailure.Kind, paths: Set<String>? = nil) {
        lock.lock()
        failures.removeAll { $0.kind == kind && (paths?.contains($0.path) ?? true) }
        dirty = true
        lock.unlock()
        scheduleSave()
    }

    /// Merge policy as a pure function — newest entry per (kind, path) wins, and
    /// each kind is capped independently so a flood of one can't evict the other.
    static func merged(_ existing: [JobFailure], adding new: [JobFailure],
                       maxPerKind: Int) -> [JobFailure] {
        var byID: [String: JobFailure] = [:]
        for failure in existing + new {
            // `existing + new` puts new last, so a later duplicate overwrites —
            // but only if it is genuinely newer, so an out-of-order worker
            // can't replace a fresher reason with a stale one.
            if let seen = byID[failure.id], seen.date > failure.date { continue }
            byID[failure.id] = failure
        }
        var out: [JobFailure] = []
        for kind in JobFailure.Kind.allCases {
            let ofKind = byID.values.filter { $0.kind == kind }
                // Newest first, then by path so the order is stable for equal
                // timestamps (a whole chunk fails within the same millisecond).
                .sorted { $0.date == $1.date ? $0.path < $1.path : $0.date > $1.date }
            out.append(contentsOf: ofKind.prefix(max(0, maxPerKind)))
        }
        return out
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.dirty else { self.lock.unlock(); return }
            self.dirty = false
            let snapshot = self.failures
            self.lock.unlock()
            Self.save(snapshot)
        }
    }

    /// Test seam: block until queued writes have run.
    func flushForTesting() { saveQueue.sync {} }

    private static func load() -> [JobFailure] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([JobFailure].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ failures: [JobFailure]) {
        // An empty log should leave no file behind rather than an empty array.
        guard !failures.isEmpty else { try? FileManager.default.removeItem(at: fileURL); return }
        guard let data = try? JSONEncoder().encode(failures) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
