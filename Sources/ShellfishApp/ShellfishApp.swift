// Stage 4 Phase 4.5 — SwiftUI shell, minimum viable cut.
//
// Scope of THIS file:
//   - One window. No menu bar yet.
//   - SwiftUI chat view bound to the existing ConversationLoop.
//   - Native NSAlert for tool approval prompts.
//   - Same Anthropic provider, same broker, same sandbox profile,
//     same audit log as the CLI Chat binary.
//
// Now wired up (4.5 → 4.6 polish):
//   - Streaming token-by-token, inline tool-call rendering.
//   - Inline approval sheet with path resolution + sensitive-path flagging.
//   - Markdown + fenced code blocks in the transcript.
//   - MenuBarExtra with quick status/actions; ⌘N new session, ⌘L audit log.
//   - Audit log viewer panel.
//
// Still deferred:
//   - Session switcher / preset templates.
//   - Full LSUIElement menu-bar-only mode (we keep the window for now).

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
        .commands {
            // Replace the default "New" with a fresh Shellfish session.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { state.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Show Audit Log") { state.showAudit = true }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }

        // A lightweight menu-bar presence alongside the window: quick status
        // plus the two actions you'd want without hunting for the window.
        MenuBarExtra("Shellfish", systemImage: "lock.shield") {
            Text(state.isThinking ? "Working…" : "Ready")
            Divider()
            Button("New Session") { state.newSession() }
            Button("Show Audit Log") { state.showAudit = true }
            Divider()
            Button("Quit Shellfish") { NSApp.terminate(nil) }
        }
    }
}
