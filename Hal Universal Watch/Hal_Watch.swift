//
//  Hal_Watch.swift
//  Hal Universal Watch
//
//  Created by Mark Friedlander on 12/11/25.
//

// ==== LEGO START: 01 - Imports & Constants ====

import SwiftUI
import WatchConnectivity
import AVFoundation
import Combine
import WatchKit  // WKInterfaceDevice for haptic feedback on reply arrival

// ==== LEGO END: 01 - Imports & Constants ====



// ==== LEGO START: 02 - Watch App Entry Point ====

@main
struct HalWatchApp: App {

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

// ==== LEGO END: 02 - Watch App Entry Point ====



// ==== LEGO START: 03 - Connectivity â€“ WatchConnectivityManager ====

import WatchConnectivity
import Combine

class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {

    @Published var lastReceivedMessage: String = ""
    /// Mirrors `WCSession.default.isReachable`. Published so SwiftUI views
    /// can gate input on iPhone reachability per Mark's May-14 directive
    /// (Option G — real-time-or-fail). Updated on activation and via the
    /// system's `sessionReachabilityDidChange` callback.
    @Published var isReachable: Bool = false

    private var session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        guard let session = session else {
            print("[WatchConnectivity] WCSession unsupported")
            return
        }

        session.delegate = self
        session.activate()
        // sessionReachabilityDidChange doesn't fire on activation, only
        // on subsequent changes — so we have to seed isReachable from
        // the session's current state ourselves.
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }

        print("[WatchConnectivity] Session activated")
    }

    // -------------------------------------------------------------
    // MARK: - Send Text to iPhone
    // -------------------------------------------------------------
    //
    // Callers are expected to gate this on `isReachable == true`
    // (WatchRootView does so via Option G's reachability checks). The
    // guard inside is a belt-and-suspenders for the race where reachability
    // drops between the SwiftUI check and the actual sendMessage call.
    func send(text: String) {
        guard let session = session else {
            print("[WatchConnectivity] ERROR: No WCSession available")
            return
        }

        guard session.isReachable else {
            print("[WatchConnectivity] ERROR: iPhone not reachable at send time")
            return
        }

        let payload: [String: Any] = [
            "text": text,
            "source": "watch"
        ]

        // Fire and forget — the reply comes back as a separate WCSession
        // delivery (sendMessage or transferUserInfo from the iPhone) into
        // deliverReply below, not via this method's replyHandler.
        session.sendMessage(payload, replyHandler: nil) { error in
            print("[WatchConnectivity] ERROR sending: \(error.localizedDescription)")
        }

        print("[WatchConnectivity] SENT -> \(text)")
    }

    // -------------------------------------------------------------
    // MARK: - Receive Messages from iPhone
    // -------------------------------------------------------------
    //
    // Two delivery paths (matched on the iPhone side in HalWatchBridge.pushToWatch):
    //
    //   - didReceiveMessage  -> realtime sendMessage, fires immediately
    //                            when the Watch app is foregrounded and
    //                            reachable.
    //   - didReceiveUserInfo -> queued transferUserInfo, fires whenever the
    //                            Watch app next has runtime -- even if the
    //                            user let their wrist drop during generation.
    //
    // Both route through `deliverReply` so behavior is identical: update
    // lastReceivedMessage and buzz the wrist so the user notices even if
    // their screen had auto-dimmed.

    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any]) {
        deliverReply(from: message, path: "sendMessage")
    }

    func session(_ session: WCSession,
                 didReceiveUserInfo userInfo: [String : Any] = [:]) {
        deliverReply(from: userInfo, path: "transferUserInfo")
    }

    private func deliverReply(from payload: [String: Any], path: String) {
        DispatchQueue.main.async {
            guard let reply = payload["reply"] as? String, !reply.isEmpty else {
                print("[WatchConnectivity] Received \(path) payload without 'reply' field")
                return
            }
            self.lastReceivedMessage = reply
            print("[WatchConnectivity] RECEIVED via \(path): \(reply.prefix(80))")
            // Haptic moved to WatchRootView's .onReceive so it only fires
            // when the user is actively waiting for a reply (Option G).
            // Stale replies that land after the user dismissed / errored
            // out should not buzz the wrist — per Mark's "no useless pings"
            // principle.
        }
    }

    // -------------------------------------------------------------
    // MARK: - Required Delegate Stubs
    // -------------------------------------------------------------
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            print("[WatchConnectivity] Reachability changed: \(session.isReachable)")
        }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {

        if let error = error {
            print("[WatchConnectivity] Activation error: \(error.localizedDescription)")
        } else {
            print("[WatchConnectivity] Activation state: \(activationState.rawValue)")
        }
        // Reachability becomes meaningful only after activation completes;
        // publish the current value so SwiftUI views unblock from their
        // initial isReachable=false default.
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }
}

// ==== LEGO END: 03 - Connectivity â€“ WatchConnectivityManager ====



// ==== LEGO START: 04 - UI â€“ Root Container ====

enum WatchStage {
    case eyeIdle          // Crisp HAL eye, awaiting tap
    case inputActive      // Blurred eye with input UI on top
    case sending          // Blurred eye with spinner while Hal thinks
    case responseVisible  // Blurred eye with Hal's reply visible
    case errorVisible     // Blurred eye with an explicit error / unreachable message
}

/// What happened when the user finished interacting with the dictation
/// controller. Used by WatchInputView to tell WatchRootView what state
/// to transition into next.
enum WatchInputResult {
    case sent          // User dictated and we successfully called sendMessage
    case cancelled     // User dismissed the input controller without text
    case disconnected  // Reachability dropped between dictation and send
}

struct WatchRootView: View {

    @StateObject private var connectivity = WatchConnectivityManager()
    @State private var stage: WatchStage = .eyeIdle
    @State private var lastReply: String = ""
    @State private var errorMessage: String = ""
    @State private var sendingTimeoutTask: Task<Void, Never>? = nil

    // Maximum wait for a reply while in .sending. iPhone's
    // beginBackgroundTask budget is ~30s; we give a little headroom for
    // the reply transferUserInfo to land. If nothing arrives in 60s the
    // Watch shows a clear "didn't respond" error per Option G — never
    // a silent infinite hang.
    private static let sendingTimeoutSeconds: UInt64 = 60

    var body: some View {
        ZStack {
            // HAL Eye full-screen background
            Image("HalEye")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .blur(radius: stage == .eyeIdle ? 0 : 12)
                .opacity(stage == .eyeIdle ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.25), value: stage)
                .onTapGesture {
                    if stage == .eyeIdle {
                        beginInputIfReachable()
                    }
                }

            // Input UI overlay
            if stage == .inputActive {
                WatchInputView(
                    connectivity: connectivity,
                    onComplete: handleInputComplete
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Sending / thinking overlay
            if stage == .sending {
                WatchSendingOverlay()
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Response overlay
            if stage == .responseVisible {
                WatchResponseOverlay(text: lastReply) {
                    stage = .eyeIdle
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Error / unreachable overlay (Option G)
            if stage == .errorVisible {
                WatchErrorOverlay(message: errorMessage) {
                    stage = .eyeIdle
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
        // Listen for incoming replies. ONLY honor them when actively
        // waiting (.sending). Stale replies — landing after the user
        // dismissed, hit a timeout, or walked out of range — are dropped
        // silently. No useless wrist pings. (Mark's Option G principle.)
        .onReceive(connectivity.$lastReceivedMessage) { message in
            guard !message.isEmpty, stage == .sending else { return }
            sendingTimeoutTask?.cancel()
            lastReply = message
            stage = .responseVisible
            WKInterfaceDevice.current().play(.notification)
        }
        // Reachability dropping while we're waiting for a reply = walked
        // out of range. Cancel the message per Mark's directive.
        .onChange(of: connectivity.isReachable) { _, newValue in
            if !newValue && stage == .sending {
                sendingTimeoutTask?.cancel()
                errorMessage = "Hal moved out of range. Try again when you're nearby."
                stage = .errorVisible
            }
        }
    }

    // MARK: - Flow control

    /// Called when the user taps the idle eye. Gates entry into the
    /// dictation flow on iPhone reachability — if Hal isn't reachable, we
    /// say so immediately rather than letting the user dictate into a
    /// black hole.
    private func beginInputIfReachable() {
        if connectivity.isReachable {
            stage = .inputActive
        } else {
            errorMessage = "Hal isn't reachable right now. Open Hal on your iPhone, then try again."
            stage = .errorVisible
        }
    }

    /// Called by WatchInputView after the user finishes with the dictation
    /// controller. Branches on the result type — the input view re-checks
    /// reachability at send time so a drop between "tap eye" and "finish
    /// dictating" still surfaces honestly.
    private func handleInputComplete(_ result: WatchInputResult) {
        switch result {
        case .sent:
            stage = .sending
            startSendingTimeout()
        case .cancelled:
            stage = .eyeIdle
        case .disconnected:
            errorMessage = "Hal moved out of range. Try again when you're nearby."
            stage = .errorVisible
        }
    }

    /// 60-second safety net while .sending. If no reply arrives, surface
    /// a "didn't respond" error rather than an infinite spinner.
    private func startSendingTimeout() {
        sendingTimeoutTask?.cancel()
        sendingTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.sendingTimeoutSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if stage == .sending {
                    errorMessage = "Hal didn't respond. Try again."
                    stage = .errorVisible
                }
            }
        }
    }
}


// ==== LEGO END: 04 - UI â€“ Root Container ====



// ==== LEGO START: 05 - UI â€“ Input View ====

struct WatchInputView: View {
    @ObservedObject var connectivity: WatchConnectivityManager
    let onComplete: (WatchInputResult) -> Void

    var body: some View {
        Color.clear
            .onAppear {
                presentInputController()
            }
    }

    /// Present the dictation/Scribble/emoji input controller. The dismiss
    /// callback distinguishes three outcomes so WatchRootView can route
    /// correctly:
    ///   .cancelled    — user dismissed without text, or dictated empty
    ///   .disconnected — reachability dropped between dictation and send
    ///   .sent         — text was non-empty AND we successfully called send
    private func presentInputController() {
        WKExtension.shared().visibleInterfaceController?.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .allowEmoji
        ) { results in
            guard let results = results as? [String], let text = results.first else {
                onComplete(.cancelled)
                return
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onComplete(.cancelled)
                return
            }

            // Re-check reachability right before sending. The user may have
            // taken several seconds dictating — long enough for the iPhone
            // to slip out of range. Option G says: if we can't be real-time,
            // tell the user honestly, don't queue silently.
            guard connectivity.isReachable else {
                onComplete(.disconnected)
                return
            }

            connectivity.send(text: trimmed)
            onComplete(.sent)
        }
    }
}

// ==== LEGO END: 05 - UI â€“ Input View ====



// ==== LEGO START: 06 - UI â€“ Response Overlay ====

struct WatchResponseOverlay: View {
    let text: String
    let onDismiss: () -> Void

    // Dismiss now lives INSIDE the scroll content at the bottom of the
    // reply, instead of pinned to the screen. For short replies both
    // fit on screen at once; for long replies the user scrolls down
    // past the text to reach Dismiss. Trade: the button isn't always
    // visible, but the reply text isn't squeezed by it either. Mark's
    // May-14 feedback after the first hardware test.
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(text)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button("Dismiss") {
                    onDismiss()
                }
                .padding(.bottom, 4)
            }
            .padding()
        }
        .ignoresSafeArea()
    }
}

// ==== LEGO END: 06 - UI â€“ Response Overlay ====



// ==== LEGO START: 06.5 - UI - Sending Overlay ====

struct WatchSendingOverlay: View {
    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)

                Text("Hal is thinking…")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.9))
                Text("You can lower your wrist — Hal will buzz when ready.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
            .padding(12)
            .background(Color.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()
        }
        .ignoresSafeArea()
    }
}

// ==== LEGO START: 06.6 - UI - Error / Unreachable Overlay ====

/// Shown when:
///   - The user tapped the eye but the iPhone isn't reachable
///   - Reachability dropped while waiting for a reply (walked out of range)
///   - 60 seconds passed without a reply landing
///
/// Single overlay, parameterized by `message`, so all three cases share
/// the same dismissible UX. Tap "OK" to return to the idle eye. Per
/// Mark's Option G: real-time-or-fail-honestly. No silent queueing, no
/// false promises.
struct WatchErrorOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Button("OK") {
                    onDismiss()
                }
                .padding(.bottom, 4)
            }
            .padding()
        }
        .ignoresSafeArea()
    }
}

// ==== LEGO END: 06.6 - UI - Error / Unreachable Overlay ====

// ==== LEGO END: 06.5 - UI - Sending Overlay ====




// ==== LEGO START: 07 - Messaging Handlers ====

extension WatchConnectivityManager {
    // Additional logic later for handling errors, message types,
    // and clean routing as Hal's watch semantics evolve.
}

// ==== LEGO END: 07 - Messaging Handlers ====



// ==== LEGO START: 08 - Optional â€“ Hal Eye Animation (Empty Placeholder) ====

struct HalEyeView: View {
    var body: some View {
        // Placeholder for later animation.
        Circle()
            .frame(width: 20, height: 20)
            .opacity(0.2)
    }
}

// ==== LEGO END: 08 - Optional â€“ Hal Eye Animation ====
