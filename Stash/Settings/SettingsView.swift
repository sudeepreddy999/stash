import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ClipboardStore

    private let presets: [(String, Hotkey)] = [
        ("⌘⇧V", Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌃⌥V", Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))),
        ("⌥Space", Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))),
        ("⌘⇧`", Hotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌘⇧B", Hotkey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))),
    ]

    private let historySizes = [50, 100, 200, 500]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Stash at login", isOn: $appState.launchAtLogin)
                Picker("Keep up to", selection: maxItemsBinding) {
                    ForEach(historySizes, id: \.self) { n in
                        Text("\(n) clips").tag(n)
                    }
                }
                .pickerStyle(.menu)
                Text("Pinned clips don't count against the limit and are never trimmed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                Picker("Open Stash with", selection: hotkeyBinding) {
                    ForEach(presets, id: \.0) { label, hk in
                        Text(label).tag(hk)
                    }
                }
                .pickerStyle(.menu)
                if appState.hotkeyRegistrationFailed {
                    Label(
                        "This shortcut is in use by another app — pick a different one.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                } else {
                    Text("Press this anywhere to open the popup near your cursor.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("History") {
                HStack {
                    Text("Items stored")
                    Spacer()
                    Text("\(store.items.count)")
                        .foregroundStyle(.secondary)
                }
                Button("Clear all history…", role: .destructive) {
                    appState.confirmAndClearHistory()
                }
            }
            Section("Permissions") {
                Text("To paste automatically after selecting an item, grant Stash **Accessibility** access in System Settings → Privacy & Security → Accessibility.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility settings") {
                    appState.openAccessibilitySettings()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 480)
    }

    private var hotkeyBinding: Binding<Hotkey> {
        Binding(
            get: { appState.currentHotkey },
            set: { appState.currentHotkey = $0 }
        )
    }

    private var maxItemsBinding: Binding<Int> {
        Binding(
            get: { store.maxItems },
            set: { store.setMaxItems($0) }
        )
    }
}
