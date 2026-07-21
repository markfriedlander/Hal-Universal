// PrivacyMonitor.swift
// Hal Universal
//
// The privacy lock indicator's engine and UI. Surfaces, in the chat toolbar,
// whether Hal is currently in a state where data could leave the device, so the
// user can see it at a glance.
//
// THE HONEST LINE (Mark, 2026-07-19): a LOCAL MLX model runs entirely on the
// device. Nothing you type, and nothing Hal generates, ever leaves it. Apple
// Intelligence is Apple's own system, and only Apple decides when things are
// processed in the cloud, so while the device is online we CANNOT guarantee an
// Apple Intelligence request stays on-device. We don't assert that it IS sent to
// the cloud, only that it's possible, and we can't guarantee it isn't.
//
// So the lock is CLOSED (private) on a local model, or with no network, and OPEN
// (cloud possible) on Apple Intelligence with a network available.
// (This reverts a 2026-07-18 change that claimed Apple Intelligence is on-device
// only. That was an unverified inference, not a fact; see HISTORY 2026-07-19.
// Apple's documentation is incomplete on the point, so we hold the conservative
// line rather than claim certainty we don't have.)
//
// Three pieces live here:
//   1. `PrivacyMonitor`, an ObservableObject wrapping `NWPathMonitor`. Its only
//      published state is `isNetworkAvailable`. It defaults to `false` (locked is
//      the safe default) until the first network path arrives, then flips within
//      ~1s of any change.
//   2. `PrivacyMonitor.isLocked(...)`, a PURE, testable function holding the
//      lock/unlock truth table. Kept free of catalog/UI dependencies so the logic
//      can be reasoned about (and unit-tested) in isolation; the caller resolves
//      salon seat sources and passes them in.
//   3. `PrivacyLockPopover`, the small explain-yourself popover shown on tap.
//
// The glyph (lock / lock.open) and the ToolbarItem live in ChatViews.swift's
// iOSChatView, computed live from the active model + this monitor's network state
// + the salon config, so it updates the instant the user switches models or
// toggles Airplane Mode.

import SwiftUI
import Network
import Combine

// ==== LEGO START: 41 Privacy Lock (Network Monitor, Lock Truth Table, Popover) ====

/// Watches the device's network reachability for the privacy lock indicator.
/// A single shared instance is started once at app launch.
final class PrivacyMonitor: ObservableObject {
    static let shared = PrivacyMonitor()

    /// True when a usable network path exists (Wi-Fi, cellular, wired, or VPN).
    /// Drives the lock: with a network up and Apple Intelligence active, we can't
    /// guarantee on-device processing, so the lock opens. Starts `false` (the safe
    /// default, locked) until the first `NWPathMonitor` update lands, so we never
    /// briefly claim "private" before we actually know.
    @Published private(set) var isNetworkAvailable: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.MarkFriedlander.Hal.PrivacyMonitor")
    private var started = false

    private init() {}

    /// Begin monitoring. Idempotent, safe to call more than once. Call once at app
    /// launch (see Hal10000App.init).
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // `.satisfied` means a usable path exists. VPN reports satisfied (it IS
            // a usable, cloud-capable path, correctly treated as network-available).
            // `.unsatisfied` / `.requiresConnection` (Airplane Mode, Wi-Fi up but
            // unreachable, cellular off) means not available, so the lock closes.
            let available = (path.status == .satisfied)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isNetworkAvailable != available {
                    self.isNetworkAvailable = available
                }
            }
        }
        monitor.start(queue: queue)
    }

    // MARK: - Lock decision (pure truth table)

    /// The lock/unlock decision, as a pure function of the inputs. See the honest
    /// line at the top of this file. `salonSeatSources` is the resolved
    /// `ModelSource` of each ACTIVE salon seat (the caller looks these up; an
    /// unresolvable seat is passed as `.appleFoundation`, the conservative,
    /// cloud-possible assumption, so we never falsely claim "private").
    ///
    /// Returns `true` = locked (a local model, or no network, nothing leaves the
    /// device), `false` = unlocked (Apple Intelligence active with a network up, we
    /// can't guarantee it stays on-device).
    static func isLocked(
        activeModelSource: ModelSource,
        networkAvailable: Bool,
        salonEnabled: Bool,
        salonSeatSources: [ModelSource]
    ) -> Bool {
        // No network means nothing can leave the device, whatever the model is.
        guard networkAvailable else { return true }

        // Network is up. In a salon, ANY Apple Intelligence seat means we can't
        // guarantee on-device, so it's locked only if every active seat is a local
        // model.
        if salonEnabled && !salonSeatSources.isEmpty {
            return salonSeatSources.allSatisfy { $0 == .mlx }
        }

        // Single-model path.
        switch activeModelSource {
        case .mlx:
            return true                 // local model, entirely on-device
        case .appleFoundation:
            return false                // Apple Intelligence + network, can't guarantee on-device
        }
    }

}


// MARK: - PrivacyLockPopover (tap explanation)

/// The small popover shown when the user taps the lock. Explains the current
/// state in plain language and offers a one-tap jump to the Model Library. The
/// locked state just reassures; the unlocked state is where the user needs
/// actionable detail, so that's where the explanation carries weight.
struct PrivacyLockPopover: View {
    let isLocked: Bool
    /// Invoked when the user taps "Model Library", the caller dismisses the
    /// popover and presents the library.
    let onOpenModelLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isLocked ? "lock" : "lock.open")
                Text(isLocked ? "On-device" : "Cloud possible")
                    .fontWeight(.semibold)
            }
            .font(.headline)

            Text(explanation)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onOpenModelLibrary) {
                HStack(spacing: 4) {
                    Text("Model Library")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var explanation: String {
        if isLocked {
            return "Nothing leaves your device right now."
        } else {
            return "Apple Intelligence is Apple's own system, and only Apple decides when things are processed in the cloud. To guarantee private, on-device-only behavior, choose a local model or shut off all networks."
        }
    }
}

// ==== LEGO END: 41 Privacy Lock (Network Monitor, Lock Truth Table, Popover) ====
