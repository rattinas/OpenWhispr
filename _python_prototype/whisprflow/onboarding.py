"""Onboarding wizard for first-time setup."""

import webbrowser
import rumps
import sounddevice as sd
from whisprflow import settings
from whisprflow.license import validate_license
from whisprflow.config import LANGUAGES, HOTKEYS


def needs_onboarding() -> bool:
    return not settings.is_onboarded()


def run_onboarding():
    """Run the step-by-step setup wizard."""

    # Step 1: Welcome
    rumps.alert(
        title="Welcome to WhisprFlow! 🎙",
        message=(
            "WhisprFlow turns your voice into polished text — instantly.\n\n"
            "Hold a key, speak, release. Your words appear at the cursor, "
            "cleaned up and ready to send.\n\n"
            "Let's set you up in 2 minutes."
        ),
        ok="Let's go →",
    )

    # Step 2: License
    _step_license()

    # Step 3: Speech Engine (Groq)
    _step_stt()

    # Step 4: Polish Engine (Anthropic)
    _step_polish()

    # Step 5: Language
    _step_language()

    # Step 6: Hotkey
    _step_hotkey()

    # Step 7: Done
    hotkey = HOTKEYS.get(settings.get_hotkey(), "CTRL")
    rumps.alert(
        title="You're all set! 🎉",
        message=(
            f"WhisprFlow is ready to use.\n\n"
            f"→ Hold {hotkey} to record\n"
            f"→ Release to paste polished text\n\n"
            f"Look for the 🎙 in your menu bar.\n"
            f"Tip: Click it to change modes, view stats, and more."
        ),
        ok="Start using WhisprFlow",
    )

    settings.set_onboarded()


def _step_license():
    resp = rumps.alert(
        title="Step 1: License Key 🔐",
        message=(
            "Enter your license key to unlock WhisprFlow.\n"
            "No key? Start with a free trial (50 uses)."
        ),
        ok="Enter License Key",
        cancel="Start Free Trial",
    )
    if resp == 1:  # Enter key
        _prompt_license()


def _prompt_license():
    resp = rumps.Window(
        title="Enter License Key",
        message="Format: WF-XXXXX-XXXXX-XXXXX-XXXXX",
        default_text="",
        ok="Activate",
        cancel="Skip (use trial)",
    ).run()
    if resp.clicked and resp.text.strip():
        if validate_license(resp.text.strip()):
            settings.set_license_key(resp.text.strip())
            rumps.alert("License Activated ✅", "Lifetime access unlocked!")
        else:
            rumps.alert("Invalid Key ❌", "Please check your key and try again.")
            _prompt_license()


def _step_stt():
    resp = rumps.alert(
        title="Step 2: Speech Recognition 🎙",
        message=(
            "How should WhisprFlow transcribe your voice?\n\n"
            "☁️ Groq Cloud (recommended)\n"
            "  → Fast, accurate, free API key\n"
            "  → Get yours at console.groq.com\n\n"
            "💻 Local Whisper\n"
            "  → Fully offline, ~1.6GB download\n"
            "  → Slower but completely private"
        ),
        ok="Use Groq (recommended)",
        cancel="Use Local Whisper",
    )
    if resp == 1:  # Groq
        settings.set_stt_provider("groq")
        _prompt_groq_key()
    else:
        settings.set_stt_provider("local")


def _prompt_groq_key():
    resp = rumps.alert(
        title="Groq API Key",
        message=(
            "To use Groq, you need a free API key:\n\n"
            "1. Go to console.groq.com\n"
            "2. Sign up (free)\n"
            "3. Go to API Keys → Create API Key\n"
            "4. Copy the key\n\n"
            "Click 'Open Groq' to open the website."
        ),
        ok="Open Groq & Enter Key",
        cancel="Skip for now",
    )
    if resp == 1:
        webbrowser.open("https://console.groq.com/keys")
        key_resp = rumps.Window(
            title="Paste your Groq API Key",
            message="Starts with 'gsk_'",
            default_text="",
            ok="Save",
            cancel="Skip",
        ).run()
        if key_resp.clicked and key_resp.text.strip():
            settings.set_groq_key(key_resp.text.strip())


def _step_polish():
    resp = rumps.alert(
        title="Step 3: Text Polishing 🤖",
        message=(
            "How should WhisprFlow clean up your text?\n\n"
            "☁️ Anthropic Claude (recommended)\n"
            "  → Best quality, fast\n"
            "  → Requires API key (pay per use)\n\n"
            "💻 Ollama (local)\n"
            "  → Free, offline\n"
            "  → Requires Ollama installed (ollama.com)\n"
            "  → Lower quality"
        ),
        ok="Use Claude (recommended)",
        cancel="Use Ollama (local)",
    )
    if resp == 1:
        settings.set_polish_provider("anthropic")
        _prompt_anthropic_key()
    else:
        settings.set_polish_provider("ollama")


def _prompt_anthropic_key():
    resp = rumps.alert(
        title="Anthropic API Key",
        message=(
            "To use Claude, you need an API key:\n\n"
            "1. Go to console.anthropic.com\n"
            "2. Sign up & add billing\n"
            "3. Go to API Keys → Create Key\n"
            "4. Copy the key\n\n"
            "Cost: ~$0.001 per dictation (very cheap).\n"
            "Click 'Open Anthropic' to open the website."
        ),
        ok="Open Anthropic & Enter Key",
        cancel="Skip for now",
    )
    if resp == 1:
        webbrowser.open("https://console.anthropic.com/settings/keys")
        key_resp = rumps.Window(
            title="Paste your Anthropic API Key",
            message="Starts with 'sk-ant-'",
            default_text="",
            ok="Save",
            cancel="Skip",
        ).run()
        if key_resp.clicked and key_resp.text.strip():
            settings.set_anthropic_key(key_resp.text.strip())


def _step_language():
    # Show language options
    lang_list = "\n".join(f"  {code} = {name}" for code, name in LANGUAGES.items())
    resp = rumps.Window(
        title="Step 4: Language 🌐",
        message=f"Which language do you speak most?\n\n{lang_list}\n\nType the code (e.g. 'de' for German):",
        default_text="de",
        ok="Save",
        cancel="Use German (default)",
    ).run()
    if resp.clicked and resp.text.strip() in LANGUAGES:
        settings.set_language(resp.text.strip())
    else:
        settings.set_language("de")


def _step_hotkey():
    import threading
    from pynput import keyboard as kb

    captured = [None]

    def capture():
        def on_press(key):
            if key == kb.Key.ctrl_l or key == kb.Key.ctrl_r:
                captured[0] = "ctrl"
            elif hasattr(key, 'name') and key.name.startswith('f'):
                captured[0] = key.name
            elif hasattr(key, 'char') and key.char:
                captured[0] = key.char
            if captured[0]:
                return False
        listener = kb.Listener(on_press=on_press)
        listener.start()
        listener.join(timeout=15)
        if listener.is_alive():
            listener.stop()

    rumps.alert(
        title="Step 5: Hotkey ⌨️",
        message="After closing this dialog, press the key you want to use for dictation.\n\nPopular choices: Control, F5, F8",
        ok="I'm ready",
    )

    t = threading.Thread(target=capture)
    t.start()
    t.join(timeout=15)

    if captured[0]:
        settings.set_hotkey(captured[0])
        desc = HOTKEYS.get(captured[0], captured[0].upper())
        rumps.alert("Hotkey Set ✅", f"Your hotkey: {desc}")
    else:
        settings.set_hotkey("ctrl")
        rumps.alert("Hotkey", "No key pressed. Using Control as default.")
