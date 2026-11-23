# JaSub — Real-Time Meeting Transcription & Translation

> Also available on iPhone & iPad: **[LiveSub →](https://apps.apple.com/tw/app/livesub/id6771318855)**

Real-time speech transcription and translation for macOS 26.4+. No API keys, no subscription. Fully on-device by default; optional high-fidelity mode routes translation through Apple servers via Private Cloud Compute.

Uses Apple's native stack exclusively:

- **ASR**: SpeechAnalyzer + SpeechTranscriber (Speech.framework, macOS 26+); DictationTranscriber with contextual strings when a custom vocabulary is in use
- **Translation**: Translation.framework `.highFidelity` (Apple servers, optional) or `.lowLatency` (on-device, < 100ms, default) → FoundationModels / Apple Intelligence (fallback, ~500ms)
- **System audio**: CATapDescription + IOProc — captures browser or any app audio without a virtual audio driver

## Download

**[→ Download the latest JaSub (DMG)](https://github.com/ultima6-tw/livesub-macos/releases/latest)**

> Requires macOS 26.4+ (Tahoe) + Apple Intelligence + Apple Silicon.  
> Signed with Developer ID and notarised by Apple — opens without Gatekeeper warnings.

### Updating

From 0.3.13 on, JaSub checks GitHub for a new version once a day and asks before installing (Sparkle; turn off with **Check for Updates Automatically** in the menu, or use **Check Now**). To get 0.3.13 from an older version, download the DMG once and drag JaSub into Applications to replace it.

> Upgrading from **0.3.8 or earlier** (ad-hoc signed builds): first remove JaSub from **System Settings → Privacy & Security → Screen Recording** and **Microphone**, then install, launch, grant permissions again, and relaunch once. Releases signed with the same Developer ID keep their permissions.

![JaSub subtitle overlay windows](app/docs/screenshot-overview.png)

---

## Menu Bar App

A native SwiftUI menu bar app with floating subtitle overlay windows.

### Requirements

- macOS 26.4+ (Tahoe) with Apple Intelligence enabled
- Apple Silicon Mac
- Xcode 26+ (`xcode-select --install` or full Xcode)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Install translation language packs (required)

**System Settings → General → Language & Region → Translation Languages**

Install the language pairs you need (e.g. English ↔ Chinese, Japanese ↔ Chinese). Required for < 100ms translation. Without this the app uses FoundationModels (~500ms), which is still fully on-device.

### Build and install

```bash
cd app
./setup.sh        # install xcodegen and generate .xcodeproj (first time only)
./package.sh      # Release build → sign → notarise → dist/JaSub-<version>.dmg + dist/appcast.xml
```

`package.sh` needs a Developer ID Application certificate, a `notarytool` keychain profile and the Sparkle EdDSA private key (see the header of the script). To build for yourself without these, open `JaSub.xcodeproj` in Xcode and sign with your own team.

### Usage

| Action | Result |
|--------|--------|
| Left-click menu bar icon | Open settings popover (language, audio source, font size) |
| Right-click menu bar icon | Quick menu: Start / Stop / Quit |
| Icon turns red | App is running — click to access Stop |

![Settings popover](app/docs/screenshot-popover.png)

### Features

| Feature | Details |
|---------|---------|
| Source language | Dynamically queried from `SFSpeechRecognizer.supportedLocales()`; frequent languages shown first |
| Target language | Dynamically queried from `Translation.framework`, installed packs listed first; frequent languages shown first |
| Frequent languages | Top-3 most-used source and target languages float to the top of each picker automatically |
| High Quality Translation | Optional toggle — routes translation through Apple servers (`.highFidelity`); falls back to on-device silently if no network |
| Language names | Localised to system display language |
| Audio source | Microphone (CoreAudio device list) or Browser / System Audio (CATapDescription + IOProc) |
| Font size | 12–40pt stepper, persisted across launches — subtitle windows are freely resizable |
| Show original | Toggle original-language subtitle window |
| Custom vocabulary | Optional word lists (names, jargon, drug names…) given to speech recognition as hints and used to correct near-miss spellings; add `term = translation` to force a translation. Manage, reorder, import/export as plain text; example lists included |
| Speak translation to headphones | Reads each translated sentence aloud — headphones only; selectable voice per target language and a translation-volume slider |
| Automatic updates | Daily check on GitHub (Sparkle 2, EdDSA-signed), asks before installing; can be turned off |
| Session log | Auto-creates `~/Documents/JaSub/YYYY-MM-DD HH-mm.txt` on start, appends each sentence in real time |
| Log folder | Opens `~/Documents/JaSub` in Finder |

![Subtitle windows — resizable, font size 12–40pt](app/docs/screenshot-subtitles.png)

> Both subtitle windows can be freely resized by dragging any edge or corner. Font size (12–40pt) is controlled from the settings popover and persisted across launches.

### Localisation

The UI adapts to the system language automatically. Supported languages:

English · 繁體中文 · 简体中文 · 日本語 · 한국어 · Français · Deutsch · Español · Português (BR) · Italiano · العربية · Русский · Nederlands · Polski · ภาษาไทย · Türkçe · Українська · Tiếng Việt · Bahasa Indonesia

### Upgrading

See [Updating](#updating) above.

### Permissions

- **Speech Recognition** — prompted on first start
- **Microphone** — prompted on first start (microphone mode)
- **Screen & System Audio Recording** — required for browser audio capture (System Settings → Privacy & Security → Screen Recording)

---

## Architecture

```
Microphone
    ↓ AVAudioEngine (16kHz mono float32)
    ↓ AsyncStream<[Float]>

Browser / System Audio
    ↓ CATapDescription + IOProc (48kHz → resample → 16kHz)
    ↓ AsyncStream<[Float]>

SpeechAnalyzer + SpeechTranscriber  [ASRManager]
    partial → live subtitle update
    final   → hallucination filter → translation queue

Translation.framework  [TranslatorManager]
    ① Translation.framework  .highFidelity  (Apple servers, optional)
       or .lowLatency  (on-device, < 100ms, default)
       .highFidelity failure → auto-fallback to .lowLatency
    ② FoundationModels fallback  (Apple Intelligence 3B, ~500ms)
       guardrail → completion-style retry → ⚠ original text

@MainActor TranslationEngine → SwiftUI floating NSPanel windows
```

---

## Why SpeechAnalyzer?

`SpeechAnalyzer` (macOS 26+) is Apple's API for continuous live transcription. No session time limit, progressive partial results, fully Neural Engine, automatic model download.

**Evolution**: mlx-whisper → WhisperKit → SFSpeechRecognizer → **SpeechAnalyzer**. WhisperKit with `--use-prefill-prompt` invalidated the Neural Engine cache (7–10s/segment). SFSpeechRecognizer was superseded when SpeechAnalyzer shipped in macOS 26.

---

## Known Limitations

**Music / singing**: SpeechAnalyzer is speech-optimised. Some lyrics are recognised but gaps are expected.

**Proper nouns**: No hot-words API — character names and technical terms may be phonetically substituted.

---

## CLI version (legacy, no longer actively developed)

A Python + Swift CLI version is available in `server/` for headless or terminal use. No further development planned — the Menu Bar App is the primary version.

```bash
./run.sh    # auto-setup + interactive menu (language pair + audio source)
```

Requires Python 3.13+ and Xcode Command Line Tools. See `NOTES.md` for architecture details and known issues.
