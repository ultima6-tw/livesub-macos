import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuBarView: View {
    @StateObject private var engine = TranslationEngine.shared
    @StateObject private var speech = SpeechOutputManager.shared
    @StateObject private var updates = UpdaterManager.shared
    @State private var showingDomainsSheet = false
    @State private var voiceRevision = 0   // forces Picker refresh after UserDefaults write

    private var ttsVoiceID: Binding<String> {
        Binding(
            get: { _ = voiceRevision; return SpeechOutputManager.selectedVoiceID(for: engine.selectedTgtID) },
            set: { SpeechOutputManager.setSelectedVoiceID($0, for: engine.selectedTgtID); voiceRevision += 1 })
    }

    /// "Use Custom Vocabulary" checkbox: off clears the selection (standard
    /// recognition); on restores the last-used list, else the first one.
    private var useVocabulary: Binding<Bool> {
        Binding(
            get: { engine.selectedDomain != nil },
            set: { on in
                let lastKey = "jasub.lastDomainID"
                if on {
                    let last = UserDefaults.standard.string(forKey: lastKey) ?? ""
                    engine.selectedDomainID = engine.domains.contains { $0.id == last }
                        ? last : (engine.domains.first?.id ?? "")
                } else {
                    if engine.selectedDomain != nil {
                        UserDefaults.standard.set(engine.selectedDomainID, forKey: lastKey)
                    }
                    engine.selectedDomainID = ""
                }
            })
    }

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

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Speak Translation to Headphones", isOn: $speech.isEnabled)
                    .toggleStyle(.checkbox)
                if speech.isEnabled {
                    Text(speech.headphonesConnected ? "Headphones detected" : "No headphones — silent")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Picker("Voice", selection: ttsVoiceID) {
                            Text("Automatic").tag("")
                            ForEach(SpeechOutputManager.voiceOptions(for: engine.selectedTgtID)) { opt in
                                Text(opt.label).tag(opt.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            speech.preview(languageID: engine.selectedTgtID)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Preview voice")
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $speech.volume, in: 0.1...1.0)
                        Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    .help("Translation volume")
                    if !speech.latencyInfo.isEmpty {
                        Text(speech.latencyInfo)   // TEMP: latency tuning
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Toggle("Diagnostic Logging", isOn: $engine.diagnosticLogging)
                .toggleStyle(.checkbox)

            // Custom vocabulary (optional). Off = standard SpeechTranscriber;
            // on = DictationTranscriber biased with the chosen word list.
            // Fixed for the session (switching ASR engines needs a restart).
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Use Custom Vocabulary", isOn: useVocabulary)
                    .toggleStyle(.checkbox)
                    .disabled(engine.isRunning || engine.domains.isEmpty)
                if engine.selectedDomain != nil {
                    Picker("", selection: $engine.selectedDomainID) {
                        ForEach(engine.domains) { domain in
                            Text(verbatim: domain.name.isEmpty ? "—" : domain.name).tag(domain.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
                    .disabled(engine.isRunning)
                }
                Button("Manage Vocabularies…") { showingDomainsSheet = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .padding(.leading, 18)
                    .sheet(isPresented: $showingDomainsSheet) {
                        DomainsSheet(engine: engine)
                    }
                Text(verbatim: NSLocalizedString("hint.vocabMenu",
                    value: "Add names, jargon and other words you often hear so speech recognition picks them up more reliably.",
                    comment: "Explains the custom vocabulary option in the menu"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }

            // Updates (Sparkle)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Toggle("Check for Updates Automatically", isOn: $updates.automaticallyChecksForUpdates)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(!updates.canCheckForUpdates)
                }
                Text(verbatim: NSLocalizedString("hint.updates",
                    value: "Checks GitHub for a new version once a day and asks before installing. Nothing else is sent.",
                    comment: "Explains the automatic update check"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

private struct DomainsSheet: View {
    @ObservedObject var engine: TranslationEngine
    @State private var editingID: String?
    @Environment(\.dismiss) private var dismiss

    private var editingDomain: ContentDomain? {
        engine.domains.first { $0.id == editingID }
    }

    /// Binding by id (not index) so deleting a domain can't leave the
    /// TextEditor holding an out-of-range index.
    private func field(_ keyPath: WritableKeyPath<ContentDomain, String>, id: String) -> Binding<String> {
        Binding(
            get: { engine.domains.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                if let i = engine.domains.firstIndex(where: { $0.id == id }) {
                    engine.domains[i][keyPath: keyPath] = value
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom Vocabularies").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc also closes
                .help("Close")
            }
            Text(verbatim: NSLocalizedString("hint.vocab",
                value: "Turn on \"Use Custom Vocabulary\" and pick a list before Start. Words in the list are given to speech recognition as hints and used to correct near-miss spellings in the transcript; words not in the list are unaffected. Add names, jargon and other words that are often misheard, in the language being spoken — common words don't need to be added. One per line, e.g. \"Feshbach resonance\"; add \" = translation\" to also force how it is translated. Import / Export use plain-text files in the same format.",
                comment: "Explains custom vocabularies in the Manage Vocabularies sheet"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    List(selection: $editingID) {
                        ForEach(engine.domains) { domain in
                            Text(verbatim: domain.name.isEmpty ? "—" : domain.name)
                                .tag(Optional(domain.id))
                        }
                        // Drag to reorder; the menu's picker uses the same order.
                        .onMove { engine.domains.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(width: 160, height: 260)
                    HStack(spacing: 4) {
                        // "+" asks which language the words are in; it is
                        // recorded in the name, e.g. "New Vocabulary (English)".
                        Menu {
                            ForEach(languageOptions, id: \.self) { code in
                                Button(ContentDomain.languageName(code)) {
                                    let domain = ContentDomain(
                                        name: uniqueName(ContentDomain.name(
                                            NSLocalizedString("vocab.newName", value: "New Vocabulary", comment: ""),
                                            language: code)),
                                        glossaryText: "")
                                    engine.domains.append(domain)
                                    editingID = domain.id
                                }
                            }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Button {
                            guard let id = editingID else { return }
                            editingID = nil
                            if engine.selectedDomainID == id { engine.selectedDomainID = "" }
                            engine.domains.removeAll { $0.id == id }
                        } label: { Image(systemName: "minus") }
                        .disabled(editingID == nil || engine.isRunning)
                    }
                    .buttonStyle(.borderless)
                }

                if let domain = editingDomain {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Vocabulary Name", text: field(\.name, id: domain.id))
                            .textFieldStyle(.roundedBorder)
                        let count = domain.terms.count
                        Text(verbatim: String(format: NSLocalizedString("domain.termCount",
                            value: "%d terms (first %d used for speech recognition)", comment: ""),
                            count, ASRManager.maxContextualStrings))
                            .font(.caption2)
                            .foregroundStyle(count > ASRManager.maxContextualStrings ? .orange : .secondary)
                        TextEditor(text: field(\.glossaryText, id: domain.id))
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 320, minHeight: 236)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    }
                } else {
                    Text("Select or add a vocabulary.")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 320, minHeight: 260)
                }
            }

            HStack {
                Button("Import…") { importFiles() }
                Button("Export…") { exportSelected() }
                    .disabled(editingDomain == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(16)
        .onAppear {
            editingID = engine.selectedDomain?.id ?? engine.domains.first?.id
        }
    }

    /// Same name as an existing list → "Name 2", "Name 3", … (like Finder),
    /// so duplicates stay distinguishable in the menu.
    private func uniqueName(_ name: String) -> String {
        let existing = Set(engine.domains.map(\.name))
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    /// Languages offered for a new/imported list: the current source
    /// language first, then every recognizable language (one per language
    /// code, so en-US / en-GB collapse to "English").
    private var languageOptions: [String] {
        var seen = Set<String>()
        return ([engine.selectedSrcID] + engine.sourceLanguages.map(\.id))
            .map(ContentDomain.languageCode)
            .filter { seen.insert($0).inserted }
    }

    /// Imports one vocabulary per plain-text file (same format as the editor);
    /// the file name becomes the vocabulary name, with the language picked
    /// in the panel's accessory view appended.
    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let options = languageOptions
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: options.map(ContentDomain.languageName))
        popup.selectItem(at: 0)
        let label = NSTextField(labelWithString: NSLocalizedString("vocab.importLanguage",
            value: "Language of the words:", comment: "Label next to the language picker when importing"))
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        NSApp.activate()   // menu-bar app: bring the panel to the front
        guard panel.runModal() == .OK else { return }
        let language = options.indices.contains(popup.indexOfSelectedItem)
            ? options[popup.indexOfSelectedItem] : engine.selectedSrcID
        var lastID: String?
        for url in panel.urls {
            var enc = String.Encoding.utf8
            guard let text = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, usedEncoding: &enc)) else { continue }
            let domain = ContentDomain(
                name: uniqueName(ContentDomain.name(url.deletingPathExtension().lastPathComponent,
                                                    language: language)),
                glossaryText: text)
            engine.domains.append(domain)
            lastID = domain.id
        }
        if let lastID { editingID = lastID }
    }

    /// Exports the selected vocabulary as a UTF-8 plain-text file.
    private func exportSelected() {
        guard let domain = editingDomain else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = domain.name.trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = (base.isEmpty
            ? NSLocalizedString("vocab.newName", value: "New Vocabulary", comment: "") : base) + ".txt"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? domain.glossaryText.write(to: url, atomically: true, encoding: .utf8)
    }
}
