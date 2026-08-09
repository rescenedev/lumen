import Foundation

/// A cache key that survives the same storage being mounted somewhere else.
///
/// Everything derived (thumbnails, the EXIF index) was keyed by absolute path,
/// which quietly assumes a file is always reachable at the same one. It isn't:
/// the reference NAS share appears as `/Volumes/zpool` on one login and
/// `/Users/zihado/nas-mnt/zpool` on the next, and an external disk lands on
/// `/Volumes/orico 1` when the first mount is stale. Every such change made the
/// whole cache miss — measured 26,926 dead EXIF entries and ~68,000 orphaned
/// thumbnails on the reference machine, i.e. hours of re-reading the NAS for
/// work that had already been done.
///
/// The identity used instead is the volume, not the mount point:
///   • local volumes — the volume UUID, stable across remounts and renames
///   • network shares — the share itself (`//host/share`), with the login user
///     stripped, because the same share mounted by a different account is the
///     same bytes
enum VolumeIdentity {
    /// `<volume id><path relative to the mount point>`, e.g.
    /// `//192.168.123.104/zpool/photos/2011/a.jpg`. Falls back to the absolute
    /// path when the volume can't be identified, so a key always exists.
    static func key(for path: String) -> String {
        guard let mount = mount(containing: path) else { return path }
        let relative = String(path.dropFirst(mount.point == "/" ? 0 : mount.point.count))
        return mount.id + relative
    }

    /// Drop the cached mount table — call when a volume mounts or unmounts.
    static func invalidate() {
        lock.lock(); mounts = nil; lock.unlock()
    }

    // MARK: Mount table

    struct Mount: Sendable, Equatable {
        /// Where it is mounted right now (`/Users/zihado/nas-mnt/zpool`).
        var point: String
        /// What it IS, independent of where (`//192.168.123.104/zpool`).
        var id: String
        var kind: Kind = .internalDisk
        /// Human name of the volume, for a tooltip ("orico", "zpool").
        var name: String = ""
    }

    /// Where a folder physically lives. The sidebar draws all folders the same,
    /// so a NAS root that takes minutes to open looks exactly like a folder on
    /// the internal SSD — this is what lets the row say which it is.
    enum Kind: Sendable, Equatable {
        case internalDisk
        case external
        case network

        /// SF Symbol, following Finder's sidebar vocabulary.
        var symbol: String {
            switch self {
            case .internalDisk: return "folder"
            case .external: return "externaldrive"
            case .network: return "externaldrive.badge.wifi"
            }
        }

        var label: String {
            switch self {
            case .internalDisk: return "This Mac"
            case .external: return "External disk"
            case .network: return "Network share"
            }
        }
    }

    /// Which storage a path sits on. `.internalDisk` when it can't be told —
    /// the neutral answer, and the same icon the sidebar drew before.
    static func kind(for path: String) -> Kind {
        mount(containing: path)?.kind ?? .internalDisk
    }

    /// "Network share · zpool" for a row tooltip, nil when it's the boot disk
    /// (saying "This Mac" on every local folder would be noise).
    static func describe(_ path: String) -> String? {
        guard let m = mount(containing: path), m.kind != .internalDisk else { return nil }
        return m.name.isEmpty ? m.kind.label : "\(m.kind.label) · \(m.name)"
    }

    /// Pure classifier — testable without mounting anything.
    static func classify(device: String, isInternal: Bool?, isRemovable: Bool?) -> Kind {
        if device.hasPrefix("//") { return .network }
        if !device.hasPrefix("/"), device.contains(":") { return .network }
        if isRemovable == true { return .external }
        // `volumeIsInternal == false` on a local device means an attached disk.
        // Unknown (nil) stays internal: guessing "external" would put a drive
        // badge on the boot volume.
        if isInternal == false { return .external }
        return .internalDisk
    }

    private static let lock = NSLock()
    private static var mounts: [Mount]?

    private static func mount(containing path: String) -> Mount? {
        lock.lock()
        if mounts == nil { mounts = loadMounts() }
        let table = mounts ?? []
        lock.unlock()
        // Longest mount point wins: "/" prefixes everything, and a share can be
        // mounted underneath another volume's tree.
        return table.first { path == $0.point || path.hasPrefix($0.point == "/" ? "/" : $0.point + "/") }
    }

    /// Read the live mount table. `getmntinfo` is kernel state — no filesystem
    /// round-trip, so this is safe even when a share is wedged.
    private static func loadMounts() -> [Mount] {
        var raw: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&raw, MNT_NOWAIT)
        guard count > 0, let raw else { return [] }
        var out: [Mount] = []
        for i in 0..<Int(count) {
            var fs = raw[i]
            let point = string(from: &fs.f_mntonname)
            let from = string(from: &fs.f_mntfromname)
            guard !point.isEmpty else { continue }
            out.append(describe(mountPoint: point, device: from))
        }
        // Longest first, so the containment test finds the most specific mount.
        out.sort { $0.point.count > $1.point.count }
        return out
    }

    private static func string<T>(from tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// What this volume IS. Pure given its inputs, so it is unit-testable
    /// without mounting anything; `uuid` is the caller-supplied lookup result.
    static func identity(device: String, uuid: String?) -> String {
        // A network share names itself: //user@host/share. The user is who is
        // looking, not what is being looked at, so it is dropped — mounting the
        // same share as someone else must not invalidate the cache.
        if device.hasPrefix("//") {
            let body = device.dropFirst(2)
            let withoutUser = body.contains("@") ? body.drop(while: { $0 != "@" }).dropFirst() : body
            return "//" + withoutUser.lowercased()
        }
        // NFS and similar: host:/export.
        if !device.hasPrefix("/"), device.contains(":") { return device.lowercased() }
        // Local disk: /dev/diskNsM is NOT stable (numbering shifts between
        // boots and reattachments), so the volume UUID is the only usable id.
        if let uuid, !uuid.isEmpty { return "vol:" + uuid.lowercased() }
        return device
    }

    /// One filesystem lookup per MOUNT (not per file), done while the table is
    /// built. Network shares are answered from the device string alone, so a
    /// wedged NAS is never probed here.
    private static func describe(mountPoint: String, device: String) -> Mount {
        let isNetworkDevice = device.hasPrefix("//")
            || (!device.hasPrefix("/") && device.contains(":"))
        if isNetworkDevice {
            return Mount(point: mountPoint,
                         id: identity(device: device, uuid: nil),
                         kind: .network,
                         name: (mountPoint as NSString).lastPathComponent)
        }
        let values = try? URL(fileURLWithPath: mountPoint).resourceValues(
            forKeys: [.volumeUUIDStringKey, .volumeNameKey,
                      .volumeIsInternalKey, .volumeIsRemovableKey])
        return Mount(point: mountPoint,
                     id: identity(device: device, uuid: values?.volumeUUIDString),
                     kind: classify(device: device,
                                    isInternal: values?.volumeIsInternal,
                                    isRemovable: values?.volumeIsRemovable),
                     name: values?.volumeName ?? (mountPoint as NSString).lastPathComponent)
    }
}
