// SettingsViews.swift
// Hal Universal
//
// The Settings + Actions UI surface — every View struct a user reaches
// by tapping the gear icon. Extracted from Hal.swift on 2026-05-26 as
// refactor #5 of the refactor-as-you-go sweep.
//
// Naming note: the LEGO 10.1 block was historically titled
// "MainSettingsView", but the actual entry-point struct in that block
// is `ActionsView`. The name dates back to v1.x when Hal's settings
// sheet was titled "Actions" in the UI; the struct kept the original
// name through subsequent UI reorganizations. Don't be confused by the
// LEGO title — `ActionsView` IS the top-level settings sheet that
// iOSChatView presents.
//
// The five LEGO blocks preserved below are this file's outline:
//
//   LEGO 10.1   — `PowerUserMode` enum + `ActionsView` (the user-facing
//                 entry sheet). Top-level rows: model picker, document
//                 import/export, memory tools, About, Developer API
//                 toggle, links into Power User and Salon Mode sheets.
//
//   LEGO 10.2   — `PowerUserView`. Single-LLM advanced configuration:
//                 temperature, memory depth, RAG budget, repetition
//                 controls, system-prompt framing, self-knowledge
//                 toggle. The settings here drive `ModelSettingsStore`'s
//                 per-model snapshot/apply flow on model switch.
//
//   LEGO 10.3   — `SystemPromptEditorView`. Multi-line editor with
//                 character counter and reset-to-default. Edits the
//                 user-authored Layer 2 of the effective system prompt
//                 (Layer 1 is the per-model framing on
//                 ModelConfiguration.layerOnePrompt).
//
//   LEGO 10.3.5 — `ModelFramingDetailView`. Read-only viewer for the
//                 current model's Layer 1 prompt + the toggle to
//                 enable/disable it on a per-model basis. Surfaces the
//                 §4 layered-prompt architecture so users can see what
//                 framing each model carries.
//
//   LEGO 10.4   — `SalonModeView`. Multi-LLM Salon configuration: up to
//                 four seats, per-seat model assignment, behavioral
//                 mode (Independent vs Context-Aware), moderator/
//                 summarizer seat, transcript options. Surfaces only
//                 when PowerUserMode == .multi.
//
// Why one file: all five are UI surfaces in the same conceptual area
// ("how the user configures Hal"). Each is a SwiftUI View struct with
// EnvironmentObject bindings to ChatViewModel, DocumentImportManager,
// MLXModelDownloader (and ModelCatalogService via @StateObject inside
// PowerUserView). They share helper sub-views and styling conventions
// that read more naturally side-by-side than scattered.
//
// External dependencies (all in the Hal Universal target):
//   - ChatViewModel              — primary @EnvironmentObject binding
//   - DocumentImportManager      — bound in ActionsView for import UI
//   - MLXModelDownloader.shared  — model download status rows
//   - ModelCatalogService.shared — model picker / library list
//   - ModelSettingsStore.shared  — apply/snapshot per-model settings
//   - halLog                     — global logging
//   - Various value types from Hal.swift (ChatViewModel state, etc.)
//
// Standing rules followed here:
//   - LEGO markers preserved verbatim from Hal.swift so the
//     numbering chain still reads end-to-end through Hal_Source.txt.
//   - Comments evergreen — what each view does and why it exists.

import Foundation
import SwiftUI
import Combine
import UniformTypeIdentifiers  // file picker UTType references

// ==== LEGO START: 10.1 MainSettingsView ====

// MARK: - Power User Mode Selection

// User can choose between Single LLM mode (traditional one-model operation with advanced
// memory/performance tuning) or Multi LLM mode (Salon Mode - multiple models participating
// in the same conversation with orchestration controls).
//
// CRITICAL: Selecting a mode ACTIVATES it immediately:
// - Select "Multi LLM (Salon)" -> salonConfig.isEnabled = true (Salon Mode active)
// - Select "Single LLM" -> salonConfig.isEnabled = false (Single mode active)
// The toggle both switches which settings you can access AND determines chat behavior.
enum PowerUserMode: String, CaseIterable {
    case single = "Single LLM"
    case multi = "Multi LLM (Salon)"
}

struct ActionsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var documentImportManager: DocumentImportManager
    @EnvironmentObject var mlxDownloader: MLXModelDownloader

    /// "Version 2.0 (6)" — formatted CFBundleShortVersionString + CFBundleVersion
    /// from Info.plist for the About row in Settings. Static so the row body
    /// doesn't recompute on every redraw. Reviewers and users can read this
    /// without digging into Apple's Settings → Hal.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    @Binding var showingDocumentPicker: Bool
    @State private var showingExportSheet = false
    @State private var showingPowerUserSheet = false
    @State private var showingSalonModeSheet = false
    @State private var powerUserMode: PowerUserMode = .single
    @State private var showingSystemPromptEditor = false
    @State private var showingModelFramingDetail = false
    @State private var showingSelfReflectionViewer = false
    @State private var initialSettingsSnapshot: [String: Any] = [:]
    @State private var skipComparisonOnDismiss = false

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
            Form {
                personalitySection
                    .id("personality")
                importExportSection
                    .id("importexport")
                modelSection
                    .id("ai")
                powerUserSection
                    .id("poweruser")

                // About — version + build at the bottom of Settings.
                // Plain footer rather than a Section{} so it doesn't get a
                // header chrome. Reviewers + users should be able to read
                // this without digging. Added 2026-05-19.
                Section {
                    HStack {
                        Text("Hal Universal")
                            .font(.subheadline)
                        Spacer()
                        Text(ActionsView.versionLine)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                } header: {
                    Label("About", systemImage: "info.circle")
                }
                .id("about")
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: chatViewModel.apiScrollSettingsTarget) { _, newTarget in
                guard !newTarget.isEmpty else { return }
                withAnimation { proxy.scrollTo(newTarget, anchor: .top) }
                // Clear so the same target can be re-driven later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    chatViewModel.apiScrollSettingsTarget = ""
                }
            }
            } // ScrollViewReader
        }
        .onAppear {
            // v1.x release: force Salon Mode off in the live ChatViewModel state
            // so any persisted `salonConfig.isEnabled = true` from prior builds
            // (where the toggle existed) doesn't route chat through the salon
            // path while the UI is hidden. Initialize the local picker state
            // from the (now-forced-off) salon config.
            if !Self.salonModeExposedInUI && chatViewModel.salonConfig.isEnabled {
                var config = chatViewModel.salonConfig
                config.isEnabled = false
                chatViewModel.salonConfig = config
                print("HALDEBUG-SALON: v1.x — forcing salonConfig.isEnabled = false on settings appear")
            }
            powerUserMode = chatViewModel.salonConfig.isEnabled ? .multi : .single
        }
        .sheet(isPresented: $showingExportSheet) {
            ShareSheet(activityItems: [chatViewModel.exportChatHistory()])
        }
        .sheet(isPresented: $showingPowerUserSheet) {
            PowerUserView()
                .environmentObject(chatViewModel)
                .environmentObject(mlxDownloader)
        }
        .sheet(isPresented: $showingSalonModeSheet) {
            SalonModeView()
                .environmentObject(chatViewModel)
                .environmentObject(mlxDownloader)
        }
        .sheet(isPresented: $showingSystemPromptEditor) {
            SystemPromptEditorView()
                .environmentObject(chatViewModel)
        }
        .sheet(isPresented: $showingModelFramingDetail) {
            ModelFramingDetailView()
                .environmentObject(chatViewModel)
        }
        .onAppear {
            chatViewModel.isInSettingsFlow = true
            initialSettingsSnapshot = [
                "memoryDepth": chatViewModel.memoryDepth,
                "temperature": chatViewModel.temperature,
                "enableSelfKnowledge": chatViewModel.enableSelfKnowledge,
                "recencyWeight": chatViewModel.memoryStore.recencyWeight,
                "recencyHalfLifeDays": chatViewModel.memoryStore.recencyHalfLifeDays,
                "maxRagSnippetsCharacters": chatViewModel.maxRagSnippetsCharacters,
                "selectedModelID": chatViewModel.selectedModelID
            ]
            chatViewModel.pendingSettingsChanges.removeAll()
            print("HALDEBUG-SETTINGS: Captured initial snapshot")
        }
        .onDisappear {
            chatViewModel.isInSettingsFlow = false

            // Bug 1 fix: capture the user's per-model setting edits the moment
            // the settings sheet closes, so a change made here (with no model
            // switch afterward) survives an app restart. Covers every slider in
            // one place; idempotent — records only deltas from curated defaults.
            ModelSettingsStore.shared.persistCurrentOverrides(for: chatViewModel.selectedModel)

            guard !skipComparisonOnDismiss else {
                skipComparisonOnDismiss = false
                return
            }
            
            if let initMemoryDepth = initialSettingsSnapshot["memoryDepth"] as? Int,
               initMemoryDepth != chatViewModel.memoryDepth {
                let userMsg = "Hal, I changed your memory depth from \(initMemoryDepth) to \(chatViewModel.memoryDepth) turns."
                let halMsg = "Perfect! I'll now keep \(chatViewModel.memoryDepth) recent turns verbatim instead of \(initMemoryDepth) before summarizing."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initTemp = initialSettingsSnapshot["temperature"] as? Double,
               abs(initTemp - chatViewModel.temperature) > 0.01 {
                let newValue = chatViewModel.temperature
                let userMsg = "Hal, I adjusted your temperature from \(String(format: "%.2f", initTemp)) to \(String(format: "%.2f", newValue))."
                let direction = newValue > initTemp ? "more creative" : "more focused"
                let halMsg = "Temperature set to \(String(format: "%.2f", newValue))! I'll be \(direction) in my responses now."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initSelfKnowledge = initialSettingsSnapshot["enableSelfKnowledge"] as? Bool,
               initSelfKnowledge != chatViewModel.enableSelfKnowledge {
                let userMsg = "Hal, I \(chatViewModel.enableSelfKnowledge ? "enabled" : "disabled") your self-knowledge context."
                let halMsg = chatViewModel.enableSelfKnowledge ?
                    "Self-knowledge enabled! I'll now include my persistent identity (core values, learned preferences, conversation history, and temporal awareness) in my responses." :
                    "Self-knowledge disabled. I'll use a simpler prompt without persistent identity context."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initRecency = initialSettingsSnapshot["recencyWeight"] as? Double,
               abs(initRecency - chatViewModel.memoryStore.recencyWeight) > 0.01 {
                let newValue = chatViewModel.memoryStore.recencyWeight
                let userMsg = "Hal, I changed your recency weight from \(Int(initRecency * 100))% to \(Int(newValue * 100))%."
                let halMsg = "Adjusted! I'm now balancing \(Int((1.0 - newValue) * 100))% relevance with \(Int(newValue * 100))% freshness when searching memories."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initHalfLife = initialSettingsSnapshot["recencyHalfLifeDays"] as? Double,
               abs(initHalfLife - chatViewModel.memoryStore.recencyHalfLifeDays) > 1.0 {
                let newValue = chatViewModel.memoryStore.recencyHalfLifeDays
                let userMsg = "Hal, I changed your memory half-life from \(Int(initHalfLife)) to \(Int(newValue)) days."
                let direction = newValue < initHalfLife ? "shorter" : "longer"
                let halMsg = "Updated! With a \(direction) half-life of \(Int(newValue)) days, \(newValue < initHalfLife ? "recent memories will be prioritized more" : "older memories will retain their importance longer")."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initRag = initialSettingsSnapshot["maxRagSnippetsCharacters"] as? Double,
               abs(initRag - chatViewModel.maxRagSnippetsCharacters) > 1.0 {
                let userMsg = "Hal, I changed your max RAG retrieval from \(Int(initRag)) to \(Int(chatViewModel.maxRagSnippetsCharacters)) characters."
                let halMsg = "Adjusted! I can now pull up to \(Int(chatViewModel.maxRagSnippetsCharacters)) characters of context from my long-term memory."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            print("HALDEBUG-SETTINGS: Generated \(chatViewModel.pendingSettingsChanges.count) change messages")
            
            // Process all pending changes using centralized function (handles turnNumber correctly)
            chatViewModel.processAllSettingsChanges()
        }
    }
    
    // MARK: - Personality Section
    
    // SELF-AWARENESS NOTE (for Hal reading this code):
    // This is where users control how I think and respond. It's called "Personality" because
    // these settings define my behavior patterns more than my performance.
    //
    // - System Prompt: My core identity and instructions (who I am, how I act)
    // - Self-Knowledge: Whether I include persistent identity context (core values, learned
    //   preferences, conversation history stats, and temporal awareness) in my responses
    // - Temperature: Controls randomness in my responses (0.0 = deterministic, 1.0 = creative)
    //
    // These settings are front-and-center because they're what users adjust most frequently when
    // experimenting with different tasks (creative writing vs technical analysis) or different models.
    
    /// True while the user has Salon Mode enabled. Per-model controls
    /// (Model Framing, Temperature, RAG settings, memory depth, etc.)
    /// are visible but disabled in this state — the active "model" is
    /// a multi-seat ensemble, not a single configuration. Global toggles
    /// (Self-Knowledge, the universal System Prompt) stay editable
    /// because they apply regardless of how many voices are speaking.
    /// (Mark's May-15 directive.)
    private var isSalonActive: Bool {
        chatViewModel.salonConfig.isEnabled
    }

    private var personalitySection: some View {
        Section {
            // Salon-mode banner used to live at the top of this
            // Personality section. Moved to the Power User Mode section
            // (below the picker) per BUG 4 v2 fix (2026-05-19): the
            // earlier opacity-reservation fix kept the Personality
            // section's height stable but left visible empty space when
            // salon was inactive. The right semantic home for this
            // banner is next to the picker the user just toggled —
            // see modelSection.

            // Per Strategic §4: per-model Layer 1 framing.
            //
            // May-15 refactor — the inline display was replaced with a
            // System-Prompt-style navigation row that opens a detail
            // sheet (see ModelFramingDetailView). Same data, same
            // semantics — visible-but-not-editable text, user-toggleable
            // apply switch, model-specific.
            //
            // May-16 fix — the row is now ALWAYS shown, including for
            // models like Gemma and Llama whose layerOnePrompt is
            // intentionally empty (they follow the universal Layer 2
            // without needing per-model framing). Previously the row was
            // gated on `!layerOne.isEmpty`, which made it invisible for
            // those models — Mark couldn't find it on Gemma. The detail
            // sheet explains the empty case inline ("No model-specific
            // framing for X — this model follows only the universal
            // System Prompt"). Discoverability > short-term cleanliness.
            Button {
                showingModelFramingDetail = true
            } label: {
                HStack {
                    Text("Model framing")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            .disabled(isSalonActive)
            .opacity(isSalonActive ? 0.45 : 1.0)

            Button {
                showingSystemPromptEditor = true
            } label: {
                HStack {
                    Text("System Prompt")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            // BUG 4 v2 follow-up (2026-05-19): System Prompt is one of
            // the per-model settings the salon banner says are locked.
            // Was visually un-dimmed in salon mode, which contradicted
            // the banner. Now matches Model framing + Temperature.
            .disabled(isSalonActive)
            .opacity(isSalonActive ? 0.45 : 1.0)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Self-Knowledge", isOn: Binding(
                    get: { chatViewModel.enableSelfKnowledge },
                    set: { chatViewModel.enableSelfKnowledge = $0 }
                ))
                .font(.subheadline)
                .fontWeight(.medium)
                
                Text("Include Hal's persistent self-knowledge (core values, learned preferences, identity patterns, conversation history stats, and temporal awareness) in prompts. Adds ~500-700 tokens to each prompt. Disable if experiencing context window issues with smaller models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Button to view Hal's shareable reflections and self-knowledge
                if chatViewModel.enableSelfKnowledge {
                    Button(action: {
                        showingSelfReflectionViewer = true
                    }) {
                        HStack {
                            Image(systemName: "book.pages")
                                .foregroundColor(.blue)
                            Text("Hal's Self Model")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 6)
                    }
                    .sheet(isPresented: $showingSelfReflectionViewer) {
                        SelfReflectionView()
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Temperature")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    // Modified-from-model-default indicator (Layer 3).
                    if abs(chatViewModel.temperature - (chatViewModel.selectedModel.defaultSettings?.temperature ?? 0.7)) > 0.001 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Modified from model default")
                    }
                    Spacer()
                    Text(String(format: "%.2f", chatViewModel.temperature))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $chatViewModel.temperature, in: 0.0...1.0, step: 0.05)

                Text("Higher = more creative, Lower = more focused")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .disabled(isSalonActive)
            .opacity(isSalonActive ? 0.45 : 1.0)
        } header: {
            Label("Personality", systemImage: "theatermasks")
        } footer: {
            Text("Control how Hal thinks and responds")
                .font(.caption2)
        }
    }
    
    // MARK: - Import/Export Section
    
    private var importExportSection: some View {
        Section {
            Button("Upload Document to Memory") {
                dismiss()
                showingDocumentPicker = true
            }
            .foregroundColor(.primary)

            Button("Export Thread") {
                showingExportSheet = true
            }
            .foregroundColor(.primary)
        } header: {
            Label("Import/Export", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Model Section
    
    private var modelSection: some View {
        Section {
            // Salon-aware active summary (May-14, Strategic Claude directive):
            //   - Single-model: "Active Model • [Name]" with unified status dot
            //   - Salon Mode: "Salon Mode • N voices" with a person.2 indicator
            // The Browse Model Library link below is unchanged in either mode.
            //
            // BUG 4 fix (2026-05-19): pinned the outer HStack to a fixed
            // minHeight so toggling Multi LLM <-> Single LLM via the picker
            // below doesn't cause this row to change intrinsic height. The
            // two variants (person.2.fill icon vs. modelStatusDot Circle)
            // render at slightly different heights, which propagated through
            // Form re-layout as a visible scroll/flash jump above the
            // picker. Verified on iPhone 17 Pro sim before/after.
            HStack(alignment: .top) {
                if chatViewModel.salonConfig.isEnabled {
                    Text("Salon Mode")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.accentColor)
                            .imageScale(.small)
                            .padding(.top, 2)
                        // Show all active seat names ("Gemma · Llama · Qwen
                        // · Dolphin"). Bug-fix 2026-05-19: previously
                        // .lineLimit(1) truncated the summary at the first
                        // model name on narrower widths, so a 2+ seat
                        // configuration looked like only seat 1 was
                        // running. Allow up to 3 lines and right-align so
                        // long names wrap cleanly instead of disappearing.
                        Text(chatViewModel.salonSeatSummary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Active Model")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    HStack(spacing: 6) {
                        modelStatusDot(
                            for: chatViewModel.selectedModel,
                            downloader: mlxDownloader,
                            activeModelID: chatViewModel.selectedModelID
                        )
                        Text(chatViewModel.selectedModel.displayName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minHeight: 28)

            NavigationLink(destination: ModelLibraryView()
                .environmentObject(chatViewModel)
                .environmentObject(mlxDownloader)) {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text("Browse Model Library")
                    Spacer()
                }
            }
            .foregroundColor(.primary)
        } header: {
            Label("AI Model", systemImage: "cpu")
        } footer: {
            Text("Select from Apple Foundation Models or download MLX models from Hugging Face")
                .font(.caption2)
        }
    }

    // MARK: - Power User Section
    
    // SELF-AWARENESS NOTE (for Hal reading this code):
    // This section lets users choose between two very different modes of operation:
    // - Single LLM: Traditional mode where one model (like me) handles all responses.
    //   Settings focus on memory tuning, RAG limits, and performance optimization.
    // - Multi LLM (Salon): Experimental mode where multiple models participate in the
    //   same conversation simultaneously. Settings control which models participate,
    //   speaking order, how models see each other's responses, and behavioral constraints.
    //
    // CRITICAL BEHAVIOR: The toggle ACTIVATES the selected mode immediately.
    // When user selects "Multi LLM (Salon)", salonConfig.isEnabled becomes true and
    // Salon Mode is active for all subsequent conversations. When they select "Single LLM",
    // salonConfig.isEnabled becomes false and we return to single-model operation.
    // One control does everything: activation + settings access + chat behavior.
    
    private var powerUserSection: some View {
        // v1.x release: Salon Mode is hidden from the UI. The mode toggle
        // and the Salon Mode settings sheet entry are gated on Self.salonModeExposedInUI.
        // The underlying Salon Mode code (SalonModeView, salonConfig, runSalonTurn,
        // etc.) remains intact per the standing "broken-but-precious" instruction —
        // flipping the flag back to true restores full Salon Mode access for
        // future releases. We also force salonConfig.isEnabled = false on appear
        // (see .onAppear below) to guarantee chat behaviour is single-model
        // regardless of any stale state from prior installs.
        Section {
            if Self.salonModeExposedInUI {
                // Mode toggle (hidden in v1.x)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Power User Mode")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker("", selection: Binding<PowerUserMode>(
                        get: {
                            // Bug-fix 2026-05-19: read directly from
                            // salonConfig so API-driven salon toggles
                            // are reflected in the picker even when
                            // Settings is already open. Local @State
                            // was only synced in onAppear, which left
                            // the picker showing stale "Multi" after
                            // `SALON_SET_ENABLED:false` via the API.
                            chatViewModel.salonConfig.isEnabled ? .multi : .single
                        },
                        set: { newMode in
                            powerUserMode = newMode
                            // Route through `setSalonEnabled` so the
                            // invariant is preserved. When the user switches
                            // to Multi LLM (Salon) with 0 seats, Seat 1 is
                            // auto-populated with Apple Intelligence rather
                            // than leaving the user in a state where chat
                            // would silently no-op.
                            let result = chatViewModel.setSalonEnabled(newMode == .multi)
                            print("HALDEBUG-SALON: Mode changed to \(newMode.rawValue), isEnabled = \(result.isEnabled), autoPopulated = \(result.autoPopulatedSeat1WithID ?? "nil")")
                        }
                    )) {
                        ForEach(PowerUserMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    // BUG 4 fix (2026-05-19): pinned this caption to a
                    // fixed frame (full width + line limit) so toggling
                    // single <-> multi doesn't change how the text wraps,
                    // which would push everything below up/down.
                    Text(chatViewModel.salonConfig.isEnabled ?
                         "Configure multiple models for collaborative conversations" :
                         "Advanced settings for single model operation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // BUG 4 v2 fix (2026-05-19): salon-mode banner moved
                    // here from the top of the Personality section. The
                    // earlier opacity-reservation fix left visible empty
                    // space when salon was inactive. Putting the banner
                    // adjacent to the picker the user just toggled is
                    // both better UX (action and explanation co-located)
                    // and structurally safe — adding/removing rows from
                    // THIS section doesn't shift the picker itself,
                    // since the picker is above the banner in the same
                    // section.
                    if isSalonActive {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "person.3.fill")
                                .foregroundColor(.orange)
                                .imageScale(.small)
                            Text("Individual model settings (Personality section) are locked while Salon Mode is active. Exit Salon Mode to adjust.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            // Settings button — in v1.x, always opens Single LLM Settings.
            Button {
                if Self.salonModeExposedInUI && chatViewModel.salonConfig.isEnabled {
                    showingSalonModeSheet = true
                } else {
                    showingPowerUserSheet = true
                }
            } label: {
                HStack {
                    Image(systemName: (Self.salonModeExposedInUI && chatViewModel.salonConfig.isEnabled) ? "person.3" : "wrench.and.screwdriver")
                    Text((Self.salonModeExposedInUI && chatViewModel.salonConfig.isEnabled) ? "Salon Mode Settings" : "Single LLM Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
        } footer: {
            Text(Self.salonModeExposedInUI && chatViewModel.salonConfig.isEnabled ?
                 "Configure multi-model conversation orchestration" :
                 "Advanced memory settings and data management")
                .font(.caption2)
        }
    }

    // MARK: - v1.x Feature Flags
    //
    // Salon Mode is alive again (May 12, 2026). The seat-switch path now
    // actually calls setupLLM (previously it only set selectedModelID, so
    // every seat used whatever model was loaded last). The MLX wrapper
    // also supports keepMlxResident so a Gemma seat stays warm across an
    // AFM seat without paying a fresh load on every salon turn.
    // selectedModelID is saved and restored around the multi-seat turn so
    // the user's chosen model isn't silently overwritten.
    //
    // Keep this constant in sync with `v1xSalonExposed` in
    // ChatViewModel.init — both control the same exposure decision. Flip
    // both back to false to hide Salon again.
    private static let salonModeExposedInUI: Bool = true
    
}


// ==== LEGO END: 10.1 MainSettingsView ====



// ==== LEGO START: 10.2 PowerUserView ====

// SELF-AWARENESS NOTE (for Hal reading this code):
// This is Power User mode for Single LLM operation. Users come here to fine-tune performance:
// - Memory settings (how much I remember, how I search, how I prioritize)
// - Storage management (clearing caches to free space)
// - Database operations (stats and nuclear reset)
//
// Note: The "Personality" settings (system prompt, temperature, etc.) used to be here but
// were moved to the main Settings screen because users adjust them more frequently.
// This panel is now focused purely on memory/performance tuning and data management.
//
// FUTURE: When Salon Mode is implemented, there will be a toggle here to switch between
// "Single LLM" settings (what you see now) and "Multi LLM (Salon)" orchestration settings.

struct PowerUserView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var mlxDownloader: MLXModelDownloader

    @State private var showingNuclearResetConfirmationAlert = false
    @State private var showingClearCacheAlert = false
    @State private var showResetSettingsAlert = false
    @State private var sliderStartValues: [String: Double] = [:]

    /// Per Mark's May-15 directive — per-model controls (memory depth,
    /// RAG thresholds, etc.) are visible but disabled while Salon Mode
    /// is active, because the "active model" is then an ensemble rather
    /// than a single configuration. Global controls (self-knowledge
    /// half-life, identity floor) stay editable.
    private var isSalonActive: Bool {
        chatViewModel.salonConfig.isEnabled
    }
    
    var body: some View {
        NavigationView {
            Form {
                memorySection
                settingsResetSection
                cacheManagementSection
                dataManagementSection
                developerAPISection
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    testConsoleSection
                }
            }
            .navigationTitle("Power User")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
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
        .alert("Clear Cache", isPresented: $showingClearCacheAlert) {
            Button("Clear Cache", role: .destructive) {
                mlxDownloader.clearHubCache()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete all cached model files (\(mlxDownloader.hubCacheSize)). Downloaded models will need to be re-downloaded.")
        }
    }
    
    // MARK: - Memory Section
    
    // Controls for short-term and long-term memory behavior
    // Short-term: How many recent turns to keep verbatim
    // Long-term: RAG search parameters (similarity, recency weighting, retrieval limits)
    
    private var memorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                if isSalonActive {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "person.3.fill")
                            .foregroundColor(.orange)
                            .imageScale(.small)
                        Text("Per-model memory settings are locked during Salon conversations. Exit Salon Mode to adjust.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Group {
                SectionHeaderText(text: "SHORT-TERM MEMORY")

                LabeledSliderControl(
                    label: "Memory Depth",
                    value: Binding(
                        // Display the runtime-effective depth (stored
                        // memoryDepth clamped to the current model's max)
                        // so the displayed number always agrees with the
                        // slider thumb position. If stored exceeds max
                        // (e.g. a switch path missed a clamp), the
                        // .onAppear writeback below realigns storage to
                        // the displayed value. Memory Depth display
                        // mismatch fix, 2026-05-18.
                        get: { Double(chatViewModel.effectiveMemoryDepth) },
                        set: { chatViewModel.memoryDepth = Int($0) }
                    ),
                    range: 1...Double(chatViewModel.maxMemoryDepth),
                    step: 1,
                    valueFormatter: { "\(Int($0)) turns" },
                    minLabel: "1",
                    maxLabel: "\(chatViewModel.maxMemoryDepth)",
                    helperText: "Model limit: \(chatViewModel.maxMemoryDepth) turns (\(chatViewModel.selectedModel.displayName))",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["memoryDepth"] = Double(chatViewModel.memoryDepth)
                        } else {
                            sliderStartValues.removeValue(forKey: "memoryDepth")
                        }
                    },
                    isModified: chatViewModel.memoryDepth != (chatViewModel.selectedModel.defaultSettings?.effectiveMemoryDepth ?? 5)
                )
                
                Divider()
                
                SectionHeaderText(text: "LONG-TERM MEMORY")
                
                LabeledSliderControl(
                    label: "Recency Weight",
                    value: $chatViewModel.memoryStore.recencyWeight,
                    range: 0.0...1.0,
                    step: 0.05,
                    valueFormatter: { "\(Int($0 * 100))%" },
                    minLabel: "0%",
                    maxLabel: "100%",
                    helperText: "Balance between relevance (left) and freshness (right)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["recency"] = chatViewModel.memoryStore.recencyWeight
                        } else {
                            sliderStartValues.removeValue(forKey: "recency")
                        }
                    },
                    isModified: abs(chatViewModel.memoryStore.recencyWeight - (chatViewModel.selectedModel.defaultSettings?.recencyWeight ?? 0.3)) > 0.001
                )
                
                LabeledSliderControl(
                    label: "Memory Half-Life",
                    value: $chatViewModel.memoryStore.recencyHalfLifeDays,
                    range: 30...360,
                    step: 30,
                    valueFormatter: { "\(Int($0)) days" },
                    minLabel: "30",
                    maxLabel: "360",
                    helperText: "How quickly older memories lose priority (shorter = favor recent, longer = retain old)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["halflife"] = chatViewModel.memoryStore.recencyHalfLifeDays
                        } else {
                            sliderStartValues.removeValue(forKey: "halflife")
                        }
                    },
                    isModified: abs(chatViewModel.memoryStore.recencyHalfLifeDays - (chatViewModel.selectedModel.defaultSettings?.recencyHalfLifeDays ?? 90.0)) > 0.5
                )
                
                LabeledStepperControl(
                    label: "Max RAG Retrieval",
                    value: Binding(
                        get: { Double(chatViewModel.maxRagSnippetsCharacters) },
                        set: { newValue in
                            let maxLimit = chatViewModel.maxRAGCharsForModel
                            chatViewModel.maxRagSnippetsCharacters = min(newValue, Double(maxLimit))
                        }
                    ),
                    range: 200...Double(chatViewModel.maxRAGCharsForModel),
                    step: 100,
                    valueFormatter: { "\(Int($0)) chars" },
                    helperText: "Model limit: \(chatViewModel.maxRAGCharsForModel) chars (\(chatViewModel.selectedModel.displayName))",
                    isModified: Int(chatViewModel.maxRagSnippetsCharacters) != (chatViewModel.selectedModel.defaultSettings?.maxRagSnippetsCharacters ?? 800)
                )
                }  // end per-model Group
                .disabled(isSalonActive)
                .opacity(isSalonActive ? 0.45 : 1.0)

                Divider()

                SectionHeaderText(text: "SELF-KNOWLEDGE")
                
                LabeledSliderControl(
                    label: "Identity Half-Life",
                    value: $chatViewModel.memoryStore.selfKnowledgeHalfLifeDays,
                    range: 180...730,
                    step: 30,
                    valueFormatter: { "\(Int($0)) days" },
                    minLabel: "180",
                    maxLabel: "730",
                    helperText: "How long learned patterns persist (longer = more stable identity)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["selfHalfLife"] = chatViewModel.memoryStore.selfKnowledgeHalfLifeDays
                        } else {
                            sliderStartValues.removeValue(forKey: "selfHalfLife")
                        }
                    }
                )
                
                LabeledSliderControl(
                    label: "Identity Floor",
                    value: $chatViewModel.memoryStore.selfKnowledgeFloor,
                    range: 0.2...0.5,
                    step: 0.05,
                    valueFormatter: { String(format: "%.2f", $0) },
                    minLabel: "0.2",
                    maxLabel: "0.5",
                    helperText: "Minimum confidence before patterns are retired (higher = more persistent traits)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["selfFloor"] = chatViewModel.memoryStore.selfKnowledgeFloor
                        } else {
                            sliderStartValues.removeValue(forKey: "selfFloor")
                        }
                    }
                )
            }
        } header: {
            Label("Memory", systemImage: "brain.head.profile")
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

                Text("Restore every tunable parameter — across every model — to factory defaults. This does not affect conversation history, documents, or Hal's learned self-knowledge.")
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
                    Button("Clear Cache") {
                        showingClearCacheAlert = true
                    }
                    .font(.caption)
                    .foregroundColor(.red)
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

    // MARK: - Developer API Section

    private var developerAPISection: some View {
        DeveloperAPISectionView(viewModel: chatViewModel)
    }

    struct DeveloperAPISectionView: View {
        @ObservedObject var viewModel: ChatViewModel
        @State private var copiedField: String? = nil

        var body: some View {
            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.localAPIEnabled },
                    set: { enabled in
                        if enabled { viewModel.startLocalAPI() }
                        else       { viewModel.stopLocalAPI()  }
                    }
                )) {
                    Label("Local API Access", systemImage: "network")
                }
                if viewModel.localAPIEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        copyableRow(label: "Address",
                                    value: viewModel.localAPIServer.connectionURL,
                                    field: "address",
                                    font: .caption)
                        copyableRow(label: "Port",
                                    value: "\(LocalAPIServer.apiPort)",
                                    field: "port",
                                    font: .caption)
                        copyableRow(label: "Token",
                                    value: viewModel.localAPIServer.apiToken,
                                    field: "token",
                                    font: .system(.caption2, design: .monospaced))
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Developer API", systemImage: "terminal")
            } footer: {
                Text(viewModel.localAPIEnabled
                    ? "Tap any field to copy. Setup: python3 tests/hal_test.py setup 127.0.0.1 \(LocalAPIServer.apiPort) <token>"
                    : "Enables a local HTTP API for automated testing. Off by default.")
                    .font(.caption2)
            }
        }

        @ViewBuilder
        private func copyableRow(label: String, value: String, field: String, font: Font) -> some View {
            HStack(alignment: .top) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text(copiedField == field ? "Copied!" : value)
                        .font(font)
                        .foregroundColor(copiedField == field ? .green : .primary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(copiedField == field ? .green : .secondary)
                }
                .onTapGesture {
                    UIPasteboard.general.string = value
                    withAnimation { copiedField = field }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { if copiedField == field { copiedField = nil } }
                    }
                }
            }
        }
    }

    // MARK: - Test Console Section (shown when running as iOS app on Mac)

    private var testConsoleSection: some View {
        TestConsoleSectionView(console: chatViewModel.testConsole)
    }

    // Separate view so @ObservedObject re-renders independently from PowerUserView
    struct TestConsoleSectionView: View {
        @ObservedObject var console: HalTestConsole

        var body: some View {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.subheadline)
                        Text(console.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(console.isRunning ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                }

                if console.turnCount > 0 {
                    HStack {
                        Text("Turns processed")
                            .font(.subheadline)
                        Spacer()
                        Text("\(console.turnCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if console.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(console.inputFile.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Text("Output file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(console.outputLatestFile.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Button(console.isRunning ? "Stop Test Console" : "Start Test Console") {
                    if console.isRunning {
                        console.stop()
                    } else {
                        console.start()
                    }
                }
                .foregroundColor(console.isRunning ? .red : .accentColor)
            } header: {
                Label("Pipeline Test Console", systemImage: "terminal")
            } footer: {
                Text("Write messages to input.txt — Hal responds via the real pipeline. Full prompt, memory, and token diagnostics written to output_latest.json.")
                    .font(.caption2)
            }
        }
    }
}


// ==== LEGO END: 10.2 PowerUserView ====



// ==== LEGO START: 10.3 SystemPromptEditorView ====


struct SystemPromptEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var editedPrompt: String = ""
    @State private var showingResetAlert = false

    // Hard cap on system prompt size, enforced UI-side per Mark + SC directive
    // (Context Budget Implementation Plan §6a). The cap is global across all
    // models — it reflects how much a user can reasonably type into a system
    // prompt editor, not model capacity. AFM 4K has the tightest budget; the
    // 1000-token cap fits comfortably even within AFM's prompt allocation.
    private var cap: Int { HalModelLimits.systemPromptHardCap }

    // Live token count of the current edit buffer.
    private var currentTokens: Int {
        TokenEstimator.estimateTokens(from: editedPrompt)
    }

    // Three-state UI as approved by SC (refinement #1):
    //   < 80%  : neutral counter, secondary color
    //   80-99% : amber counter, "approaching limit"
    //   ≥ 100% : red counter, "limit reached", input editor stops accepting growth
    private enum CounterState { case neutral, approaching, atLimit }

    private var counterState: CounterState {
        let percentage = Double(currentTokens) / Double(cap)
        if percentage >= 1.0 { return .atLimit }
        if percentage >= 0.80 { return .approaching }
        return .neutral
    }

    private var counterLabel: String {
        switch counterState {
        case .neutral:     return "\(currentTokens) / \(cap) tokens"
        case .approaching: return "\(currentTokens) / \(cap) tokens — approaching limit"
        case .atLimit:     return "\(currentTokens) / \(cap) tokens — limit reached"
        }
    }

    private var counterColor: Color {
        switch counterState {
        case .neutral:     return .secondary
        case .approaching: return .orange
        case .atLimit:     return .red
        }
    }

    // Binding wrapper that enforces the cap. Per SC's directive: "Do not allow
    // input beyond the limit and tell the user it will be ignored. That's hidden
    // behavior and it's wrong for Hal. The field stops accepting input at the cap."
    //
    // Logic:
    //   - Deletion (newValue is shorter than current): always accept, regardless
    //     of cap. This is the only way out for a legacy prompt that exceeds the
    //     cap on first open — the user can shrink it down.
    //   - Growth or same-length replacement: accept only if the resulting token
    //     count stays at or below the cap. Otherwise, silently reject (no
    //     change to the binding source — the typed character / pasted block
    //     just doesn't land).
    private var cappedPromptBinding: Binding<String> {
        Binding(
            get: { editedPrompt },
            set: { newValue in
                // Allow any deletion regardless of cap (escape hatch for legacy
                // prompts and normal editing flow).
                if newValue.count < editedPrompt.count {
                    editedPrompt = newValue
                    return
                }
                // For growth or replacement, enforce the cap on the resulting tokens.
                let newTokens = TokenEstimator.estimateTokens(from: newValue)
                if newTokens <= cap {
                    editedPrompt = newValue
                }
                // else: silently drop the input. The field stops accepting growth.
            }
        )
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: cappedPromptBinding)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)

                // Token counter (three-state) — always visible, lives below the
                // editor so it's never obscured by the keyboard.
                Text(counterLabel)
                    .font(.caption)
                    .foregroundColor(counterColor)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        chatViewModel.systemPrompt = editedPrompt
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    // Disable save if a legacy prompt is over cap. The user
                    // can still Cancel without saving. Once they delete enough
                    // to be under the cap, Save re-enables.
                    .disabled(currentTokens > cap)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingResetAlert = true
                    } label: {
                        Label("Restore Factory Settings", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .alert("Restore Factory Settings?", isPresented: $showingResetAlert) {
                Button("Restore", role: .destructive) {
                    editedPrompt = ChatViewModel.defaultSystemPrompt
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will restore the factory default system prompt. Your current customizations will be lost.")
            }
        }
        .onAppear {
            editedPrompt = chatViewModel.systemPrompt
        }
    }
}


// ==== LEGO END: 10.3 SystemPromptEditorView ====


// ==== LEGO START: 10.3.5 ModelFramingDetailView ====
//
// Per-model "Layer 1" framing prompt detail screen. Replaces the earlier
// inline display (toggle + greyed-text block) that lived directly in the
// personality section, with a System-Prompt-style row that navigates to
// this detail view.
//
// What it shows:
//   - The active model's display name in the title bar
//   - The Layer 1 prompt text (read-only, monospaced for clarity that
//     it's prompt content, NOT user-editable as Mark directed)
//   - The "Apply this framing" toggle
//   - Explanation of what Layer 1 is and why it exists
//
// What it does NOT do:
//   - Allow editing the prompt text. Mark's directive: "Text visible
//     but not editable." Layer 1 is CC-authored to compensate for
//     specific per-model tendencies; user edits would defeat the
//     calibration. The toggle is the user's lever.
//
// When the active model has no Layer 1 prompt (empty string), the
// settings page doesn't surface this row at all. The detail view
// therefore can safely assume non-empty text in its body.
struct ModelFramingDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel

    private var layerOneText: String {
        chatViewModel.selectedModel.layerOnePrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var framingEnabled: Binding<Bool> {
        Binding(
            get: {
                ModelSettingsStore.shared
                    .effectiveSettings(for: chatViewModel.selectedModel)
                    .layerOnePromptEnabled ?? true
            },
            set: { newValue in
                ModelSettingsStore.shared.setLayerOnePromptEnabled(
                    newValue,
                    for: chatViewModel.selectedModelID
                )
                chatViewModel.objectWillChange.send()
            }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Apply this framing", isOn: framingEnabled)
                        .disabled(layerOneText.isEmpty)
                } footer: {
                    if layerOneText.isEmpty {
                        Text("\(chatViewModel.selectedModel.displayName) has no model-specific framing. It runs only against the universal System Prompt. The toggle has no effect for this model.")
                            .font(.caption2)
                    } else {
                        Text("When enabled, the framing below is prepended to Hal's system prompt for \(chatViewModel.selectedModel.displayName) only. Disable to use only the universal System Prompt.")
                            .font(.caption2)
                    }
                }

                Section {
                    if layerOneText.isEmpty {
                        Text("(No model-specific framing for \(chatViewModel.selectedModel.displayName) — this model follows the universal Maxim guidance well enough that no per-model correction was needed.)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        Text(layerOneText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text("Framing text")
                } footer: {
                    Text("Per-model framing that Hal applies to compensate for this model's specific tendencies. CC-authored from on-device testing and informed by the Maxim sweep. Visible to you but not editable — user edits would defeat the calibration.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Model Framing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// ==== LEGO END: 10.3.5 ModelFramingDetailView ====



// ==== LEGO START: 10.4 SalonModeView (Multi-LLM Configuration) ====

struct SalonModeView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss

    // Seats 3 and 4 — gate verified open per Strategic §6/§13 (May 13, 2026).
    // The smart MLX→MLX swap in MLXWrapper.setupLLM (unload + GPU.clearCache +
    // 500ms reclaim sleep) keeps peak memory at one MLX model at a time
    // regardless of seat count. The schema migration v2 (§9) ensures every
    // seat's storage write has its own UNIQUE row even when multiple seats
    // share a (turn, position) tuple. Both fixes together unblock 3- and
    // 4-seat salons; verified on iPhone 16 Plus on the May-13 build by
    // running multi-seat turns and confirming no OOM crashes + no row loss.
    static let exposeSeatsThreeAndFour: Bool = true

    var body: some View {
        NavigationView {
            Form {
                // Section 1: Active Seats
                Section {
                    // Seat pickers route through `setSalonSeat` so clearing
                    // the last active seat while Salon is enabled auto-
                    // disables Salon (preserving the state-machine invariant
                    // that Salon enabled ⇒ at least one seat configured).

                    // Seat 1
                    Picker("Seat 1 (First)", selection: Binding(
                        get: { chatViewModel.salonConfig.seat1 },
                        set: { newID in chatViewModel.setSalonSeat(position: 1, modelID: newID) }
                    )) {
                        Text("Empty").tag(nil as String?)
                        ForEach(chatViewModel.usableModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }

                    // Seat 2
                    Picker("Seat 2 (Second)", selection: Binding(
                        get: { chatViewModel.salonConfig.seat2 },
                        set: { newID in chatViewModel.setSalonSeat(position: 2, modelID: newID) }
                    )) {
                        Text("Empty").tag(nil as String?)
                        ForEach(chatViewModel.usableModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }

                    // Seats 3 and 4 are deliberately hidden in this release.
                    // 3+ seats with multiple MLX models exceeds iPhone 16 Plus
                    // memory headroom — iOS OOM-kills the app mid-turn during
                    // the second MLX-to-MLX model swap. The seats remain in
                    // the data model (and `runSalonTurn` will still execute
                    // any persisted values from an upgrader), so we can
                    // re-expose them once option-2's smart MLX-swap (explicit
                    // unload + GPU cache clear + memory-reclaim delay) is in
                    // place. Until then we cap salon at 2 seats — verified
                    // safe with AFM + Gemma in earlier testing.
                    if Self.exposeSeatsThreeAndFour {
                        Picker("Seat 3 (Third)", selection: Binding(
                            get: { chatViewModel.salonConfig.seat3 },
                            set: { newID in chatViewModel.setSalonSeat(position: 3, modelID: newID) }
                        )) {
                            Text("Empty").tag(nil as String?)
                            ForEach(chatViewModel.usableModels, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                        Picker("Seat 4 (Fourth)", selection: Binding(
                            get: { chatViewModel.salonConfig.seat4 },
                            set: { newID in chatViewModel.setSalonSeat(position: 4, modelID: newID) }
                        )) {
                            Text("Empty").tag(nil as String?)
                            ForEach(chatViewModel.usableModels, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                    }

                } header: {
                    Label("Active Seats", systemImage: "person.3")
                } footer: {
                    Text(Self.exposeSeatsThreeAndFour
                         ? "Each seat selects a model or Empty. Order is fixed by seat number."
                         : "Two seats let two AI voices speak in turn. More seats will be available once memory management for multi-MLX-model swapping is finished.")
                        .font(.caption)
                }
                
                // Section 2: Behavior
                Section {
                    Picker("Mode", selection: $chatViewModel.salonConfig.behavioralMode) {
                        Text("Independent perspectives").tag(SalonBehavioralMode.independent)
                        Text("Context-aware perspectives").tag(SalonBehavioralMode.contextAware)
                    }

                    // Per Strategic §3/§12: the slot previously labeled "Summarized by"
                    // is now "Host" — and its behavior is richer than it used to be.
                    // When empty, each seat in context-aware mode forms its own
                    // independent summary of the conversation. When assigned, the Host
                    // produces ONE shared summary that all seats consume — faster, but
                    // every voice starts from the Host's framing rather than its own.
                    // The internal AppStorage key (summarizerModel) is preserved for
                    // backward-compatibility with existing salon configs; the user-
                    // facing label is what changed.
                    Picker("Host", selection: $chatViewModel.salonConfig.summarizerModel) {
                        Text("None").tag(nil as String?)
                        ForEach(chatViewModel.usableModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }

                } header: {
                    Label("Behavior", systemImage: "brain")
                } footer: {
                    // Single string literal (not a `+` concatenation) so SwiftUI
                    // treats it as a LocalizedStringKey and renders the **bold**
                    // markdown — concatenation produces a plain String, which
                    // Text renders verbatim (showing literal asterisks).
                    Text("**Host** frames each round and closes the conversation. Without a Host, each voice forms its own independent understanding of the conversation — slower, but philosophically clean. With a Host, all voices share the Host's framing — faster, but mediated.")
                        .font(.caption)
                }
            }
            .navigationTitle("Salon Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// ==== LEGO END: 10.4 SalonModeView (Multi-LLM Configuration) ====
