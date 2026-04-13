# TalkIsCheap — Ship Checklist

## Done
- [x] Hotkey Hold-Detection — sofort starten, kein 0.3s delay mehr
- [x] Markdown-Rendering — `.full` interpretedSyntax für Überschriften/Listen
- [x] PDF + Word Dateien einlesen (PDFKit + DOCX XML Parser)
- [x] Onboarding Flow — öffnet automatisch als NSPanel beim ersten Start
- [x] Hardcoded Dev-Pfad in MenuBarIcon entfernt
- [x] Branding: Website WhisprFlow → TalkIsCheap überall
- [x] License Secret + Prefix synchronisiert (Swift ↔ TypeScript)
- [x] Logging bereinigt — keine vollen Transkripte mehr in Logs
- [x] Website baut erfolgreich (Next.js 16)
- [x] Swift App baut + installiert in dist/

## Before Public Release
- [ ] Domain kaufen + Vercel deployen
- [ ] Stripe Live-Keys konfigurieren (aktuell: test mode)
- [ ] Resend Domain verifizieren (noreply@...)
- [ ] DMG erstellen: `TalkIsCheap-latest.dmg` in website/public/download/
- [ ] Code Signing + Notarization (braucht Apple Developer Account)
- [ ] Finder Quick Action testen auf frischem Mac
- [ ] Kassetten-Icon testen — prüfen ob Bundle Resources korrekt geladen werden

## File Locations
- Swift App: `TalkIsCheap/Sources/TalkIsCheap/`
- Website: `/Users/bene/Documents/Projekte/talkischeap-website/`
- Python Prototype: `_python_prototype/`
- Key Generator: `TalkIsCheap/scripts/generate_keys.swift`
- Build: `cd TalkIsCheap && swift build`
- Install: `cp .build/debug/TalkIsCheap dist/TalkIsCheap.app/Contents/MacOS/TalkIsCheap`
