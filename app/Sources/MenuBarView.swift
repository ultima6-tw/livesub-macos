import SwiftUI
import AppKit

struct MenuBarView: View {
    @StateObject private var engine = TranslationEngine.shared
    @State private var showingTerminologySheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .firstTextBaseline) {
                Label("JaSub", systemImage: "captions.bubble.fill")
                    .font(.headline)
                Spacer()
                if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("v\(v)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Source language
            VStack(alignment: .leading, spacing: 4) {
                Text("Source Language").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $engine.selectedSrcID) {
                    if !frequentSourceLanguages.isEmpty {
                        Section("Frequent") {
                            ForEach(frequentSourceLanguages) { lang in Text(lang.name).tag(lang.id) }
                        }
                        Section("All") {
                            ForEach(nonFrequentSourceLanguages) { lang in Text(lang.name).tag(lang.id) }
                        }
                    } else {
                        ForEach(engine.sourceLanguages) { lang in Text(lang.name).tag(lang.id) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Target language
            VStack(alignment: .leading, spacing: 4) {
                Text("Translation Target").font(.caption).foregroundStyle(.secondary)
                if engine.isLoadingTargets {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("", selection: $engine.selectedTgtID) {
                        let frequentTgtIDs = Set(frequentTargetLanguages.map(\.id))
                        let installed = engine.targetLanguages.filter { $0.isInstalled && !frequentTgtIDs.contains($0.id) }
                        let uninstalled = engine.targetLanguages.filter(\.needsDownload)
                        if !frequentTargetLanguages.isEmpty {
                            Section("Frequent") {
                                ForEach(frequentTargetLanguages) { lang in Text(lang.name).tag(lang.id) }
                            }
                        }
                        if !installed.isEmpty {
                            Section("Installed") {
                                ForEach(installed) { lang in Text(lang.name).tag(lang.id) }
                            }
                        }
                        if !uninstalled.isEmpty {
                            Section("Language Pack Not Installed") {
                                ForEach(uninstalled) { lang in Text(lang.name + "  ↓").tag(lang.id) }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if engine.selectedTgt?.needsDownload == true {
                        Text(verbatim: NSLocalizedString("hint.installTranslationPack",
                            value: "Go to System Settings → General → Language & Region → Translation Languages to install the language pack.",
                            comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            // Audio source
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Source").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $engine.selectedDevice) {
                    Section("Input Device") {
                        ForEach(engine.inputDevices) { device in
                            HStack(spacing: 4) {
                                Text(device.name)
                                if device.isDefault {
                                    Text("(Default)").foregroundStyle(.secondary)
                                }
                            }
                            .tag(device.name)
                        }
                    }
                    Section("System Audio") {
                        Text("Browser / System Audio")
                            .tag(TranslationEngine.systemAudioID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Allow Scrolling", isOn: $engine.allowUserScroll)
                .toggleStyle(.checkbox)

            Toggle("Show Original", isOn: $engine.showOriginal)
                .toggleStyle(.checkbox)

            Toggle("Show Translation", isOn: $engine.showTranslation)
                .toggleStyle(.checkbox)

            Toggle("Save Transcript", isOn: $engine.saveTranscript)
                .toggleStyle(.checkbox)

            Toggle("Diagnostic Logging", isOn: $engine.diagnosticLogging)
                .toggleStyle(.checkbox)

            Button {
                showingTerminologySheet = true
            } label: {
                Label("Manage Terminology…", systemImage: "textformat.abc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .sheet(isPresented: $showingTerminologySheet) {
                TerminologySheet(text: $engine.terminologyGlossaryText)
            }

            Toggle("High Quality Translation", isOn: $engine.highFidelityTranslation)
                .toggleStyle(.checkbox)
            if engine.highFidelityTranslation {
                if engine.translationFallbackActive {
                    Label("No network — using on-device translation", systemImage: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Requires network. Falls back to on-device if unavailable.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Font size
            HStack(spacing: 6) {
                Text("Font Size").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(engine.translationFontSize))pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                Stepper("", value: $engine.translationFontSize, in: 12...40, step: 2)
                    .labelsHidden()
            }

            Divider()

            if let status = engine.startupStatus {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = engine.startError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Log status
            if engine.isRunning, let logURL = engine.currentLogURL {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(logURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(logURL.deletingLastPathComponent())
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    engine.isRunning ? engine.stop() : engine.start()
                } label: {
                    Text(LocalizedStringKey(engine.isRunning ? "Stop" : "Start"))
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .accentColor)
                .disabled(engine.isLoadingTargets || engine.selectedTgtID.isEmpty)
                .keyboardShortcut(.return)

                Spacer()

                Button("Log Folder") { openLogsFolder() }
                    .buttonStyle(.bordered)

                Button("Quit JaSub") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var frequentSourceLanguages: [SourceLanguage] {
        let counts = engine.srcUsageCounts
        return engine.sourceLanguages
            .filter { counts[$0.id, default: 0] > 0 }
            .sorted { counts[$0.id, default: 0] > counts[$1.id, default: 0] }
            .prefix(3).map { $0 }
    }

    private var nonFrequentSourceLanguages: [SourceLanguage] {
        let ids = Set(frequentSourceLanguages.map(\.id))
        return engine.sourceLanguages.filter { !ids.contains($0.id) }
    }

    private var frequentTargetLanguages: [TargetLanguage] {
        let counts = engine.tgtUsageCounts
        return engine.targetLanguages
            .filter { $0.isInstalled && counts[$0.id, default: 0] > 0 }
            .sorted { counts[$0.id, default: 0] > counts[$1.id, default: 0] }
            .prefix(3).map { $0 }
    }

    private func openLogsFolder() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("JaSub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

private struct TerminologySheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminology Glossary").font(.headline)
            Text("One term per line, e.g. \"Max Verstappen\" — ASR output is fuzzy-corrected against this list. Add \" = translation\" to also force that term's translated form, e.g. \"Max Verstappen = 麥克斯·維斯塔潘\" (only takes effect if the translator leaves it untranslated).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 320, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(16)
    }
}
