import AppKit
import SwiftUI
import ShareBarCore

/// The setup window's content: hostname field (disabled in quick mode), the quick-link
/// toggle, the login checkbox, Set Up / Cancel, and a monospaced read-only log streaming
/// the child process's output.
struct SetupView: View {
    @ObservedObject var model: SetupWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Share Bar")
                .font(.headline)

            TextField("Hostname, for example s.example.com", text: $model.hostname)
                .textFieldStyle(.roundedBorder)
                .disabled(model.quickMode || model.isRunning)

            Toggle("Quick link, no domain needed", isOn: $model.quickMode)
                .disabled(model.isRunning)

            Toggle("Open Share Bar at login", isOn: $model.openAtLogin)
                .disabled(model.isRunning)

            if !model.statusLine.isEmpty {
                Text(model.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(model.log.isEmpty ? " " : model.log)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                // Always enabled and bound to Escape: while a run is in flight it cancels
                // that run (same as before); otherwise it closes the window, since there is
                // nothing left to cancel.
                Button("Cancel") {
                    if model.isRunning {
                        model.cancel()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button("Set Up") { model.setUp() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSetUp)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
