// MaintenanceTasks.swift
// Hal Universal
//
// Background housekeeping that runs once at app launch. Today: garbage-
// collect cached model files for embedding backends that have been
// removed from the codebase since the last install.
//
// Why this exists: when EmbeddingGemma was pulled in v2.0.1 (2026-05-20),
// any user who had already downloaded its ~210 MB of weights (whether
// via the pre-bug-fix App Store install, or a Debug build) would have
// those files sitting orphaned in Caches/huggingface/models/. The
// runtime path that uses them is commented out, so they're pure dead
// weight on disk. Hal cleans them up automatically at next launch.
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
}
