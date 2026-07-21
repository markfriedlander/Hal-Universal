// MLXModelDownloader.swift
// Hal Universal
//
// Downloads MLX-compatible models from HuggingFace into the shared store
// and tracks their on-disk state. Two cooperating singletons:
//
//   BackgroundDownloadCoordinator — the low-level transport. Owns one
//   foreground URLSession and one background URLSession; enqueues a
//   download task per file in a model's repo; migrates tasks between
//   the two sessions on app-lifecycle transitions; persists per-task
//   metadata so background-session callbacks delivered after a relaunch
//   can route correctly. Posts `.mlxModelDidDownload` when every file for
//   a model has landed.
//
//   MLXModelDownloader — the higher-level coordinator. Holds the
//   user-facing @Published `downloadStates` dict that the Model Library
//   UI binds to; manages a queue of downloads (one active, others
//   waiting); handles disk-space pre-flight; persists in-flight markers
//   so a download interrupted by termination resumes on next launch;
//   listens for the coordinator's completion notification and updates
//   `downloadedModelIDs` for the runtime "is this model present?" check.
//
// The two classes are tightly coupled: MLXModelDownloader calls into the
// coordinator's API and observes its notification, and the coordinator
// calls back into the downloader's completion hook.
//
// `.mlxModelDidDownload` Notification.Name is defined at the bottom of
// this file. HalAppDelegate routes iOS background-session events to the
// coordinator's `backgroundCompletionHandler`.

import Foundation
import SwiftUI
import Combine
import UIKit


// ==== LEGO START: 45 BackgroundDownloadCoordinator + MLXModelDownloader ====

// MARK: - Background Download Coordinator
//
// True iOS-style background downloader for HuggingFace MLX models. Replaces
// HubApi.snapshot's foreground URLSession with a `URLSessionConfiguration.background`
// session so model downloads continue while the app is suspended OR terminated.
// iOS delivers completion events to `HalAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
// even after the app process has been killed; we reconnect to the in-flight
// session by re-instantiating the URLSession with the same identifier.
//
// Design overview:
//   - One URLSession with a fixed background identifier (process-wide singleton).
//   - For each model, we fetch the file list from the HF tree API, filter by
//     MLX-compatible patterns (*.safetensors, *.json, *.jinja — same set
//     mlx-swift-lm uses), and enqueue a download task per file.
//   - Per-task metadata (modelID, target path) is persisted in UserDefaults
//     so callbacks delivered after a relaunch can route correctly even
//     though the in-memory map was wiped by termination.
//   - When all files for a model land, we post `.mlxModelDidDownload` —
//     same notification the legacy HubApi path used, so downstream
//     observers (catalog refresh, MLX wrapper loading) keep working unchanged.
//
// What this DOESN'T preserve from HubApi:
//   - LFS pointer resolution beyond what the resolve URL handles
//   - Authenticated repo access via HF_TOKEN (curated models are all public)
//   - Symlinked file deduplication across revisions
//
// All three are acceptable losses for the curated public-model use case.
class BackgroundDownloadCoordinator: NSObject, URLSessionDownloadDelegate, ObservableObject {
    static let shared = BackgroundDownloadCoordinator()

    /// Background URLSession identifier. Must be stable across app launches so
    /// iOS can reconnect us to in-flight downloads from a previous run.
    static let backgroundSessionID = "com.MarkFriedlander.Hal-Universal.modelDownload.v1"

    /// Completion handler passed in by `HalAppDelegate`. Invoked once all
    /// pending background events have been processed so iOS knows it's safe
    /// to suspend us again.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Per-Task Metadata (session-aware)
    //
    // Two storage backends:
    //   - Background tasks: persisted to UserDefaults. Background URLSession
    //     tasks survive app termination, so on relaunch we need to look up
    //     each reconnected task's modelID/filename/target to route delegate
    //     callbacks correctly.
    //   - Foreground tasks: in-memory only. Foreground URLSession tasks die
    //     with the app, so persistence would be pointless. Lighter weight.
    //
    // Key collision is avoided naturally because the two dictionaries are
    // separate. Within each session, taskIdentifier is unique.
    struct TaskContext: Codable {
        let modelID: String     // e.g. "mlx-community/gemma-4-e2b-it-4bit"
        let filename: String    // e.g. "model.safetensors"
        let targetPath: String  // absolute path where the finished file lands
    }

    private let taskContextDefaultsKey = "bgDownloadTaskContexts.v1"

    /// Background-session task contexts. Persisted across app launches.
    private var backgroundTaskContexts: [String: TaskContext] {
        get {
            guard let data = UserDefaults.standard.data(forKey: taskContextDefaultsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: TaskContext].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: taskContextDefaultsKey)
            }
        }
    }

    /// Foreground-session task contexts. In-memory only.
    private var foregroundTaskContexts: [Int: TaskContext] = [:]

    private func contextLookup(session: SessionKind, taskID: Int) -> TaskContext? {
        switch session {
        case .foreground: return foregroundTaskContexts[taskID]
        case .background: return backgroundTaskContexts[String(taskID)]
        }
    }

    private func saveContext(_ context: TaskContext, session: SessionKind, taskID: Int) {
        switch session {
        case .foreground:
            foregroundTaskContexts[taskID] = context
        case .background:
            var contexts = backgroundTaskContexts
            contexts[String(taskID)] = context
            backgroundTaskContexts = contexts
        }
    }

    private func removeContext(session: SessionKind, taskID: Int) {
        switch session {
        case .foreground:
            foregroundTaskContexts.removeValue(forKey: taskID)
        case .background:
            var contexts = backgroundTaskContexts
            contexts.removeValue(forKey: String(taskID))
            backgroundTaskContexts = contexts
        }
    }

    // MARK: - Dual URLSessions (v2.0 hybrid architecture)
    //
    // Hal uses TWO URLSession instances for model downloads:
    //
    //   foregroundSession — standard config. Fast (~99 Mbps observed on
    //   110 Mbps WiFi). Active while the app is in the foreground. Tasks
    //   die when the app is suspended or terminated.
    //
    //   backgroundSession — background mode with the stable identifier
    //   below. Bandwidth-throttled by iOS (~1.7 MB/s observed) but
    //   survives app suspension, screen lock, and even termination.
    //   Reconnects automatically on relaunch.
    //
    // On didEnterBackground, in-flight foreground tasks are migrated to
    // the background session via cancel-with-resume-data so the download
    // keeps going (slowly) while the user is away. On willEnterForeground,
    // they're migrated back so the user gets full bandwidth while watching.
    //
    // This matches the canonical iOS pattern used by Apple's own apps
    // (App Store, Podcasts, Music): fast when watching, resilient when not.

    enum SessionKind { case foreground, background }

    /// Per-task tracking key — discriminates foreground vs background tasks
    /// because URLSession.taskIdentifier is unique only within a single
    /// session. A foreground task with ID 5 and a background task with ID 5
    /// are completely different tasks; keying by raw Int would collide.
    struct TaskKey: Hashable {
        let session: SessionKind
        let id: Int
    }

    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        // Serial queue keeps delegate callbacks ordered, matching background.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.allowsCellularAccess = true              // user already accepted the hardware disclosure
        config.sessionSendsLaunchEvents = true          // wake us when complete
        config.isDiscretionary = false                  // ASAP, not "when convenient"
        // Note: shouldUseExtendedBackgroundIdleMode was deprecated in iOS 18.4
        // (no longer supported by URLSession). It used to signal "extend idle
        // mode for this session to keep connections open longer." Removing it
        // has no functional impact on our use case — background URLSession
        // already keeps state across app suspension via nsurlsessiond.
        // The OperationQueue must be serial to keep delegate ordering deterministic.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    /// Resolve which session a delegate callback came from.
    private func sessionKind(of session: URLSession) -> SessionKind {
        return session === foregroundSession ? .foreground : .background
    }

    /// Lifecycle observers held for the coordinator's lifetime so the
    /// notification subscriptions persist. Set up in init.
    private var lifecycleObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        halLog("HALDEBUG-BGDL: BackgroundDownloadCoordinator init; will lazily create URLSessions (fg + bg id=\(Self.backgroundSessionID))")
        // Touch the lazy background session so iOS immediately replays any
        // pending events from a previous app instance. Foreground session
        // is touched on first download attempt.
        _ = backgroundSession
        setupLifecycleObservers()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupLifecycleObservers() {
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.migrateForegroundTasksToBackground() }
        }
        let fgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.migrateBackgroundTasksToForeground() }
        }
        lifecycleObservers = [bgObserver, fgObserver]
    }

    // MARK: - Pinned revisions
    //
    // Curated models pinned to a specific HF revision (a commit SHA) so an
    // upstream re-conversion can never silently break a shipped build. Any repo
    // not listed here tracks `main` (HEAD), unchanged from before.
    //
    // Why this exists: on 2026-07-06 `mlx-community/gemma-4-e2b-it-4bit` was
    // re-converted upstream; the new conversion quantizes a layer that
    // mlx-swift-lm's Gemma4Text builds as a non-quantizable `ScaledLinear`, so
    // the model fails to load ("Mismatched parameter per_layer_model_projection…
    // Actual [8960,192], expected [8960,1536]"). Nothing in Hal's download code
    // broke — HEAD simply moved. Pinning to the last-good revision immunizes us.
    // Full story: HISTORY 2026-07-20 (Gemma revision-pin). The lookup is applied
    // at BOTH the tree-listing and file-resolve URLs below, so every download
    // path (first-time, resume, adopt) honors the pin without touching callers.
    static let pinnedRevisions: [String: String] = [
        // Last revision before the 2026-07-06 re-conversion (2026-05-19): original
        // working weights + the latest chat-template fix. Verified via the repo's
        // HF commit history.
        "mlx-community/gemma-4-e2b-it-4bit": "2c3e507453b4f218d05fe3cc97bea5c5a654257e"
    ]

    /// The HF revision to download `repoID` at: a pinned commit SHA if the repo
    /// is pinned, otherwise `"main"` (HEAD, the prior behavior for everything).
    static func revision(forRepoID repoID: String) -> String {
        pinnedRevisions[repoID] ?? "main"
    }

    // MARK: - Public API

    /// Kick off a background download for every file in the repo that matches
    /// the MLX patterns. Returns immediately. Use the `progress(for:)` /
    /// `isComplete(for:)` accessors to track state. Posts `.mlxModelDidDownload`
    /// when ALL files for the model have finished landing.
    ///
    /// `repoID` is the full HF repo path (e.g. "mlx-community/gemma-4-e2b-it-4bit").
    /// `modelID` is what MLXModelDownloader uses to identify the model — usually
    /// identical to `repoID`.
    func startDownload(modelID: String, repoID: String) async throws {
        halLog("HALDEBUG-BGDL: startDownload modelID=\(modelID) repoID=\(repoID)")

        // DEDUP: cancel any in-flight tasks for this model in EITHER session
        // before enqueuing fresh ones. Without this, repeat calls accumulate
        // duplicate tasks racing for the same bytes (we surfaced this bug
        // today via HALDEBUG-BGDL-BYTES: model.safetensors had 3 concurrent
        // tasks at ~0.7 MB/s each instead of 1 at ~2-3 MB/s).
        var cancelledIDs: [String] = []
        for session in [foregroundSession, backgroundSession] {
            let kind = sessionKind(of: session)
            let snapshot = await session.allTasks
            for task in snapshot {
                guard let context = contextLookup(session: kind, taskID: task.taskIdentifier),
                      context.modelID == modelID else { continue }
                if task.state == .running || task.state == .suspended {
                    task.cancel()
                    cancelledIDs.append("\(kind == .foreground ? "fg" : "bg"):\(task.taskIdentifier)")
                }
            }
        }
        if !cancelledIDs.isEmpty {
            halLog("HALDEBUG-BGDL: Cancelled \(cancelledIDs.count) stale in-flight task(s) for \(modelID): \(cancelledIDs)")
        }

        // Fetch the file list from the HF tree API.
        let allFiles = try await fetchRepoFileList(repoID: repoID)
        let mlxFiles = allFiles.filter { Self.matchesMLXPattern($0) }
        if mlxFiles.isEmpty {
            halLog("HALDEBUG-BGDL: No MLX-compatible files found in \(repoID); aborting")
            throw NSError(domain: "BackgroundDownloadCoordinator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No MLX-compatible files found in repository \(repoID)."
            ])
        }
        halLog("HALDEBUG-BGDL: Found \(mlxFiles.count) MLX files for \(modelID): \(mlxFiles.joined(separator: ", "))")

        // Ensure target directory exists.
        let modelDir = modelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Initialize per-model byte tracking so progress can be computed.
        bytesExpectedByModel[modelID] = 0
        bytesWrittenByModel[modelID] = 0
        filesPendingByModel[modelID] = Set(mlxFiles)

        // Choose session based on current app state. Foreground = fast for
        // active downloads; background = resilient if app is suspended.
        // The didEnterBackground / willEnterForeground migration handlers
        // will move tasks between sessions as the app's state changes.
        let appActive = await MainActor.run { UIApplication.shared.applicationState == .active }
        let chosenSession = appActive ? foregroundSession : backgroundSession
        let chosenKind: SessionKind = appActive ? .foreground : .background
        halLog("HALDEBUG-BGDL: Enqueuing on \(chosenKind == .foreground ? "FOREGROUND" : "BACKGROUND") session (app state: \(appActive ? "active" : "inactive/background"))")

        // Enqueue a download task per file.
        for filename in mlxFiles {
            // Files already present at target with non-zero size: skip.
            let targetURL = modelDir.appendingPathComponent(filename)
            if let existingSize = try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64,
               existingSize > 0 {
                halLog("HALDEBUG-BGDL: \(filename) already present (\(existingSize) bytes); skipping")
                var pending = filesPendingByModel[modelID] ?? []
                pending.remove(filename)
                filesPendingByModel[modelID] = pending
                continue
            }

            guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(Self.revision(forRepoID: repoID))/\(filename)") else {
                halLog("HALDEBUG-BGDL: Could not build URL for \(filename); skipping")
                continue
            }

            let task = chosenSession.downloadTask(with: url)
            let context = TaskContext(modelID: modelID, filename: filename, targetPath: targetURL.path)
            saveContext(context, session: chosenKind, taskID: task.taskIdentifier)
            task.resume()
            halLog("HALDEBUG-BGDL: Enqueued \(chosenKind == .foreground ? "fg" : "bg") task \(task.taskIdentifier) for \(filename)")
        }

        // If all files were already present, treat the model as complete now.
        if (filesPendingByModel[modelID] ?? []).isEmpty {
            await MainActor.run { self.notifyModelDownloadComplete(modelID: modelID) }
        }
    }

    // MARK: - Per-Model Progress Tracking

    @Published var bytesWrittenByModel: [String: Int64] = [:]
    @Published var bytesExpectedByModel: [String: Int64] = [:]
    private var filesPendingByModel: [String: Set<String>] = [:]
    /// Per-model record of files whose move-into-place failed: modelID → (file →
    /// error). A model with any entry here when its last file settles is a FAILED
    /// download — it must not be claimed or marked downloaded. Cleared when the
    /// failure is reported (or, implicitly, when a fresh download re-seeds pending).
    private var filesFailedByModel: [String: [String: String]] = [:]

    func progress(for modelID: String) -> Double {
        let expected = bytesExpectedByModel[modelID] ?? 0
        let written = bytesWrittenByModel[modelID] ?? 0
        guard expected > 0 else { return 0 }
        return min(1.0, Double(written) / Double(expected))
    }

    func isComplete(for modelID: String) -> Bool {
        return (filesPendingByModel[modelID] ?? []).isEmpty && (bytesExpectedByModel[modelID] ?? 0) > 0
    }

    // MARK: - HuggingFace Tree API
    //
    // GET https://huggingface.co/api/models/<repo>/tree/<revision>   (revision = pin or "main")
    // Returns a JSON array of {"type": "file"|"directory", "path": "...", "size": Int}
    private func fetchRepoFileList(repoID: String) async throws -> [String] {
        // `?recursive=1` is REQUIRED. Without it the HF tree API returns only the
        // top level: root files, plus subfolders as `type: "directory"` entries
        // (which the `type == "file"` filter below then drops). So every file
        // inside a subfolder — `1_Pooling/config.json`, `unet/…`, `onnx/…` — is
        // invisible, and the model downloads "successfully" while silently missing
        // its nested files. Flat repos (all of Hal's Picks today) are unaffected;
        // this matters for the Community browser, which points at arbitrary repos.
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(Self.revision(forRepoID: repoID))?recursive=1") else {
            throw NSError(domain: "BackgroundDownloadCoordinator", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bad repo ID: \(repoID)"
            ])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BackgroundDownloadCoordinator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "HF tree API returned status \(status) for \(repoID)"
            ])
        }
        struct TreeEntry: Decodable {
            let type: String
            let path: String
            let size: Int64?
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.filter { $0.type == "file" }.map { $0.path }
    }

    // MARK: - Pattern Matching
    //
    // Same set mlx-swift-lm's ModelFactory uses: *.safetensors, *.json, *.jinja.
    // The *.jinja is critical for modern chat-template models (Gemma 4 etc).
    private static func matchesMLXPattern(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".json")
            || lower.hasSuffix(".jinja")
    }

    private func modelDirectory(for modelID: String) -> URL {
        // v2.1: models live in the App-Group shared store, not per-app Caches,
        // so Hal and Posey share one copy. See SharedModelStore.swift.
        SharedModelStore.mlxModelDir(modelID)
    }

    // MARK: - Completion Notification

    @MainActor
    private func notifyModelDownloadComplete(modelID: String) {
        halLog("HALDEBUG-BGDL: ✅ Model \(modelID) fully downloaded; posting .mlxModelDidDownload")
        // Mark in MLXModelDownloader's downloaded set so future model-status
        // queries report it as downloaded.
        MLXModelDownloader.shared.markModelAsDownloadedFromBackground(modelID: modelID)
        // v2.1 shared store: record Hal's claim on the freshly-downloaded model
        // (so Posey's delete can't pull it out from under Hal) and exclude it
        // from iCloud backup — App Group containers aren't auto-excluded the way
        // Library/Caches is (App Review 2.5.1).
        SharedModelStore.claim(modelID: modelID, repo: modelID)
        SharedModelStore.excludeFromBackup(modelID)
        // Release the cross-app download lock now the model is whole. This is the
        // success release site (claim first, then release) — placing it here
        // rather than in performLockedDownload means a completion delivered after
        // a background relaunch, when that Task is gone, still clears the lock. A
        // waiting sibling sees "no lock + a claim" and adopts.
        SharedModelStore.releaseDownloadLock(modelID: modelID)
        NotificationCenter.default.post(name: .mlxModelDidDownload, object: nil, userInfo: ["modelID": modelID])
    }

    /// The failure counterpart to ``notifyModelDownloadComplete``. Called when a
    /// model's last file settles and one or more files failed to move into place.
    ///
    /// It is the mirror image of the success path, and the asymmetry is the point:
    /// it does **NOT** `claim` the model and does **NOT** mark it downloaded — those
    /// two lines are exactly what wrote a phantom into the shared manifest. It DOES
    /// release the cross-app download lock (Hal is no longer downloading, so a
    /// sibling may try) and delete the partial model directory (a half-model is
    /// unusable; a clean slate lets a retry start fresh). The dir is model-scoped
    /// (`mlxModelDir(id)`), never the shared root.
    ///
    /// It posts `.mlxModelDownloadFailed` so `waitForModelCompletion` — which waits
    /// on the success notification with no timeout — throws instead of spinning
    /// forever, and the UI can surface the error.
    @MainActor
    private func notifyModelDownloadFailed(modelID: String, failures: [String: String]) {
        let summary = failures.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        halLog("HALDEBUG-BGDL: ❌ Model \(modelID) FAILED — \(failures.count) file(s) did not save. Not claiming, not marking downloaded. [\(summary)]")

        // Release the lock; do NOT claim, do NOT mark downloaded.
        SharedModelStore.releaseDownloadLock(modelID: modelID)

        // Remove the partial model directory so a retry starts clean and no
        // half-model masquerades as present. Model-scoped (the coordinator's own
        // `modelDirectory(for:)` = `mlxModelDir(id)`) — never the shared root.
        let dir = modelDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }

        // DownloadState lives on MLXModelDownloader, not the coordinator — mirror
        // the success path, which delegates its state bookkeeping to `.shared`.
        MLXModelDownloader.shared.markModelFailedFromBackground(modelID: modelID, failureCount: failures.count)

        // Clear the failure ledger for this model and post the failure signal.
        self.filesFailedByModel[modelID] = nil
        NotificationCenter.default.post(name: .mlxModelDownloadFailed, object: nil, userInfo: ["modelID": modelID])
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kind = sessionKind(of: session)
        guard let context = contextLookup(session: kind, taskID: downloadTask.taskIdentifier) else {
            halLog("HALDEBUG-BGDL: didFinishDownloadingTo received for unknown \(kind == .foreground ? "fg" : "bg") task \(downloadTask.taskIdentifier); ignoring")
            return
        }

        // Move the downloaded temp file to the target path. This must happen
        // synchronously inside the delegate callback — iOS deletes `location`
        // as soon as we return.
        let target = URL(fileURLWithPath: context.targetPath)
        // Create the file's PARENT directory first. For a nested file
        // (`1_Pooling/config.json`), `target` lives in a subfolder that
        // `createDirectory(modelDir)` at enqueue time did NOT create, and
        // `moveItem` will not make intermediates — so without this the move
        // throws and (because iOS reclaims `location` the instant we return) the
        // bytes are simply gone. No-op for a root-level file.
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        var moveError: String?
        do {
            try FileManager.default.moveItem(at: location, to: target)
            halLog("HALDEBUG-BGDL: Moved \(context.filename) → \(target.path) (\(kind == .foreground ? "fg" : "bg") task \(downloadTask.taskIdentifier))")
        } catch {
            moveError = error.localizedDescription
            halLog("HALDEBUG-BGDL: ❌ Move failed for \(context.filename): \(error.localizedDescription)")
        }

        // Update bookkeeping. Note: didCompleteWithError will fire shortly
        // after this; final cleanup happens there.
        //
        // A failed move must NOT be allowed to count as a finished file. The old
        // code removed `filename` from `pending` unconditionally, so a model whose
        // files all failed to move still emptied `pending`, fired
        // notifyModelDownloadComplete, and — the dangerous part — CLAIMED the model
        // in the shared manifest and marked it downloaded. The ledger then asserted
        // Hal owned a model that wasn't on disk (the same shape of lie that made the
        // clearHubCache bug destructive), and the user saw "Model ready" for a model
        // that would fail to load later. So we track per-file move failures and, when
        // the last file settles, route to success ONLY if none failed.
        // Bind an immutable copy for the concurrently-executing Task (capturing the
        // `var` directly is a Swift 6 data-race error).
        let moveErrorResult = moveError
        Task { @MainActor in
            var pending = self.filesPendingByModel[context.modelID] ?? []
            pending.remove(context.filename)
            self.filesPendingByModel[context.modelID] = pending
            if let moveErrorResult {
                self.filesFailedByModel[context.modelID, default: [:]][context.filename] = moveErrorResult
            }
            if pending.isEmpty {
                if let failures = self.filesFailedByModel[context.modelID], !failures.isEmpty {
                    self.notifyModelDownloadFailed(modelID: context.modelID, failures: failures)
                } else {
                    self.notifyModelDownloadComplete(modelID: context.modelID)
                }
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let kind = sessionKind(of: session)
        guard let context = contextLookup(session: kind, taskID: downloadTask.taskIdentifier) else { return }
        let key = TaskKey(session: kind, id: downloadTask.taskIdentifier)
        Task { @MainActor in
            // Update the per-model totals. Each file contributes its own
            // expected-bytes count; we accumulate so the model's overall
            // progress is bytes-summed across all files.
            //
            // Because didWriteData fires repeatedly with cumulative totals
            // *for that single file*, we recompute by subtracting the
            // previous per-task contribution and adding the new one.
            let prev = self.bytesWrittenByTask[key] ?? 0
            let delta = max(0, totalBytesWritten - prev)
            self.bytesWrittenByTask[key] = totalBytesWritten
            self.bytesWrittenByModel[context.modelID, default: 0] += delta

            // Same trick for expected. Update if it shrank from -1 (unknown).
            if totalBytesExpectedToWrite > 0 {
                let prevExpected = self.bytesExpectedByTask[key] ?? 0
                let expectedDelta = totalBytesExpectedToWrite - prevExpected
                if expectedDelta != 0 {
                    self.bytesExpectedByTask[key] = totalBytesExpectedToWrite
                    self.bytesExpectedByModel[context.modelID, default: 0] += expectedDelta
                }
            }

            // Throttled byte-flow logging (v2.0 diagnostic addition).
            // Logs include session kind (fg/bg) so we can correlate
            // throughput with which session is actively transferring.
            let now = Date()
            let lastLog = self.lastByteLogTimeByTask[key] ?? .distantPast
            if now.timeIntervalSince(lastLog) >= 5.0 {
                let prevBytesAtLog = self.lastByteLogBytesByTask[key] ?? 0
                let bytesSinceLastLog = max(0, totalBytesWritten - prevBytesAtLog)
                let secondsSinceLastLog = lastLog == .distantPast ? 0 : now.timeIntervalSince(lastLog)
                let throughputMBs = secondsSinceLastLog > 0
                    ? Double(bytesSinceLastLog) / 1_048_576.0 / secondsSinceLastLog
                    : 0
                let writtenMB = Double(totalBytesWritten) / 1_048_576.0
                let expectedMB = totalBytesExpectedToWrite > 0
                    ? Double(totalBytesExpectedToWrite) / 1_048_576.0
                    : -1
                let pct = totalBytesExpectedToWrite > 0
                    ? Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
                    : -1
                let kindStr = kind == .foreground ? "fg" : "bg"
                if expectedMB > 0 {
                    halLog("HALDEBUG-BGDL-BYTES: \(kindStr) task \(downloadTask.taskIdentifier) (\(context.filename)) \(String(format: "%.1f", writtenMB))/\(String(format: "%.1f", expectedMB)) MB (\(pct)%) | \(String(format: "%.2f", throughputMBs)) MB/s")
                } else {
                    halLog("HALDEBUG-BGDL-BYTES: \(kindStr) task \(downloadTask.taskIdentifier) (\(context.filename)) \(String(format: "%.1f", writtenMB)) MB (expected unknown) | \(String(format: "%.2f", throughputMBs)) MB/s")
                }
                self.lastByteLogTimeByTask[key] = now
                self.lastByteLogBytesByTask[key] = totalBytesWritten
            }
        }
    }

    // Per-task tracking keyed by TaskKey (session + taskID) because
    // taskIdentifier is unique only within a single URLSession.
    private var bytesWrittenByTask: [TaskKey: Int64] = [:]
    private var bytesExpectedByTask: [TaskKey: Int64] = [:]
    // For throttled byte-flow logging (5 second cadence per task).
    private var lastByteLogTimeByTask: [TaskKey: Date] = [:]
    private var lastByteLogBytesByTask: [TaskKey: Int64] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let kind = sessionKind(of: session)
        let key = TaskKey(session: kind, id: task.taskIdentifier)
        let kindStr = kind == .foreground ? "fg" : "bg"
        guard let context = contextLookup(session: kind, taskID: task.taskIdentifier) else { return }

        // Suppress noisy "cancelled" logs when this cancellation is part of
        // a planned lifecycle migration (foreground↔background). Those
        // cancellations are expected — they produce the resume data that
        // we hand to the other session.
        let isMigrationCancel = migratingTaskIDs.remove(key) != nil
        if let error = error as NSError? {
            if isMigrationCancel {
                halLog("HALDEBUG-BGDL: \(kindStr) task \(task.taskIdentifier) (\(context.filename)) cancelled-for-migration (expected)")
            } else if error.code == NSURLErrorCancelled {
                halLog("HALDEBUG-BGDL: \(kindStr) task \(task.taskIdentifier) (\(context.filename)) cancelled")
            } else {
                halLog("HALDEBUG-BGDL-ERROR: \(kindStr) task \(task.taskIdentifier) (\(context.filename)) failed: \(error.localizedDescription) (domain=\(error.domain), code=\(error.code))")
            }
        } else {
            halLog("HALDEBUG-BGDL: \(kindStr) task \(task.taskIdentifier) (\(context.filename)) completed")
        }
        removeContext(session: kind, taskID: task.taskIdentifier)
        Task { @MainActor in
            self.bytesWrittenByTask.removeValue(forKey: key)
            self.bytesExpectedByTask.removeValue(forKey: key)
            self.lastByteLogTimeByTask.removeValue(forKey: key)
            self.lastByteLogBytesByTask.removeValue(forKey: key)
        }
    }

    /// Tracks task keys that we have cancelled deliberately as part of a
    /// foreground↔background migration. didCompleteWithError uses this to
    /// suppress the noisy "task X failed: cancelled" log for those cases.
    /// Entries are consumed (removed) when didCompleteWithError fires for
    /// them.
    private var migratingTaskIDs: Set<TaskKey> = []

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        halLog("HALDEBUG-BGDL: urlSessionDidFinishEvents — invoking app delegate completion handler")
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    // MARK: - Helpers for upstream coordination

    /// True if there's at least one in-flight (running or suspended) download
    /// task for this model in either session. Used by MLXModelDownloader to
    /// decide whether to re-trigger startDownload on launch — if BGDL has
    /// already auto-reconnected to in-flight URLSession tasks (which
    /// URLSessionConfiguration.background does automatically), the upstream
    /// auto-resume should NOT re-trigger and wipe BGDL's recovered state.
    func hasActiveTasks(for modelID: String) async -> Bool {
        for session in [foregroundSession, backgroundSession] {
            let kind = sessionKind(of: session)
            let tasks = await session.allTasks
            for task in tasks {
                guard let context = contextLookup(session: kind, taskID: task.taskIdentifier),
                      context.modelID == modelID else { continue }
                if task.state == .running || task.state == .suspended {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Cancellation

    /// Cancel all in-flight download tasks for a specific model in BOTH
    /// sessions (foreground + background). Called when the user explicitly
    /// cancels via the UI. URLSession cancellation propagates as
    /// `URLError.cancelled` to didCompleteWithError, where we remove the
    /// per-task context. We also drop the per-model bookkeeping here so a
    /// follow-up retry starts clean.
    func cancelDownload(modelID: String) async {
        halLog("HALDEBUG-BGDL: cancelDownload requested for \(modelID)")
        var cancelled = 0
        for session in [foregroundSession, backgroundSession] {
            let kind = sessionKind(of: session)
            let allTasks = await session.allTasks
            for task in allTasks {
                if let context = contextLookup(session: kind, taskID: task.taskIdentifier),
                   context.modelID == modelID {
                    task.cancel()
                    cancelled += 1
                }
            }
        }
        halLog("HALDEBUG-BGDL: Cancelled \(cancelled) in-flight task(s) for \(modelID) across both sessions")
        await MainActor.run {
            self.filesPendingByModel.removeValue(forKey: modelID)
            self.bytesWrittenByModel.removeValue(forKey: modelID)
            self.bytesExpectedByModel.removeValue(forKey: modelID)
        }
    }

    // MARK: - Lifecycle Migration (v2.0 hybrid)
    //
    // When the app backgrounds, transfer in-flight foreground tasks to the
    // background session so the download keeps going (slowly) while the
    // user is away. When the app foregrounds, reverse the migration so the
    // user gets full bandwidth while watching.
    //
    // The migration uses `URLSessionDownloadTask.cancel(byProducingResumeData:)`
    // which returns a `Data` blob iOS uses to resume the download from the
    // exact byte where it stopped. HuggingFace's CDN supports HTTP Range
    // requests so resumption should work cleanly.

    func migrateForegroundTasksToBackground() async {
        let snapshot = await foregroundSession.allTasks
        let downloadTasks = snapshot.compactMap { $0 as? URLSessionDownloadTask }
        guard !downloadTasks.isEmpty else {
            halLog("HALDEBUG-BGDL: migrateForegroundTasksToBackground: no foreground tasks to migrate")
            return
        }
        halLog("HALDEBUG-BGDL: migrateForegroundTasksToBackground: migrating \(downloadTasks.count) task(s) to background session")

        for task in downloadTasks {
            guard task.state == .running || task.state == .suspended else { continue }
            guard let context = contextLookup(session: .foreground, taskID: task.taskIdentifier) else {
                halLog("HALDEBUG-BGDL: migrate: foreground task \(task.taskIdentifier) has no context; skipping")
                continue
            }
            let oldKey = TaskKey(session: .foreground, id: task.taskIdentifier)
            migratingTaskIDs.insert(oldKey)

            // cancel-with-resume-data is async via callback. Wrap in
            // withCheckedContinuation so we can await it cleanly.
            let resumeData: Data? = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { data in
                    continuation.resume(returning: data)
                })
            }

            // Tear down foreground bookkeeping for this task.
            // (didCompleteWithError will also fire and remove the context,
            // but doing it here too is idempotent and safer against races.)
            await MainActor.run {
                self.bytesWrittenByTask.removeValue(forKey: oldKey)
                self.bytesExpectedByTask.removeValue(forKey: oldKey)
                self.lastByteLogTimeByTask.removeValue(forKey: oldKey)
                self.lastByteLogBytesByTask.removeValue(forKey: oldKey)
            }
            removeContext(session: .foreground, taskID: task.taskIdentifier)

            // Hand off to background session.
            let newTask: URLSessionDownloadTask
            if let resumeData {
                newTask = backgroundSession.downloadTask(withResumeData: resumeData)
                halLog("HALDEBUG-BGDL: migrate ✅ \(context.filename) fg→bg with \(resumeData.count) bytes of resume data; new bg task \(newTask.taskIdentifier)")
            } else if let url = task.originalRequest?.url {
                // No resume data — restart from byte 0. Loud log so we
                // notice if this happens often (would indicate the CDN
                // isn't supporting Range requests, which would be bad).
                newTask = backgroundSession.downloadTask(with: url)
                halLog("HALDEBUG-BGDL: migrate ⚠️ \(context.filename) fg→bg WITHOUT resume data; restarting from 0; new bg task \(newTask.taskIdentifier)")
            } else {
                halLog("HALDEBUG-BGDL: migrate ❌ \(context.filename) has no URL — cannot continue")
                continue
            }
            saveContext(context, session: .background, taskID: newTask.taskIdentifier)
            newTask.resume()
        }
    }

    func migrateBackgroundTasksToForeground() async {
        let snapshot = await backgroundSession.allTasks
        let downloadTasks = snapshot.compactMap { $0 as? URLSessionDownloadTask }
        guard !downloadTasks.isEmpty else {
            halLog("HALDEBUG-BGDL: migrateBackgroundTasksToForeground: no background tasks to migrate")
            return
        }
        halLog("HALDEBUG-BGDL: migrateBackgroundTasksToForeground: migrating \(downloadTasks.count) task(s) to foreground session")

        for task in downloadTasks {
            guard task.state == .running || task.state == .suspended else { continue }
            guard let context = contextLookup(session: .background, taskID: task.taskIdentifier) else {
                halLog("HALDEBUG-BGDL: migrate: background task \(task.taskIdentifier) has no context; skipping")
                continue
            }
            let oldKey = TaskKey(session: .background, id: task.taskIdentifier)
            migratingTaskIDs.insert(oldKey)

            let resumeData: Data? = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { data in
                    continuation.resume(returning: data)
                })
            }

            await MainActor.run {
                self.bytesWrittenByTask.removeValue(forKey: oldKey)
                self.bytesExpectedByTask.removeValue(forKey: oldKey)
                self.lastByteLogTimeByTask.removeValue(forKey: oldKey)
                self.lastByteLogBytesByTask.removeValue(forKey: oldKey)
            }
            removeContext(session: .background, taskID: task.taskIdentifier)

            let newTask: URLSessionDownloadTask
            if let resumeData {
                newTask = foregroundSession.downloadTask(withResumeData: resumeData)
                halLog("HALDEBUG-BGDL: migrate ✅ \(context.filename) bg→fg with \(resumeData.count) bytes of resume data; new fg task \(newTask.taskIdentifier)")
            } else if let url = task.originalRequest?.url {
                newTask = foregroundSession.downloadTask(with: url)
                halLog("HALDEBUG-BGDL: migrate ⚠️ \(context.filename) bg→fg WITHOUT resume data; restarting from 0; new fg task \(newTask.taskIdentifier)")
            } else {
                halLog("HALDEBUG-BGDL: migrate ❌ \(context.filename) has no URL — cannot continue")
                continue
            }
            saveContext(context, session: .foreground, taskID: newTask.taskIdentifier)
            newTask.resume()
        }
    }
}

// MARK: - MLX Model Downloader (Singleton)
class MLXModelDownloader: ObservableObject {
    static let shared = MLXModelDownloader()
    
    // MARK: - Download State Structure
    
    struct DownloadState {
        var isDownloading: Bool
        var progress: Double
        var message: String
        var error: String?
        var localPath: URL?
    }
    
    struct QueuedDownload {
        let modelID: String
        let repoID: String
        let sizeGB: Double?
    }
    
    // MARK: - Multi-Model State
    
    @Published var downloadStates: [String: DownloadState] = [:]
    
    // Persistent storage of downloaded model IDs
    @AppStorage("downloadedModelIDs") private var downloadedModelIDsData: Data = Data() {
        didSet {
            objectWillChange.send()
        }
    }
    
    private var downloadedModelIDs: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: downloadedModelIDsData)) ?? []
        }
        set {
            downloadedModelIDsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
    
    // Helper: Construct runtime path for a model ID (App-Group shared store).
    private func modelPath(for modelID: String) -> URL {
        SharedModelStore.mlxModelDir(modelID)
    }
    
    // MARK: - Download Queue Management

    private var downloadQueue: [QueuedDownload] = []
    private var currentDownloadTask: Task<Void, Never>?
    private var currentDownloadModelID: String?

    // MARK: - In-Flight Persistence (Background-Resume Support)
    //
    // iOS aggressively suspends/terminates apps that go to background while
    // doing network work. The underlying HubApi snapshot is a foreground
    // URLSession so its task is cancelled the moment iOS suspends us, even
    // though partial files survive on disk. We use TWO mitigations:
    //
    // 1) `UIApplication.beginBackgroundTask` around the download to ask iOS
    //    for a brief grace period (~30s) when the user leaves the app. Lets
    //    brief app-switches and screen locks finish or significantly
    //    advance the download.
    //
    // 2) Persist the in-flight model IDs to AppStorage. On next launch,
    //    re-fire startDownload for any model that was in flight before
    //    termination. HubApi.snapshot already resumes from partial files
    //    (it checks per-file existence/size), so re-firing picks up where
    //    we left off rather than restarting from zero.
    //
    // A proper URLSession.background-based downloader (true background
    // downloads while app is suspended) is documented as a follow-up; that
    // requires replacing HubApi.snapshot with our own file fetcher, which
    // is a real refactor.
    @AppStorage("inFlightDownloadIDs") private var inFlightDownloadIDsData: Data = Data()

    private var inFlightDownloadIDs: Set<String> {
        get { (try? JSONDecoder().decode(Set<String>.self, from: inFlightDownloadIDsData)) ?? [] }
        set { inFlightDownloadIDsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func markInFlight(_ modelID: String, repoID: String, sizeGB: Double?) {
        var ids = inFlightDownloadIDs
        ids.insert(modelID)
        inFlightDownloadIDs = ids
        // Persist the repoID + sizeGB so resume has all the args it needs.
        var meta = (UserDefaults.standard.dictionary(forKey: "inFlightDownloadMeta") as? [String: [String: Any]]) ?? [:]
        meta[modelID] = ["repoID": repoID, "sizeGB": sizeGB ?? 0.0]
        UserDefaults.standard.set(meta, forKey: "inFlightDownloadMeta")
    }

    private func clearInFlight(_ modelID: String) {
        var ids = inFlightDownloadIDs
        ids.remove(modelID)
        inFlightDownloadIDs = ids
        var meta = (UserDefaults.standard.dictionary(forKey: "inFlightDownloadMeta") as? [String: [String: Any]]) ?? [:]
        meta.removeValue(forKey: modelID)
        UserDefaults.standard.set(meta, forKey: "inFlightDownloadMeta")
    }

    /// Re-fire any downloads that were in flight when the app was last
    /// terminated. Called from init() after the existing models are detected.
    /// Models already fully downloaded (detected by the existing loop) get
    /// cleared from the in-flight set automatically.
    private func resumeInFlightDownloadsIfAny() async {
        let pending = inFlightDownloadIDs
        guard !pending.isEmpty else {
            halLog("HALDEBUG-DOWNLOAD: resumeInFlightDownloadsIfAny: no pending markers")
            return
        }
        let meta = (UserDefaults.standard.dictionary(forKey: "inFlightDownloadMeta") as? [String: [String: Any]]) ?? [:]
        halLog("HALDEBUG-DOWNLOAD: resumeInFlightDownloadsIfAny: found \(pending.count) in-flight marker(s): \(pending.sorted())")

        // Settle delay before consulting BGDL state. On relaunch, two
        // recovery paths can fire concurrently: (a) URLSessionConfiguration.
        // background auto-reconnects to in-flight tasks the system kept
        // alive in nsurlsessiond, and (b) willEnterForeground fires
        // BGDL's migrateBackgroundTasksToForeground. The migration moves
        // bg tasks → fg tasks via cancel-with-resume-data, which leaves
        // the bg task in `cancelling` state for a few ms — and during that
        // window our hasActiveTasks check returns false because cancelling
        // tasks aren't .running or .suspended. We've seen this race lose
        // by ~1ms in testing. 1.5s is plenty for migration to settle (it
        // typically completes in ~10ms total) and only fires on relaunches
        // with in-flight markers (rare in practice).
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        halLog("HALDEBUG-DOWNLOAD: resumeInFlightDownloadsIfAny: settle complete, evaluating each marker")

        for modelID in pending {
            // Use COMPLETION (sentinel), not mere disk-presence, to decide a marker
            // is stale. A marker persists to next launch ONLY when the download did
            // not finish (completion clears it) — so a partial dir must never be
            // declared "done" here. The old `isModelDownloaded` check ("dir has any
            // files") did exactly that: it cleared the marker for a half-downloaded
            // model, leaving it permanently incomplete but reading as present.
            // Partial models now fall through to the branches below, which either
            // let recovered background tasks keep running or re-fetch and download
            // only the missing files.
            if SharedModelStore.isRepoComplete(modelID) {
                clearInFlight(modelID)
                halLog("HALDEBUG-DOWNLOAD: \(modelID) is verified complete (sentinel); clearing in-flight marker")
                continue
            }

            // CRITICAL: do NOT re-trigger startDownload if BGDL has already
            // auto-reconnected to in-flight URLSession tasks for this model
            // (URLSessionConfiguration.background does this automatically on
            // app launch, restoring tasks that survived termination). If we
            // re-fired startDownload, its dedup logic would cancel BGDL's
            // recovered tasks — including any that came back via the
            // willEnterForeground migration with valid resume data — and
            // restart from byte 0. We observed exactly this regression
            // during the §7 locked-phone test in v2.0 hybrid testing.
            let bgdlAlreadyActive = await BackgroundDownloadCoordinator.shared.hasActiveTasks(for: modelID)
            if bgdlAlreadyActive {
                halLog("HALDEBUG-DOWNLOAD: \(modelID) — BGDL already has in-flight tasks (auto-reconnected); NOT re-triggering startDownload. Letting BGDL continue.")

                // BUG FIX (2026-05-17, §7 retest aftermath): when iOS jetsam-
                // kills Hal mid-download and the fresh process recovers via
                // this branch, the @Published downloadStates dict starts
                // empty. The Model Library UI binds to downloadStates[modelID]
                // for the progress bar, so users saw no progress UI even
                // though BGDL was actively downloading. Mark caught this
                // during the §7 long-lock test (commit `97c8a7a`-adjacent).
                //
                // Fix: populate downloadStates with an `isDownloading: true`
                // state seeded from BGDL's current byte counters, then spawn
                // a polling task that mirrors BGDL progress into the
                // @Published dict. The polling task self-terminates when
                // markModelAsDownloadedFromBackground flips isDownloading
                // to false on completion — the same lifecycle the normal
                // startDownload path uses.
                let initialFraction = BackgroundDownloadCoordinator.shared.progress(for: modelID)
                let initialClamped = max(0.0, min(0.99, initialFraction))
                await MainActor.run {
                    let seedState = DownloadState(
                        isDownloading: true,
                        progress: initialClamped,
                        message: "Downloading \(Int(initialClamped * 100))%...",
                        error: nil,
                        localPath: nil
                    )
                    self.downloadStates[modelID] = seedState
                }
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if Task.isCancelled { break }
                        let shouldContinue = await MainActor.run { () -> Bool in
                            guard var state = self.downloadStates[modelID], state.isDownloading else {
                                return false
                            }
                            let bgdlFraction = BackgroundDownloadCoordinator.shared.progress(for: modelID)
                            let fraction = max(0.0, min(0.99, bgdlFraction))
                            state.progress = fraction
                            state.message = "Downloading \(Int(fraction * 100))%..."
                            self.downloadStates[modelID] = state
                            return true
                        }
                        if !shouldContinue { break }
                    }
                }
                continue
            }

            let modelMeta = meta[modelID] ?? [:]
            let repoID = modelMeta["repoID"] as? String ?? modelID
            let sizeGB = modelMeta["sizeGB"] as? Double
            let size = (sizeGB ?? 0.0) > 0.0 ? sizeGB : nil
            halLog("HALDEBUG-DOWNLOAD: Auto-resuming download for \(modelID) (no in-flight BGDL tasks found)")
            // forceResume: this model has a persisted in-flight marker and no
            // completion sentinel — it is verifiably PARTIAL. Skip startDownload's
            // disk-presence "already downloaded" guard, which would otherwise see
            // the partial dir and refuse to finish it.
            Task { await self.startDownload(modelID: modelID, repoID: repoID, sizeGB: size, forceResume: true) }
        }
    }
    
    // MARK: - Cache Management
    
    @Published var hubCacheSize: String = "Calculating..."
    @Published var isCacheCalculating: Bool = false
    
    // MARK: - Directory Management
    
    private var hubCacheDirectory: URL {
        SharedModelStore.huggingFaceRoot
    }
    
    private var legacyModelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MLXModels", isDirectory: true)
    }
    
    // MARK: - UI Convenience Accessors (Backward Compatibility)
    
    var isDownloading: Bool {
        downloadStates.values.contains { $0.isDownloading }
    }
    
    var progress: Double {
        downloadStates.values.first { $0.isDownloading }?.progress ?? 0.0
    }
    
    var downloadMessage: String {
        if let downloading = downloadStates.values.first(where: { $0.isDownloading }) {
            return downloading.message
        }
        return downloadStates.values.first?.message ?? ""
    }
    
    var downloadError: String? {
        downloadStates.values.first { $0.error != nil }?.error
    }
    
    var currentDownloadID: String? {
        downloadStates.first { $0.value.isDownloading }?.key
    }
    
    // Legacy accessor used by the current UI.
    // This will be removed once the UI transitions to multi-model support.
    var downloadedModelURL: URL? {
        downloadStates.values.first { $0.localPath != nil }?.localPath
    }
    
    // MARK: - Initialization
    
    private init() {
        print("HALDEBUG-DETECTION: MLXModelDownloader.init() starting...")
        
        // Clean up legacy storage (delete, don't migrate)
        cleanupLegacyModelStorage()
        
        Task.detached {
            await MainActor.run {
                // Load all downloaded model IDs from persistent storage
                let modelIDs = self.downloadedModelIDs
                print("HALDEBUG-DETECTION: Loaded \(modelIDs.count) model IDs from storage")
                
                // Verify each model exists and initialize state
                var validIDs = modelIDs
                for modelID in modelIDs {
                    // DIAGNOSTIC: Show what we're checking
                    print("HALDEBUG-DETECTION: 🔍 Checking model: \(modelID)")
                    
                    let expectedPath = self.modelPath(for: modelID)
                    
                    // DIAGNOSTIC: Show the path we constructed
                    print("HALDEBUG-DETECTION:    Expected path: \(expectedPath.path)")
                    
                    // DIAGNOSTIC: Check what FileManager actually returns
                    let exists = FileManager.default.fileExists(atPath: expectedPath.path)
                    print("HALDEBUG-DETECTION:    FileManager.fileExists: \(exists)")
                    
                    if FileManager.default.fileExists(atPath: expectedPath.path) {
                        // DIAGNOSTIC: If exists, check if it's a directory and what's in it
                        var isDirectory: ObjCBool = false
                        FileManager.default.fileExists(atPath: expectedPath.path, isDirectory: &isDirectory)
                        print("HALDEBUG-DETECTION:    Is directory: \(isDirectory.boolValue)")
                        
                        if isDirectory.boolValue {
                            do {
                                let contents = try FileManager.default.contentsOfDirectory(atPath: expectedPath.path)
                                print("HALDEBUG-DETECTION:    Directory contains \(contents.count) items")
                                // Show first few files
                                for (index, item) in contents.prefix(5).enumerated() {
                                    print("HALDEBUG-DETECTION:       [\(index + 1)] \(item)")
                                }
                                if contents.count > 5 {
                                    print("HALDEBUG-DETECTION:       ... and \(contents.count - 5) more items")
                                }
                            } catch {
                                print("HALDEBUG-DETECTION:    ❌ Could not list directory contents: \(error.localizedDescription)")
                            }
                        }
                        
                        self.downloadStates[modelID] = DownloadState(
                            isDownloading: false,
                            progress: 1.0,
                            message: "Model ready.",
                            error: nil,
                            localPath: expectedPath
                        )
                        print("HALDEBUG-DETECTION: ✅ Restored model: \(modelID)")
                    } else {
                        // DIAGNOSTIC: If doesn't exist, check the parent directory
                        let parentURL = expectedPath.deletingLastPathComponent()
                        let parentExists = FileManager.default.fileExists(atPath: parentURL.path)
                        print("HALDEBUG-DETECTION:    ❌ Path does not exist")
                        print("HALDEBUG-DETECTION:    Parent path: \(parentURL.path)")
                        print("HALDEBUG-DETECTION:    Parent exists: \(parentExists)")
                        
                        if parentExists {
                            // Show what IS in the parent directory
                            do {
                                let parentContents = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
                                print("HALDEBUG-DETECTION:    Parent directory contains \(parentContents.count) items")
                                for (index, item) in parentContents.prefix(10).enumerated() {
                                    print("HALDEBUG-DETECTION:       [\(index + 1)] \(item)")
                                }
                                if parentContents.count > 10 {
                                    print("HALDEBUG-DETECTION:       ... and \(parentContents.count - 10) more items")
                                }
                            } catch {
                                print("HALDEBUG-DETECTION:    ❌ Could not list parent directory: \(error.localizedDescription)")
                            }
                        }
                        
                        // Remove invalid ID from storage
                        validIDs.remove(modelID)
                        print("HALDEBUG-DETECTION: ❌ Removed invalid model ID: \(modelID)")
                    }
                }
                
                // Save cleaned IDs if any were invalid
                if validIDs.count != modelIDs.count {
                    self.downloadedModelIDs = validIDs
                }
                
                print("HALDEBUG-DETECTION: MLXModelDownloader.init() complete - \(self.downloadStates.count) models ready")
            }

            // After model detection, re-fire any in-flight downloads
            // that were interrupted by app termination. See the
            // resumeInFlightDownloadsIfAny() comment block for the
            // rationale and the two-mitigation design. (Now async
            // because it consults BGDL's task state before re-triggering;
            // pulled out of the MainActor.run above because the await
            // can't live inside a synchronous closure.)
            await self.resumeInFlightDownloadsIfAny()

            // Calculate cache size in background
            await self.updateCacheSize()
        }
    }
    
    // MARK: - Legacy Cleanup
    
    private func cleanupLegacyModelStorage() {
        // Remove old MLXModels directory from Application Support
        if FileManager.default.fileExists(atPath: legacyModelsDir.path) {
            do {
                try FileManager.default.removeItem(at: legacyModelsDir)
                print("HALDEBUG-CLEANUP: ✅ Removed legacy MLXModels directory")
            } catch {
                print("HALDEBUG-CLEANUP: ⚠️ Failed to remove legacy directory: \(error.localizedDescription)")
            }
        }
        
        // Delete legacy single-model storage keys (don't migrate)
        let legacyKeys = [
            "downloadedMLXPath",
            "partialMLXDownloadProgress",
            "partialMLXDownloadSize",
            "hasPartialMLXDownload",
            "downloadedModelPaths"  // OLD path-based storage
        ]
        
        for key in legacyKeys {
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                print("HALDEBUG-CLEANUP: ✅ Removed legacy key: \(key)")
            }
        }
    }
    
    // MARK: - Multi-Model Download Management
    
    /// Checks the device's available storage against a required size.
    /// Returns nil if there's enough space; returns a human-readable
    /// error message if not. Uses the `.volumeAvailableCapacityForImportantUsageKey`
    /// resource value, which accounts for iOS's purgeable-storage reclamation
    /// (it's the same number iOS uses internally when deciding whether to
    /// allow a download). 30% margin covers temp files during download +
    /// any post-download decompression overhead.
    ///
    /// Pre-flight check added 2026-05-16 per SC + Mark — covers BOTH curated
    /// and community models. The same code path handles either; the only
    /// difference is the model-name lookup for the error message.
    private nonisolated func checkAvailableSpace(forModelSizeGB sizeGB: Double, modelDisplayName: String) -> String? {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard let values = try? cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let availableBytes = values.volumeAvailableCapacityForImportantUsage else {
            // We couldn't determine free space at all. Refuse rather than
            // silently proceed — partial download + cryptic iOS error is
            // worse than an upfront refusal with a clear message.
            return "\(modelDisplayName) couldn't be downloaded: this device's available storage couldn't be determined. Free up some space and try again."
        }

        let requiredBytes = Int64(sizeGB * 1.3 * 1_073_741_824)  // 30% margin
        if availableBytes >= requiredBytes {
            return nil  // Sufficient space — proceed.
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let requiredStr = formatter.string(fromByteCount: requiredBytes)
        let availableStr = formatter.string(fromByteCount: availableBytes)
        return "Downloading \(modelDisplayName) needs about \(requiredStr) free, but only \(availableStr) is available on this device. Free up some space and try again."
    }

    /// - Parameter forceResume: set by the in-flight RESUME path, which has already
    ///   determined (via the completion sentinel) that this model is PARTIAL and
    ///   needs finishing. It skips the "already downloaded" early-return below —
    ///   that guard uses `isModelDownloaded` (disk-presence: true for a merely
    ///   non-empty dir), so for a half-downloaded model it would wrongly declare
    ///   "already downloaded" and refuse to resume, leaving the model permanently
    ///   partial. Normal callers keep the guard so a present (or sibling-downloaded)
    ///   model isn't needlessly re-fetched.
    func startDownload(modelID: String, repoID: String, sizeGB: Double? = nil, forceResume: Bool = false) async {
        // Check if already downloaded (skipped on an explicit resume — see above).
        if !forceResume && isModelDownloaded(modelID) {
            await MainActor.run {
                print("HALDEBUG-DOWNLOAD: Model already downloaded: \(modelID)")
                if var state = self.downloadStates[modelID] {
                    state.message = "Model already downloaded."
                    self.downloadStates[modelID] = state
                }
            }
            return
        }
        
        // Check if already downloading
        await MainActor.run {
            if let state = downloadStates[modelID], state.isDownloading {
                print("HALDEBUG-DOWNLOAD: Download already in progress for: \(modelID)")
                return
            }
        }
        
        // Check if another download is active
        if currentDownloadTask != nil {
            await MainActor.run {
                // Add to queue
                let queuedDownload = QueuedDownload(modelID: modelID, repoID: repoID, sizeGB: sizeGB)
                downloadQueue.append(queuedDownload)

                var state = downloadStates[modelID] ?? DownloadState(
                    isDownloading: false,
                    progress: 0.0,
                    message: "Queued...",
                    error: nil,
                    localPath: nil
                )
                state.message = "Queued (position \(downloadQueue.count))..."
                downloadStates[modelID] = state

                print("HALDEBUG-DOWNLOAD: Queued download for \(modelID) (position \(downloadQueue.count))")
            }
            return
        }

        // PRE-FLIGHT DISK SPACE CHECK (added 2026-05-16 per SC + Mark).
        //
        // Refuse cleanly here rather than starting a download that will
        // fail partway through with a cryptic iOS "cannot write file" error
        // and leave the user wondering what went wrong. Two cases:
        //
        //   1. sizeGB known (curated models always; community models when
        //      HF returned siblings.size) → check available space against
        //      sizeGB * 1.3 (30% margin for temp + decompression overhead).
        //   2. sizeGB unknown (rare community-model edge case where HF
        //      didn't return per-file sizes) → refuse outright, ask the
        //      user to ensure they have enough free space first. Better to
        //      refuse than silently start a download we can't size-check.
        let modelDisplayName = await MainActor.run {
            ModelCatalogService.shared.getModel(byID: modelID)?.displayName ?? modelID
        }
        let spaceError: String? = {
            guard let sizeGB = sizeGB, sizeGB > 0 else {
                return "\(modelDisplayName) couldn't be downloaded: this model's size couldn't be determined from its repository. Make sure you have plenty of free space on the device before trying again."
            }
            return checkAvailableSpace(forModelSizeGB: sizeGB, modelDisplayName: modelDisplayName)
        }()
        if let spaceError = spaceError {
            await MainActor.run {
                halLog("HALDEBUG-DOWNLOAD: Refusing \(modelID) — insufficient space. \(spaceError)")
                var state = downloadStates[modelID] ?? DownloadState(
                    isDownloading: false,
                    progress: 0.0,
                    message: spaceError,
                    error: spaceError,
                    localPath: nil
                )
                state.isDownloading = false
                state.progress = 0.0
                state.message = spaceError
                state.error = spaceError
                downloadStates[modelID] = state
                // downloadError is a computed property that surfaces the
                // first non-nil error across downloadStates — setting
                // state.error above is sufficient to make it visible.
            }
            return
        }

        // CROSS-APP DOWNLOAD LOCK (v2.1). Before fetching, try to claim the
        // shared "one app downloads this model at a time" slot. If the sibling
        // app (Posey) is already downloading this same repo into the shared
        // container, don't start a second copy — wait for theirs to land and
        // adopt it (zero re-download), taking over only if their download dies.
        // See SharedModelStore BLOCK SMS.4 and awaitSharedDownloadThenAdopt.
        let gotLock = SharedModelStore.acquireDownloadLock(modelID: modelID)
        if !gotLock {
            let holder = SharedModelStore.downloadLock(modelID: modelID)?.holder
            halLog("HALDEBUG-DOWNLOAD: \(modelID) already being downloaded by \(SharedModelStore.appDisplayName(holder)); waiting to adopt instead of duplicating")
            await MainActor.run {
                self.currentDownloadModelID = modelID
                var state = self.downloadStates[modelID] ?? DownloadState(
                    isDownloading: true, progress: 0.0, message: "", error: nil, localPath: nil
                )
                state.isDownloading = true
                state.error = nil
                state.message = "Downloading in \(SharedModelStore.appDisplayName(holder))…"
                self.downloadStates[modelID] = state
                self.currentDownloadTask = Task {
                    await self.awaitSharedDownloadThenAdopt(modelID: modelID, repoID: repoID, sizeGB: sizeGB)
                }
            }
            return
        }

        // We hold the cross-app lock — run the actual download.
        await performLockedDownload(modelID: modelID, repoID: repoID, sizeGB: sizeGB)
    }

    /// Runs the real download once the cross-app download lock is held. Split out
    /// from `startDownload` so the take-over path (a prior holder died mid-
    /// download) can reach it without re-tripping `startDownload`'s
    /// already-present / queue guards. Releases the lock on cancel and failure;
    /// the success path releases it in
    /// `BackgroundDownloadCoordinator.notifyModelDownloadComplete` (next to the
    /// claim) so a completion delivered after a background relaunch still clears
    /// the lock.
    private func performLockedDownload(modelID: String, repoID: String, sizeGB: Double?) async {
        // Start download
        await MainActor.run {
            currentDownloadModelID = modelID

            var state = downloadStates[modelID] ?? DownloadState(
                isDownloading: true,
                progress: 0.0,
                message: "Starting download...",
                error: nil,
                localPath: nil
            )
            state.isDownloading = true
            state.progress = 0.0
            state.message = "Starting download..."
            state.error = nil
            downloadStates[modelID] = state
        }

        // Snapshot the huggingface cache directory size before download starts,
        // so we can subtract pre-existing content and compute byte-accurate progress.
        let huggingfaceDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
        let priorBytes = directorySize(huggingfaceDir)
        let expectedBytes = sizeGB.map { Int64($0 * 1_073_741_824) } ?? 0
        print("HALDEBUG-PROGRESS: sizeGB=\(String(describing: sizeGB)) expectedBytes=\(expectedBytes) for \(modelID)")

        // Polling task: sources progress from BackgroundDownloadCoordinator's
        // per-task byte tracking (urlSession didWriteData callbacks). This is
        // a v2.0 fix for the long-standing broken progress meter — the
        // previous implementation polled directorySize, which only updates
        // when a file atomically moves from URLSession's staging area to the
        // cache. For one big file (model.safetensors at 3.6 GB), that meant
        // 0% until 100% in a single jump, with no in-flight visibility.
        // BGDL's progress(for:) returns bytes-received / bytes-expected
        // aggregated across all in-flight tasks for the model, giving us
        // real-time accurate progress for both users and diagnostics.
        let progressPollingTask: Task<Void, Never>? = expectedBytes > 0 ? Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                // Heartbeat: keep our cross-app lock fresh so a sibling app
                // waiting on this model doesn't judge our live download stale
                // and start a redundant copy. (Only fires while we're in the
                // foreground; the staleness window covers backgrounded holders.)
                SharedModelStore.refreshDownloadLock(modelID: modelID)
                await MainActor.run {
                    let bgdlFraction = BackgroundDownloadCoordinator.shared.progress(for: modelID)
                    // Fallback to legacy directorySize if BGDL hasn't yet
                    // populated its byte tracking (e.g. session not yet
                    // attached after restart). Keeps the meter alive.
                    let fraction: Double
                    if bgdlFraction > 0 {
                        fraction = min(0.99, bgdlFraction)
                    } else {
                        let written = self.directorySize(huggingfaceDir)
                        let newBytes = max(0, written - priorBytes)
                        fraction = min(0.99, Double(newBytes) / Double(expectedBytes))
                    }
                    if var state = self.downloadStates[modelID], state.isDownloading {
                        state.progress = fraction
                        state.message = "Downloading \(Int(fraction * 100))%..."
                        self.downloadStates[modelID] = state
                    }
                }
            }
        } : nil

        // Mark this download as in-flight BEFORE the network call so that
        // if iOS terminates us mid-download, the next launch knows to
        // resume it. Cleared in the success / cancel / error paths below.
        markInFlight(modelID, repoID: repoID, sizeGB: sizeGB)

        currentDownloadTask = Task {
            // Request a background-task assertion so iOS gives us a brief
            // grace period (~30s) if the user backgrounds the app mid-
            // download. Not a true background download — HubApi still uses
            // a foreground URLSession — but enough that short app-switches
            // and screen locks usually complete the transfer or get close
            // enough that the resume-on-launch path picks up cleanly.
            let bgTaskID = await MainActor.run { () -> UIBackgroundTaskIdentifier in
                UIApplication.shared.beginBackgroundTask(withName: "ModelDownload-\(modelID)") {
                    // Expiration handler — iOS is about to suspend us.
                    // The in-flight marker is already persisted; resume
                    // path will fire on next launch.
                    print("HALDEBUG-DOWNLOAD: Background task expiring for \(modelID) — iOS will suspend; resume on next launch")
                }
            }

            defer {
                // Always end the background task, regardless of outcome.
                Task { @MainActor in
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                    }
                }
            }

            do {
                halLog("HALDEBUG-DOWNLOAD: Starting download for \(modelID) from \(repoID) via BackgroundDownloadCoordinator")

                // Replaces HubApi.snapshot. The coordinator enqueues a
                // background URLSession download task per file (matching
                // the same MLX patterns: *.safetensors, *.json, *.jinja)
                // and returns once enqueueing is done. The actual downloads
                // run in iOS-managed background tasks that survive app
                // suspension and termination — which fixes the "user
                // pockets the phone mid-download" case from yesterday.
                try await BackgroundDownloadCoordinator.shared.startDownload(modelID: modelID, repoID: repoID)

                // If every file was already present on disk (e.g. an interrupted
                // download we're resuming), the coordinator may have posted the
                // completion notification before we got here. Check first.
                let alreadyComplete = await MainActor.run { self.isModelDownloaded(modelID) }
                if alreadyComplete {
                    halLog("HALDEBUG-DOWNLOAD: \(modelID) already complete on coordinator start; treating as done")
                    progressPollingTask?.cancel()
                    return
                }

                // Wait for the .mlxModelDidDownload notification matching
                // this modelID. The coordinator's notifyModelDownloadComplete
                // posts it AND calls markModelAsDownloadedFromBackground,
                // which handles ALL the success bookkeeping (DownloadState,
                // downloadedModelIDs, in-flight marker, currentDownloadTask
                // clear, queue advance, cache size) AND releases the cross-app
                // download lock. So all we do here on success is cancel the
                // polling task and log.
                try await self.waitForModelCompletion(modelID: modelID)
                progressPollingTask?.cancel()
                halLog("HALDEBUG-DOWNLOAD: ✅ Download notification received for \(modelID); coordinator handled bookkeeping")
            } catch is CancellationError {
                // User explicit cancel via the UI. Tell the coordinator to
                // tear down its background URLSession tasks for this model so
                // they don't continue burning bandwidth after the cancel.
                await BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
                progressPollingTask?.cancel()
                // Release the cross-app lock so a sibling app can proceed.
                SharedModelStore.releaseDownloadLock(modelID: modelID)
                await MainActor.run {
                    if var state = self.downloadStates[modelID] {
                        state.isDownloading = false
                        state.message = "Download cancelled at \(Int(state.progress * 100))%"
                        state.error = "Cancelled"
                        self.downloadStates[modelID] = state
                    }
                    self.currentDownloadTask = nil
                    self.currentDownloadModelID = nil

                    // User explicitly cancelled — don't auto-resume on next launch.
                    self.clearInFlight(modelID)

                    print("HALDEBUG-DOWNLOAD: Download cancelled for \(modelID); coordinator tasks cancelled; in-flight marker cleared")

                    // Process next item in queue if any
                    self.processNextInQueue()
                }
            } catch {
                progressPollingTask?.cancel()
                // Release the cross-app lock so a sibling app (or our own
                // next-launch resume) can retry this model.
                SharedModelStore.releaseDownloadLock(modelID: modelID)
                await MainActor.run {
                    if var state = self.downloadStates[modelID] {
                        state.isDownloading = false
                        state.error = error.localizedDescription
                        state.message = "Download failed — will retry next launch."
                        state.progress = 0.0
                        self.downloadStates[modelID] = state
                    }
                    self.currentDownloadTask = nil
                    self.currentDownloadModelID = nil

                    // Keep the in-flight marker. iOS-suspension cancellation arrives
                    // here as a URLError (-999), not CancellationError, so leaving
                    // the marker in place lets resumeInFlightDownloadsIfAny() pick
                    // the download back up automatically when the user returns to
                    // the app. If the error is a hard failure (no network, etc.),
                    // the next launch's retry will fail the same way until the user
                    // explicitly cancels via the UI.
                    print("HALDEBUG-DOWNLOAD: ❌ Download failed for \(modelID): \(error.localizedDescription) — in-flight marker preserved for next-launch resume")

                    // Process next item in queue if any
                    self.processNextInQueue()
                }
            }
        }
    }

    /// The wait-and-adopt path taken when a sibling app already holds the
    /// download lock for `modelID`. Polls the shared store: if the sibling's
    /// download completes, we adopt the finished copy with zero re-download; if
    /// the sibling releases without finishing, or its lock goes stale (crash /
    /// force-quit), we take over and download it ourselves. Runs inside
    /// `currentDownloadTask`, so a user cancel (which cancels that task) ends it.
    private func awaitSharedDownloadThenAdopt(modelID: String, repoID: String, sizeGB: Double?) async {
        let modelDir = SharedModelStore.mlxModelDir(modelID)
        let expectedBytes = sizeGB.map { Int64($0 * 1_073_741_824) } ?? 0
        halLog("HALDEBUG-DOWNLOAD: awaiting sibling download of \(modelID) to adopt")

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { break }

            // Did it finish elsewhere? Completion = lock released AND a claim
            // recorded AND files on disk (the sibling's notifyModelDownloadComplete
            // does claim-then-release, so seeing no lock + a claim means whole).
            if SharedModelStore.downloadLock(modelID: modelID) == nil,
               !SharedModelStore.claimants(modelID: modelID).isEmpty,
               SharedModelStore.isRepoDownloaded(modelID) {
                halLog("HALDEBUG-DOWNLOAD: sibling finished \(modelID); adopting with zero re-download")
                adoptSharedModel(modelID: modelID)
                return
            }

            // Try to (re)acquire. Succeeds once the holder releases (gave up
            // without finishing) or its lock ages past the staleness backstop
            // (presumed dead). Either way, we now own the slot and download.
            if SharedModelStore.acquireDownloadLock(modelID: modelID) {
                // Race guard: it may have completed in the same tick we grabbed.
                if !SharedModelStore.claimants(modelID: modelID).isEmpty,
                   SharedModelStore.isRepoDownloaded(modelID) {
                    SharedModelStore.releaseDownloadLock(modelID: modelID)
                    adoptSharedModel(modelID: modelID)
                    return
                }
                halLog("HALDEBUG-DOWNLOAD: took over \(modelID) download (prior holder released or went stale)")
                await performLockedDownload(modelID: modelID, repoID: repoID, sizeGB: sizeGB)
                return
            }

            // Still held by the sibling — reflect their progress from the shared
            // dir's completed bytes so the user sees movement, not a dead bar.
            let size = directorySize(modelDir)
            let holder = SharedModelStore.downloadLock(modelID: modelID)?.holder
            await MainActor.run {
                guard var state = self.downloadStates[modelID], state.isDownloading else { return }
                if expectedBytes > 0 {
                    let frac = min(0.99, Double(size) / Double(expectedBytes))
                    state.progress = frac
                    state.message = "Downloading in \(SharedModelStore.appDisplayName(holder)) — \(Int(frac * 100))%…"
                } else {
                    state.message = "Downloading in \(SharedModelStore.appDisplayName(holder))…"
                }
                self.downloadStates[modelID] = state
            }
        }
    }

    /// Adopt a model that a sibling app downloaded into the shared container:
    /// record Hal's claim (so the sibling's delete can't pull it out from under
    /// us), exclude it from iCloud backup, and run the same success bookkeeping a
    /// real download would. No bytes are fetched. (The whole downloader is
    /// MainActor-isolated by the project default, so no explicit annotation is
    /// needed here.)
    private func adoptSharedModel(modelID: String) {
        SharedModelStore.claim(modelID: modelID, repo: modelID)
        SharedModelStore.excludeFromBackup(modelID)
        halLog("HALDEBUG-DOWNLOAD: ✅ Adopted shared model \(modelID) (fetched by another app; zero re-download)")
        markModelAsDownloadedFromBackground(modelID: modelID)
        NotificationCenter.default.post(name: .mlxModelDidDownload, object: nil, userInfo: ["modelID": modelID])
    }

    /// Returns the total bytes of all files under a directory tree (non-recursive symlinks excluded).
    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let bytes = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(bytes)
            }
        }
        return size
    }

    private func processNextInQueue() {
        guard !downloadQueue.isEmpty else { return }
        
        let nextDownload = downloadQueue.removeFirst()
        print("HALDEBUG-DOWNLOAD: Processing queued download: \(nextDownload.modelID)")
        
        Task {
            await startDownload(modelID: nextDownload.modelID, repoID: nextDownload.repoID, sizeGB: nextDownload.sizeGB)
        }
    }
    
    func cancelDownload(modelID: String) {
        // Cancel active download if this is the one
        if currentDownloadModelID == modelID {
            currentDownloadTask?.cancel()
            currentDownloadTask = nil
            currentDownloadModelID = nil
        } else {
            // Remove from queue if queued
            downloadQueue.removeAll { $0.modelID == modelID }
        }

        // Release the cross-app download lock if we held it (harmless no-op if we
        // didn't, or if we were only waiting to adopt a sibling's download).
        SharedModelStore.releaseDownloadLock(modelID: modelID)
        
        // Update state
        if var state = downloadStates[modelID] {
            state.isDownloading = false
            state.message = "Download cancelled at \(Int(state.progress * 100))%"
            state.error = "Cancelled"
            downloadStates[modelID] = state
        }
        
        print("HALDEBUG-DOWNLOAD: Cancelled active download for \(modelID)")
    }
    
    func deleteModel(modelID: String) async {
        let expectedPath = modelPath(for: modelID)

        // Abnormal-path cleanup FIRST — before releasing the claim or removing
        // files. If the model is mid-download (or was interrupted), three pieces of
        // state would otherwise outlive the delete:
        //   1. In-flight background URLSession tasks — a straggler completing after
        //      we remove the directory would MOVE its file back in and re-create the
        //      model on disk (observed 2026-07-16: DELETE returned ok, model
        //      reappeared). Cancel them first.
        //   2. The cross-app download lock — `releaseClaim` does not touch it, so the
        //      lock lingered after delete (observed: lockCount stayed 1). Release it.
        //   3. The in-flight resume marker — otherwise the next launch's resume path
        //      would try to re-download a model the user deliberately deleted.
        await BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
        SharedModelStore.releaseDownloadLock(modelID: modelID)
        clearInFlight(modelID)

        // v2.1 shared store: release Hal's claim FIRST. The files are removed
        // only when NO other app (Posey) still claims the model. So deleting a
        // shared model in Hal drops Hal's claim and leaves Posey's copy on disk;
        // deleting a Hal-only model (no remaining claimant) removes the files as
        // before. This is what makes "delete in one app can't break the other."
        let safeToDelete = SharedModelStore.releaseClaim(modelID: modelID)
        let fileExists = FileManager.default.fileExists(atPath: expectedPath.path)

        if safeToDelete && fileExists {
            do {
                try FileManager.default.removeItem(at: expectedPath)
                print("HALDEBUG-DOWNLOAD: Model deleted from: \(expectedPath.path)")

                await MainActor.run {
                    var modelIDs = self.downloadedModelIDs
                    modelIDs.remove(modelID)
                    self.downloadedModelIDs = modelIDs

                    var state = self.downloadStates[modelID] ?? DownloadState(
                        isDownloading: false,
                        progress: 0.0,
                        message: "Model deleted.",
                        error: nil,
                        localPath: nil
                    )
                    state.localPath = nil
                    state.progress = 0.0
                    state.message = "Model deleted."
                    self.downloadStates[modelID] = state

                    Task { await self.updateCacheSize() }
                }
            } catch {
                await MainActor.run {
                    var state = self.downloadStates[modelID] ?? DownloadState(
                        isDownloading: false,
                        progress: 0.0,
                        message: "Delete failed.",
                        error: error.localizedDescription,
                        localPath: nil
                    )
                    state.error = "Delete failed: \(error.localizedDescription)"
                    state.message = "Delete failed."
                    self.downloadStates[modelID] = state
                }
            }
        } else {
            // Not removed from disk — either another app still claims the model
            // (files kept, shared) or it wasn't present. Drop Hal's local
            // tracking either way. NOTE: for a still-shared model the files
            // remain, so isModelDownloaded (disk-truth) will still report it
            // present — that's correct (it IS on the device, via the other app).
            if !safeToDelete {
                print("HALDEBUG-DOWNLOAD: Released Hal's claim on \(modelID); another app still uses it — files kept.")
            }
            await MainActor.run {
                var modelIDs = self.downloadedModelIDs
                modelIDs.remove(modelID)
                self.downloadedModelIDs = modelIDs

                var state = self.downloadStates[modelID] ?? DownloadState(
                    isDownloading: false,
                    progress: 0.0,
                    message: "Model was already deleted.",
                    error: nil,
                    localPath: nil
                )
                state.message = safeToDelete
                    ? "Model was already deleted."
                    : "Removed from Hal. Still downloaded in another app (Posey)."
                self.downloadStates[modelID] = state
                Task { await self.updateCacheSize() }
            }
        }
    }
    
    func isModelDownloaded(_ modelID: String) -> Bool {
        // Disk-truth against the App-Group shared store: a model is "present"
        // if its files exist there, regardless of WHICH app fetched them. This
        // is what lets Hal see (and load) models Posey downloaded, without Hal
        // having its own record of the download. Matches Posey's
        // `SharedModelStore.isRepoDownloaded`. Mid-download a partial dir reads
        // present, so callers that care also check `isDownloading`.
        return SharedModelStore.isRepoDownloaded(modelID)
    }

    /// Waits asynchronously for the `.mlxModelDidDownload` notification that
    /// matches the given `modelID`. Used by startDownload to keep its
    /// currentDownloadTask alive for the duration of the actual download even
    /// though `BackgroundDownloadCoordinator.startDownload` returns
    /// immediately after enqueueing the file tasks. Cancellation propagates
    /// through Task.checkCancellation.
    private func waitForModelCompletion(modelID: String) async throws {
        // Race success against failure: whichever fires for this modelID first
        // wins. Without the failure arm, a failed download (which no longer posts
        // .mlxModelDidDownload) would leave this waiting forever and the download
        // UI spinning. The failure arm throws so the caller's existing catch treats
        // it as a failed download and tears the task down.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let succeeded = NotificationCenter.default.notifications(named: .mlxModelDidDownload)
                for await n in succeeded {
                    try Task.checkCancellation()
                    if (n.userInfo?["modelID"] as? String) == modelID { return }
                }
            }
            group.addTask {
                let failed = NotificationCenter.default.notifications(named: .mlxModelDownloadFailed)
                for await n in failed {
                    try Task.checkCancellation()
                    if (n.userInfo?["modelID"] as? String) == modelID {
                        throw NSError(domain: "BackgroundDownloadCoordinator", code: 10, userInfo: [
                            NSLocalizedDescriptionKey: "Download failed for \(modelID) — one or more files could not be saved."
                        ])
                    }
                }
            }
            // Take the first arm to finish (return or throw), then cancel the other.
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Called by `BackgroundDownloadCoordinator` once all files for a model
    /// have finished downloading via the background URLSession. We need to
    /// mirror the bookkeeping that the legacy HubApi-based startDownload
    /// did at its success site: persist the model ID, update the
    /// DownloadState, clear the in-flight marker, and refresh the catalog.
    func markModelAsDownloadedFromBackground(modelID: String) {
        let finalURL = modelPath(for: modelID)

        // Durably record that this download VERIFIABLY completed, BEFORE clearing
        // the in-flight marker below. If the process dies in the tiny window
        // between here and clearInFlight, the next launch's resume path sees the
        // sentinel and correctly treats the model as done. Without it, resume fell
        // back to "dir has any files," so a half-downloaded model read as complete,
        // its marker got cleared, and it was left permanently partial-but-"done".
        SharedModelStore.markRepoComplete(modelID)

        var modelIDs = self.downloadedModelIDs
        modelIDs.insert(modelID)
        self.downloadedModelIDs = modelIDs

        var state = self.downloadStates[modelID] ?? DownloadState(
            isDownloading: false,
            progress: 1.0,
            message: "Model ready.",
            error: nil,
            localPath: finalURL
        )
        state.isDownloading = false
        state.progress = 1.0
        state.message = "Model ready."
        state.localPath = finalURL
        state.error = nil
        self.downloadStates[modelID] = state

        // Clear the in-flight marker so the next launch doesn't try to resume.
        self.clearInFlight(modelID)

        // Clear current task tracking if this was the active one.
        if self.currentDownloadModelID == modelID {
            self.currentDownloadModelID = nil
            self.currentDownloadTask = nil
        }

        // Refresh cache size to reflect the new download.
        Task { await self.updateCacheSize() }

        halLog("HALDEBUG-DOWNLOAD: ✅ Background download finalized for \(modelID)")

        // Process the next queued download, if any.
        self.processNextInQueue()
    }

    /// The failure counterpart to ``markModelAsDownloadedFromBackground``. Surfaces
    /// the failure in the model's DownloadState. Deliberately does NOT insert into
    /// `downloadedModelIDs` and does NOT clear the in-flight marker — the coordinator
    /// path that threw will decide resume policy (a move failure is preserved for a
    /// next-launch retry, same as other hard failures). Lock release, partial-dir
    /// cleanup, and the manifest (non-)claim are handled by the coordinator's
    /// `notifyModelDownloadFailed` before this is called.
    func markModelFailedFromBackground(modelID: String, failureCount: Int) {
        var state = self.downloadStates[modelID] ?? DownloadState(
            isDownloading: false, progress: 0, message: "", error: nil, localPath: nil)
        state.isDownloading = false
        state.progress = 0
        state.message = "Download failed."
        state.error = "\(failureCount) file(s) couldn't be saved. Tap to retry."
        state.localPath = nil
        self.downloadStates[modelID] = state
        halLog("HALDEBUG-DOWNLOAD: ❌ Background download marked FAILED for \(modelID) (\(failureCount) file(s))")
    }
    
    func getModelPath(_ modelID: String) -> URL? {
        // Gate on the SAME shared-store disk-truth that `isModelDownloaded` uses,
        // NOT Hal's private `downloadedModelIDs` record. A model a sibling app
        // (Posey) downloaded is present in the App-Group store and selectable in
        // the Model Library (the row uses isModelDownloaded), but it's not in
        // Hal's own downloadedModelIDs — so the old guard returned nil here, the
        // MLX load failed with "not downloaded," and switchToModel reverted to the
        // previous model. That's the "tried to switch to Dolphin, got Bonsai" bug
        // (2026-07-11): the two presence checks disagreed. Keeping them identical
        // fixes it and lets Hal load any model present in the shared store.
        guard isModelDownloaded(modelID) else { return nil }
        let path = modelPath(for: modelID)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
    
    // MARK: - Cache Management
    
    @MainActor
    func updateCacheSize() async {
        isCacheCalculating = true
        
        let size = await calculateDirectorySize(hubCacheDirectory)
        
        hubCacheSize = size > 0 ? formatBytes(Int64(size)) : "No cache"
        isCacheCalculating = false
    }
    
    /// What a "clear Hal's models" pass will do, expressed per model so the UI can
    /// tell the truth before the user commits.
    struct ClearModelsPlan {
        /// Hal is the only claimant — releasing drops the refcount to zero and the
        /// files go.
        var willDelete: [String] = []
        /// A sibling app in the family still claims these. Hal's claim is released
        /// but the bytes stay on disk.
        var willStayForOthers: [String] = []
        /// Display names of the sibling apps holding those claims, so the
        /// confirmation can name them ("also used by Posey"). Populated by
        /// ``previewClearHalsModels()`` only — the post-hoc result doesn't need it,
        /// since `releaseClaim` reports a verdict rather than a claimant list.
        var otherClaimants: Set<String> = []

        var isEmpty: Bool { willDelete.isEmpty && willStayForOthers.isEmpty }
        var totalClaimed: Int { willDelete.count + willStayForOthers.count }
    }

    /// Dry run of ``clearHalsModels()``. Drives the confirmation copy so the
    /// button's promise matches its behavior — the old alert said "this will
    /// delete all cached model files," which was the other half of the bug.
    @MainActor
    func previewClearHalsModels() -> ClearModelsPlan {
        var plan = ClearModelsPlan()
        for modelID in SharedModelStore.modelsClaimedByThisApp() {
            let others = SharedModelStore.claimants(modelID: modelID)
                .filter { $0 != SharedModelStore.thisAppID }
            if others.isEmpty {
                plan.willDelete.append(modelID)
            } else {
                plan.willStayForOthers.append(modelID)
                for appID in others {
                    plan.otherClaimants.insert(SharedModelStore.displayName(forAppID: appID))
                }
            }
        }
        return plan
    }

    /// Release Hal's claim on every model Hal claims, and delete from disk ONLY
    /// the ones no sibling app still wants.
    ///
    /// This deliberately does **not** remove `hubCacheDirectory`. That directory is
    /// `SharedModelStore.huggingFaceRoot` — the App-Group container shared with
    /// Posey and the rest of the family — so a `removeItem` there took out every
    /// app's models in one shot: no manifest read, no claim check, no notification
    /// to the app whose files just vanished. And because `manifest.json` lives one
    /// level ABOVE `huggingface/`, it survived the wipe and went on describing
    /// files that no longer existed, so the next `releaseClaim` reasoned from
    /// fiction. (Found 2026-07-15 from the AI Camera project; the call predated the
    /// shared store, was correct when the cache was Hal's alone, and never got
    /// re-read when the store moved underneath it.)
    ///
    /// The contract, from `SharedModelStore`'s own header: *releasing in one app
    /// releases only that app's claim; files go only when NO app still claims the
    /// model.* The per-model Delete path already honored it. This now does too.
    ///
    /// Deletes are scoped to `mlxModelDir(id)` — one model at a time, never a root
    /// delete. Returns what actually happened.
    @MainActor
    @discardableResult
    func clearHalsModels() -> ClearModelsPlan {
        var result = ClearModelsPlan()

        for modelID in SharedModelStore.modelsClaimedByThisApp() {
            // Release first, then act on the answer. `true` means the refcount hit
            // zero — nobody else is holding this model.
            guard SharedModelStore.releaseClaim(modelID: modelID) else {
                result.willStayForOthers.append(modelID)
                print("HALDEBUG-CACHE: kept \(modelID) — still claimed by another app")
                continue
            }

            let dir = modelPath(for: modelID)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                // Claimed in the ledger but already gone from disk. The release
                // above is the useful half; nothing to remove.
                result.willDelete.append(modelID)
                continue
            }
            do {
                try FileManager.default.removeItem(at: dir)
                result.willDelete.append(modelID)
                print("HALDEBUG-CACHE: ✅ deleted \(modelID)")
            } catch {
                // The claim is already released, so leave it out of both lists
                // rather than report a delete that didn't happen.
                print("HALDEBUG-CACHE: ❌ failed to delete \(modelID): \(error.localizedDescription)")
            }
        }

        // Hal now claims nothing, regardless of what stayed on disk for a sibling.
        // Anything still present shows up via the shared-store disk-truth path
        // (`isModelDownloaded`) as present-but-unclaimed, which is correct.
        downloadedModelIDs = []
        downloadStates = [:]

        // Do NOT assert "No cache" — a sibling app's models may still be sitting in
        // the shared container, and claiming the store is empty would be the same
        // kind of lie this fix exists to remove. Re-measure instead.
        Task { @MainActor in await updateCacheSize() }

        print("HALDEBUG-CACHE: cleared Hal's models — \(result.willDelete.count) deleted, \(result.willStayForOthers.count) kept for other apps")
        return result
    }
    
    // MARK: - Utility Methods
    
    private func calculateDirectorySize(_ directory: URL) async -> UInt64 {
        return await withCheckedContinuation { continuation in
            Task.detached {
                var totalSize: UInt64 = 0
                
                guard FileManager.default.fileExists(atPath: directory.path) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                while let fileURL = enumerator.nextObject() as? URL {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        
                        // Only count files, not directories
                        if let isDirectory = resourceValues.isDirectory, !isDirectory {
                            if let fileSize = resourceValues.totalFileAllocatedSize {
                                totalSize += UInt64(fileSize)
                            }
                        }
                    } catch {
                        // Skip files we can't read
                        continue
                    }
                }
                
                continuation.resume(returning: totalSize)
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Notification
extension Notification.Name {
    // `nonisolated` so these constants can be read from Sendable/detached contexts
    // (e.g. the task-group arms in `waitForModelCompletion`). Notification-name
    // constants carry no state and were never meaningfully actor-bound.
    nonisolated static let mlxModelDidDownload = Notification.Name("mlxModelDidDownload")
    /// Posted when a model's download settles with one or more files that failed
    /// to save. Distinct from success so waiters can throw rather than hang and the
    /// UI can show an error. `userInfo["modelID"]`.
    nonisolated static let mlxModelDownloadFailed = Notification.Name("mlxModelDownloadFailed")
}

// ==== LEGO END: 45 BackgroundDownloadCoordinator + MLXModelDownloader ====
