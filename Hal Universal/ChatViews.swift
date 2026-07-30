// ChatViews.swift
// Hal Universal
//
// The user-facing chat UI plus the app bootstrap that puts it on screen:
// the @main entry point and HalAppDelegate, the iOSChatView chat shell,
// the slide-out thread panel, the message-bubble renderer, and a small
// zero-dependency block-level markdown renderer. See the master index in
// Hal.swift for this file's blocks.
//
// Note: HistoricalContext (conversationCount, relevantConversations,
// contextSnippets, relevanceScores) is defined here but is conceptually a
// MemoryStore value type; it's used by MemoryStore.currentHistoricalContext
// and one ChatBubbleView writer.

import Foundation
import SharedModelStoreKit
import SwiftUI
import Combine
import UIKit

// ==== LEGO START: 53 App Entry & iOSChatView (UI Shell) ====


// MARK: - HistoricalContext (from Hal10000App.swift)
struct HistoricalContext {
    let conversationCount: Int
    let relevantConversations: Int
    let contextSnippets: [String]
    let relevanceScores: [Double]
    let totalTokens: Int
}

// MARK: - App Entry Point (for iOS)
// MARK: - App Delegate (background URLSession dispatch)
//
// SwiftUI's @main App lifecycle doesn't directly expose UIKit AppDelegate
// methods like `application:didFinishLaunchingWithOptions:` and
// `application:handleEventsForBackgroundURLSession:completionHandler:`.
// `UIApplicationDelegateAdaptor` (below) bridges UIKit's AppDelegate
// methods into SwiftUI's App lifecycle.
//
// One responsibility lives here:
//
//  1. Background URLSession completion dispatch — iOS calls
//     handleEventsForBackgroundURLSession when it wakes the app to deliver
//     completion events for a background download (used by the model
//     downloader so downloads survive app suspension).
final class HalAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // MLX_METAL_GPU_ARCH workaround (2026-05-17, EmbeddingGemma load
        // crash on device + sim). MLX's `mlx::core::metal::Device::Device()`
        // (device.cpp:328) calls `device_->architecture()->name()->utf8String()`
        // and passes the result to `std::string()`. On iOS 26.5 the
        // architecture name can be nil; libc++ Hardening aborts with
        // "basic_string(const char*) detected nullptr" before the model
        // load completes. Setting MLX_METAL_GPU_ARCH overrides the lookup
        // (device.cpp:326): `arch_ = env::metal_gpu_arch()` — if non-empty,
        // the crashing line is skipped. "apple9" matches the GPU
        // generation of A17 Pro / A18 / M3+ devices and the iOS 26 sim;
        // the value primarily affects kernel selection downstream, not the
        // basic load path. Set early so MLX reads it before any other code
        // touches Stream.gpu or Device.gpu.
        setenv("MLX_METAL_GPU_ARCH", "apple9", 1)
        halLog("HALDEBUG-EMBEDDING: Set MLX_METAL_GPU_ARCH=apple9 (libc++ string-nullptr workaround for iOS 26.5).")

        // Crash guard: if the previous launch attempted a Gemma load and
        // the process died before recordLoadSuccess cleared the flag, fall
        // back to NLContextual on this launch. Re-enabling Gemma requires
        // an explicit SET_EMBEDDING_BACKEND:embeddinggemma. Done once at
        // launch (not on every embed() call) to avoid race-y intermediate
        // states during warm-up.
        let resolvedBackend = EmbeddingBackend.applyCrashGuardAtLaunch()
        halLog("HALDEBUG-EMBEDDING: Crash guard resolved backend=\(resolvedBackend.rawValue).")

        // Maintenance: garbage-collect cached files for embedding backends
        // that have been removed since this device last installed the app.
        // Added 2026-05-20 (v2.0.1 hotfix) to clean up orphaned
        // EmbeddingGemma weights from pre-removal installs. Idempotent.
        MaintenanceTasks.runAtLaunch()

        // Warm up the contextual embedding model in the background. The
        // first call to NLContextualEmbedding.requestEmbeddingAssets() may
        // need to download model files; doing it at launch (rather than
        // lazily on the first chat turn) keeps the first turn responsive
        // once the assets are in place.
        //
        // REMOVED 2026-05-20: Gemma-specific delayed warm-up branch.
        // Previously: `if backendAtBoot == .embeddingGemma` → +2s delay
        // to avoid racing MLXModelDownloader init. Gemma backend removed
        // in v2.0.1 hotfix; the remaining backends (NLContextual, Nomic)
        // don't need the delay.
        EmbeddingProvider.shared.warmUp()
        halLog("HALDEBUG-EMBEDDING: AppDelegate triggered EmbeddingProvider warm-up.")

        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        halLog("HALDEBUG-BGDL: AppDelegate received handleEventsForBackgroundURLSession id=\(identifier)")
        if identifier == BackgroundDownloadCoordinator.backgroundSessionID {
            BackgroundDownloadCoordinator.shared.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}

@main
struct Hal10000App: App {
    @UIApplicationDelegateAdaptor(HalAppDelegate.self) var appDelegate
    // Use the shared singleton so the whole app binds to one VM instance.
    // @StateObject wrapping a singleton works correctly — the wrapper just
    // observes the same object across re-renders without trying to recreate
    // it (same pattern as DocumentImportManager.shared /
    // MLXModelDownloader.shared below).
    @StateObject private var chatViewModel = ChatViewModel.shared
    @StateObject private var documentImportManager = DocumentImportManager.shared
    @StateObject private var mlxDownloader = MLXModelDownloader.shared // Inject MLXModelDownloader
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure the shared model store with the family App-Group id BEFORE any
        // store access (the download coordinator constructed just below touches it),
        // then stamp this launch so Hal's model claims stay fresh (the 30-day lease).
        // See the SharedModelStoreKit package.
        SharedModelStore.configure(appGroupID: "group.com.MarkFriedlander.aifamily")
        SharedModelStore.touchHeartbeat()
        // Active dead-app cleanup (SharedModelStoreKit 1.1.0). Runs off the main thread
        // so a large reap never blocks launch. Order matters and touchHeartbeat above
        // has already stamped US, so Hal is never seen as stale: grace-stamp any
        // pre-lease (heartbeat-less) claims to give them a fair lease window, then reap
        // provably-dead claimants and delete any now-unclaimed model files. Safe against
        // the rest of launch: a model Hal is about to load is claimed by Hal (fresh), so
        // it can never be reaped; only genuinely abandoned models are removed.
        DispatchQueue.global(qos: .utility).async {
            SharedModelStore.graceStampMissingHeartbeats()
            SharedModelStore.reapStaleClaims()
        }
        // Eagerly construct the background download coordinator so its URLSession
        // is wired up before iOS dispatches any pending completion events on
        // app launch (e.g. when iOS wakes us to deliver a finished download).
        _ = BackgroundDownloadCoordinator.shared
        // Start watching network reachability for the privacy lock indicator.
        // Idempotent; the first path update flips the lock off "locked" default.
        PrivacyMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            iOSChatView()
                .environmentObject(chatViewModel)
                .environmentObject(documentImportManager)
                .environmentObject(mlxDownloader) // Pass MLXModelDownloader
                .onChange(of: scenePhase) { _, phase in
                    // Bug 1 catch-all: if the user edits a per-model setting and
                    // backgrounds the app WITHOUT closing the settings sheet (so
                    // the sheet's onDisappear never fires), persist on the way to
                    // the background so the edit survives a later cold relaunch.
                    if phase == .background {
                        ModelSettingsStore.shared.persistCurrentOverrides(for: chatViewModel.selectedModel)
                    }
                }
        }
        // Mac support is via "Designed for iPad" (automatic for any iPad-targeted
        // app on Apple Silicon Macs) — NOT Mac Catalyst. The OS chooses the window
        // shape; we don't configure it from here. A prior #if targetEnvironment(macCatalyst)
        // block lived here aiming to override the default size, but it was dead code
        // (no Catalyst target exists in this project) and .defaultSize is a Catalyst-only
        // API anyway. Removed in v2.0.
    }
}



// MARK: - Primary chat surface with unified settings
import SwiftUI

struct iOSChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    // Privacy lock indicator: the shared network monitor (started at launch)
    // plus the tap-popover flag. The lock glyph is computed live in
    // `isPrivacyLocked` from the active model + this monitor + the salon config.
    @StateObject private var privacyMonitor = PrivacyMonitor.shared
    @State private var showingPrivacyPopover = false
    @State private var showingReasoningPopover = false
    // Thermal-consent toll (2026-07-23). Turning thinking ON with a heavy model
    // (Bonsai) or an unprofiled experimental model shows a repeating warning first;
    // switching INTO such a model while thinking is already on warns after the fact
    // (the 300ms throttle is enforced at the generation path either way — this is the
    // heads-up, not the protection). Two flags because the two paths offer different
    // choices (turn on / not now  vs  keep on / turn off). See needsThermalConsent.
    @State private var showingThermalConsentToggle = false
    @State private var showingThermalConsentSwitch = false
    // Tap-popover for the thermal indicator (the filling thermometer glyph, shown
    // only above nominal). Explains the current thermal state + what the governor
    // is doing. See ThermalIndicatorPopover.
    @State private var showingThermalIndicatorPopover = false
    // One-time model-storage migration notice (Layer 2 of the consent flow): shown at
    // launch to users who had models under the old pre-version scheme, gating the
    // cleanup behind their choice. See ModelStorageMigrationNotice + MaintenanceTasks.
    @State private var showingModelStorageNotice = false
    // Set when the user taps "Model Library" in the privacy popover; consumed
    // in the popover's onDisappear so the sheet presents only AFTER the popover
    // is fully gone (a popover + sheet can't present at once — same race as the
    // download disclosure sheet; .popover has no onDismiss, hence onDisappear).
    @State private var pendingModelLibraryNav = false
    @State private var scrollToBottomTrigger = UUID()
    // Sheet flags moved to ChatViewModel.showingSettings / showingThreadPanel /
    // showingDocumentPicker so the LocalAPIServer can read them via GET_UI_STATE.
    @FocusState private var isInputFocused: Bool // NEW: Track text field focus
    // Scroll behavior (2026-05-17, Mark's directive):
    //
    // Single rule: when the user sends a message, that message scrolls
    // to the top of the visible area. ONCE. After that, the user is in
    // complete control — no automatic repositioning, no percentage
    // calculations, no anchor reapplication mid-stream, no
    // bottom-follow. Hal's response naturally appears below the user's
    // message as it streams in; if the response grows beyond the visible
    // area, the user scrolls themselves to see more.
    //
    // The previous implementation (May 16, scroll-anchor spec) maintained
    // a pinned exchange ID, character-count heuristics, drag-disengage
    // logic, and bottom-follow fallbacks. All removed. This is simpler
    // and matches the ChatGPT/Claude.ai web pattern: scrollTo(userMessage,
    // anchor: .top) on send, then nothing.

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top chrome — two rows: full-width thread title, then the icon row.
                chromeHeader
                // Messages
                ScrollViewReader { proxy in
                    List {
                        // FIXED: Use message.id as the identifier instead of array indices
                        // This allows SwiftUI to properly track content changes within each message
                        ForEach(chatViewModel.messages) { message in
                            let messageIndex = chatViewModel.messages.firstIndex(where: { $0.id == message.id }) ?? 0
                            ChatBubbleView(
                                message: message,
                                messageIndex: messageIndex
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                            // Explicit clear background to prevent the "footer-visible-but-text-
                            // missing-after-reload" bug. SwiftUI's default list row background
                            // can occasionally paint over bubble content when the List is
                            // recreated via `.id(messagesVersion)` after a conversation reload —
                            // the row background sits ABOVE the bubble's text but BELOW its
                            // footer position. Setting an explicit clear background removes the
                            // default row-background layer entirely.
                            .listRowBackground(Color.clear)
                            .id(message.id)
                        }
                        // Bottom sentinel kept as a scroll target for app-
                        // launch positioning. No auto-scroll handlers
                        // attached — the user is in complete control after
                        // the initial launch placement.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    // Soft fades so messages dissolve into the chrome instead of
                    // ending on a hard edge (Mark, 2026-07-23): fade DOWN into the
                    // top chrome, and UP into the composer at the bottom. Fades to
                    // the app background (matches the dark chrome); non-interactive
                    // so scrolling and taps pass straight through.
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 28)
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 28)
                        .allowsHitTesting(false)
                    }
                    .id(chatViewModel.messagesVersion)
                    .onTapGesture {
                        // Dismiss keyboard when tapping message area.
                        dismissKeyboard()
                    }
                    .gesture(
                        // Downward drag dismisses the keyboard. No scroll
                        // state tracking — the user's scrolling stands on
                        // its own and we don't intervene.
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.height > 50 {
                                    dismissKeyboard()
                                }
                            }
                    )
                    .onAppear {
                        // App launch — position at the most recent activity
                        // so the user sees their latest exchange when the
                        // chat opens. This is the only "automatic" scroll
                        // that happens outside of send-start, and it only
                        // fires once when the view first appears.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: chatViewModel.isSendingMessage) { oldValue, newValue in
                        // Single rule: on send-start, scroll the user's
                        // new message to the top of the visible area.
                        // ONCE. After that, no further auto-scrolling —
                        // the user is in complete control. Hal's response
                        // streams in below the user's message naturally;
                        // if it grows beyond the visible area, the user
                        // scrolls themselves to keep reading.
                        guard newValue == true else { return }
                        guard let latestUser = chatViewModel.messages.last(where: { $0.isFromUser }) else { return }
                        halLog("HALDEBUG-SCROLL: Send-start — scrolling user message \(latestUser.id.uuidString.prefix(8)) to top, then yielding control to user.")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(latestUser.id, anchor: .top)
                            }
                        }
                    }
                }

                // Composer
                composer
            }
            // Native nav bar hidden — the two-row `chromeHeader` above replaces it
            // (2026-07-23) so the thread title gets a full-width line of its own
            // instead of fighting the icons for space and truncating to "Wha...".
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $chatViewModel.showingThreadPanel) {
                ThreadPanelView(isPresented: $chatViewModel.showingThreadPanel)
                    .environmentObject(chatViewModel)
            }

            // Unified Settings sheet
            .sheet(isPresented: $chatViewModel.showingSettings) {
                ActionsView(showingDocumentPicker: $chatViewModel.showingDocumentPicker)
                    .environmentObject(chatViewModel)
                    .environmentObject(DocumentImportManager.shared)
                    .environmentObject(MLXModelDownloader.shared)
            }

            // Document picker sheet
            .sheet(isPresented: $chatViewModel.showingDocumentPicker) {
                DocumentPicker()
                    .environmentObject(chatViewModel)
                    .environmentObject(DocumentImportManager.shared)
            }

            // API-driven sub-sheet navigation (root-level so SET_UI_STATE
            // can present these without Settings being open).
            .sheet(isPresented: $chatViewModel.apiNavSystemPrompt) {
                SystemPromptEditorView()
                    .environmentObject(chatViewModel)
            }
            .sheet(isPresented: $chatViewModel.apiNavModelFraming) {
                ModelFramingDetailView()
                    .environmentObject(chatViewModel)
            }
            .sheet(isPresented: $chatViewModel.apiNavSelfModel) {
                SelfReflectionView()
                    .environmentObject(chatViewModel)
            }
            .sheet(isPresented: $chatViewModel.apiNavPowerUser) {
                PowerUserView()
                    .environmentObject(chatViewModel)
                    .environmentObject(MLXModelDownloader.shared)
            }
            .sheet(isPresented: $chatViewModel.apiNavSalonSettings) {
                SalonModeView()
                    .environmentObject(chatViewModel)
            }
            .sheet(isPresented: $chatViewModel.apiNavModelLibrary) {
                NavigationView {
                    ModelLibraryView()
                        .environmentObject(chatViewModel)
                        .environmentObject(MLXModelDownloader.shared)
                }
            }
            // Antenna-driven nav to the reorg's two sub-screens (Lab #7), so screenshot
            // automation can reach them without the settings-button routing (which sends
            // Salon users to SalonModeView). Presenting these directly also lets us verify
            // the Salon-grayed Thinking Cap, which the normal path can't reach.
            .sheet(isPresented: $chatViewModel.apiNavMaintenance) {
                MaintenanceView()
                    .environmentObject(chatViewModel)
                    .environmentObject(MLXModelDownloader.shared)
            }
            .sheet(isPresented: $chatViewModel.apiNavLab) {
                LabView()
                    .environmentObject(chatViewModel)
            }
            // One-time model-storage migration notice (Layer 2). Shown once at launch
            // to users who had pre-version model copies; both buttons mark it handled
            // so it never returns. See ModelStorageMigrationNotice.
            .sheet(isPresented: $showingModelStorageNotice) {
                ModelStorageMigrationNotice()
            }
            .task {
                // Present after the shell settles. `migrationNoticeShouldShow` is set by
                // the synchronous launch detection (MaintenanceTasks.runAtLaunch) and
                // goes false the moment either button is tapped, so this fires at most once.
                if MaintenanceTasks.migrationNoticeShouldShow {
                    showingModelStorageNotice = true
                }
            }
            // Thermal-consent toll — path 1: the user tapped the brain to turn
            // thinking ON with a heavy/unprofiled model. Gate before enabling.
            .alert(thermalConsentTitle(for: chatViewModel.selectedModel),
                   isPresented: $showingThermalConsentToggle) {
                Button("Not now", role: .cancel) { }
                Button("Turn on thinking") {
                    chatViewModel.setReasoning(true)
                }
            } message: {
                Text(thermalConsentMessage(for: chatViewModel.selectedModel))
            }
            // Thermal-consent toll — path 2: thinking is already on and the user
            // switched INTO a heavy/unprofiled model (fired by the onChange below).
            // The switch already happened, so the choice is about thinking state.
            .alert(thermalConsentTitle(for: chatViewModel.selectedModel),
                   isPresented: $showingThermalConsentSwitch) {
                Button("Turn thinking off") {
                    chatViewModel.setReasoning(false)
                }
                Button("Keep thinking on", role: .cancel) { }
            } message: {
                Text(thermalConsentMessage(for: chatViewModel.selectedModel))
            }
            // Warn when switching INTO a consent model while thinking is already on;
            // the brain-toggle gate can't catch this path. Safety (the 300ms throttle)
            // is enforced at the generation path regardless — this is the heads-up.
            .onChange(of: chatViewModel.selectedModelID) { _, _ in
                if chatViewModel.reasoningEnabled && chatViewModel.selectedModel.needsThermalConsent {
                    showingThermalConsentSwitch = true
                }
            }
        }
    }

    // MARK: - Top chrome (two-row: full-width title + icon row)
    //
    // Replaces the native nav bar (2026-07-23). Row 1 is the full-width thread
    // name on its own line (no more truncating to "Wha..." against the icons);
    // row 2 is the control + status icons. FIXED — no collapse-on-scroll (Mark:
    // the one line of height isn't worth the scroll-tracking + jank; revisit only
    // if the fixed row proves annoying in use). The icons are the same buttons and
    // popovers that used to live in `.toolbar`, moved verbatim into an HStack.
    private var chromeHeader: some View {
        VStack(spacing: 2) {
            Text(conversationTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            chromeIconRow
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var chromeIconRow: some View {
        HStack(spacing: 22) {
            // Threads / conversation list — leftmost (as in the old nav bar).
            Button {
                chatViewModel.showingThreadPanel = true
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            Spacer(minLength: 12)
            // Thermal indicator — appear-when-warm (see ThermalIndicatorPopover).
            if chatViewModel.thermalLevel >= 1 {
                Button {
                    showingThermalIndicatorPopover = true
                } label: {
                    Image(systemName: thermalGlyphName(chatViewModel.thermalLevel))
                }
                .popover(isPresented: $showingThermalIndicatorPopover) {
                    ThermalIndicatorPopover(level: chatViewModel.thermalLevel)
                        .presentationCompactAdaptation(.popover)
                }
            }
            // Reasoning / thinking toggle — monochrome (bright on / dim off).
            // In Salon Mode thinking is unavailable (single-LLM only): the button
            // stays tappable but dims and, instead of toggling, opens the popover
            // to explain why. A dead disabled control would explain nothing —
            // off-brand for a transparency app.
            Button {
                if chatViewModel.salonConfig.isEnabled {
                    // Salon Mode: thinking is gated off. Explain, don't toggle.
                    showingReasoningPopover = true
                } else if chatViewModel.reasoningEnabled {
                    // Turning thinking OFF — never gated.
                    chatViewModel.setReasoning(false)
                    showingReasoningPopover = true
                } else if chatViewModel.selectedModel.needsThermalConsent {
                    // Turning thinking ON with a heavy/unprofiled model: toll first.
                    showingThermalConsentToggle = true
                } else {
                    chatViewModel.setReasoning(true)
                    showingReasoningPopover = true
                }
            } label: {
                Image(systemName: "brain")
                    // Colour tracks the EFFECTIVE state (reasoningActive), so the
                    // glyph reads dim in Salon even if reasoningEnabled is still
                    // stored true. Extra dim signals "unavailable but tappable".
                    .foregroundStyle(chatViewModel.reasoningActive ? Color.primary : Color.secondary)
                    .opacity(chatViewModel.salonConfig.isEnabled ? 0.45 : 1.0)
            }
            .popover(isPresented: $showingReasoningPopover) {
                ReasoningPopover(
                    isOn: chatViewModel.reasoningEnabled,
                    modelName: chatViewModel.selectedModel.displayName,
                    unavailableInSalon: chatViewModel.salonConfig.isEnabled
                )
                .presentationCompactAdaptation(.popover)
            }
            // Privacy lock.
            Button {
                showingPrivacyPopover = true
            } label: {
                Image(systemName: isPrivacyLocked ? "lock" : "lock.open")
            }
            .popover(isPresented: $showingPrivacyPopover) {
                PrivacyLockPopover(
                    isLocked: isPrivacyLocked
                ) {
                    // Record intent + dismiss the popover; the Model Library sheet
                    // presents from onDisappear once the popover is fully gone.
                    pendingModelLibraryNav = true
                    showingPrivacyPopover = false
                }
                .presentationCompactAdaptation(.popover)
                .onDisappear {
                    if pendingModelLibraryNav {
                        pendingModelLibraryNav = false
                        chatViewModel.apiNavModelLibrary = true
                    }
                }
            }
            // Settings.
            Button {
                chatViewModel.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .font(.title3)
        // Monochrome/white icons to match the stark chrome; the brain sets its own
        // foreground (bright on / dim off) which overrides this tint.
        .tint(.primary)
    }

    // MARK: - Thermal-consent copy
    // Honest wording for the thinking-mode toll. Heat tracks a model's ACTIVE
    // parameters per token, so Bonsai (8B dense) is the calibrated-hot case and any
    // experimental (non-curated) model is the unprofiled case. The escalation is
    // stated plainly: throttled → answer may cut off → iOS protects the hardware
    // (nothing is damaged). See ModelConfiguration.needsThermalConsent.
    private func thermalConsentTitle(for model: ModelConfiguration) -> String {
        "\(model.displayName) runs warm in thinking mode"
    }

    /// Filling-thermometer glyph for the thermal indicator, by OS thermal level
    /// (1 fair / 2 serious / 3 critical). Level 0 (nominal) hides the glyph, so it
    /// isn't mapped here. Monochrome; the fill level carries the meaning.
    private func thermalGlyphName(_ level: Int) -> String {
        switch level {
        case 1:  return "thermometer.low"
        case 2:  return "thermometer.medium"
        case 3:  return "thermometer.high"
        default: return "thermometer.medium"
        }
    }

    private func thermalConsentMessage(for model: ModelConfiguration) -> String {
        let name = model.displayName
        if model.id == ModelConfiguration.bonsai8B2bit.id {
            return "\(name) is an 8-billion-parameter model. In thinking mode it thinks and then answers, which is a lot of sustained work for the device. To keep it cool, Hal slows \(name) down while it thinks, so replies come slowly. If the device still gets too warm an answer can come out short or cut off, and if it gets warmer still the OS steps in to protect the device. Nothing is damaged. You can turn thinking off anytime with the brain button."
        } else {
            return "\(name) isn't a model Hal has tuned for heat. In thinking mode it thinks and then answers, which is sustained work for the device. Hal will slow it down if it starts running warm, but a reply can still come out short or cut off, and if the device gets hot enough the OS steps in to protect it. Nothing is damaged. You can turn thinking off anytime with the brain button."
        }
    }

    // MARK: - Conversation Title (Title Bar)
    // Thread title sourced from the threads table via chatViewModel.threads.
    // Falls back to "Hal" for empty threads (e.g., brand new conversation before first message).
    private var conversationTitle: String {
        chatViewModel.threads.first(where: { $0.id == chatViewModel.conversationId })?.title ?? "Hal"
    }

    /// Whether the privacy lock reads "locked" (nothing leaves the device) right
    /// now. Recomputed on every render from @Published state (the active model,
    /// the network monitor, and the salon config), so the toolbar updates the
    /// instant any of them changes, so the glyph flips live on a model switch or
    /// an Airplane-Mode toggle. The pure decision lives in PrivacyMonitor.isLocked;
    /// here we just resolve each active salon seat's source (unknown →
    /// .appleFoundation, the conservative cloud-possible assumption) and hand it
    /// the inputs.
    private var isPrivacyLocked: Bool {
        let seatSources = chatViewModel.salonConfig.activeSeats.map { seat in
            ModelCatalogService.shared.getModel(byID: seat.modelID)?.source ?? .appleFoundation
        }
        return PrivacyMonitor.isLocked(
            activeModelSource: chatViewModel.selectedModel.source,
            networkAvailable: privacyMonitor.isNetworkAvailable,
            salonEnabled: chatViewModel.salonConfig.isEnabled,
            salonSeatSources: seatSources
        )
    }

    // MARK: - Composer (Text Input Area)
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $chatViewModel.currentMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(20)
                .lineLimit(1...10)
                .focused($isInputFocused)
                .disabled(chatViewModel.isSendingMessage)
                .onTapGesture {
                    // Keyboard appears only on explicit tap
                    isInputFocused = true
                }

            Button {
                if chatViewModel.isSendingMessage {
                    // TODO: Implement cancellation logic if needed
                } else {
                    // Dismiss keyboard before sending
                    dismissKeyboard()
                    Task {
                        await chatViewModel.sendMessage()
                    }
                }
            } label: {
                Image(systemName: chatViewModel.isSendingMessage ? "stop.circle.fill" : "paperplane.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
            .disabled(chatViewModel.isSendingMessage || chatViewModel.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Composer uses the lighter `.ultraThinMaterial` (its original). We tried
        // matching it to the darker top chrome, but the composer sits against the
        // KEYBOARD (a system element we can't recolor), and a dark composer clashed
        // with the light keyboard. The lighter material blends with the keyboard, so
        // it stays. Top/bottom chrome intentionally differ for this reason. (2026-07-24.)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Keyboard Dismissal Helper
    // NEW: Platform-safe keyboard dismissal
    private func dismissKeyboard() {
        #if os(iOS)
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Model-storage migration notice (Layer 2 of the consent flow)
//
// A one-time launch screen shown to users who had models under the OLD pre-version
// storage scheme. It explains the change in Hal's own voice (the project's
// "access to reflection" maxim, pointed at the user) and, crucially, GATES the
// cleanup: nothing is deleted until the user chooses. "Remove old copies" runs the
// cleanup engine; "Not now" leaves the files untouched. Either choice marks the
// notice handled so it never shows again; the Settings "Free up old model files"
// button remains the ongoing door. Interactive dismissal is disabled so the choice
// is deliberate (both options are gentle). See MaintenanceTasks for the engine.
private struct ModelStorageMigrationNotice: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(.tint)
                        .padding(.top, 8)

                    Text("I changed how I keep my models")
                        .font(.title2).bold()
                        .fixedSize(horizontal: false, vertical: true)

                    Text("I now store each model under its exact version, so one can never be quietly replaced by a different or untested build, and so I can safely share a single copy with companion apps coming soon.")

                    Text("The models you downloaded before this change can't be verified that way, so I won't reuse them. Nothing you made is affected: your conversations and my memory are untouched. The next time you reach for one of these models, I'll download a fresh, verified copy, once.")

                    Text("Want me to clear the old, unusable copies now to free up the space?")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }

            VStack(spacing: 12) {
                Button {
                    MaintenanceTasks.freeOldModelFiles()
                    MaintenanceTasks.markMigrationNoticeHandled()
                    ModelCatalogService.shared.refreshDownloadStates()
                    dismiss()
                } label: {
                    Text("Remove old copies").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    MaintenanceTasks.markMigrationNoticeHandled()
                    dismiss()
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding([.horizontal, .bottom], 24)
            .padding(.top, 8)
        }
        .interactiveDismissDisabled(true)
    }
}

// ==== LEGO END: 53 App Entry & iOSChatView (UI Shell) ====


// ==== LEGO START: 54 ThreadPanelView ====

// MARK: - Thread Panel
/// Slide-out panel accessed via hamburger icon. Lists all conversation threads, most recent first.
/// New Thread button at top. Each thread shows title + subtitle (date + message count).
/// Tapping a thread switches to it with full context restoration.
/// Reset Thread button per thread row (swipe-to-delete style, with confirmation).
struct ThreadPanelView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var threadToDelete: ThreadRecord? = nil
    @State private var showingDeleteConfirmation = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                // New Thread button at top
                Button {
                    chatViewModel.startNewConversation()
                    isPresented = false
                } label: {
                    Label("New Thread", systemImage: "square.and.pencil")
                        .foregroundColor(.accentColor)
                }

                // Thread list, most recent first (already sorted by loadAllThreads)
                ForEach(chatViewModel.threads) { thread in
                    threadRow(thread)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .alert("Reset Thread?", isPresented: $showingDeleteConfirmation, presenting: threadToDelete) { thread in
            Button("Reset", role: .destructive) {
                resetThread(thread)
            }
            Button("Cancel", role: .cancel) { }
        } message: { thread in
            Text("This will permanently delete all messages in \"\(thread.title)\". This cannot be undone.")
        }
        .onAppear {
            chatViewModel.loadThreads()
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadRecord) -> some View {
        Button {
            chatViewModel.switchToThread(thread.id)
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.body)
                        .fontWeight(thread.id == chatViewModel.conversationId ? .semibold : .regular)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(subtitleText(for: thread))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if thread.id == chatViewModel.conversationId {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                Button {
                    threadToDelete = thread
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                threadToDelete = thread
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitleText(for thread: ThreadRecord) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(thread.lastActiveAt))
        return dateFormatter.string(from: date)
    }

    private func resetThread(_ thread: ThreadRecord) {
        if thread.id == chatViewModel.conversationId {
            // Resetting the active thread — start fresh
            chatViewModel.memoryStore.deleteThread(id: thread.id)
            chatViewModel.startNewConversation()
        } else {
            // Resetting an inactive thread — just delete its data
            chatViewModel.memoryStore.deleteThread(id: thread.id)
            chatViewModel.loadThreads()
        }
    }
}

// ==== LEGO END: 54 ThreadPanelView ====


// ==== LEGO START: 55 ChatBubbleView & TimerView (Message UI Components) ====

// PreferenceKey used by ChatBubbleView to read the bubble's actual
// container width via GeometryReader. This is what fixes rotation
// reflow — UIScreen-based screenWidth doesn't reactively update on
// device rotation (no observable triggers a body recompute), so
// bubble maxWidth stayed pinned to the orientation at first render.
// GeometryReader is reactive to size changes, so the measured width
// tracks rotation correctly. Reduce takes max so the outermost
// measurement wins if multiple geometry readers stack.
private struct BubbleContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - ThinkingDisclosure
//
// Collapsible panel that shows a reasoning model's thinking trace
// (message.thinking), separated from the visible answer. EXPOSED BY DEFAULT and
// STICKY across relaunch (Mark, 2026-07-23): on a transparency project the
// reasoning is often the part most worth reading, so it should be visible without
// a tap and it should NOT auto-collapse the instant the answer arrives. The
// expanded state is one shared, persisted preference — expanding or collapsing any
// panel sets the app-wide default, and that choice survives relaunch. Tappable to
// toggle. See Docs/Think_Tokens_Reasoning_Transparency.md.
private struct ThinkingDisclosure: View {
    let text: String
    let isStreaming: Bool
    // One shared, persisted preference (@AppStorage), defaulting to true so
    // thinking is shown by default. Replaces the old per-view @State that started
    // collapsed and force-collapsed the panel the moment streaming ended.
    @AppStorage("reasoningPanelExpanded") private var expanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                Text(isStreaming ? "Thinking…" : "Thinking")
                if isStreaming {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .tint(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
    }
}

// MARK: - ReasoningPopover
//
// Plain-language explanation shown when the user taps the brain toggle, mirroring
// PrivacyLockPopover. Describes the new reasoning state (on/off) for the active
// model. See Docs/Think_Tokens_Reasoning_Transparency.md.
struct ReasoningPopover: View {
    let isOn: Bool
    let modelName: String
    // When true, thinking is gated off because Salon Mode is active. Overrides
    // the on/off copy with an explanation of why the control is unavailable.
    // Defaults false so existing call sites are unchanged.
    var unavailableInSalon: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.headline)

            Text(explanation)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var title: String {
        if unavailableInSalon { return "Thinking off in Salon Mode" }
        return isOn ? "Thinking on" : "Thinking off"
    }

    private var explanation: String {
        if unavailableInSalon {
            return "Watching Hal think runs one model through a reason-then-answer pass. Thinking is only available in single LLM mode. Switch back to a single model to turn it on."
        }
        if isOn {
            return "\(modelName) will think each answer through first. You'll see its thinking stream into a panel above the reply, then the answer beneath. It's slower and more deliberate. Tap the brain again to switch back to direct replies."
        } else {
            return "\(modelName) answers directly, with no visible thinking. Tap the brain whenever you want to watch it think a question through before it replies."
        }
    }
}

// MARK: - ThermalIndicatorPopover
//
// Plain-language explanation shown when the user taps the thermal glyph, mirroring
// PrivacyLockPopover. Only shown above nominal (the glyph hides at level 0), so the
// text describes fair/serious/critical; a nominal fallback is kept for safety. Each
// line states what the ThermalGovernor (Block 61) actually does at that level, so
// the explanation is honest, not decorative. Copy approved by Mark 2026-07-23;
// "phone" changed to the neutral "device" 2026-07-29 so it reads right on iPad
// and Mac too, the sentences are otherwise unchanged.
struct ThermalIndicatorPopover: View {
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: glyph)
                .font(.headline)

            Text(explanation)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var glyph: String {
        switch level {
        case 1:  return "thermometer.low"
        case 2:  return "thermometer.medium"
        case 3:  return "thermometer.high"
        default: return "thermometer.low"
        }
    }

    private var explanation: String {
        switch level {
        case 1:
            return "Your device is warming up. Hal is easing off slightly to slow the climb."
        case 2:
            return "Your device is hot. Hal is slowing down to let it cool."
        case 3:
            return "Your device is very hot. Hal is pausing until it cools."
        default:
            return "Your device is running cool."
        }
    }
}

// MARK: - Chat display appearance (user-facing, opt-in)
//
// Two independent, opt-in controls over how the conversation reads. Their DEFAULTS
// reproduce the pre-2026-07-25 look exactly (body text at ~20pt, generous margins),
// so no existing user's chat changes unless they choose to change it. Text size is an
// explicit base point size; a `@ScaledMetric(relativeTo: .body)` multiplier is layered
// on at the render site so the system Dynamic Type / accessibility setting still scales
// it. Density controls only spacing (margins, line spacing, bubble padding), never font.
// Read via `@AppStorage` in ChatBubbleView (and passed into MarkdownView).

enum ChatTextSize: Int, CaseIterable, Identifiable {
    case small = 15, medium = 17, large = 20, xLarge = 24
    var id: Int { rawValue }
    var pointSize: CGFloat { CGFloat(rawValue) }
    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .xLarge: return "Extra Large"
        }
    }
    /// The default equals the historical body size (`.title3` ≈ 20pt).
    static let defaultValue: ChatTextSize = .large
    static let storageKey = "chatTextSizePt"
}

enum ChatDensity: String, CaseIterable, Identifiable {
    case comfortable, cozy, compact
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// Outer margin from the screen edge to the message row.
    var edgePadding: CGFloat {
        switch self { case .comfortable: return 16; case .cozy: return 11; case .compact: return 8 }
    }
    /// Horizontal padding inside a message bubble.
    var bubbleHPadding: CGFloat {
        switch self { case .comfortable: return 14; case .cozy: return 12; case .compact: return 10 }
    }
    /// Vertical padding inside a message bubble.
    var bubbleVPadding: CGFloat {
        switch self { case .comfortable: return 10; case .cozy: return 8; case .compact: return 7 }
    }
    /// Line spacing on body text.
    var lineSpacing: CGFloat {
        switch self { case .comfortable: return 6; case .cozy: return 4; case .compact: return 3 }
    }
    /// Vertical padding between message rows.
    var rowVPadding: CGFloat {
        switch self { case .comfortable: return 4; case .cozy: return 3; case .compact: return 2 }
    }
    /// Horizontal inset for HAL's flat (background-less) replies. Unlike the user's gray
    /// bubble, Hal's text has no background, so bubble padding just wastes space; tighter
    /// levels shed it so the text flows toward the edge.
    var assistantHInset: CGFloat {
        switch self { case .comfortable: return 14; case .cozy: return 8; case .compact: return 2 }
    }
    /// Fraction of the container width Hal's replies may use. Comfortable keeps the classic
    /// 0.90 cap; tighter levels let the text run essentially edge-to-edge (the Claude/Gemini
    /// look). The user's own bubbles are unaffected — they stay bubbles.
    var assistantWidthFraction: CGFloat {
        switch self { case .comfortable: return 0.90; case .cozy: return 0.97; case .compact: return 1.0 }
    }
    /// The default reproduces the historical spacing exactly.
    static let defaultValue: ChatDensity = .comfortable
    static let storageKey = "chatDensity"
}

// MARK: - ChatBubbleView (from Hal10000App.swift for consistent UI)
struct ChatBubbleView: View {
    let message: ChatMessage
    let messageIndex: Int
    @EnvironmentObject var chatViewModel: ChatViewModel

    // Chat display appearance (opt-in). Defaults reproduce today's look exactly.
    @AppStorage(ChatTextSize.storageKey) private var chatTextSizePt: Int = ChatTextSize.defaultValue.rawValue
    @AppStorage(ChatDensity.storageKey) private var chatDensityRaw: String = ChatDensity.defaultValue.rawValue
    // System Dynamic Type multiplier (1.0 at default) layered on the chosen base size so
    // accessibility text scaling still works. See ChatTextSize.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1.0
    private var chatDensity: ChatDensity { ChatDensity(rawValue: chatDensityRaw) ?? .comfortable }
    private var chatBodyPt: CGFloat { CGFloat(chatTextSizePt) * dynamicTypeScale }
    @State private var showingDetails: Bool = false
    @State private var showingCompressionExplanation: Bool = false
    // Item 4 (2026-05-17): "View Prompt Details" sheet state. Presents
    // the color-coded, collapsible PromptDetailView (lives in its own
    // file as of 2026-05-17). Only ever set true on the assistant-side
    // branch of the bubble's contextMenu — user bubbles don't surface it.
    @State private var showingPromptDetail: Bool = false

    // MARK: - Prompt-detail context resolution
    //
    // These two properties give the new PromptDetailView the surrounding
    // chat context it needs without coupling the view to ChatViewModel.
    //
    // `precedingUserContent`: the user message that paired with this
    // assistant message (same turn number, immediately prior in the
    // messages array). Walking backwards is robust to interleaved status
    // messages or salon participants that don't share the turn.
    //
    // `recentHistory`: up to ~4 turn pairs before this message, so the
    // detail view can show "what the model saw as conversation history."
    // Capped to keep the sheet's history section scrollable rather than
    // unboundedly long for deep conversations.
    private var precedingUserContent: String? {
        guard let idx = chatViewModel.messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            let m = chatViewModel.messages[i]
            if m.isFromUser && m.turnNumber == message.turnNumber { return m.content }
        }
        return nil
    }

    private var recentHistory: [ChatMessage] {
        guard let idx = chatViewModel.messages.firstIndex(where: { $0.id == message.id }) else { return [] }
        let start = max(0, idx - 8)  // ~4 turn pairs (user + assistant each)
        return Array(chatViewModel.messages[start..<idx])
    }

    // Provide screen width directly.
    //
    // BUG FIX (Mark report, May 11, 2026): the original implementation
    // filtered scenes by `activationState == .foregroundActive`. On a
    // freshly-reloaded conversation (cold launch, app returning from
    // background, or list rebuilt via `.id(messagesVersion)`), the scene
    // can briefly be in `.foregroundInactive` while views are computing
    // layout. That made screenWidth return 0, which collapsed
    // `.frame(maxWidth: screenWidth * 0.90)` to 0 — text wrapped to zero
    // width and became invisible while the footer (which has no width
    // constraint) still rendered. Tapping the input gave the keyboard
    // safe-area-change re-layout that re-evaluated this property when
    // the scene was finally `.foregroundActive`, hence "the text shows
    // again after I tap the box."
    //
    // Fixed by:
    //   1. Accepting any non-background scene (handles `.foregroundInactive`)
    //   2. Falling back to UIScreen.main.bounds.width if no scene resolves
    //   3. Final fallback to 390 (iPhone 16 logical width) so we never
    //      return 0 even in pathological launch sequences
    private var screenWidth: CGFloat {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }) {
            let w = scene.screen.bounds.width
            if w > 0 { return w }
        }
        // No scene resolved (extremely rare — only seen during cold-launch
        // race conditions before any window scene attaches). Drop straight
        // to the safe-fallback width. iPhone 16 logical width is 390pt;
        // the GeometryReader-measured value (Phase 6b) replaces this within
        // milliseconds of first layout, so the fallback is purely a
        // never-return-zero guard.
        // (Previously fell back to UIScreen.main.bounds.width, but that
        // was deprecated in iOS 26 — the scene-based check above is the
        // recommended replacement and it covers every non-edge case.)
        return 390
    }

    // Reactive measurement of the bubble's actual container width.
    // Populated by a GeometryReader background in `body`. Updates on
    // every layout pass (including rotation), so chat bubbles reflow
    // correctly when the user rotates between portrait and landscape.
    // Falls back to screenWidth on the very first render before the
    // first layout pass populates this value.
    @State private var measuredContainerWidth: CGFloat = 0

    // Single source of truth for bubble maxWidth. Prefers the
    // GeometryReader-measured value when available (reactive),
    // falls back to screenWidth (cold-launch first render only).
    private var bubbleMaxWidth: CGFloat {
        let base = measuredContainerWidth > 0 ? measuredContainerWidth : screenWidth
        return base * 0.90
    }

    /// Max width for HAL's flat replies — density-aware. Comfortable equals the classic
    /// `bubbleMaxWidth` (0.90); Compact lets Hal's text run full-width. User bubbles keep
    /// using `bubbleMaxWidth`. See ChatDensity.assistantWidthFraction.
    private var assistantMaxWidth: CGFloat {
        let base = measuredContainerWidth > 0 ? measuredContainerWidth : screenWidth
        return base * chatDensity.assistantWidthFraction
    }

    // SALON MODE FIX: Use stored turnNumber from database instead of calculating from array position
    var actualTurnNumber: Int {
        return message.turnNumber
    }
    
    var metadataText: String {
        var parts: [String] = []
        parts.append("Turn \(actualTurnNumber)")
        parts.append("~\(message.content.split(separator: " ").count) tokens")
        parts.append(message.timestamp.formatted(date: .abbreviated, time: .shortened))
        if let duration = message.thinkingDuration {
            parts.append(String(format: "%.1f sec", duration))
        }
        return parts.joined(separator: " · ")
    }
    
    // MARK: - Status Message Detection
    var isStatusMessage: Bool {
        ["Reading your message...",
         "Assembling recent context... (short-term memory)",
         "Recalling relevant memories... (long-term memory)",
         "Formulating a reply..."].contains(message.content)
    }
    
    // MARK: - Footer View (Updated with Processing/Inference labels)
    @ViewBuilder
    var footerView: some View {
        // Follow the speaker: the user's footer aligns right (under their right-flush
        // bubble); Hal's aligns left (under his left-flush text). See the Hal-branch
        // placement, which also insets it to match the text's left edge.
        VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 2) {
            if message.isPartial {
                // Show the model that's currently generating, alongside the
                // spinner and timer, so the user knows which engine is
                // producing the response in real time (matches Maxim #2 —
                // access to reflection / transparency by default).
                // recordedByModel is set on the partial placeholder at
                // creation, so the lookup is valid even before generation
                // returns.
                let activeModelName = ModelCatalogService.shared.getModel(byID: message.recordedByModel)?.displayName ?? message.recordedByModel
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.gray)
                    Text("Processing...")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    TimerView(startDate: message.timestamp)
                    Text("• \(activeModelName)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .transition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                let formattedDate = message.timestamp.formatted(date: .abbreviated, time: .shortened)
                let turnText = "Turn \(actualTurnNumber)"
                let durationText = message.thinkingDuration.map { String(format: "Inference %.1f sec", $0) }
                let modelName = !message.isFromUser ? (ModelCatalogService.shared.getModel(byID: message.recordedByModel)?.displayName ?? message.recordedByModel) : nil
                // Salon footer fields (Strategic §6/§13 follow-up):
                //   Seat: "Seat N of M" when the message came from a salon
                //         seat (seatNumber non-nil). M is the active seat
                //         count at the *current* salonConfig — close-enough
                //         for almost every real conversation (users rarely
                //         reconfigure mid-thread); a true historical M
                //         would require schema work.
                //   Host: "Host" when the message is the moderator/Host
                //         summary. Detected by the "📋 Summary:" prefix
                //         that runModeratorSummary applies — unambiguous
                //         and survives even if recordedByModel coincides
                //         with a regular seat's model.
                let seatText: String? = {
                    guard let seat = message.seatNumber else { return nil }
                    let totalSeats = chatViewModel.salonConfig.activeSeats.count
                    if totalSeats > 0 {
                        return "Seat \(seat) of \(totalSeats)"
                    }
                    return "Seat \(seat)"
                }()
                let hostText: String? = (!message.isFromUser && message.content.hasPrefix("\u{1F4CB} Summary:")) ? "Host" : nil
                let footerString = ([formattedDate, turnText, durationText, modelName, seatText, hostText].compactMap { $0 }).joined(separator: ", ")

                // Compression / truncation footer (Phase 6b, refined per Mark
                // 2026-05-16): when a segment was compressed or truncated
                // during this turn's prompt assembly, the metadata text and
                // the badge glyph render as a SINGLE inline Text — the
                // glyph flows directly after the last word with no
                // multi-line layout gap. The entire footer line becomes
                // tappable so the user can hit anywhere on the metadata
                // line to see what happened, not just the small icon.
                //
                // Glyph choice:
                //   rectangle.compress.vertical = intelligent compression
                //   scissors                     = truncation fallback
                //
                // No text label on the badge — the popover is the
                // explanation. The glyph is distinctive enough on its own.
                let hasCompression = !message.compressedSegments.isEmpty
                let hasTruncation = !message.truncatedSegments.isEmpty
                let hasBadge = hasCompression || hasTruncation

                HStack {
                    if hasBadge {
                        let glyphName = hasTruncation ? "scissors" : "rectangle.compress.vertical"
                        // Color the entire metadata line by the most-severe
                        // state: red when any segment was truncated, gray
                        // when only compression succeeded. The strong
                        // signal on truncation is intentional — the user
                        // should notice when intelligent compression failed
                        // and we had to cut content instead.
                        let lineColor: Color = hasTruncation ? .red : .gray
                        Button {
                            showingCompressionExplanation = true
                        } label: {
                            // Text interpolation with embedded Image (iOS 17+
                            // replacement for the deprecated `Text + Text`
                            // operator). Single color applied to the full
                            // attributed text — see lineColor reasoning above.
                            Text("\(footerString) \(Image(systemName: glyphName))")
                                .font(.caption2)
                                .foregroundColor(lineColor)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingCompressionExplanation,
                                 attachmentAnchor: .point(.center),
                                 arrowEdge: .top) {
                            CompressionExplanationView(
                                compressedSegments: message.compressedSegments,
                                truncatedSegments: message.truncatedSegments
                            )
                            .presentationCompactAdaptation(.popover)
                        }
                    } else {
                        Text(footerString)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                .transition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
    

    // Inline-details segments — the SAME breakdown, in the SAME order, that
    // the PromptDetailView sheet builds. Rendering these with each kind's
    // color (below) makes the inline view speak the identical color language
    // as the viewer: system prompt purple, temporal orange, memory/RAG green,
    // and so on. Mirrors the sheet's `segments` so the two never drift.
    // Display only — no data or prompt is changed.
    private var inlinePromptSegments: [PromptDetailSegment] {
        var result: [PromptDetailSegment] = []
        if let prompt = message.fullPromptUsed, !prompt.isEmpty {
            result.append(contentsOf: parsePromptSegments(fullPrompt: prompt))
        }
        if !recentHistory.isEmpty {
            let body = recentHistory.map { m in
                let speaker = m.isFromUser ? "User" : "Hal"
                return "[\(speaker)] \(m.content)"
            }.joined(separator: "\n\n")
            result.append(PromptDetailSegment(kind: .conversationHistory, content: body))
        }
        if let userMsg = precedingUserContent, !userMsg.isEmpty {
            result.append(PromptDetailSegment(kind: .userMessage, content: userMsg))
        }
        return result
    }

    private func buildDetailsShareText() -> String {
        var lines: [String] = []
        // Header line: turn number + model + (salon) seat / host attribution.
        // Mirrors the in-app footer so exported transcripts carry the same
        // attribution the user saw in the conversation view.
        var headerFields: [String] = ["turn \(actualTurnNumber)"]
        let modelName = ModelCatalogService.shared.getModel(byID: message.recordedByModel)?.displayName ?? message.recordedByModel
        if !message.isFromUser, !modelName.isEmpty {
            headerFields.append("model: \(modelName)")
        }
        if let seat = message.seatNumber {
            let totalSeats = chatViewModel.salonConfig.activeSeats.count
            headerFields.append(totalSeats > 0 ? "seat \(seat) of \(totalSeats)" : "seat \(seat)")
        }
        if !message.isFromUser, message.content.hasPrefix("\u{1F4CB} Summary:") {
            headerFields.append("role: Host")
        }
        lines.append("Assistant response (\(headerFields.joined(separator: ", "))):")
        lines.append(message.content)
        lines.append("")
        if let prompt = message.fullPromptUsed, !prompt.isEmpty {
            lines.append("━━ Full Prompt Used ━━")
            lines.append(prompt)
            lines.append("")
        }
        if let ctx = message.usedContextSnippets, !ctx.isEmpty {
            lines.append("━━ Context Snippets ━━")
            for (i, s) in ctx.enumerated() {
                let src = s.source
                let rel = String(format: "%.2f", s.relevance)
                lines.append("[\(i+1)] src=\(src) rel=\(rel)")
                lines.append(s.content)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(.init(message.content))
                        .font(.system(size: chatBodyPt))
                        .textSelection(.enabled)
                        .padding(.vertical, chatDensity.bubbleVPadding)
                        .padding(.horizontal, chatDensity.bubbleHPadding)
                        .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
                        .background(Color.gray.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .transition(.move(edge: .bottom))
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIPasteboard.general.string = chatViewModel.exportChatHistory()
                            } label: {
                                Label("Copy Thread", systemImage: "doc.on.doc.fill")
                            }
                            Button {
                                UIPasteboard.general.string = buildDetailsShareText()
                            } label: {
                                Label("Copy Message Detailed", systemImage: "doc.text.magnifyingglass")
                            }
                            Button {
                                UIPasteboard.general.string = chatViewModel.exportChatHistoryDetailed()
                            } label: {
                                Label("Copy Thread Detailed", systemImage: "doc.text.fill")
                            }
                        }
                    footerView
                }
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let thinking = message.thinking, !thinking.isEmpty {
                            ThinkingDisclosure(text: thinking, isStreaming: message.isPartial && message.content.isEmpty)
                                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                        }
                        if isStatusMessage {
                            Text(message.content)
                                .font(.system(size: chatBodyPt))
                                .lineSpacing(chatDensity.lineSpacing)
                                .italic()
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(.vertical, chatDensity.bubbleVPadding)
                                .padding(.horizontal, chatDensity.assistantHInset)
                                .frame(maxWidth: assistantMaxWidth, alignment: .leading)
                        } else {
                            MarkdownView(text: message.content,
                                         bodyPointSize: chatBodyPt,
                                         lineSpacing: chatDensity.lineSpacing)
                                .textSelection(.enabled)
                                .padding(.vertical, chatDensity.bubbleVPadding)
                                .padding(.horizontal, chatDensity.assistantHInset)
                                .frame(maxWidth: assistantMaxWidth, alignment: .leading)
                        }
                        if chatViewModel.showInlineDetails {
                            let segments = inlinePromptSegments
                            VStack(alignment: .leading, spacing: 4) {
                                if segments.isEmpty {
                                    // No captured prompt for this message — keep the
                                    // original plain-text details so nothing is lost.
                                    Text(buildDetailsShareText())
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    // Same sections as the viewer, each in its color.
                                    ForEach(segments) { segment in
                                        Text(segment.content)
                                            .font(.caption2)
                                            .foregroundColor(segment.kind.color)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(6)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(8)
                            .transition(.opacity)
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("Copy Message", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = chatViewModel.exportChatHistory()
                        } label: {
                            Label("Copy Thread", systemImage: "doc.on.doc.fill")
                        }
                        Button {
                            UIPasteboard.general.string = buildDetailsShareText()
                        } label: {
                            Label("Copy Message Detailed", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            UIPasteboard.general.string = chatViewModel.exportChatHistoryDetailed()
                        } label: {
                            Label("Copy Thread Detailed", systemImage: "doc.text.fill")
                        }
                        Divider()
                        // "View Details Inline" toggles the per-bubble
                        // inline detail expansion (footer metadata).
                        // The trailing "Inline" is the distinguishing
                        // word from "Prompt Details Viewer" below;
                        // pre-rename, the two items were "View Details"
                        // and "View Prompt Details" which read as
                        // near-duplicates in the menu. 2026-05-18.
                        Button {
                            chatViewModel.showInlineDetails.toggle()
                        } label: {
                            Label("View Details Inline", systemImage: "info.circle")
                        }
                        // "Prompt Details Viewer" opens the new
                        // color-coded, collapsible sheet
                        // (PromptDetailView.swift, Item 4 / 2026-05-17,
                        // parser collapse landed in e8ce4f4 /
                        // 2026-05-18). Distinct from inline details
                        // — this is the full sheet experience.
                        Button {
                            showingPromptDetail = true
                        } label: {
                            Label("Prompt Details Viewer", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .sheet(isPresented: $showingPromptDetail) {
                        PromptDetailView(
                            message: message,
                            precedingUserContent: precedingUserContent,
                            recentHistory: recentHistory
                        )
                    }
                    // Test hook: the harness can open this bubble's prompt-detail
                    // sheet by setting apiPromptDetailMessageID to this message's id
                    // (normally opened from the context menu, so not otherwise
                    // API-drivable). See SET_UI_STATE:promptdetail.
                    .onChange(of: chatViewModel.apiPromptDetailMessageID) { _, newID in
                        if !newID.isEmpty && newID == message.id.uuidString {
                            showingPromptDetail = true
                        }
                    }
                    // Match Hal's text: same left inset (assistantHInset) and same width
                    // frame, so the footer lines up flush under the start of his reply.
                    footerView
                        .padding(.horizontal, chatDensity.assistantHInset)
                        .frame(maxWidth: assistantMaxWidth, alignment: .leading)
                }
                Spacer()
            }
        }
        .padding(.horizontal, chatDensity.edgePadding)
        .padding(.vertical, chatDensity.rowVPadding)
        // No `.animation(value: message.content)` here on purpose: animating on
        // per-token content changes made every streaming line-wrap / markdown
        // reflow ANIMATE (0.1s) instead of snapping, which read as a visible
        // "jump and resettle" at line-ends (worst on markdown-heavy models).
        // Bubble insertion is still animated below (keyed on isPartial / id) —
        // just not per-token content growth.
        .animation(.interactiveSpring(response: 0.6,
                                      dampingFraction: 0.7,
                                      blendDuration: 0.3),
                   value: message.isPartial)
        .animation(.interactiveSpring(response: 0.6,
                                      dampingFraction: 0.7,
                                      blendDuration: 0.3),
                   value: message.id)
        .onAppear {
            if message.isPartial {
                print("HALDEBUG-UI: Displaying partial message bubble (turn \(actualTurnNumber))")
            }
            // Diagnostic for the "footer visible but text missing after reload"
            // bug. If we ever render a non-partial bubble with empty / whitespace-
            // only content while the footer still claims a real turn, log it.
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isPartial && trimmed.isEmpty {
                halLog("HALDEBUG-UI: ⚠️ Non-partial bubble rendered with empty content (turn \(actualTurnNumber), id \(message.id.uuidString.prefix(8)), isFromUser=\(message.isFromUser), recordedByModel=\(message.recordedByModel))")
            }
        }
        .onChange(of: message.isPartial) { _, newValue in
            if !newValue && message.content.count > 0 {
                print("HALDEBUG-UI: Message bubble completed - turn \(actualTurnNumber), \(message.content.count) characters")
            }
        }
        // Measure the bubble's actual container width via a clear
        // GeometryReader background — non-layout-impacting, reactive
        // to size changes including rotation. Feeds measuredContainerWidth,
        // which bubbleMaxWidth reads, which the three .frame(maxWidth:)
        // modifiers above reference. This is what makes chat bubbles
        // reflow correctly when the device rotates portrait↔landscape.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BubbleContainerWidthKey.self,
                                       value: proxy.size.width)
            }
        )
        .onPreferenceChange(BubbleContainerWidthKey.self) { newWidth in
            if newWidth > 0 && newWidth != measuredContainerWidth {
                measuredContainerWidth = newWidth
            }
        }
    }
}

// CompressionExplanationView — popover content for the footer badge.
// Per Mark's Phase 6b direction: "let's give them like a little tool tip
// or something that explains it... lead to greater transparency."
//
// Two distinct copy blocks: one for intelligent compression (the normal
// path), one for truncation fallback (the catastrophic failure path).
// Both can appear together if some segments compressed cleanly and
// others fell back during the same turn.
//
// Below the explanations: a list of segments that were affected, so the
// user can see *exactly* which parts of Hal's memory were touched. This
// is the "transparency as architecture" principle applied to the UI.
struct CompressionExplanationView: View {
    let compressedSegments: Set<PromptSegmentKind>
    let truncatedSegments: Set<PromptSegmentKind>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !compressedSegments.isEmpty {
                    Text("Memory condensed")
                        .font(.headline)
                    Text("The model you're using has a smaller context window than the size of Hal's full memory. To stay honest about everything Hal knows about you, Hal's full memory is preserved in the database, but for this turn it was condensed by the model itself to fit. Open Settings → Power User → Database to see Hal's full memory anytime.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !truncatedSegments.isEmpty {
                    if !compressedSegments.isEmpty {
                        Divider()
                    }
                    Text("Memory truncated")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text("The model couldn't condense part of Hal's memory in time (the LLM was unavailable, took too long, or the condensed result didn't pass verification). For this turn, that part was cut at the budget limit rather than intelligently distilled. Hal's full memory is preserved in the database. This only affects what the model saw for this single turn.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                let allAffected: [PromptSegmentKind] = Array(compressedSegments.union(truncatedSegments))
                    .sorted { $0.rawValue < $1.rawValue }
                if !allAffected.isEmpty {
                    Text("Affected this turn:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(allAffected, id: \.self) { kind in
                        let isTruncated = truncatedSegments.contains(kind)
                        HStack(spacing: 6) {
                            Image(systemName: isTruncated ? "scissors" : "rectangle.compress.vertical")
                                .foregroundColor(isTruncated ? .red : .secondary)
                                .font(.caption)
                            Text(kind.displayName)
                                .font(.caption)
                            if isTruncated {
                                Text("(truncated)")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            } else {
                                Text("(condensed)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(idealWidth: 340, maxWidth: 340,
               idealHeight: 320, maxHeight: 480)
    }
}

// TimerView
struct TimerView: View {
    let startDate: Date
    @State private var hasLoggedLongThinking = false
    var body: some View {
        TimelineView(.periodic(from: startDate, by: 0.5)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            if elapsed > 30.0 && !hasLoggedLongThinking {
                DispatchQueue.main.async {
                    print("HALDEBUG-MODEL: Long thinking time detected - \(String(format: "%.1f", elapsed)) seconds")
                    hasLoggedLongThinking = true
                }
            }
            return Text(String(format: "%.1f sec", max(0, elapsed)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
// ==== LEGO END: 55 ChatBubbleView & TimerView (Message UI Components) ====

// ==== LEGO START: 56 MarkdownView (Block-Level Markdown Renderer) ====

// MARK: - Markdown Block Renderer
// Parses markdown into typed blocks and renders each as a distinct SwiftUI view.
// Handles headers, lists, code blocks, and paragraphs. Inline styles (bold, italic,
// inline code) within each block are handled by AttributedString.
// Zero third-party dependencies.

private enum MDBlock {
    case heading(String, level: Int)
    case paragraph(String)
    case unorderedItem(String)
    case orderedItem(String, number: Int)
    case codeBlock(String)
}

struct MarkdownView: View {
    let text: String
    // Chat display appearance, passed down from ChatBubbleView. Defaults reproduce the
    // historical look (body ≈ .title3 at 20pt, line spacing 6). Headings scale with the
    // body via `sizeRatio` so their proportions hold at any chosen text size.
    var bodyPointSize: CGFloat = 20
    var lineSpacing: CGFloat = 6
    private var sizeRatio: CGFloat { bodyPointSize / 20.0 }

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Defensive fallback: parseBlocks returned nothing for non-empty input.
                // Should never happen in normal use, but if it does, render the raw text
                // so the user sees SOMETHING rather than empty space with just a footer.
                // This addresses the "footer visible but text missing after reload" report.
                Text(text)
                    .font(.system(size: bodyPointSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(.primary)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let s, let level):
            headingView(s, level: level)
        case .paragraph(let s):
            inlineText(s)
                .font(.system(size: bodyPointSize))
                .lineSpacing(lineSpacing)
                .foregroundColor(.primary)
        case .unorderedItem(let s):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2022}")
                    .font(.system(size: bodyPointSize))
                    .foregroundColor(.secondary)
                inlineText(s)
                    .font(.system(size: bodyPointSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(.primary)
            }
        case .orderedItem(let s, let number):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: bodyPointSize))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                inlineText(s)
                    .font(.system(size: bodyPointSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(.primary)
            }
        case .codeBlock(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(6)
        }
    }

    @ViewBuilder
    private func headingView(_ s: String, level: Int) -> some View {
        switch level {
        case 1:
            inlineText(s).font(.system(size: 22 * sizeRatio, weight: .bold)).foregroundColor(.primary).padding(.top, 4)
        case 2:
            inlineText(s).font(.system(size: 20 * sizeRatio, weight: .bold)).foregroundColor(.primary).padding(.top, 4)
        case 3:
            inlineText(s).font(.system(size: 17 * sizeRatio, weight: .semibold)).foregroundColor(.primary).padding(.top, 2)
        default:
            inlineText(s).font(.footnote.bold()).foregroundColor(.secondary)
        }
    }

    // Render a string with inline markdown (bold, italic, inline code, links).
    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    // Parse a markdown string into an ordered sequence of typed blocks.
    private func parseBlocks(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var codeAccum: [String]? = nil

        for line in source.components(separatedBy: "\n") {
            // Code fence toggle
            if line.hasPrefix("```") {
                if let acc = codeAccum {
                    blocks.append(.codeBlock(acc.joined(separator: "\n")))
                    codeAccum = nil
                } else {
                    codeAccum = []
                }
                continue
            }
            // Accumulate inside a code block
            if codeAccum != nil {
                codeAccum!.append(line)
                continue
            }

            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }

            // Headings: count leading # characters
            if t.first == "#" {
                let level = t.prefix(while: { $0 == "#" }).count
                let body = String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(body, level: min(level, 4)))
                continue
            }

            // Unordered list: starts with "- " or "* "
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                blocks.append(.unorderedItem(String(t.dropFirst(2))))
                continue
            }

            // Ordered list: starts with one or more digits followed by ". "
            let leadingDigits = t.prefix(while: { $0.isNumber })
            if !leadingDigits.isEmpty {
                let afterDigits = t.dropFirst(leadingDigits.count)
                if afterDigits.hasPrefix(". ") {
                    let number = Int(String(leadingDigits)) ?? 1
                    let body = String(afterDigits.dropFirst(2))
                    blocks.append(.orderedItem(body, number: number))
                    continue
                }
            }

            // Paragraph: merge consecutive non-blank, non-list lines (soft-wrap)
            if case .paragraph(let prev) = blocks.last {
                blocks[blocks.count - 1] = .paragraph(prev + " " + t)
            } else {
                blocks.append(.paragraph(t))
            }
        }

        // Flush unclosed code block
        if let acc = codeAccum {
            blocks.append(.codeBlock(acc.joined(separator: "\n")))
        }

        return blocks
    }
}

// ==== LEGO END: 56 MarkdownView (Block-Level Markdown Renderer) ====
