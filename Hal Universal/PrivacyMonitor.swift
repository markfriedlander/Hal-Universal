// PrivacyMonitor.swift
// Hal Universal
//
// The privacy lock indicator's engine + UI, added in v2.1. Surfaces — in the
// chat toolbar — whether Hal is currently operating in a state where data
// *could* leave the device, so the user can see it at a glance and choose.
// This operationalizes the standing WWDC26 principle: "PCC is the user's
// choice via Airplane Mode; we don't block Apple's routing, we make the state
// visible." See NEXT.md → "Privacy Lock indicator" for the full design.
//
// Three pieces live here:
//   1. `PrivacyMonitor` — an ObservableObject wrapping `NWPathMonitor`. Its
//      only published state is `isNetworkAvailable`. It defaults to `false`
//      (locked-is-the-safe-default) until the first network path arrives,
//      then flips within ~1s of any change.
//   2. `PrivacyMonitor.isLocked(...)` — a PURE, testable function holding the
//      lock/unlock truth table. Kept free of catalog/UI dependencies so the
//      logic can be reasoned about (and unit-tested) in isolation; the caller
//      resolves salon seat sources and passes them in.
//   3. `PrivacyLockPopover` — the small explain-yourself popover shown on tap.
//
// The glyph itself (lock / lock.open) and the ToolbarItem live in
// ChatViews.swift's iOSChatView, computed live from the active model + this
// monitor's network state + the salon config, so it updates the instant the
// user switches models or toggles Airplane Mode.

import SwiftUI
import Network
import Combine

// ========== BLOCK PM.1: PrivacyMonitor (network path) - START ==========

/// Watches the device's network reachability for the privacy lock indicator.
/// A single shared instance is started once at app launch.
final class PrivacyMonitor: ObservableObject {
    static let shared = PrivacyMonitor()

    /// True when a usable network path exists (Wi-Fi, cellular, wired, or VPN).
    /// Starts `false` so the lock reads "locked" (the safe default) until the
    /// first `NWPathMonitor` update lands — we never want to briefly claim
    /// "cloud possible" before we actually know, nor briefly claim "private"
    /// when we don't yet know. Locked-until-known is the honest default.
    @Published private(set) var isNetworkAvailable: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.MarkFriedlander.Hal.PrivacyMonitor")
    private var started = false

    private init() {}

    /// Begin monitoring. Idempotent — safe to call more than once. Call once
    /// at app launch (see Hal10000App.init).
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // `.satisfied` means a usable path exists. VPN reports satisfied
            // (it IS a usable, cloud-capable path — correctly treated as
            // network-available). `.unsatisfied` / `.requiresConnection`
            // (Airplane Mode, Wi-Fi up but unreachable, cellular off) → not
            // available → the lock closes.
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

    // ========== BLOCK PM.2: lock decision (pure truth table) - START ==========

    /// The lock/unlock decision, as a pure function of the inputs. See the
    /// truth table in NEXT.md. `salonSeatSources` is the resolved `ModelSource`
    /// of each ACTIVE salon seat (the caller looks these up; an unresolvable
    /// seat should be passed as `.appleFoundation` — the conservative,
    /// cloud-capable assumption, so we never falsely claim "private").
    ///
    /// Returns `true` = locked (no data can leave), `false` = unlocked
    /// (a cloud-capable path is active).
    static func isLocked(
        activeModelSource: ModelSource,
        networkAvailable: Bool,
        salonEnabled: Bool,
        salonSeatSources: [ModelSource]
    ) -> Bool {
        // No network → nothing can leave the device, whatever the model is.
        guard networkAvailable else { return true }

        // Network is up. In a salon, ANY cloud-capable (non-MLX) active seat
        // unlocks the indicator — worst-case attribution. Locked only if every
        // active seat runs on-device.
        if salonEnabled && !salonSeatSources.isEmpty {
            return salonSeatSources.allSatisfy { $0 == .mlx }
        }

        // Single-model path.
        switch activeModelSource {
        case .mlx:
            return true                 // local model → always on-device
        case .appleFoundation:
            return false                // AFM + network → PCC possible → unlocked
        }
    }

    // ========== BLOCK PM.2: lock decision (pure truth table) - END ==========
}

// ========== BLOCK PM.1: PrivacyMonitor (network path) - END ==========

// ========== BLOCK PM.3: PrivacyLockPopover (tap explanation) - START ==========

/// The small popover shown when the user taps the lock. Explains the current
/// state in plain language and offers a one-tap jump to the Model Library.
struct PrivacyLockPopover: View {
    let isLocked: Bool
    let modelName: String
    /// Invoked when the user taps "Model Library" — the caller dismisses the
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
            return "Hal is fully on-device right now. The active model (\(modelName)) runs on this iPhone — no request you send and no response you receive leaves your phone."
        } else {
            return "Apple Intelligence may route some queries to Apple's Private Cloud Compute. To guarantee fully on-device operation, switch to Airplane Mode or pick a downloaded local model from the Model Library."
        }
    }
}

// ========== BLOCK PM.3: PrivacyLockPopover (tap explanation) - END ==========
