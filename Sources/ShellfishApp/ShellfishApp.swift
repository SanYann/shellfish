// Stage 4 Phase 4.5 — SwiftUI shell, minimum viable cut.
//
// Scope of THIS file:
//   - One window. No menu bar yet.
//   - SwiftUI chat view bound to the existing ConversationLoop.
//   - Native NSAlert for tool approval prompts.
//   - Same Anthropic provider, same broker, same sandbox profile,
//     same audit log as the CLI Chat binary.
//
// What's deferred to later iterations of 4.5:
//   - Menu-bar mode (LSUIElement, MenuBarExtra, click-to-open behavior).
//   - Inline tool-call rendering in the message list.
//   - Audit log viewer panel.
//   - Session switcher / preset templates.
//   - Streaming token-by-token.
//
// The goal here is "minimum thing you'd send someone": a real window
// running on top of the working headless kernel.

import SwiftUI
import AppKit

/// SwiftPM-built SwiftUI apps don't ship as proper `.app` bundles, so macOS
/// won't auto-promote them to a regular activatable app — the process runs
/// but no dock icon appears and the window never comes to front. We fix that
/// here by explicitly setting the activation policy at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ShellfishMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Shellfish") {
            ChatView()
                .environmentObject(state)
                .frame(minWidth: 560, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
    }
}
