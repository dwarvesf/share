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
                .onChange(of: model.hostname) { _ in model.hostnameEdited() }

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
                Button("Cancel") { model.cancel() }
                    .disabled(!model.isRunning)
                Button("Set Up") { model.setUp() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSetUp)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
