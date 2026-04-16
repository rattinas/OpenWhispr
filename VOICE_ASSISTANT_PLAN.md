# TalkIsCheap — Voice Assistant Mode (Always-Listening + Window Management)

## Vision
TalkIsCheap wird zum sprachgesteuerten Desktop-Assistenten. Lokales Whisper läuft permanent, erkennt ein Custom Wake Word, und führt dann Sprachbefehle aus:
- Window Management (Fenster verschieben, anordnen, snappen)
- App-Kategorisierung (Kommunikation, Development, Office automatisch erkennen)
- Text-Eingabe in beliebige Fenster
- Apps öffnen/schließen

## Architektur

### 1. Always-Listening Pipeline
```
Mikrofon → VAD (Voice Activity Detection) → Wake Word Detection → Whisper STT → Command Parser → Aktion ausführen
```

**Nicht**: Whisper permanent laufen lassen (zu CPU-intensiv)
**Stattdessen**: Leichtgewichtige Pipeline:
- **VAD** (Voice Activity Detection): `webrtcvad` oder Apple's `AVAudioEngine` built-in silence detection → erkennt ob jemand spricht (< 1% CPU)
- **Wake Word Detection**: Kleines ML-Modell das nur das Codewort erkennt (~5% CPU):
  - Option A: Apple's Speech Framework mit custom vocabulary
  - Option B: `openWakeWord` Python-Modell (3MB, läuft lokal)
  - Option C: Eigenes Modell trainiert auf die Aufnahmen des Users
- **Whisper STT**: Erst NACH Wake Word Detection → transkribiert den eigentlichen Befehl (3-10 Sek)
- **Command Parser**: Claude Haiku oder lokales LLM interpretiert den Befehl → mapped auf eine Aktion

### 2. Wake Word Training
- User geht in Settings → "Train Wake Word"
- Spricht das Codewort 5x ein (verschiedene Betonungen)
- App extrahiert Audio-Fingerprint (MFCC Features)
- Speichert als Template in ~/Library/Application Support/TalkIsCheap/wakeword/
- Bei Erkennung: Cross-Correlation mit Templates, Threshold für Aktivierung

### 3. Command Parser
Befehlskategorien:

**Window Management:**
- "Slack nach links oben" → findWindow(bundleId: slack) → moveToQuadrant(.topLeft)
- "VS Code links, Safari rechts" → splitScreen(left: vscode, right: safari)
- "Drei VS Code Fenster nebeneinander" → tileWindows(app: vscode, count: 3, direction: .horizontal)
- "Alle Kommunikations-Apps links" → findCategory(.communication) → moveToHalf(.left)

**App Control:**
- "Öffne Safari" → NSWorkspace.shared.launchApplication("Safari")
- "Schließe Slack" → findWindow(slack) → close()

**Text Entry:**
- "Schreib in Slack: Hey Team, ich bin in 5 Minuten da" → focusWindow(slack) → typeText("...")

**Display Layout Presets:**
- "Arbeitsmodus" → vorgefertigtes Layout laden
- "Meeting-Modus" → anderes Layout

### 4. Window Management APIs (macOS)
```swift
// Fenster finden
CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) → Liste aller Fenster

// Fenster verschieben/resizen via Accessibility API
let app = AXUIElementCreateApplication(pid)
var window: AnyObject?
AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &window)
AXUIElementSetAttributeValue(window, kAXPositionAttribute, point)
AXUIElementSetAttributeValue(window, kAXSizeAttribute, size)
```

### 5. App-Kategorisierung
Erweiterte Version des bestehenden App-Aware-Mappings:
```swift
let categories: [String: [String]] = [
    "communication": ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord", 
                       "ru.keepcoder.Telegram", "com.apple.MobileSMS", "com.microsoft.teams"],
    "development":   ["com.microsoft.VSCode", "com.apple.dt.Xcode", "dev.zed.Zed", 
                       "com.googlecode.iterm2", "com.apple.Terminal"],
    "browser":       ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"],
    "office":        ["com.apple.iWork.Pages", "com.microsoft.Word", "com.microsoft.Excel"],
    "email":         ["com.apple.mail", "com.microsoft.Outlook"],
    "media":         ["com.apple.Music", "com.spotify.client", "com.apple.QuickTimePlayerX"],
]
```

### 6. Display Quadranten/Zonen
```
┌──────────┬──────────┐
│ Top-Left │ Top-Right│
├──────────┼──────────┤
│ Bot-Left │ Bot-Right│
└──────────┴──────────┘

oder:
┌─────┬─────┬─────┐
│ 1/3 │ 1/3 │ 1/3 │  (drei Fenster nebeneinander)
└─────┴─────┴─────┘
```

## Neue Dateien

### Swift App:
- `Services/AlwaysListeningService.swift` — Audio-Stream, VAD, Wake Word Detection
- `Services/WakeWordTrainer.swift` — Aufnahme + Template-Speicherung
- `Services/CommandParser.swift` — Sprachbefehl → Aktion via Claude/lokales LLM
- `Services/WindowManager.swift` — CGWindow + AXUIElement APIs
- `Services/AppCategorizer.swift` — BundleID → Kategorie-Mapping
- `Models/DisplayLayout.swift` — Layout-Presets
- `Views/WakeWordTrainingView.swift` — Training UI
- `Views/LayoutEditorView.swift` — Layout-Preset Editor

### Neue Settings:
- `alwaysListeningEnabled: Bool` (default false)
- `wakeWord: String` (default "Hey Computer")
- `wakeWordSensitivity: Double` (0.5-1.0)
- `savedLayouts: [DisplayLayout]`

## Implementierungsreihenfolge

### Phase 1: Window Management (ohne Voice)
1. `WindowManager.swift` — Fenster finden, verschieben, resizen via Accessibility API
2. Keyboard-Shortcuts: Ctrl+Option+Pfeiltasten für Quick-Snapping
3. App-Kategorisierung mit erweitertem Mapping
4. Layout-Presets (speichern/laden)

### Phase 2: Voice Commands
5. `CommandParser.swift` — Sprachbefehle interpretieren via Claude Haiku
6. Integration in bestehenden Hotkey-Flow: neuer Modus "Command Mode"
7. Hold Ctrl+Option → Sprachebefehl → Aktion

### Phase 3: Always-Listening + Wake Word
8. `AlwaysListeningService.swift` — VAD + Audio-Stream
9. `WakeWordTrainer.swift` — Training Flow
10. Wake Word Detection (Apple Speech Framework oder openWakeWord)
11. Nahtlose Übergabe: Wake Word → Whisper STT → Command Parser → Aktion

### Phase 4: Polish
12. Layout-Preset-Editor UI
13. Multi-Monitor Support
14. Undo-Funktion (letzte Window-Anordnung wiederherstellen)
15. "Arbeitsmodus" / "Meeting-Modus" Presets

## Abhängigkeiten
- Accessibility Permission (bereits vorhanden)
- Microphone Permission (bereits vorhanden)
- Lokales Whisper-Modell (bereits im Local-Setup-Flow)
- Claude Haiku für Command-Parsing (oder lokales LLM via Ollama)

## Risiken
- **CPU-Verbrauch**: Always-Listening muss extrem effizient sein (<5% CPU idle)
- **Batterie**: Auf Laptops kritisch — Auto-Pause wenn auf Batterie?
- **Falsche Aktivierung**: Wake Word muss robust genug sein um nicht bei normalen Gesprächen auszulösen
- **Privacy**: User muss explizit opt-in für Always-Listening
