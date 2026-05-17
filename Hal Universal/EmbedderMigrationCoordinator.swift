// EmbedderMigrationCoordinator.swift
// Hal Universal
//
// Extracted from Hal.swift 2026-05-17 afternoon as part of the standing
// refactor-as-you-go directive.
//
// Drives the user-facing flow for upgrading the embedding backend:
//   1. Download EmbeddingGemma (~210MB) via the existing
//      MLXModelDownloader / BackgroundDownloadCoordinator pipeline.
//   2. Switch the active backend (UserDefaults + wipe existing embeddings).
//   3. Re-embed all stored rows in the background (the migration).
//
// Two-way: every step is reversible. Switching from Gemma back to
// Apple NLContextual goes through the same wipe + re-embed flow.
//
// State is a single @Published `phase`. The UI observes it to render
// the appropriate label + progress (download progress bar, then migration
// row counter, then idle). Errors land as an .error phase that the user
// dismisses to retry.

import Foundation
import Combine
import SwiftUI

@MainActor
final class EmbedderMigrationCoordinator: ObservableObject {
    static let shared = EmbedderMigrationCoordinator()

    enum Phase: Equatable {
        case idle
        case downloading(progress: Double, message: String)
        case switching(target: String)
        case migrating(updated: Int, total: Int)
        case done(message: String)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var activeBackend: EmbeddingBackend = EmbeddingBackend.current()

    private var pollTask: Task<Void, Never>?

    private init() {}

    /// Refresh from UserDefaults — called when the view appears so we
    /// don't drift if the backend was changed by an API caller.
    func refresh() {
        activeBackend = EmbeddingBackend.current()
    }

    /// Trigger the Gemma download via the existing catalog downloader.
    /// Returns immediately; polls progress until done or error.
    func startDownload() {
        guard let modelID = EmbeddingBackend.embeddingGemma.modelID else { return }
        if MLXModelDownloader.shared.isModelDownloaded(modelID) {
            phase = .done(message: "EmbeddingGemma already downloaded.")
            return
        }
        phase = .downloading(progress: 0, message: "Starting download…")
        Task {
            await MLXModelDownloader.shared.startDownload(modelID: modelID, repoID: modelID, sizeGB: 0.21)
        }
        // Poll the downloader state on the main actor so SwiftUI updates.
        // Strong self capture (coordinator is a singleton; lifetime is the app).
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
                let state = MLXModelDownloader.shared.downloadStates[modelID]
                let downloaded = MLXModelDownloader.shared.isModelDownloaded(modelID)
                if downloaded {
                    self.phase = .done(message: "EmbeddingGemma downloaded.")
                    return
                }
                if let s = state, let err = s.error, !err.isEmpty {
                    self.phase = .error("Download failed: \(err)")
                    return
                }
                if let s = state {
                    self.phase = .downloading(progress: s.progress, message: s.message)
                }
            }
        }
    }

    /// Switch the active embedding backend and re-embed every existing
    /// row that has a NULL embedding. Runs on a background task and
    /// publishes progress.
    func switchAndMigrate(to target: EmbeddingBackend, memoryStore: MemoryStore) {
        // Refuse if the target backend requires a download that hasn't
        // happened yet. Belt + suspenders — UI should not offer the
        // switch button in that case.
        if let id = target.modelID, !MLXModelDownloader.shared.isModelDownloaded(id) {
            phase = .error("\(target.displayName) is not downloaded yet.")
            return
        }

        phase = .switching(target: target.displayName)
        pollTask?.cancel()
        let coordinator = self
        let storeRef = memoryStore
        pollTask = Task.detached(priority: .userInitiated) {
            // Persist the new backend, wipe existing embeddings.
            UserDefaults.standard.set(target.rawValue, forKey: EmbeddingBackend.defaultsKey)
            UserDefaults.standard.removeObject(forKey: "embeddingSystemVersion")
            storeRef.wipeStaleEmbeddingsIfNeeded()
            // Kick off async warm-up; wait until loaded (cap at ~60s so
            // a busted load doesn't hang the UI forever).
            EmbeddingProvider.shared.warmUp()
            let deadline = Date().addingTimeInterval(60)
            while !EmbeddingProvider.shared.isLoaded {
                if Date() > deadline {
                    await MainActor.run {
                        coordinator.phase = .error("\(target.displayName) failed to load within 60s. Try again.")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await MainActor.run {
                coordinator.activeBackend = target
                coordinator.phase = .migrating(updated: 0, total: 0)
            }
            // Run the migration. Single synchronous call — total runtime
            // depends on row count and backend speed. Future variant
            // could batch and publish per-row progress.
            let result = storeRef.reEmbedAllNullRows()
            await MainActor.run {
                coordinator.phase = .done(message: "Migrated \(result.updated) rows to \(target.displayName). (\(result.skipped) skipped, \(result.failed) failed.)")
            }
        }
    }

    /// Reset to idle so the user can try again or see fresh state.
    func dismissResult() {
        phase = .idle
    }
}

// MARK: - Embedder Backend Row + Migration Status

/// Row for a single embedding backend in the Model Library "Embedding (Memory)"
/// section. Renders name + size + blurb + the appropriate action button
/// (Download / Switch / Active).
struct EmbedderBackendRow: View {
    let backend: EmbeddingBackend
    @ObservedObject private var coordinator = EmbedderMigrationCoordinator.shared
    @ObservedObject private var downloader = MLXModelDownloader.shared
    @EnvironmentObject var chatViewModel: ChatViewModel

    @State private var isExpanded: Bool = false
    @State private var showingConfirm: Bool = false

    private var isActive: Bool { coordinator.activeBackend == backend }

    private var isDownloaded: Bool {
        guard let id = backend.modelID else { return true }  // NLContextual built-in
        return downloader.isModelDownloaded(id)
    }

    private var isDownloading: Bool {
        guard let id = backend.modelID else { return false }
        return downloader.downloadStates[id]?.isDownloading == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() } }) {
                HStack(spacing: 10) {
                    Text(backend.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let size = backend.sizeBlurb {
                        Text(size)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    // Status dot: green = active, grey = downloaded, none = not downloaded
                    if isActive {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                            .accessibilityLabel("Active")
                    } else if isDownloaded {
                        Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                            .accessibilityLabel("Downloaded")
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.vertical, 8)
                Text(backend.blurb)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                Text("\(backend.dimension)-dim sentence vectors")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
                actionRow
            }
        }
        .padding(.vertical, 4)
        .onAppear { coordinator.refresh() }
        .confirmationDialog(
            "Switch to \(backend.displayName)?",
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            Button("Switch and re-embed memories", role: .destructive) {
                coordinator.switchAndMigrate(to: backend, memoryStore: chatViewModel.memoryStore)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing embeddings will be wiped and regenerated with \(backend.displayName). This may take a few minutes depending on your memory size.")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            } else if !isDownloaded {
                if isDownloading {
                    if let state = downloader.downloadStates[backend.modelID ?? ""] {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: state.progress).progressViewStyle(.linear)
                            Text(state.message).font(.caption2).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        if let id = backend.modelID {
                            downloader.cancelDownload(modelID: id)
                        }
                    }
                    .font(.subheadline)
                } else {
                    Button(action: { coordinator.startDownload() }) {
                        Label("Download \(backend.displayName)", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else {
                Button(action: { showingConfirm = true }) {
                    Label("Switch to \(backend.displayName)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                if backend.modelID != nil {
                    Button(role: .destructive, action: {
                        if let id = backend.modelID {
                            Task { await downloader.deleteModel(modelID: id) }
                        }
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isActive)
                }
            }
        }
    }
}

/// Single-row status surface for the embedder migration. Renders nothing
/// when the coordinator is idle so the section is quiet by default.
struct EmbedderMigrationStatusRow: View {
    @ObservedObject private var coordinator = EmbedderMigrationCoordinator.shared

    var body: some View {
        switch coordinator.phase {
        case .idle:
            EmptyView()
        case .downloading(let progress, let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Downloading EmbeddingGemma…", systemImage: "arrow.down.circle")
                    .font(.subheadline)
                ProgressView(value: progress).progressViewStyle(.linear)
                Text(message).font(.caption2).foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        case .switching(let target):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Switching to \(target)…")
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
        case .migrating(let updated, let total):
            VStack(alignment: .leading, spacing: 4) {
                Label("Re-embedding memories…", systemImage: "brain")
                    .font(.subheadline)
                if total > 0 {
                    ProgressView(value: Double(updated), total: Double(total))
                        .progressViewStyle(.linear)
                    Text("\(updated) / \(total) rows").font(.caption2).foregroundColor(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .padding(.vertical, 4)
        case .done(let message):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(message).font(.caption)
                Spacer()
                Button("OK") { coordinator.dismissResult() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(message).font(.caption).foregroundColor(.red)
                Spacer()
                Button("OK") { coordinator.dismissResult() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }
}
