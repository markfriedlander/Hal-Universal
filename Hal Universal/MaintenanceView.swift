//
//  MaintenanceView.swift
//  Hal Universal
//
//  Maintenance & Reset: the app's housekeeping and reset actions, gathered onto one page
//  reached from the main Settings screen. Reset Defaults, Clear Hal's Models (storage), and
//  Nuclear Reset (wipe all data) used to be scattered in PowerUserView; grouped here
//  2026-07-28 because they are one coherent "reset & reclaim" family, all somewhat
//  destructive, and none had a good home. Each keeps its own confirmation alert. ("Free up
//  old model files" deliberately stays in the AI Model section, it's lighter and belongs
//  next to the models where a user reclaiming space will find it without digging.)
//

import SwiftUI
import Combine   // objectWillChange.send() on the shared downloader (Free-up-models row)
import SharedModelStoreKit   // SharedModelStore.clearEntireSharedStore() (Clear all family models)

// ==== LEGO START: 63 MaintenanceView (Maintenance & Reset) ====

struct MaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var mlxDownloader: MLXModelDownloader

    @State private var showResetSettingsAlert = false
    @State private var showingClearCacheAlert = false
    @State private var showingNuclearResetConfirmationAlert = false
    @State private var showingClearFamilyAlert = false

    // "Free up old model files" — moved here from the AI Model section 2026-07-29 to sit
    // beside "Clear Hal's Models" as the gentle-reclaim vs full-clear pair. `oldModelsPlan`
    // is a read-only dry run of the cleanup (what Hal can free vs what a sibling still
    // holds), refreshed on appear and after a tap; `lastFreedOldBytes` shows what a
    // just-run cleanup recovered. Together they let the subtitle tell the honest truth
    // instead of advertising space a sibling is still using. See
    // MaintenanceTasks.previewFreeOldModelFiles / freeOldModelFiles.
    @State private var oldModelsPlan = MaintenanceTasks.OldModelsPlan()
    @State private var lastFreedOldBytes: Int64 = 0

    var body: some View {
        NavigationView {
            Form {
                settingsResetSection
                cacheManagementSection
                dataManagementSection
            }
            .navigationTitle("Maintenance & Reset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Cheap dry run (a few directory checks + a manifest read) so the
                // "Free up old model files" row shows an honest, up-to-date picture.
                oldModelsPlan = MaintenanceTasks.previewFreeOldModelFiles()
            }
        }
        .alert("Confirm Nuclear Reset", isPresented: $showingNuclearResetConfirmationAlert) {
            Button("Nuclear Reset", role: .destructive) {
                chatViewModel.resetAllData()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete ALL conversations, summaries, RAG documents, and document memory from the database? This cannot be undone.")
        }
        .alert("Confirm Settings Reset", isPresented: $showResetSettingsAlert) {
            Button("Reset Settings", role: .destructive) {
                chatViewModel.resetSettingsToDefaults()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Reset all settings to factory defaults? This will reset your system prompt, memory depth, similarity threshold, recency settings, and RAG limits. Your conversation history and documents will not be affected.")
        }
        .alert("Clear Hal's Models", isPresented: $showingClearCacheAlert) {
            Button("Clear Hal's Models", role: .destructive) {
                mlxDownloader.clearHalsModels()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(clearModelsMessage)
        }
        .alert("Clear all family models?", isPresented: $showingClearFamilyAlert) {
            Button("Clear all family models", role: .destructive) {
                let removed = SharedModelStore.clearEntireSharedStore()
                oldModelsPlan = MaintenanceTasks.previewFreeOldModelFiles()
                lastFreedOldBytes = 0
                mlxDownloader.objectWillChange.send()
                ModelCatalogService.shared.refreshDownloadStates()
                Task { await mlxDownloader.updateCacheSize() }
                print("HALDEBUG-CACHE: cleared entire shared store: \(removed) repos removed")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes every downloaded AI model shared across Hal, Posey, and AI Camera to reclaim all model storage at once. Each app re-downloads what it needs the next time you use it. Your conversations, documents, and settings are not affected.")
        }
    }

    /// Confirmation copy for "Clear Hal's Models", built from a dry run so it
    /// describes what will actually happen to THIS device right now.
    ///
    /// The old copy — "this will delete all cached model files" — was technically
    /// true of the old (broken) behavior and read to every user as "Hal's files."
    /// It was deleting the whole family's. Now that the delete is claim-aware, the
    /// alert explains the sharing rather than hiding it: a co-claimed model staying
    /// on disk is the system working, and saying so is cheaper than a support email.
    private var clearModelsMessage: String {
        let plan = mlxDownloader.previewClearHalsModels()

        if plan.isEmpty {
            return "Hal isn't using any downloaded models right now, so there's nothing to clear."
        }

        var lines: [String] = []
        if !plan.willDelete.isEmpty {
            let n = plan.willDelete.count
            lines.append("\(n) model\(n == 1 ? "" : "s") will be deleted from this device.")
        }
        if !plan.willStayForOthers.isEmpty {
            let n = plan.willStayForOthers.count
            // Name the siblings when we can — "also used by Posey" explains the
            // family; "also used by another app" just raises a question.
            let byWhom = claimantList(plan.otherClaimants)
            lines.append("\(n) \(n == 1 ? "is" : "are") also used by \(byWhom) and will stay on disk, Hal just stops using \(n == 1 ? "it" : "them").")
        }
        lines.append("Anything deleted will need to be downloaded again.")
        return lines.joined(separator: " ")
    }

    /// One-line status under "Free up old model files": what Hal can actually reclaim,
    /// what a sibling is still using (named), or that a just-run cleanup is done. Honest
    /// by construction — it reads the same dry run the delete acts on, so the row never
    /// promises space a sibling still holds (the bug that made this button look dead on
    /// a shared Mac). No em dashes: user-facing string.
    private var freeOldModelsSubtitle: String {
        let plan = oldModelsPlan
        let heldBy = claimantList(plan.otherClaimants)
        if plan.freeableBytes > 0 && plan.keptBytes > 0 {
            return "Free \(fmtBytes(plan.freeableBytes)). \(fmtBytes(plan.keptBytes)) kept, in use by \(heldBy)."
        }
        if plan.freeableBytes > 0 {
            return "\(fmtBytes(plan.freeableBytes)) of old-version copies to remove."
        }
        if plan.keptBytes > 0 {
            return "\(fmtBytes(plan.keptBytes)) in use by \(heldBy). Nothing for Hal to free right now."
        }
        if lastFreedOldBytes > 0 {
            return "Freed \(fmtBytes(lastFreedOldBytes)). You're all clean."
        }
        return "Nothing to clean up."
    }

    private func fmtBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "Posey" / "Posey and AI Camera" / "A, B, and C" from a set of display names.
    /// Shared by the Clear-models confirmation and the Free-up subtitle.
    private func claimantList(_ names: Set<String>) -> String {
        let who = names.sorted()
        switch who.count {
        case 0:  return "another app in the AI family"
        case 1:  return who[0]
        case 2:  return "\(who[0]) and \(who[1])"
        default: return who.dropLast().joined(separator: ", ") + ", and " + who[who.count - 1]
        }
    }

    // MARK: - Settings Reset Section
    
    private var settingsResetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                // Per-model reset (Layer 3 of per-model settings profiles).
                // Restores just the active model's settings to its empirical
                // defaults, leaving other models' overrides untouched.
                Button(action: {
                    chatViewModel.resetSettingsToModelDefaults()
                }) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundColor(.blue)
                        Text("Reset settings for \(chatViewModel.selectedModel.displayName)")
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Text("Restore the active model's settings (temperature, memory depth, RAG budget, etc.) to its tuned defaults. Other models' settings are untouched.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // Global "nuke everything" reset (existing behavior).
                Button(action: {
                    showResetSettingsAlert = true
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundColor(.orange)
                        Text("Reset All Settings to Factory Defaults")
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Text("Restore every tunable parameter, across every model, to factory defaults. This does not affect conversation history, documents, or Hal's learned self-knowledge.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Label("Settings Reset", systemImage: "arrow.counterclockwise")
        }
    }
    
    // MARK: - Cache Management Section
    
    // Allows clearing of Hugging Face model cache to free disk space
    // This doesn't affect conversations or documents, only downloaded model files
    
    private var cacheManagementSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Cache")
                        .font(.subheadline)
                    Text(mlxDownloader.hubCacheSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if mlxDownloader.isCacheCalculating {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button("Clear Hal's Models") {
                        showingClearCacheAlert = true
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }

            // Free up old model files — the gentle, targeted reclaim that mirrors
            // "Reset settings for <model>" up in Settings Reset (versus the full
            // "Clear Hal's Models" right above). Shown only when there's actually an
            // old copy on disk (freeable OR held by a sibling) or a cleanup just ran,
            // so a clean device never sees an empty row. The subtitle is honest: it
            // reads the same dry run the delete acts on, and the button disables itself
            // when every old copy is held by a sibling (nothing Hal alone can free),
            // leaving the row as an informational "in use by X" line rather than a
            // dead button. Safe: never touches a model in use, a sibling's copy, or
            // any conversation/memory. See MaintenanceTasks.freeOldModelFiles.
            if !oldModelsPlan.isEmpty || lastFreedOldBytes > 0 {
                Button {
                    lastFreedOldBytes = MaintenanceTasks.freeOldModelFiles()
                    oldModelsPlan = MaintenanceTasks.previewFreeOldModelFiles()
                    mlxDownloader.objectWillChange.send()
                    ModelCatalogService.shared.refreshDownloadStates()
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: "trash.slash")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free up old model files")
                            Text(freeOldModelsSubtitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
                .foregroundColor(.primary)
                // Disable when nothing is Hal's to free (all kept by siblings, or a
                // cleanup just finished): the row stays visible + honest, but not tappable.
                .disabled(oldModelsPlan.freeableBytes == 0)
            }

            // Clear all family models — the last-resort safety valve. Unlike "Clear
            // Hal's Models" (which only releases Hal's claims and leaves sibling-claimed
            // models on disk), this removes EVERY shared model for the whole family at
            // once and resets the manifest, reclaiming all model storage immediately.
            // Each app re-downloads what it needs on next use. Manifest-aware
            // (SharedModelStore.clearEntireSharedStore) so it never leaves ghost entries.
            Button {
                showingClearFamilyAlert = true
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear all family models")
                            .foregroundColor(.red)
                        Text("Removes every shared model for Hal, Posey, and AI Camera at once. Each app re-downloads as needed. Last resort.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        } header: {
            Label("Storage", systemImage: "externaldrive")
        } footer: {
            Text("Clear cached Hugging Face model files to free up space")
                .font(.caption2)
        }
    }
    
    // MARK: - Data Management Section
    
    // Database statistics and nuclear reset option
    // Nuclear reset deletes ALL conversations and documents (can't be undone)
    
    private var dataManagementSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Threads")
                        .font(.subheadline)
                    Text("\(chatViewModel.memoryStore.totalConversations)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Documents")
                        .font(.subheadline)
                    Text("\(chatViewModel.memoryStore.totalDocuments)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Button("Nuclear Reset (Delete All Data)") {
                showingNuclearResetConfirmationAlert = true
            }
            .foregroundColor(.red)
        } header: {
            Label("Database", systemImage: "externaldrive.badge.questionmark")
        } footer: {
            Text("Database statistics and data management options")
                .font(.caption2)
        }
    }
}

// ==== LEGO END: 63 MaintenanceView (Maintenance & Reset) ====
