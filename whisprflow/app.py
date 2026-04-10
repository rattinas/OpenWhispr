"""WhisprFlow — Mac Menu Bar dictation app."""

import threading
import time
import rumps
import sounddevice as sd
from pynput import keyboard

from whisprflow.recorder import Recorder
from whisprflow.transcriber import Transcriber, get_groq_key, save_groq_key, get_stt_provider, save_stt_provider
from whisprflow.polisher import Polisher, MODES, get_api_key, save_api_key, get_provider, save_provider
from whisprflow.paster import paste_text
from whisprflow.app_context import get_frontmost_app, get_tone_for_app
from whisprflow.stats import log_transcription, get_stats
from whisprflow.dictionary import get_whisper_prompt, add_word, load_dictionary
from whisprflow.config import HOTKEY, SAMPLE_RATE, WHISPER_LANGUAGE


def _get_input_devices() -> list[dict]:
    devices = sd.query_devices()
    return [{"index": i, "name": d["name"]}
            for i, d in enumerate(devices) if d["max_input_channels"] > 0]


class WhisprFlowApp(rumps.App):
    def __init__(self):
        super().__init__("WhisprFlow", title="⏳")

        self.recorder = Recorder()
        self.transcriber = Transcriber()
        self.polisher = Polisher()

        self.recording = False
        self.processing = False
        self._target_app = None

        # Menu
        self.status_item = rumps.MenuItem("Loading...", callback=None)
        self.status_item.set_callback(None)

        self.mode_menu = rumps.MenuItem("✨ Polish Mode")
        self._build_mode_menu()

        self.stt_menu = rumps.MenuItem("🎙 Speech Engine")
        self._build_stt_menu()

        self.provider_menu = rumps.MenuItem("🤖 Polish Engine")
        self._build_provider_menu()

        self.mic_menu = rumps.MenuItem("🎤 Microphone")
        self._build_mic_menu()

        self.stats_item = rumps.MenuItem("📊 Stats")
        self.dict_item = rumps.MenuItem("📖 Dictionary")
        self.add_word_item = rumps.MenuItem("➕ Add Word...")
        self.groq_key_item = rumps.MenuItem("🔑 Groq API Key...")
        self.anthropic_key_item = rumps.MenuItem("🔑 Anthropic API Key...")

        self.menu = [
            self.status_item,
            None,
            self.mode_menu,
            self.stt_menu,
            self.provider_menu,
            self.mic_menu,
            None,
            self.stats_item,
            self.dict_item,
            self.add_word_item,
            None,
            self.groq_key_item,
            self.anthropic_key_item,
            None,
            rumps.MenuItem("Hotkey: hold CTRL", callback=None),
        ]

        self._start_hotkey_listener()
        threading.Thread(target=self._warm_up, daemon=True).start()

    # --- Warm up ---

    def _warm_up(self):
        stt = get_stt_provider()
        if stt == "local":
            self.status_item.title = "⏳ Loading Whisper model..."
            try:
                self.transcriber.warm_up()
            except Exception as e:
                print(f"[WhisprFlow] Whisper warm-up: {e}")

        polish = get_provider()
        if polish == "ollama":
            self.status_item.title = "⏳ Loading Ollama..."
            try:
                self.polisher.warm_up()
            except Exception as e:
                print(f"[WhisprFlow] Ollama warm-up: {e}")

        self.title = "🎙"
        stt_label = "Groq" if stt == "groq" else "Local"
        polish_label = "Claude" if polish == "anthropic" else "Ollama"
        self.status_item.title = f"✅ Ready ({stt_label} → {polish_label}) — hold CTRL"

    # --- Build menus ---

    def _build_mode_menu(self):
        for key, mode in MODES.items():
            item = rumps.MenuItem(mode["label"], callback=self._make_mode_cb(key))
            item.state = 1 if key == self.polisher.mode else 0
            self.mode_menu.add(item)

    def _make_mode_cb(self, mode_key):
        def cb(_):
            self.polisher.mode = mode_key
            for item in self.mode_menu.values():
                item.state = 0
            self.mode_menu[MODES[mode_key]["label"]].state = 1
        return cb

    def _build_stt_menu(self):
        current = get_stt_provider()

        def set_groq(_):
            if not get_groq_key():
                self._prompt_groq_key()
                if not get_groq_key():
                    return
            save_stt_provider("groq")
            self.stt_menu["☁️ Groq (online, fast)"].state = 1
            self.stt_menu["💻 Local Whisper (offline)"].state = 0

        def set_local(_):
            save_stt_provider("local")
            self.stt_menu["☁️ Groq (online, fast)"].state = 0
            self.stt_menu["💻 Local Whisper (offline)"].state = 1
            threading.Thread(target=self.transcriber.warm_up, daemon=True).start()

        groq_item = rumps.MenuItem("☁️ Groq (online, fast)", callback=set_groq)
        groq_item.state = 1 if current == "groq" else 0
        local_item = rumps.MenuItem("💻 Local Whisper (offline)", callback=set_local)
        local_item.state = 1 if current == "local" else 0

        self.stt_menu.add(groq_item)
        self.stt_menu.add(local_item)

    def _build_provider_menu(self):
        current = get_provider()

        def set_ollama(_):
            save_provider("ollama")
            self.provider_menu["💻 Ollama (local)"].state = 1
            self.provider_menu["☁️ Anthropic Claude"].state = 0

        def set_anthropic(_):
            if not get_api_key():
                self._prompt_anthropic_key()
                if not get_api_key():
                    return
            save_provider("anthropic")
            self.provider_menu["💻 Ollama (local)"].state = 0
            self.provider_menu["☁️ Anthropic Claude"].state = 1

        ollama_item = rumps.MenuItem("💻 Ollama (local)", callback=set_ollama)
        ollama_item.state = 1 if current == "ollama" else 0
        anthropic_item = rumps.MenuItem("☁️ Anthropic Claude", callback=set_anthropic)
        anthropic_item.state = 1 if current == "anthropic" else 0

        self.provider_menu.add(ollama_item)
        self.provider_menu.add(anthropic_item)

    def _build_mic_menu(self):
        devices = _get_input_devices()

        def make_cb(idx, name):
            def cb(_):
                self.recorder.set_device(idx)
                for item in self.mic_menu.values():
                    item.state = 0
                self.mic_menu[name].state = 1
            return cb

        def set_default(_):
            self.recorder.set_device(None)
            for item in self.mic_menu.values():
                item.state = 0
            self.mic_menu["System Default"].state = 1

        default = rumps.MenuItem("System Default", callback=set_default)
        default.state = 1
        self.mic_menu.add(default)
        for d in devices:
            self.mic_menu.add(rumps.MenuItem(d["name"], callback=make_cb(d["index"], d["name"])))

    # --- Hotkey ---

    def _start_hotkey_listener(self):
        if HOTKEY == "ctrl":
            self._start_ctrl_push_to_talk()
        else:
            hotkey_map = {"f5": keyboard.Key.f5, "f6": keyboard.Key.f6, "f8": keyboard.Key.f8}
            target_key = hotkey_map.get(HOTKEY, keyboard.Key.f5)
            def on_press(key):
                if key == target_key and not self.processing:
                    if self.recording:
                        self._stop_and_process()
                    else:
                        self._start_recording()
            listener = keyboard.Listener(on_press=on_press)
            listener.daemon = True
            listener.start()

    def _start_ctrl_push_to_talk(self):
        ctrl_held_alone = [True]

        def on_press(key):
            try:
                if key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r:
                    ctrl_held_alone[0] = True
                    if not self.recording and not self.processing:
                        self._start_recording()
                else:
                    ctrl_held_alone[0] = False
            except Exception as e:
                print(f"[WhisprFlow] on_press error: {e}")

        def on_release(key):
            try:
                if key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r:
                    if self.recording and ctrl_held_alone[0]:
                        self._stop_and_process()
                    ctrl_held_alone[0] = True
            except Exception as e:
                print(f"[WhisprFlow] on_release error: {e}")

        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.daemon = True
        listener.start()

    # --- Recording / Processing ---

    def _start_recording(self):
        self._target_app = get_frontmost_app()
        self.recording = True
        self.title = "🔴"
        self.status_item.title = "🔴 Recording..."
        self.recorder.start()

    def _stop_and_process(self):
        self.recording = False
        self.processing = True
        self.title = "⏳"
        self.status_item.title = "⏳ Transcribing..."
        threading.Thread(target=self._process_audio, daemon=True).start()

    def _process_audio(self):
        start_time = time.time()
        try:
            audio = self.recorder.stop()
            if len(audio) < SAMPLE_RATE * 0.3:
                self._finish("Too short")
                return

            t0 = time.time()
            prompt = get_whisper_prompt()
            raw_text = self.transcriber.transcribe(audio, language=WHISPER_LANGUAGE, prompt=prompt)
            t_transcribe = time.time() - t0

            if not raw_text.strip():
                self._finish("No speech detected")
                return

            print(f"[WhisprFlow] RAW: {raw_text}")

            self.status_item.title = "⏳ Polishing..."
            t1 = time.time()
            tone = get_tone_for_app(self._target_app)
            final_text = self.polisher.polish(raw_text, extra_context=tone)
            t_polish = time.time() - t1

            print(f"[WhisprFlow] POLISHED: {final_text}")

            paste_text(final_text)

            duration = time.time() - start_time
            log_transcription(raw_text, final_text, duration, self._target_app)

            mode = MODES[self.polisher.mode]["label"]
            word_count = len(final_text.split())
            self._finish(f"✅ {word_count}w [{mode}] {duration:.1f}s (stt:{t_transcribe:.1f} llm:{t_polish:.1f})")

        except Exception as e:
            self._finish(f"Error: {e}")
            import traceback
            traceback.print_exc()

    def _finish(self, message: str):
        self.processing = False
        self.title = "🎙"
        self.status_item.title = message
        print(f"[WhisprFlow] {message}")
        threading.Timer(8.0, self._reset_status).start()

    def _reset_status(self):
        if not self.recording and not self.processing:
            self.status_item.title = "Ready — hold CTRL"

    # --- Menu Actions ---

    @rumps.clicked("📊 Stats")
    def show_stats(self, _):
        s = get_stats()
        msg = (
            f"Words today: {s['words_today']}\n"
            f"Words this week: {s['words_week']}\n"
            f"Words total: {s['words_total']}\n"
            f"Transcriptions: {s['transcription_count']}\n"
            f"Avg. processing: {s['avg_duration']}s\n"
            f"Time saved: ~{s['time_saved_min']} min\n"
        )
        if s["top_apps"]:
            msg += "\nTop apps:\n"
            for name, count in s["top_apps"]:
                msg += f"  {name}: {count}x\n"
        rumps.alert("WhisprFlow Stats", msg)

    @rumps.clicked("📖 Dictionary")
    def show_dictionary(self, _):
        words = load_dictionary()
        if words:
            rumps.alert("Custom Dictionary", ", ".join(words))
        else:
            rumps.alert("Custom Dictionary", "No custom words yet.")

    @rumps.clicked("➕ Add Word...")
    def add_word_dialog(self, _):
        response = rumps.Window(
            message="Add a word or phrase:",
            title="Add to Dictionary",
            default_text="",
            ok="Add",
            cancel="Cancel",
        ).run()
        if response.clicked and response.text.strip():
            add_word(response.text.strip())
            rumps.notification("WhisprFlow", "Word added", response.text.strip())

    @rumps.clicked("🔑 Groq API Key...")
    def set_groq_key(self, _):
        self._prompt_groq_key()

    @rumps.clicked("🔑 Anthropic API Key...")
    def set_anthropic_key(self, _):
        self._prompt_anthropic_key()

    def _prompt_groq_key(self):
        current = get_groq_key() or ""
        masked = current[:8] + "..." if len(current) > 8 else current
        response = rumps.Window(
            message=f"Groq API Key (free at console.groq.com):\nCurrent: {masked or 'not set'}",
            title="Groq API Key",
            default_text="",
            ok="Save",
            cancel="Cancel",
        ).run()
        if response.clicked and response.text.strip():
            save_groq_key(response.text.strip())
            save_stt_provider("groq")
            self.stt_menu["☁️ Groq (online, fast)"].state = 1
            self.stt_menu["💻 Local Whisper (offline)"].state = 0
            rumps.notification("WhisprFlow", "Groq key saved", "Using Groq for speech recognition")

    def _prompt_anthropic_key(self):
        current = get_api_key() or ""
        masked = current[:8] + "..." if len(current) > 8 else current
        response = rumps.Window(
            message=f"Anthropic API Key:\nCurrent: {masked or 'not set'}",
            title="Anthropic API Key",
            default_text="",
            ok="Save",
            cancel="Cancel",
        ).run()
        if response.clicked and response.text.strip():
            save_api_key(response.text.strip())
            save_provider("anthropic")
            self.provider_menu["💻 Ollama (local)"].state = 0
            self.provider_menu["☁️ Anthropic Claude"].state = 1
            rumps.notification("WhisprFlow", "Anthropic key saved", "Using Claude for polishing")


def main():
    WhisprFlowApp().run()
