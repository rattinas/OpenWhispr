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

## Launched 2.0.0 (2026-04-17)
- [x] Domain live (talkischeap.app, Vercel prod)
- [x] Stripe Live-Keys in Vercel production (sk_live_…)
- [x] Resend Domain verifiziert (Feedback-API sendet Mails via noreply@talkischeap.app)
- [x] DMG signiert + notarisiert + stapled (TalkIsCheap-2.0.0.dmg, Apple submission Accepted)
- [x] Sparkle Auto-Update wired up (appcast.xml mit EdDSA-Signatur)
- [x] In-App Feedback-Form (Settings → About)

## Post-Launch (manuelle QA)
- [ ] Frischer Mac: DMG ziehen, installieren, ersten Flow durchspielen
- [ ] Kassetten-Icon: Menubar zeigt Icon statt `mic` Fallback (testen auf fresh Mac)
- [ ] Finder Quick Action: "TalkIsCheap: Transcribe" auf .m4a/.mp3 Rechtsklick
- [ ] Stripe Live Flow: 1x Test-Kauf mit echter Karte → License kommt per Mail
- [ ] Auto-Update 2.0.0 → 2.0.1: Dummy-Release bauen, schauen ob Sparkle-Dialog kommt

## File Locations
- Swift App: `TalkIsCheap/Sources/TalkIsCheap/`
- Website: `/Users/bene/Documents/Projekte/talkischeap-website/`
- Python Prototype: `_python_prototype/`
- Key Generator: `TalkIsCheap/scripts/generate_keys.swift`
- Release: `cd TalkIsCheap && ./scripts/release.sh <version> <build>`
- Build: `cd TalkIsCheap && swift build`
- Install: `cp .build/release/TalkIsCheap dist/TalkIsCheap.app/Contents/MacOS/TalkIsCheap`
