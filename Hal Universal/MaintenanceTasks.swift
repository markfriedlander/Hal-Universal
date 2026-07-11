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
        // The migration touches the App-Group store (MainActor-isolated) and
        // refreshes the catalog, so it runs on the main actor. Cheap: on iOS the
        // Caches→App-Group move is a same-volume rename (re-links the directory,
        // never copies the GBs inside), so this doesn't block launch on file size.
        Task { @MainActor in migrateLegacyCachesModelsToSharedStore() }
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
}
// ==== LEGO END: 40 MaintenanceTasks (Launch Housekeeping) ====
