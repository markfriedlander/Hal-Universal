// ==== LEGO START: 40 MaintenanceTasks (Launch Housekeeping) ====
// MaintenanceTasks.swift
// Hal Universal
//
// Background housekeeping that runs once at app launch:
//   - garbage-collects cached model files for embedding backends that
//     have been removed from the codebase, so retired weights don't sit
//     orphaned on disk.
//   - migrates legacy model caches into the shared App-Group store.
//
// Extensible by design: add a backend's modelID to
// `removedEmbeddingBackendModelIDs` whenever a backend is retired, and
// its cache directory will be removed on the next launch of every
// affected device. Idempotent — no-op if the directory doesn't exist.

import Foundation
import SharedModelStoreKit

enum MaintenanceTasks {

    /// HuggingFace model IDs for embedding backends that USED TO be
    /// supported and whose cache directories should be wiped on launch.
    /// Adding an entry here is enough — the wipe happens automatically.
    /// Order doesn't matter; identifiers must match the path that
    /// MLXModelDownloader / BackgroundDownloadCoordinator wrote files to,
    /// which is `Caches/huggingface/models/<modelID>/`.
    nonisolated static let removedEmbeddingBackendModelIDs: [String] = [
        "mlx-community/embeddinggemma-300m-4bit",  // removed 2026-05-20
    ]

    /// Single entry point called once from the app's launch hook. Cheap
    /// to call — does an existence check before any file I/O. Logs each
    /// action via halLog so device-side telemetry shows which devices
    /// actually had orphaned files.
    nonisolated static func runAtLaunch() {
        cleanupOrphanedEmbeddingCaches()
        // Detect (synchronously, before any UI can appear) which models this device
        // carried under the OLD pre-version scheme, and record them durably. This
        // drives the one-time launch consent notice and the download flow's
        // "this is a replacement" wording. Cheap: a handful of directory-existence
        // checks. It RECORDS but never deletes — under the consent design, removing a
        // superseded copy happens only on a user action (the launch notice's "Remove
        // old copies", or Settings' "Free up old model files"), never automatically.
        recordPreVersionModelsAtLaunch()
        // The legacy Caches→App-Group migration still runs (a dead one-shot on shipped
        // devices, guarded by its own flag). It touches the MainActor-isolated store,
        // so it hops to the main actor. No automatic sweep follows it anymore; anything
        // it parks under a bare id is folded into the record (still no deletion).
        Task { @MainActor in
            migrateLegacyCachesModelsToSharedStore()
            recordPreVersionModelsAtLaunch()
        }
    }

    /// Iterate the removed-backend list and delete each one's cache dir
    /// if present. Idempotent. Errors are logged but never re-thrown —
    /// a cleanup failure should never block app launch.
    private nonisolated static func cleanupOrphanedEmbeddingCaches() {
        let fm = FileManager.default
        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            halLog("HALDEBUG-CLEANUP: cachesDirectory unavailable — skipping orphan-cache scan")
            return
        }
        for modelID in removedEmbeddingBackendModelIDs {
            let dir = cachesDir
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(modelID, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                // Not present — quietest path. No log to avoid noise on
                // every launch of every device (which is most of them).
                continue
            }
            do {
                try fm.removeItem(at: dir)
                halLog("HALDEBUG-CLEANUP: removed orphaned embedding cache for \(modelID) at \(dir.path)")
            } catch {
                halLog("HALDEBUG-CLEANUP: failed to remove \(dir.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - v2.1 legacy → shared-store model migration
    //
    // v2.0 downloaded MLX models + the Nomic embedder asset to the per-app
    // `Caches/huggingface/models/<org>/<name>/`. v2.1 reads from the App-Group
    // shared container instead (`SharedModelStore`), so a v2.0 user who upgrades
    // would find the shared store empty and appear to have lost every download —
    // facing a multi-GB re-fetch. This one-shot moves their existing models into
    // the shared store so they carry forward untouched. Idempotent + guarded by a
    // one-shot flag so it costs nothing after the first successful pass. On the
    // dev device (which never used the legacy location) it's a no-op that just
    // sets the flag. Posey needs no equivalent — it was greenfield on the shared
    // store from day one.

    private nonisolated static let didMigrateDefaultsKey = "didMigrateV2CachesModels.v1"

    /// Move any models sitting in the legacy `Caches/huggingface/models/` into the
    /// App-Group shared store, claiming each for Hal and excluding it from iCloud
    /// backup. Returns a human-readable action log (used by the LEGACY_MIGRATION
    /// test verb). `force` bypasses the one-shot flag for testing.
    @discardableResult
    @MainActor
    static func migrateLegacyCachesModelsToSharedStore(force: Bool = false) -> [String] {
        let fm = FileManager.default
        var actions: [String] = []

        if !force && UserDefaults.standard.bool(forKey: didMigrateDefaultsKey) {
            return ["skipped: already migrated (flag set)"]
        }

        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            halLog("HALDEBUG-MIGRATE: cachesDirectory unavailable — skipping legacy model migration")
            return ["skipped: no caches dir"]
        }

        let legacyHF = cachesDir.appendingPathComponent("huggingface", isDirectory: true)
        let legacyModelsRoot = legacyHF.appendingPathComponent("models", isDirectory: true)

        guard fm.fileExists(atPath: legacyModelsRoot.path) else {
            // Fresh v2.1 install, or a prior pass already drained it. Record the
            // flag so we never scan again.
            UserDefaults.standard.set(true, forKey: didMigrateDefaultsKey)
            return ["nothing to migrate: no legacy models dir"]
        }

        // Repo dirs live two levels down: models/<org>/<name>. Enumerating the
        // real directory (rather than a hardcoded curated list) means a user's
        // community models migrate too — nobody loses a download.
        let retired = Set(removedEmbeddingBackendModelIDs)
        var allOK = true
        let orgDirs = (try? fm.contentsOfDirectory(
            at: legacyModelsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        for orgDir in orgDirs {
            guard (try? orgDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let org = orgDir.lastPathComponent
            let nameDirs = (try? fm.contentsOfDirectory(
                at: orgDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

            for nameDir in nameDirs {
                guard (try? nameDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let repoID = "\(org)/\(nameDir.lastPathComponent)"

                // A retired backend the orphan-cleanup didn't catch — remove,
                // never migrate.
                if retired.contains(repoID) {
                    try? fm.removeItem(at: nameDir)
                    actions.append("removed retired \(repoID)")
                    continue
                }

                if SharedModelStore.isRepoDownloaded(repoID) {
                    // Shared store already has it (Posey, or a prior migration).
                    // The legacy copy is a redundant duplicate — drop it.
                    do {
                        try fm.removeItem(at: nameDir)
                        actions.append("reconciled \(repoID): shared copy exists → removed legacy duplicate")
                    } catch {
                        allOK = false
                        actions.append("FAILED removing legacy duplicate \(repoID): \(error.localizedDescription)")
                        halLog("HALDEBUG-MIGRATE: failed to remove legacy duplicate \(repoID): \(error.localizedDescription)")
                        continue
                    }
                } else {
                    // Move it into the shared store.
                    let dest = SharedModelStore.mlxModelDir(repoID)
                    do {
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Guard against an empty stub dir at the destination that
                        // would make moveItem fail (isRepoDownloaded reads empty
                        // dirs as absent).
                        try? fm.removeItem(at: dest)
                        try fm.moveItem(at: nameDir, to: dest)
                        actions.append("migrated \(repoID) → shared store")
                        halLog("HALDEBUG-MIGRATE: migrated \(repoID) from legacy Caches to shared store")
                    } catch {
                        allOK = false
                        actions.append("FAILED migrating \(repoID): \(error.localizedDescription)")
                        halLog("HALDEBUG-MIGRATE: failed to migrate \(repoID): \(error.localizedDescription)")
                        continue   // don't claim/exclude something we couldn't move
                    }
                }

                // Migrated or reconciled: record Hal's claim (so it's refcount-
                // protected once Posey is in the picture) and exclude from iCloud
                // backup (App-Group containers aren't auto-excluded — 2.5.1).
                SharedModelStore.claim(modelID: repoID, repo: repoID)
                SharedModelStore.excludeFromBackup(repoID)
            }

            // Drop the now-empty org dir.
            if let remaining = try? fm.contentsOfDirectory(atPath: orgDir.path), remaining.isEmpty {
                try? fm.removeItem(at: orgDir)
            }
        }

        // If the whole legacy tree drained, remove it so future launches
        // short-circuit even before the flag check.
        if let remaining = try? fm.contentsOfDirectory(atPath: legacyModelsRoot.path), remaining.isEmpty {
            try? fm.removeItem(at: legacyHF)
            actions.append("removed drained legacy huggingface dir")
        }

        // Only set the one-shot flag on a fully clean pass — a partial failure
        // (e.g. a cross-container move that didn't take) should retry next launch
        // rather than be silently abandoned.
        if allOK {
            UserDefaults.standard.set(true, forKey: didMigrateDefaultsKey)
        }

        // The catalog/Library show downloaded state by disk-truth, so the moved
        // models just need a refresh to appear.
        ModelCatalogService.shared.refreshDownloadStates()

        if actions.isEmpty { actions.append("no legacy repos found") }
        return actions
    }

    // MARK: - v2.5 model-storage migration: detection, consent, cleanup
    //
    // Version-safety moved every curated model from its PLAIN `repo` folder to a
    // version-stamped `repo@<sha>` folder, and the plain copy is never trusted again,
    // so the old plain copies are dead weight. We could delete them automatically, but
    // that removes files from a user's device (and forces a re-download) without
    // asking. So in HAL (which has real users) this is CONSENT-GATED:
    //
    //   - Detection (recordPreVersionModelsAtLaunch) runs automatically at launch and
    //     only RECORDS which models were affected. It never deletes.
    //   - Deletion (freeOldModelFiles) runs only on an explicit user action: the
    //     one-time launch notice's "Remove old copies", or the always-available
    //     "Free up old model files" button in Settings.
    //   - Per-model, the download flow uses `isPreVersionModel` to explain that a model
    //     you already had needs a fresh, verified copy.
    //
    // The two companion apps (unreleased, no users to ask) still sweep automatically.
    // Only Hal gates deletion behind consent. Safe by construction everywhere: the
    // cleanup only ever removes a superseded PLAIN copy of a pinned repo, never a
    // version-stamped copy, and never any conversation or memory data. `plainFolderRepos`
    // (the embedders + sd-turbo) are skipped — their bare id IS their real identity.

    private nonisolated static let hadOldModelsKey      = "modelMigration.hadOldModels.v1"
    private nonisolated static let preVersionRepoIDsKey = "modelMigration.preVersionRepoIDs.v1"
    private nonisolated static let noticeHandledKey     = "modelMigration.launchNoticeHandled.v1"

    /// The set of repo IDs that had a pre-version (plain) copy on this device. Durable:
    /// it outlives the plain files (so "you previously had this" survives the cleanup),
    /// and an entry is dropped only once its version-stamped replacement lands.
    nonisolated static func preVersionModelIDs() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: preVersionRepoIDsKey),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return ids
    }
    private nonisolated static func setPreVersionModelIDs(_ ids: Set<String>) {
        UserDefaults.standard.set((try? JSONEncoder().encode(ids)) ?? Data(), forKey: preVersionRepoIDsKey)
    }

    /// Did this device carry any pre-version model copies? Drives whether the one-time
    /// launch notice ever shows. Set once during detection; never auto-cleared.
    nonisolated static func deviceHadPreVersionModels() -> Bool {
        UserDefaults.standard.bool(forKey: hadOldModelsKey)
    }

    /// True while the one-time launch notice still needs showing: the device had old
    /// models AND the user hasn't dismissed the notice yet.
    @MainActor
    static var migrationNoticeShouldShow: Bool {
        deviceHadPreVersionModels() && !UserDefaults.standard.bool(forKey: noticeHandledKey)
    }

    /// Record that the user has seen and dismissed the one-time launch notice (via
    /// either button). It never shows again; the Settings button is the ongoing door.
    @MainActor
    static func markMigrationNoticeHandled() {
        UserDefaults.standard.set(true, forKey: noticeHandledKey)
    }

    /// Is `repoID` a model this device had under the old scheme and hasn't yet replaced
    /// with a verified copy? Drives the download flow's "this is a replacement" wording.
    nonisolated static func isPreVersionModel(_ repoID: String) -> Bool {
        preVersionModelIDs().contains(repoID)
    }

    /// Called when a version-stamped copy of `repoID` lands (download complete or
    /// adopt): the pre-version copy has now been replaced, so drop it from the record.
    nonisolated static func notePreVersionModelReplaced(_ repoID: String) {
        var ids = preVersionModelIDs()
        if ids.remove(repoID) != nil { setPreVersionModelIDs(ids) }
    }

    /// Detection (synchronous, at launch). For every pinned non-plainFolder repo with a
    /// plain copy on disk, record it as a pre-version model. Records only, never
    /// deletes. Idempotent (unions into the durable set).
    nonisolated static func recordPreVersionModelsAtLaunch() {
        var ids = preVersionModelIDs()
        var found = false
        for repoID in SharedModelStore.pinnedRevisions.keys {
            guard SharedModelStore.requiredIdentity(forRepoID: repoID) != repoID else { continue }
            guard SharedModelStore.isRepoDownloaded(repoID) else { continue }
            found = true
            ids.insert(repoID)
        }
        if found {
            setPreVersionModelIDs(ids)
            UserDefaults.standard.set(true, forKey: hadOldModelsKey)
            halLog("HALDEBUG-MIGRATE: recorded \(ids.count) pre-version model(s) present on device")
        }
    }

    /// Total bytes reclaimable by removing this device's superseded plain copies. Lets
    /// the Settings button show a size and disable itself when there's nothing to do.
    @MainActor
    static func reclaimableOldModelBytes() -> Int64 {
        var total: Int64 = 0
        for repoID in SharedModelStore.pinnedRevisions.keys {
            guard SharedModelStore.requiredIdentity(forRepoID: repoID) != repoID else { continue }
            guard SharedModelStore.isRepoDownloaded(repoID) else { continue }
            total += SharedModelStore.sizeOnDisk(repoID)
        }
        return total
    }

    /// The single cleanup engine behind all three doors (launch notice, Settings button,
    /// and the companion apps' automatic sweep). Removes this device's superseded plain
    /// copies and returns the bytes actually freed. For each pinned non-plain repo with a
    /// plain copy, drop Hal's claim on the bare id and, once no app in the family still
    /// claims it, delete the folder (the store's refcount keeps a sibling's copy safe).
    /// Also clears each removed repo from the pre-version record. Idempotent.
    @MainActor
    @discardableResult
    static func freeOldModelFiles() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for repoID in SharedModelStore.pinnedRevisions.keys {
            guard SharedModelStore.requiredIdentity(forRepoID: repoID) != repoID else { continue }
            guard SharedModelStore.isRepoDownloaded(repoID) else { continue }
            let size = SharedModelStore.sizeOnDisk(repoID)
            // Drop Hal's claim on the bare id; the store deletes files only when no app
            // in the family still claims it. Re-check presence before removing.
            let safeToDelete = SharedModelStore.releaseClaim(modelID: repoID)
            guard safeToDelete, SharedModelStore.isRepoDownloaded(repoID) else {
                halLog("HALDEBUG-SWEEP: kept plain copy of \(repoID) — another app still claims it")
                continue
            }
            do {
                try fm.removeItem(at: SharedModelStore.mlxModelDir(repoID))
                freed += size
                halLog("HALDEBUG-SWEEP: reaped superseded plain copy of \(repoID) (\(size) bytes)")
            } catch {
                halLog("HALDEBUG-SWEEP: failed to reap plain \(repoID): \(error.localizedDescription)")
            }
        }
        return freed
    }

    // MARK: - TEST-ONLY helpers (drive the LEGACY_MIGRATION verb)
    //
    // The dev device never used the legacy location, so real migration is a
    // no-op there. These let the on-device test harness plant a fake model in the
    // legacy path, run the migration, inspect where things landed, and clean up —
    // exercising both the move and the already-present-reconcile branches without
    // a real v2.0 install. Not used by production launch.

    nonisolated static func debugPlantLegacyModel(repoID: String) -> Bool {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let dir = caches.appendingPathComponent("huggingface/models/\(repoID)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ok = (try? Data("{\"_legacy_migration_test\":true}".utf8)
            .write(to: dir.appendingPathComponent("config.json"))) != nil
        return ok
    }

    nonisolated static func debugLegacyPresent(repoID: String) -> Bool {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let dir = caches.appendingPathComponent("huggingface/models/\(repoID)", isDirectory: true)
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }

    nonisolated static func debugMigrationFlagSet() -> Bool {
        UserDefaults.standard.bool(forKey: didMigrateDefaultsKey)
    }

    nonisolated static func debugResetMigrationFlag() {
        UserDefaults.standard.removeObject(forKey: didMigrateDefaultsKey)
    }

    /// Remove a (test) repo from BOTH the legacy and shared locations and drop
    /// Hal's claim — leaves the device clean after a migration test. MainActor
    /// because it touches the (MainActor-isolated) shared store.
    @MainActor
    static func debugRemoveModelEverywhere(repoID: String) {
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("huggingface/models/\(repoID)", isDirectory: true))
        }
        try? fm.removeItem(at: SharedModelStore.mlxModelDir(repoID))
        _ = SharedModelStore.releaseClaim(modelID: repoID)
    }

    // MARK: - TEST-ONLY: migration-consent state (drive the MIGRATION_DEBUG verb)
    //
    // The dev device's real pre-version copies were already reaped, so the launch
    // notice won't arm naturally. These let the harness force the "affected user"
    // state to screenshot the notice + Settings button, inspect the flags, and reset.
    // Never used by production.

    /// Arm the one-time launch notice for the next launch (device "had old models",
    /// notice not yet handled).
    nonisolated static func debugForceShowNotice() {
        UserDefaults.standard.set(true, forKey: hadOldModelsKey)
        UserDefaults.standard.removeObject(forKey: noticeHandledKey)
    }

    /// Mark a repo as a pre-version model (drives Layer 3's replacement wording).
    nonisolated static func debugAddPreVersionModel(_ repoID: String) {
        var ids = preVersionModelIDs(); ids.insert(repoID); setPreVersionModelIDs(ids)
        UserDefaults.standard.set(true, forKey: hadOldModelsKey)
    }

    /// Clear all migration-consent state (arm flag, handled flag, pre-version set).
    nonisolated static func debugResetMigrationConsent() {
        UserDefaults.standard.removeObject(forKey: hadOldModelsKey)
        UserDefaults.standard.removeObject(forKey: noticeHandledKey)
        UserDefaults.standard.removeObject(forKey: preVersionRepoIDsKey)
    }

    @MainActor
    static func debugMigrationStateJSON() -> String {
        let pre = preVersionModelIDs().sorted()
        let preJSON = "[" + pre.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        return "{\"hadOldModels\":\(deviceHadPreVersionModels()),"
            + "\"noticeHandled\":\(UserDefaults.standard.bool(forKey: noticeHandledKey)),"
            + "\"shouldShow\":\(migrationNoticeShouldShow),"
            + "\"preVersion\":\(preJSON),"
            + "\"reclaimableBytes\":\(reclaimableOldModelBytes())}"
    }
}
// ==== LEGO END: 40 MaintenanceTasks (Launch Housekeeping) ====
