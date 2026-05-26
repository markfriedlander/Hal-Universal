// MLXModelDownloader.swift
// Hal Universal
//
// Extracted from Hal.swift on 2026-05-26 as part of the refactor-as-you-go
// directive. Self-contained subsystem for downloading MLX-compatible models
// from HuggingFace and tracking their state on disk.
//
// Two cooperating classes, both singletons:
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
// Why one file: the two classes are tightly coupled — MLXModelDownloader
// calls into BackgroundDownloadCoordinator's API and observes its
// notification, and the coordinator calls back into the downloader's
// markModelAsDownloadedFromBackground completion hook. Splitting them
// would just push the seam between them out into thin interface types
// without adding any logical isolation.
//
// External dependencies:
//   - halLog (global function defined in Hal.swift)
//   - ModelCatalogService.shared (Hal.swift LEGO 30) for display-name
//     lookup in pre-flight refusal messages
//   - HalAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)
//     which routes iOS background-session events to our coordinator's
//     `backgroundCompletionHandler` — implemented in Hal.swift
//   - .mlxModelDidDownload Notification.Name is defined at the bottom
//     of THIS file (was inside the same LEGO block prior to extraction)

import Foundation
import SwiftUI
import Combine
import UIKit


// ==== LEGO START: 29 BackgroundDownloadCoordinator + MLXModelDownloader ====

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

            guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename)") else {
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
    // GET https://huggingface.co/api/models/<repo>/tree/main
    // Returns a JSON array of {"type": "file"|"directory", "path": "...", "size": Int}
    private func fetchRepoFileList(repoID: String) async throws -> [String] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main") else {
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
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    // MARK: - Completion Notification

    @MainActor
    private func notifyModelDownloadComplete(modelID: String) {
        halLog("HALDEBUG-BGDL: ✅ Model \(modelID) fully downloaded; posting .mlxModelDidDownload")
        // Mark in MLXModelDownloader's downloaded set so future model-status
        // queries report it as downloaded.
        MLXModelDownloader.shared.markModelAsDownloadedFromBackground(modelID: modelID)
        NotificationCenter.default.post(name: .mlxModelDidDownload, object: nil, userInfo: ["modelID": modelID])
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
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            halLog("HALDEBUG-BGDL: Moved \(context.filename) → \(target.path) (\(kind == .foreground ? "fg" : "bg") task \(downloadTask.taskIdentifier))")
        } catch {
            halLog("HALDEBUG-BGDL: ❌ Move failed for \(context.filename): \(error.localizedDescription)")
        }

        // Update bookkeeping. Note: didCompleteWithError will fire shortly
        // after this; final cleanup happens there.
        Task { @MainActor in
            var pending = self.filesPendingByModel[context.modelID] ?? []
            pending.remove(context.filename)
            self.filesPendingByModel[context.modelID] = pending
            if pending.isEmpty {
                self.notifyModelDownloadComplete(modelID: context.modelID)
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
    
    // Helper: Construct runtime path for a model ID
    private func modelPath(for modelID: String) -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
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
            if isModelDownloaded(modelID) {
                // Already done — clean up the stale in-flight marker.
                clearInFlight(modelID)
                halLog("HALDEBUG-DOWNLOAD: \(modelID) is already downloaded; clearing in-flight marker")
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
            Task { await self.startDownload(modelID: modelID, repoID: repoID, sizeGB: size) }
        }
    }
    
    // MARK: - Cache Management
    
    @Published var hubCacheSize: String = "Calculating..."
    @Published var isCacheCalculating: Bool = false
    
    // MARK: - Directory Management
    
    private var hubCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "huggingface")
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

    func startDownload(modelID: String, repoID: String, sizeGB: Double? = nil) async {
        // Check if already downloaded
        if isModelDownloaded(modelID) {
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
                // clear, queue advance, cache size). So all we do here on
                // success is cancel the polling task and log.
                try await self.waitForModelCompletion(modelID: modelID)
                progressPollingTask?.cancel()
                halLog("HALDEBUG-DOWNLOAD: ✅ Download notification received for \(modelID); coordinator handled bookkeeping")
            } catch is CancellationError {
                // User explicit cancel via the UI. Tell the coordinator to
                // tear down its background URLSession tasks for this model so
                // they don't continue burning bandwidth after the cancel.
                await BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
                progressPollingTask?.cancel()
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
        
        if FileManager.default.fileExists(atPath: expectedPath.path) {
            do {
                try FileManager.default.removeItem(at: expectedPath)
                print("HALDEBUG-DOWNLOAD: Model deleted from: \(expectedPath.path)")
                
                await MainActor.run {
                    // Remove from persistent storage
                    var modelIDs = self.downloadedModelIDs
                    modelIDs.remove(modelID)
                    self.downloadedModelIDs = modelIDs
                    
                    // Update state
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
                    
                    // Update cache size
                    Task {
                        await self.updateCacheSize()
                    }
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
            // File doesn't exist, clean up storage anyway
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
                state.message = "Model was already deleted."
                self.downloadStates[modelID] = state
            }
        }
    }
    
    func isModelDownloaded(_ modelID: String) -> Bool {
        return downloadedModelIDs.contains(modelID) &&
               FileManager.default.fileExists(atPath: modelPath(for: modelID).path)
    }

    /// Waits asynchronously for the `.mlxModelDidDownload` notification that
    /// matches the given `modelID`. Used by startDownload to keep its
    /// currentDownloadTask alive for the duration of the actual download even
    /// though `BackgroundDownloadCoordinator.startDownload` returns
    /// immediately after enqueueing the file tasks. Cancellation propagates
    /// through Task.checkCancellation.
    private func waitForModelCompletion(modelID: String) async throws {
        let notifications = NotificationCenter.default.notifications(named: .mlxModelDidDownload)
        for await notification in notifications {
            try Task.checkCancellation()
            if let id = notification.userInfo?["modelID"] as? String, id == modelID {
                return
            }
        }
    }

    /// Called by `BackgroundDownloadCoordinator` once all files for a model
    /// have finished downloading via the background URLSession. We need to
    /// mirror the bookkeeping that the legacy HubApi-based startDownload
    /// did at its success site: persist the model ID, update the
    /// DownloadState, clear the in-flight marker, and refresh the catalog.
    func markModelAsDownloadedFromBackground(modelID: String) {
        let finalURL = modelPath(for: modelID)
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
    
    func getModelPath(_ modelID: String) -> URL? {
        guard downloadedModelIDs.contains(modelID) else { return nil }
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
    
    func clearHubCache() {
        if FileManager.default.fileExists(atPath: hubCacheDirectory.path) {
            do {
                try FileManager.default.removeItem(at: hubCacheDirectory)
                
                // Clear all model states since cache is gone
                downloadedModelIDs = []
                downloadStates = [:]
                hubCacheSize = "No cache"
                
                print("HALDEBUG-CACHE: ✅ Cleared Hub cache and all model states")
            } catch {
                if var state = downloadStates.values.first {
                    state.error = "Failed to clear cache: \(error.localizedDescription)"
                    state.message = "Cache clear failed."
                }
                print("HALDEBUG-CACHE: ❌ Failed to clear cache: \(error.localizedDescription)")
            }
        } else {
            hubCacheSize = "No cache"
            print("HALDEBUG-CACHE: No cache directory found to clear")
        }
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
    static let mlxModelDidDownload = Notification.Name("mlxModelDidDownload")
}

// ==== LEGO END: 29 BackgroundDownloadCoordinator + MLXModelDownloader ====
