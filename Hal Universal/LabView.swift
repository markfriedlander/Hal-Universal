//
//  LabView.swift
//  Hal Universal
//
//  The Lab: Hal's developer / power-user tools, gathered behind one door reached from the
//  main Settings screen ("The Lab" row in ActionsView, block 48). Graduated out of DEBUG
//  2026-07-28 to ship as a user-facing opt-in. This file is the whole Lab UI: the LabView
//  shell plus the Developer API + hal-CLI installer section (moved here from PowerUserView so
//  the Lab is one cohesive module). RoboRunner's editor lives in RoboRunner.swift and is
//  presented from here.
//

import SwiftUI
import UIKit   // UIPasteboard for the copy-to-clipboard rows

// ==== LEGO START: 62 LabView (The Lab UI) ====

/// The Lab screen. Gathers Hal's power tools behind one door: RoboRunner (on-device
/// automation scripting) and the local API + hal-command installer. Presented as a sheet
/// from the "The Lab" row on the main Settings screen. A one-time "here be dragons" notice
/// (a follow-up) will gate first entry; today the Lab defaults to Safe mode either way.
struct LabView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var showingRoboEditor = false

    // One-time "here be dragons" notice on first entry to The Lab. Persisted, so it shows
    // once and never again after the user acknowledges. Pairs with the Lab defaulting to
    // Safe mode: the notice warns, Safe mode enforces.
    @AppStorage("lab.dragonsAcknowledged") private var dragonsAcknowledged = false
    @State private var showDragons = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        showingRoboEditor = true
                    } label: {
                        HStack {
                            Label("RoboRunner", systemImage: "wrench.and.screwdriver")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Label("Automation", systemImage: "robotic.vacuum.fill")
                } footer: {
                    Text("Write and run on-device RoboRunner scripts.")
                }

                // Local API access + the hal-command installer (Mac). Self-contained view,
                // moved here from PowerUserView when the Lab became its own module.
                DeveloperAPISectionView(viewModel: chatViewModel)
            }
            .navigationTitle("The Lab")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingRoboEditor) {
            RoboEditorView()
                .environmentObject(chatViewModel)
        }
        // Antenna bridge: SET_UI_STATE:roboeditor drives apiNavRoboEditor, which opens/closes the
        // RoboRunner editor sheet here (local @State can't be reached directly from the API).
        .onChange(of: chatViewModel.apiNavRoboEditor) { _, open in showingRoboEditor = open }
        .onChange(of: showingRoboEditor) { _, open in
            // Keep the flag in sync when the user dismisses by hand, so a later API open still fires.
            if !open { chatViewModel.apiNavRoboEditor = false }
        }
        .onAppear {
            if !dragonsAcknowledged { showDragons = true }
        }
        .alert("Here be dragons", isPresented: $showDragons) {
            Button("Enter the Lab") { dragonsAcknowledged = true }
            Button("Not now", role: .cancel) { dismiss() }
        } message: {
            Text("The Lab holds Hal's power tools: on-device automation (RoboRunner) and a terminal bridge to Hal (the hal command). A few of them can change or delete your data. They start in Safe mode, which refuses destructive commands until you deliberately switch to Advanced. Proceed?")
        }
    }
}

struct DeveloperAPISectionView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var copiedField: String? = nil
    // Gates the one-time danger notice before the API is allowed to persist across launches.
    @State private var showingStickyConsent = false

    var body: some View {
        // Box 1, the API: the door. A local HTTP server any app can connect to.
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.localAPIEnabled },
                set: { enabled in
                    if enabled { viewModel.startLocalAPI() }
                    else       { viewModel.stopLocalAPI()  }
                }
            )) {
                // Explicit primary (white) icon so it matches the other Lab icons rather
                // than picking up the row's blue accent tint.
                Label {
                    Text("Local API Access")
                } icon: {
                    Image(systemName: "network")
                        .foregroundStyle(.primary)
                }
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

                // Persistence is opt-in and consented. By default the API turns itself
                // off every launch (a security surface should not linger silently); this
                // lets someone who trusts the device keep it on across restarts. Flipping
                // it ON routes through a one-time danger notice; OFF is free.
                Toggle(isOn: Binding(
                    get: { viewModel.localAPIStickyEnabled },
                    set: { on in
                        if on { showingStickyConsent = true }
                        else  { viewModel.localAPIStickyEnabled = false }
                    }
                )) {
                    Label {
                        Text("Keep on after I quit")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            Label("Developer API", systemImage: "antenna.radiowaves.left.and.right")
        } footer: {
            Text(viewModel.localAPIEnabled
                ? "Tap any value to copy it. With the API on, apps can reach Hal over HTTP at this address."
                : "Turn on a local HTTP API so apps can reach Hal over HTTP. Off by default.")
                .font(.caption2)
        }
        .alert("Keep the API on after you quit?", isPresented: $showingStickyConsent) {
            Button("Keep It On", role: .destructive) { viewModel.localAPIStickyEnabled = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Normally the developer API turns itself off whenever you quit Hal, so it is never listening unless you just switched it on. Turn this on and Hal will reopen the API automatically on launch whenever you left it on. That is handy for development, but it means a local network port stays reachable with your token across restarts. Only do this on a device you trust, and turn the API off when you are done.")
        }

        // Box 2, the Hal CLI: ONE client of that door, for the Mac terminal. It needs the API
        // on (nothing to talk to otherwise), so it appears only once Local API Access is
        // enabled, and only on a Mac (it writes to /usr/local/bin).
        if viewModel.localAPIEnabled && ProcessInfo.processInfo.isiOSAppOnMac {
            Section {
                halInstallerView
            } header: {
                Label("Hal CLI", systemImage: "terminal")
            }
        }
    }

    /// A labeled, tap-to-copy value. Label + copy icon on top, the FULL value below on its own
    /// line, wrapping instead of truncating (the address and 32-char token were being clipped
    /// when squeezed onto one trailing-aligned line). Tapping anywhere on the row copies.
    @ViewBuilder
    private func copyableRow(label: String, value: String, field: String, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundColor(copiedField == field ? .green : .secondary)
            }
            Text(copiedField == field ? "Copied!" : value)
                .font(font)
                .foregroundColor(copiedField == field ? .green : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = value
            withAnimation { copiedField = field }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { if copiedField == field { copiedField = nil } }
            }
        }
    }

    // MARK: - hal CLI installer (Mac only)

    /// Absolute path of the `hal` script bundled inside the app, or nil until it is added
    /// to the target as a bundled resource. The install line copies FROM this path.
    private var bundledHalPath: String? {
        Bundle.main.path(forResource: "hal", ofType: nil)
    }

    /// A readable, scoped-sudo one-liner the user pastes into their own Mac Terminal. Only the
    /// write into /usr/local/bin uses sudo; the ~/.config/hal file stays user-owned. Refuses if
    /// hal already exists (uninstall first). host/port/token come straight from this running app.
    private func installCommand(halPath: String, token: String) -> String {
        let port = LocalAPIServer.apiPort
        let configJSON = "{\"host\":\"127.0.0.1\",\"port\":\(port),\"token\":\"\(token)\"}"
        return "if [ -e /usr/local/bin/hal ]; then echo \"hal already installed. Run the uninstall line first.\"; else sudo mkdir -p /usr/local/bin && sudo install -m 755 \"\(halPath)\" /usr/local/bin/hal && install -d -m 700 ~/.config/hal && printf '\(configJSON)\\n' > ~/.config/hal/config.json && chmod 600 ~/.config/hal/config.json && echo \"hal installed. Try: hal hello\"; fi"
    }

    /// Removes exactly what the installer added, nothing else. `rmdir` only removes the config
    /// directory if it is empty, so a user's own files there are never touched.
    private var uninstallCommand: String {
        "sudo rm -f /usr/local/bin/hal && rm -f ~/.config/hal/config.json && rmdir ~/.config/hal 2>/dev/null; echo \"hal uninstalled.\""
    }

    @ViewBuilder
    private var halInstallerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install the hal command")
                .font(.subheadline).bold()
            Text("Run the hal CLI in your Mac Terminal, talking to this app over the local API. Read a line, then paste it into Terminal. The install line asks for your password because it writes hal into /usr/local/bin.")
                .font(.caption).foregroundColor(.secondary)
            if let halPath = bundledHalPath {
                commandBlock(title: "Install",
                             command: installCommand(halPath: halPath, token: viewModel.localAPIServer.apiToken),
                             field: "install")
                commandBlock(title: "Uninstall", command: uninstallCommand, field: "uninstall")
            } else {
                Text("The hal script is not bundled in this build yet.")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func commandBlock(title: String, command: String, field: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = command
                    withAnimation { copiedField = field }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { if copiedField == field { copiedField = nil } }
                    }
                } label: {
                    Label(copiedField == field ? "Copied!" : "Copy",
                          systemImage: copiedField == field ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundColor(copiedField == field ? .green : .accentColor)
            }
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        }
    }
}

// ==== LEGO END: 62 LabView (The Lab UI) ====
