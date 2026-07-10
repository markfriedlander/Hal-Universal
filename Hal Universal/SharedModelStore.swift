// SharedModelStore.swift
// Hal Universal
//
// Hal's half of the cross-app model-sharing contract (v2.1). This is a
// deliberate near-verbatim port of Posey's `SharedModelStore.swift` — the two
// apps MUST agree on the App Group id, the on-disk layout, AND the
// `manifest.json` format, or sharing silently breaks. Posey shipped this
// contract first (2026-06); Hal adopts it here so a model downloaded by either
// app is a single shared copy both can load, and neither app's delete can pull
// the files out from under the other.
//
// The shared container lives at:
//   <AppGroup>/Models/huggingface/models/<repoID>/     ← MLX models + Nomic asset
//   <AppGroup>/Models/manifest.json                    ← co-ownership refcount
//
// The `Models/` subfolder is Posey's namespacing (so other shared state can
// coexist in the container later) and is part of the contract — Hal must match
// it exactly or it looks one folder too high and sees nothing.
//
// Ownership: each app records a claim (its bundle id) on every model it uses.
// Deleting in one app releases only that app's claim; the files are removed
// only when NO app still claims the model (see releaseClaim). All manifest
// access is wrapped in NSFileCoordinator so Hal and Posey can read/write it
// concurrently without corruption.

import Foundation

// ========== BLOCK SMS.1: SHARED MODEL STORE - PATHS - START ==========

/// The on-device store for Hal's downloadable AI models (the MLX chat LLMs and
/// the Nomic embedder asset), in the App Group container shared with Posey.
enum SharedModelStore {

    /// The shared App Group identifier. Must match Posey's exactly.
    static let appGroupID = "group.com.MarkFriedlander.aifamily"

    /// This app's stable identity for ownership claims in the manifest.
    static var thisAppID: String { Bundle.main.bundleIdentifier ?? "com.MarkFriedlander.Hal-Universal" }

    /// Container root for shared models, under a `Models/` subfolder (Posey's
    /// namespacing — part of the contract). **Fallback:** if the container is
    /// unavailable (entitlement missing, a Simulator without the group, a
    /// misconfigured build) we degrade to per-app Caches rather than crash — Hal
    /// keeps working, just without cross-app sharing or purge protection.
    static var root: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("Models", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The HuggingFace-style cache root inside the store. This is what
    /// `HubApi(downloadBase:)` points at; both the MLX models
    /// (`huggingface/models/<id>`) and the Nomic asset live under here.
    static var huggingFaceRoot: URL {
        root.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Directory for one MLX model id. Matches the legacy Caches layout
    /// (`huggingface/models/<modelID>`) so detection/load/delete are unchanged
    /// apart from the root.
    static func mlxModelDir(_ modelID: String) -> URL {
        huggingFaceRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    /// "Is this HuggingFace repo present on disk?" — a non-empty repo directory.
    /// Truth-on-disk, independent of HOW it was fetched (Hal's downloader,
    /// swift-embeddings' snapshot, or a copy Posey already placed in the shared
    /// container). Mid-download a partial dir reads present, so callers that
    /// care also check the downloader's in-flight state.
    static func isRepoDownloaded(_ repo: String) -> Bool {
        let dir = mlxModelDir(repo)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }

    /// Exclude a model directory from iCloud backup. MANDATORY for App Group
    /// containers: unlike `Library/Caches` (auto-excluded), the shared container
    /// IS backed up by default, so without this every user would burn multiple
    /// GB of iCloud quota on re-downloadable model weights (App Review 2.5.1).
    /// Idempotent; safe to call on every download-complete and migration.
    static func excludeFromBackup(_ modelID: String) {
        var dir = mlxModelDir(modelID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
// ========== BLOCK SMS.1: SHARED MODEL STORE - PATHS - END ==========

// ========== BLOCK SMS.3: REFCOUNT MANIFEST (app-family co-ownership) - START ==========

extension SharedModelStore {

    /// `manifest.json` at the store root tracks which apps in the family claim
    /// each model, so deleting from one app only removes the files when **no**
    /// app still claims them. Format is identical to Posey's — the two apps
    /// read/write the same file.
    private static var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    private struct Manifest: Codable {
        var version: Int = 1
        var models: [String: Entry] = [:]
        struct Entry: Codable {
            var claimedBy: [String] = []   // bundle ids
            var repo: String?              // hf repo id (recorded for cross-app match)
            var sizeBytes: Int64?
        }
    }

    /// Record that THIS app uses `modelID`. Called on a completed download and
    /// when Hal first loads/adopts a model that's already present in the shared
    /// container (so an adopted model gains Hal's claim and Posey's delete can't
    /// then pull it out from under Hal). Idempotent.
    static func claim(modelID: String, repo: String? = nil, sizeBytes: Int64? = nil) {
        mutateManifest { m in
            var e = m.models[modelID] ?? Manifest.Entry()
            if !e.claimedBy.contains(thisAppID) { e.claimedBy.append(thisAppID) }
            if let repo { e.repo = repo }
            if let sizeBytes { e.sizeBytes = sizeBytes }
            m.models[modelID] = e
        }
    }

    /// Release THIS app's claim on `modelID`. Returns `true` iff NO app claims it
    /// anymore — i.e. it is now safe to delete the files from disk. The caller
    /// (Hal's delete path) removes files ONLY on `true`, so deleting a model
    /// Posey still uses leaves Posey's copy intact.
    @discardableResult
    static func releaseClaim(modelID: String) -> Bool {
        var safeToDelete = false
        mutateManifest { m in
            guard var e = m.models[modelID] else { safeToDelete = true; return }
            e.claimedBy.removeAll { $0 == thisAppID }
            if e.claimedBy.isEmpty {
                m.models.removeValue(forKey: modelID)
                safeToDelete = true
            } else {
                m.models[modelID] = e
            }
        }
        return safeToDelete
    }

    /// Read-only: which apps currently claim `modelID`. Used for diagnostics
    /// (e.g. the SHARED_MODELS API verb) so we can see the ledger without a
    /// mutating call.
    static func claimants(modelID: String) -> [String] {
        let coordinator = NSFileCoordinator()
        return readManifest(coordinator).models[modelID]?.claimedBy ?? []
    }

    // MARK: coordinated read / write

    private static func readManifest(_ coordinator: NSFileCoordinator) -> Manifest {
        var result = Manifest()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: manifestURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    private static func mutateManifest(_ body: (inout Manifest) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        // Read-then-write under a single write coordination so two apps can't
        // interleave a lost update.
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: manifestURL, options: [], error: &coordError) { url in
            var manifest = Manifest()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
                manifest = decoded
            }
            body(&manifest)
            if let out = try? JSONEncoder().encode(manifest) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }
}
// ========== BLOCK SMS.3: REFCOUNT MANIFEST - END ==========

// ========== BLOCK SMS.4: CROSS-APP DOWNLOAD LOCK - START ==========

extension SharedModelStore {

    // A per-model "one app downloads at a time" lock, so Hal and Posey don't
    // both fetch the same repo into the shared container at once. Because the
    // downloader stages each file and atomic-moves it into place only when it's
    // whole, a race wouldn't corrupt files — but it WOULD waste bandwidth
    // downloading the same multi-GB model twice and show two competing progress
    // bars. This lock removes both: the second app sees the first's lock, waits,
    // and adopts the finished copy (zero re-download) instead of duplicating it.
    //
    // Stored in its OWN file (`download-locks.json`), deliberately NOT folded
    // into `manifest.json`: an un-updated Posey re-encoding the manifest would
    // silently drop any field it doesn't know about (Swift Codable ignores
    // unknown keys on decode, then omits them on the next encode), which would
    // erase a lock mid-download. A separate file the old code never writes stays
    // intact. Same NSFileCoordinator discipline as the manifest.
    //
    // Staleness: a holder that dies without releasing (force-quit, jetsam) would
    // otherwise pin the lock forever. We can't introspect another process's
    // download tasks, and a backgrounded holder's process is suspended so it
    // can't heartbeat — so liveness is a timestamp backstop. A live holder in the
    // foreground refreshes the timestamp from its progress loop; once no refresh
    // has happened for `downloadLockStaleSeconds`, the lock is treated as
    // abandoned and the waiter may take over. Worst case of a too-eager takeover
    // is one redundant download, never a corrupt file — so the window is
    // generous but not paranoid.

    /// A lock older than this (no refresh) is treated as abandoned. 10 minutes:
    /// long enough that a slow-but-live background download of one of the curated
    /// models isn't stolen, short enough that a genuine crash frees the slot in a
    /// tolerable time.
    static let downloadLockStaleSeconds: TimeInterval = 600

    private static var downloadLocksURL: URL { root.appendingPathComponent("download-locks.json") }

    private struct DownloadLocks: Codable {
        var version: Int = 1
        var locks: [String: Lock] = [:]
        struct Lock: Codable {
            var holder: String   // bundle id of the app currently downloading
            var since: Double    // epoch seconds; refreshed by the live holder
        }
    }

    /// Current lock record for `modelID`, or nil if the slot is free. Read-only;
    /// does not consider staleness (callers that need the take-over decision use
    /// `acquireDownloadLock`, which does).
    static func downloadLock(modelID: String) -> (holder: String, since: Double)? {
        let coordinator = NSFileCoordinator()
        guard let l = readDownloadLocks(coordinator).locks[modelID] else { return nil }
        return (l.holder, l.since)
    }

    /// Try to claim the download slot for `modelID`. Atomic test-and-set under a
    /// single write coordination. Granted (returns true) if the slot is free,
    /// already ours, or the current lock is stale (holder presumed dead). Returns
    /// false only when another app holds a fresh lock — in which case the caller
    /// should wait and adopt rather than start a duplicate download.
    static func acquireDownloadLock(modelID: String) -> Bool {
        var granted = false
        mutateDownloadLocks { db in
            if let l = db.locks[modelID],
               l.holder != thisAppID,
               (nowEpoch() - l.since) < downloadLockStaleSeconds {
                granted = false          // someone else holds a fresh lock
                return
            }
            db.locks[modelID] = DownloadLocks.Lock(holder: thisAppID, since: nowEpoch())
            granted = true
        }
        return granted
    }

    /// Bump our lock's timestamp so a live foreground download isn't judged
    /// stale. No-op if we don't hold it. Called from the progress loop.
    static func refreshDownloadLock(modelID: String) {
        mutateDownloadLocks { db in
            guard var l = db.locks[modelID], l.holder == thisAppID else { return }
            l.since = nowEpoch()
            db.locks[modelID] = l
        }
    }

    /// Release our lock (no-op if we don't hold it). Called on download complete
    /// (next to the claim), cancel, and failure.
    static func releaseDownloadLock(modelID: String) {
        mutateDownloadLocks { db in
            if db.locks[modelID]?.holder == thisAppID {
                db.locks.removeValue(forKey: modelID)
            }
        }
    }

    /// Human-friendly name for a holder bundle id, for the "Downloading in …"
    /// status the waiting app shows.
    static func appDisplayName(_ bundleID: String?) -> String {
        switch bundleID {
        case "com.MarkFriedlander.Posey":        return "Posey"
        case "com.MarkFriedlander.Hal-Universal": return "Hal"
        case .some(let id):                       return id
        case .none:                               return "another app"
        }
    }

    private static func nowEpoch() -> Double { Date().timeIntervalSince1970 }

    // MARK: coordinated read / write (mirrors the manifest's discipline)

    private static func readDownloadLocks(_ coordinator: NSFileCoordinator) -> DownloadLocks {
        var result = DownloadLocks()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: downloadLocksURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(DownloadLocks.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    private static func mutateDownloadLocks(_ body: (inout DownloadLocks) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: downloadLocksURL, options: [], error: &coordError) { url in
            var db = DownloadLocks()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(DownloadLocks.self, from: data) {
                db = decoded
            }
            body(&db)
            if let out = try? JSONEncoder().encode(db) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: test-only helpers (drive the DOWNLOAD_LOCK diagnostic verb)
    //
    // TEST-ONLY. These let the local-API test harness plant a "another app holds
    // the lock" state and clear it, to exercise Hal's wait/adopt/take-over path
    // on-device without a second real app in lockstep. Posey does NOT need to
    // copy this section — production sharing never calls it.

    static func debugPlantForeignLock(modelID: String, holder: String, ageSeconds: Double = 0) {
        mutateDownloadLocks { db in
            db.locks[modelID] = DownloadLocks.Lock(holder: holder, since: nowEpoch() - ageSeconds)
        }
    }

    static func debugClearAllDownloadLocks() {
        mutateDownloadLocks { db in db.locks.removeAll() }
    }

    static func debugAllDownloadLocks() -> [(modelID: String, holder: String, ageSeconds: Double)] {
        let coordinator = NSFileCoordinator()
        return readDownloadLocks(coordinator).locks.map {
            ($0.key, $0.value.holder, nowEpoch() - $0.value.since)
        }
    }
}
// ========== BLOCK SMS.4: CROSS-APP DOWNLOAD LOCK - END ==========
