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

        print("[WatchConnectivity] Session activated")
    }

    // -------------------------------------------------------------
    // MARK: - Send Text to iPhone
    // -------------------------------------------------------------
    func send(text: String) {
        guard let session = session else {
            print("[WatchConnectivity] ERROR: No WCSession available")
            return
        }

        guard session.isReachable else {
            print("[WatchConnectivity] ERROR: iPhone not reachable")
            return
        }

        let payload: [String: Any] = [
            "text": text,
            "source": "watch"
        ]

        // Fire and forget - response will be pushed back by iPhone separately
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
            // Haptic so the user notices even if their wrist had dropped or
            // the screen had auto-dimmed during a slow generation. The Watch
            // app doesn't time out client-side, but the screen does -- and a
            // buzz is the only reliable signal that the reply arrived.
            WKInterfaceDevice.current().play(.notification)
        }
    }

    // -------------------------------------------------------------
    // MARK: - Required Delegate Stubs
    // -------------------------------------------------------------
    func sessionReachabilityDidChange(_ session: WCSession) {
        print("[WatchConnectivity] Reachability changed: \(session.isReachable)")
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {

        if let error = error {
            print("[WatchConnectivity] Activation error: \(error.localizedDescription)")
        } else {
            print("[WatchConnectivity] Activation state: \(activationState.rawValue)")
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
}

struct WatchRootView: View {

    @StateObject private var connectivity = WatchConnectivityManager()
    @State private var stage: WatchStage = .eyeIdle
    @State private var lastReply: String = ""

    var body: some View {
        ZStack {
            // HAL Eye full-screen background
            Image("HalEye")
                .resizable()
                .scaledToFit()                                        // FIXED: Changed from scaledToFill to scaledToFit for proper centering
                .frame(maxWidth: .infinity, maxHeight: .infinity)    // FIXED: Added explicit frame to ensure centering
                .ignoresSafeArea()
                .blur(radius: stage == .eyeIdle ? 0 : 12)
                .opacity(stage == .eyeIdle ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.25), value: stage)
                .onTapGesture {
                    if stage == .eyeIdle {
                        stage = .inputActive
                    }
                }

            // Input UI overlay
            if stage == .inputActive {
                WatchInputView(connectivity: connectivity, onSend: {
                    stage = .sending
                })
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Sending/thinking overlay
            if stage == .sending {
                WatchSendingOverlay()
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Response overlay
            if stage == .responseVisible {
                WatchResponseOverlay(text: lastReply) {
                    stage = .eyeIdle      // tap to dismiss reply
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
        // Listen for incoming responses
        .onReceive(connectivity.$lastReceivedMessage) { message in
            guard !message.isEmpty else { return }
            lastReply = message
            stage = .responseVisible
        }
    }
}


// ==== LEGO END: 04 - UI â€“ Root Container ====



// ==== LEGO START: 05 - UI â€“ Input View ====

struct WatchInputView: View {
    @ObservedObject var connectivity: WatchConnectivityManager
    let onSend: () -> Void

    var body: some View {
        Color.clear
            .onAppear {
                // Trigger input controller immediately when this view appears
                presentInputController()
            }
    }
    
    // Present the text input controller with all input methods
    private func presentInputController() {
        WKExtension.shared().visibleInterfaceController?.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .allowEmoji
        ) { results in
            guard let results = results as? [String], let text = results.first else {
                // User cancelled - go back to eye
                onSend()
                return
            }
            
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onSend()
                return
            }
            
            // Send to Hal and transition to thinking state
            connectivity.send(text: trimmed)
            onSend()
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
