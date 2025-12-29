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



// ==== LEGO START: 03 - Connectivity – WatchConnectivityManager ====

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

        session.sendMessage(payload, replyHandler: { [weak self] reply in
            // Handle Hal's response from iPhone
            DispatchQueue.main.async {
                if let replyText = reply["reply"] as? String {
                    self?.lastReceivedMessage = replyText
                    print("[WatchConnectivity] RECEIVED REPLY ← \(replyText)")
                } else {
                    print("[WatchConnectivity] Reply missing 'reply' field")
                }
            }
        }) { error in
            print("[WatchConnectivity] ERROR sending: \(error.localizedDescription)")
        }

        print("[WatchConnectivity] SENT → \(text)")
    }

    // -------------------------------------------------------------
    // MARK: - Receive Messages from iPhone
    // -------------------------------------------------------------
    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any]) {

        DispatchQueue.main.async {
            if let reply = message["reply"] as? String {
                self.lastReceivedMessage = reply
                print("[WatchConnectivity] RECEIVED ← \(reply)")
            } else {
                print("[WatchConnectivity] Received message without 'reply' field")
            }
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

// ==== LEGO END: 03 - Connectivity – WatchConnectivityManager ====



// ==== LEGO START: 04 - UI – Root Container ====

enum WatchStage {
    case eyeIdle          // Crisp HAL eye, awaiting tap
    case inputActive      // Blurred eye with input UI on top
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
                    stage = .eyeIdle      // fade back to crisp eye
                })
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


// ==== LEGO END: 04 - UI – Root Container ====



// ==== LEGO START: 05 - UI – Input View ====

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
            
            // Send to Hal
            connectivity.send(text: trimmed)
            onSend()
        }
    }
}

// ==== LEGO END: 05 - UI – Input View ====



// ==== LEGO START: 06 - UI – Response Overlay ====

struct WatchResponseOverlay: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()

            ScrollView {
                Text(text)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()

            Spacer(minLength: 20)

            Button("Dismiss") {
                onDismiss()
            }
            .padding(.bottom, 20)
        }
        .ignoresSafeArea()
    }
}

// ==== LEGO END: 06 - UI – Response Overlay ====



// ==== LEGO START: 07 - Messaging Handlers ====

extension WatchConnectivityManager {
    // Additional logic later for handling errors, message types,
    // and clean routing as Hal's watch semantics evolve.
}

// ==== LEGO END: 07 - Messaging Handlers ====



// ==== LEGO START: 08 - Optional – Hal Eye Animation (Empty Placeholder) ====

struct HalEyeView: View {
    var body: some View {
        // Placeholder for later animation.
        Circle()
            .frame(width: 20, height: 20)
            .opacity(0.2)
    }
}

// ==== LEGO END: 08 - Optional – Hal Eye Animation ====

