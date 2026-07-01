import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    private let presets: [(String, Hotkey)] = [
        ("⌘⇧V", Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌃⌥V", Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))),
        ("⌥Space", Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))),
        ("⌘⇧`", Hotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌘⇧B", Hotkey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))),
    ]

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Open Stash with", selection: hotkeyBinding) {
                    ForEach(presets, id: \.0) { label, hk in
                        Text(label).tag(hk)
                    }
                }
                .pickerStyle(.menu)
                Text("Press this anywhere to open the popup near your cursor.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                HStack {
                    Text("Items stored")
                    Spacer()
                    Text("\(appState.store.items.count)")
                        .foregroundStyle(.secondary)
                }
                Button("Clear all history", role: .destructive) {
                    appState.store.clear()
                }
            }
            Section("Permissions") {
                Text("To paste automatically after selecting an item, grant Stash **Accessibility** access in System Settings → Privacy & Security → Accessibility.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }

    private var hotkeyBinding: Binding<Hotkey> {
        Binding(
            get: { appState.currentHotkey },
            set: { appState.currentHotkey = $0 }
        )
    }
}
