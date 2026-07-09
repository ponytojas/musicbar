import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("MusicBar Settings", comment: "")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            }

            Section("Menu Bar") {
                Toggle("Show album artwork", isOn: $settings.showArtwork)
                Toggle("Show artist name", isOn: $settings.showArtist)
            }

            Section("Equalizer") {
                Toggle("Show equalizer", isOn: $settings.showEqualizer)
                if settings.showEqualizer {
                    Picker("Position", selection: $settings.equalizerPosition) {
                        Text("Left of title").tag(EqualizerPosition.left)
                        Text("Right of title").tag(EqualizerPosition.right)
                    }
                    Picker("Color", selection: $settings.equalizerColorMode) {
                        Text("Default").tag(EqualizerColorMode.system)
                        Text("Single color").tag(EqualizerColorMode.custom)
                        Text("Rainbow").tag(EqualizerColorMode.rainbow)
                    }
                    if settings.equalizerColorMode == .custom {
                        ColorPicker("Custom color", selection: Binding(
                            get: { settings.equalizerColor },
                            set: { settings.equalizerColor = $0 }
                        ), supportsOpacity: false)
                    }
                }
            }

            Section {
                LabeledContent("Title width") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(value: $settings.textWidth, in: 100...250, step: 10)
                            .frame(width: 170)
                        Text("\(Int(settings.textWidth)) pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker("Auto-scroll after", selection: $settings.holdSeconds) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }
            } footer: {
                Text("Long titles always start scrolling when you hover the menu bar item.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 520)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
