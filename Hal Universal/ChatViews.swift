// ChatViews.swift
// Hal Universal
//
// The user-facing chat surface. Every SwiftUI View struct the user
// looks at when Hal is on screen — plus the app bootstrap scaffolding
// that puts iOSChatView on screen in the first place. Extracted from
// Hal.swift on 2026-05-26 as refactor #6 of the refactor-as-you-go
// sweep.
//
// Four LEGO blocks preserved below as this file's outline:
//
//   LEGO 09   — App bootstrap. `HistoricalContext` value type,
//               `HalAppDelegate` (UIApplicationDelegate handling
//               background-URLSession completion + watch-bridge
//               bootstrap + embedding warm-up + MaintenanceTasks.
//               runAtLaunch), `@main Hal10000App` (StateObject wiring
//               for ChatViewModel / DocumentImportManager /
//               MLXModelDownloader and the WindowGroup), and the
//               primary `iOSChatView` chat surface. iOSChatView holds
//               the ScrollViewReader + ForEach(messages) + composer
//               and every .sheet presentation route (settings, thread
//               panel, document picker, API-driven nav surfaces).
//
//   LEGO 09.5 — `ThreadPanelView`. Slide-out hamburger panel listing
//               all conversation threads, most recent first. New-
//               thread button, thread switching, swipe-to-delete with
//               confirmation, "Reset Thread" semantics that special-
//               case the currently-active thread.
//
//   LEGO 13   — Chat bubble rendering. `BubbleContainerWidthKey`
//               PreferenceKey (the GeometryReader-based fix for
//               rotation reflow), `ChatBubbleView` (the per-message
//               bubble with user/assistant differentiation, partial-
//               message timer, footer metadata, compression/truncation
//               badge popover, context-menu actions for copy/share/
//               inline-detail toggle, and PromptDetailView sheet
//               trigger), `CompressionExplanationView` (popover
//               content for the footer badge), and `TimerView`
//               (TimelineView-based generation-time indicator).
//
//   LEGO 13.5 — `MarkdownView`. Zero-dependency block-level markdown
//               renderer. `MDBlock` private enum + parser + per-block
//               SwiftUI view dispatch. Handles headers, ordered/
//               unordered lists, fenced code blocks, paragraphs;
//               inline styles (bold, italic, inline code, links) via
//               AttributedString.
//
// Why one file: all four are user-facing UI surfaces in the same
// conceptual area ("the chat screen the user looks at, plus what
// gets it on screen at launch"). They share helper sub-views and
// EnvironmentObject bindings; the @main entry point, the chat shell,
// the thread panel, the bubble renderer, and the markdown renderer
// all live on the same code path that runs every time a user opens
// the app. Splitting them would create a synthetic 2-3 file unit with
// no reduction in coupling.
//
// Coupling profile (clean — recon 2026-05-26):
//   - All ChatViewModel access is surface-level: reads of @Published
//     properties (messages, threads, conversationId, currentMessage,
//     isSendingMessage, showingSettings/showingThreadPanel/showing
//     DocumentPicker, apiNav* sheet flags, salonConfig.activeSeats,
//     showInlineDetails, messagesVersion), calls into explicit
//     entry points (sendMessage, startNewConversation, switchToThread,
//     loadThreads, exportChatHistory, exportChatHistoryDetailed), and
//     UI-state toggle (showInlineDetails.toggle from a context menu).
//   - Single reach-through: ThreadPanelView's resetThread calls
//     chatViewModel.memoryStore.deleteThread(id:) — preserved as-is
//     because going through ChatViewModel keeps thread-lifecycle
//     observers wired correctly.
//   - No mid-flow state access anywhere. Bug diagnosis path is
//     unchanged from pre-extraction.
//
// Cosmetic fix applied during the lift: LEGO 13's contents were
// indented 4 spaces for no structural reason (orphan indentation from
// a long-ago refactor that removed an outer wrapper without
// unindenting). Stripped during the cut. LEGO 13.5 was at proper
// indentation already.
//
// Known follow-up (deferred): `HistoricalContext` is logically a
// MemoryStore concept (carries conversationCount, relevantConversations,
// contextSnippets, relevanceScores) that happens to be defined in
// LEGO 09 for historical reasons. Used by
// `MemoryStore.currentHistoricalContext` and one ChatBubbleView writer.
// Left here for now to keep the LEGO 09 unit intact; could move to
// MemoryStore eventually as a small targeted cleanup.
//
// Standing rules followed here:
//   - LEGO markers preserved verbatim from Hal.swift so the numbering
//     chain still reads end-to-end through Hal_Source.txt.
//   - Comments throughout the body are evergreen — they explain why
//     the code is shaped the way it is, including the screenWidth
//     scene-resolution history, the rotation-reflow PreferenceKey
//     fix, and the post-May-17 scroll behavior (single rule: user
//     message scrolls to top on send, then user is in control).

import Foundation
import SwiftUI
import Combine
import UIKit

// ==== LEGO START: 09 App Entry & iOSChatView (UI Shell) ====


// MARK: - HistoricalContext (from Hal10000App.swift)
struct HistoricalContext {
    let conversationCount: Int
    let relevantConversations: Int
    let contextSnippets: [String]
    let relevanceScores: [Double]
    let totalTokens: Int
}

// MARK: - App Entry Point (for iOS)
// MARK: - App Delegate (background URLSession dispatch + Watch bridge bootstrap)
//
// SwiftUI's @main App lifecycle doesn't directly expose UIKit AppDelegate
// methods like `application:didFinishLaunchingWithOptions:` and
// `application:handleEventsForBackgroundURLSession:completionHandler:`.
// `UIApplicationDelegateAdaptor` (below) bridges UIKit's AppDelegate
// methods into SwiftUI's App lifecycle.
//
// Two responsibilities live here:
//
//  1. Background URLSession completion dispatch — iOS calls
//     handleEventsForBackgroundURLSession when it wakes the app to deliver
//     completion events for a background download (used by the model
//     downloader so downloads survive app suspension).
//
//  2. HalWatchBridge bootstrap — instantiate the WCSessionDelegate at
//     didFinishLaunchingWithOptions so the bridge is wired even when iOS
//     cold-launches the app in the background (in response to a Watch
//     message arriving while the app was never opened, or was suspended
//     long enough to be terminated). Previously the bridge was created
//     in iOSChatView.onAppear, which only fires once the chat view comes
//     onto screen — useless for the actual Watch use case where the
//     iPhone is in someone's pocket and the chat view never appears.
final class HalAppDelegate: NSObject, UIApplicationDelegate {

    // Strong reference so the bridge (and its WCSession.default delegate
    // registration) survives for the lifetime of the process.
    private var watchBridge: HalWatchBridge?

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

        // Build the bridge against the shared VM singleton. Touching
        // ChatViewModel.shared here triggers its lazy `static let` init —
        // happens once, on the main thread, exactly when we need it.
        // The bridge constructor then calls WCSession.activate() so the
        // session is ready for incoming Watch messages before any view
        // body has run.
        watchBridge = HalWatchBridge(chatViewModel: ChatViewModel.shared)
        halLog("HALDEBUG-WATCH: AppDelegate bootstrapped HalWatchBridge at didFinishLaunchingWithOptions (cold-launch ready).")

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
    // Use the shared singleton so the AppDelegate-created bridge talks
    // to the same VM instance the UI is bound to. @StateObject wrapping
    // a singleton works correctly — the wrapper just observes the same
    // object across re-renders without trying to recreate it (same
    // pattern as DocumentImportManager.shared / MLXModelDownloader.shared
    // below).
    @StateObject private var chatViewModel = ChatViewModel.shared
    @StateObject private var documentImportManager = DocumentImportManager.shared
    @StateObject private var mlxDownloader = MLXModelDownloader.shared // Inject MLXModelDownloader
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
    // Set when the user taps "Model Library" in the privacy popover; consumed
    // in the popover's onDisappear so the sheet presents only AFTER the popover
    // is fully gone (a popover + sheet can't present at once — same race as the
    // download disclosure sheet; .popover has no onDismiss, hence onDisappear).
    @State private var pendingModelLibraryNav = false
    @State private var scrollToBottomTrigger = UUID()
    // Sheet flags moved to ChatViewModel.showingSettings / showingThreadPanel /
    // showingDocumentPicker so the LocalAPIServer can read them via GET_UI_STATE.
    @FocusState private var isInputFocused: Bool // NEW: Track text field focus
    // watchBridge previously lived here as @State; moved to HalAppDelegate
    // so it survives the case where iOSChatView never appears (background
    // cold-launch via Watch message).
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
            .navigationTitle(conversationTitle)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        chatViewModel.showingThreadPanel = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                // Privacy lock — sits just left of the gear (declared first in
                // the trailing group). Monochrome outline glyph to match the
                // gearshape. Tap opens a plain-language explanation of the
                // current state. See PrivacyMonitor.swift.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingPrivacyPopover = true
                    } label: {
                        Image(systemName: isPrivacyLocked ? "lock" : "lock.open")
                    }
                    .popover(isPresented: $showingPrivacyPopover) {
                        PrivacyLockPopover(
                            isLocked: isPrivacyLocked,
                            modelName: chatViewModel.selectedModel.displayName
                        ) {
                            // Record intent + dismiss the popover; the actual
                            // Model Library sheet is presented from onDisappear
                            // below, once the popover is fully gone.
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
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        chatViewModel.showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
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
        }
    }

    // MARK: - Conversation Title (Title Bar)
    // Thread title sourced from the threads table via chatViewModel.threads.
    // Falls back to "Hal" for empty threads (e.g., brand new conversation before first message).
    private var conversationTitle: String {
        chatViewModel.threads.first(where: { $0.id == chatViewModel.conversationId })?.title ?? "Hal"
    }

    /// Whether the privacy lock reads "locked" (no data can leave the device)
    /// right now. Recomputed on every render — because it reads @Published
    /// state (the active model, the network monitor, and the salon config),
    /// SwiftUI re-renders the toolbar the instant any of them changes, so the
    /// glyph flips live on a model switch or an Airplane-Mode toggle. The pure
    /// decision lives in PrivacyMonitor.isLocked; here we just resolve each
    /// active salon seat's source (unknown → .appleFoundation, the
    /// conservative cloud-capable assumption) and hand it the inputs.
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


// ==== LEGO END: 09 App Entry & iOSChatView (UI Shell) ====


// ==== LEGO START: 09.5 ThreadPanelView ====

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

// ==== LEGO END: 09.5 ThreadPanelView ====


// ==== LEGO START: 13 ChatBubbleView & TimerView (Message UI Components) ====

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

// MARK: - ChatBubbleView (from Hal10000App.swift for consistent UI)
struct ChatBubbleView: View {
    let message: ChatMessage
    let messageIndex: Int
    @EnvironmentObject var chatViewModel: ChatViewModel
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
        VStack(alignment: .trailing, spacing: 2) {
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
                        .font(.title3)
                        .textSelection(.enabled)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
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
                        if isStatusMessage {
                            Text(message.content)
                                .font(.title3)
                                .lineSpacing(6)
                                .italic()
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                        } else {
                            MarkdownView(text: message.content)
                                .textSelection(.enabled)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                        }
                        if chatViewModel.showInlineDetails {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(buildDetailsShareText())
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(6)
                                    .background(Color.gray.opacity(0.15))
                                    .cornerRadius(8)
                            }
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
                    footerView
                }
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
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
                    Text("The model you're using has a smaller context window than the size of Hal's full memory. To stay honest about everything Hal knows about you, Hal's full memory is preserved in the database — but for this turn it was condensed by the model itself to fit. Open Settings → Power User → Database to see Hal's full memory anytime.")
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
                    Text("The model couldn't condense part of Hal's memory in time (the LLM was unavailable, took too long, or the condensed result didn't pass verification). For this turn, that part was cut at the budget limit rather than intelligently distilled. Hal's full memory is preserved in the database — this only affects what the model saw for this single turn.")
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
// ==== LEGO END: 13 ChatBubbleView & TimerView (Message UI Components) ====

// ==== LEGO START: 13.5 MarkdownView (Block-Level Markdown Renderer) ====

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

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Defensive fallback: parseBlocks returned nothing for non-empty input.
                // Should never happen in normal use, but if it does, render the raw text
                // so the user sees SOMETHING rather than empty space with just a footer.
                // This addresses the "footer visible but text missing after reload" report.
                Text(text)
                    .font(.title3)
                    .lineSpacing(6)
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
                .font(.title3)
                .lineSpacing(6)
                .foregroundColor(.primary)
        case .unorderedItem(let s):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2022}")
                    .font(.title3)
                    .foregroundColor(.secondary)
                inlineText(s)
                    .font(.title3)
                    .lineSpacing(5)
                    .foregroundColor(.primary)
            }
        case .orderedItem(let s, let number):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                inlineText(s)
                    .font(.title3)
                    .lineSpacing(5)
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
            inlineText(s).font(.title2.bold()).foregroundColor(.primary).padding(.top, 4)
        case 2:
            inlineText(s).font(.title3.bold()).foregroundColor(.primary).padding(.top, 4)
        case 3:
            inlineText(s).font(.headline).foregroundColor(.primary).padding(.top, 2)
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

// ==== LEGO END: 13.5 MarkdownView (Block-Level Markdown Renderer) ====
