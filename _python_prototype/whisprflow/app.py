"""WhisprFlow v2.0 — Mac Menu Bar dictation app."""

import threading
import time
import rumps
import sounddevice as sd
from pynput import keyboard

from whisprflow import settings
from whisprflow.recorder import Recorder
from whisprflow.transcriber import Transcriber
from whisprflow.polisher import Polisher, get_all_modes, DEFAULT_MODES
from whisprflow.paster import paste_text
from whisprflow.app_context import get_frontmost_app, get_tone_for_app
from whisprflow.stats import log_transcription, get_stats
from whisprflow.dictionary import get_whisper_prompt, add_word, load_dictionary
from whisprflow.license import can_use, is_licensed, remaining_trial, validate_license
from whisprflow.onboarding import needs_onboarding, run_onboarding
from whisprflow.config import VERSION, SAMPLE_RATE, LANGUAGES, HOTKEYS


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

        # Run onboarding if first launch
        if needs_onboarding():
            run_onboarding()

        self._build_menu()
        self._start_hotkey_listener()
        threading.Thread(target=self._warm_up, daemon=True).start()

    def _build_menu(self):
        self.status_item = rumps.MenuItem("Loading...", callback=None)
        self.status_item.set_callback(None)

        # License status
        if is_licensed():
            license_label = "🔐 Licensed ✅"
        else:
            remaining = remaining_trial()
            license_label = f"🔐 Trial ({remaining} uses left)"

        self.license_item = rumps.MenuItem(license_label)

        # Polish mode
        self.mode_menu = rumps.MenuItem("✨ Polish Mode")
        self._build_mode_menu()

        # STT engine
        self.stt_menu = rumps.MenuItem("🎙 Speech Engine")
        self._build_stt_menu()

        # Polish engine
        self.provider_menu = rumps.MenuItem("🤖 Polish Engine")
        self._build_provider_menu()

        # Language
        self.lang_menu = rumps.MenuItem("🌐 Language")
        self._build_lang_menu()

        # Hotkey
        self.hotkey_menu = rumps.MenuItem("⌨️ Hotkey")
        self._build_hotkey_menu()

        # Microphone
        self.mic_menu = rumps.MenuItem("🎤 Microphone")
        self._build_mic_menu()

        self.menu = [
            self.status_item,
            None,
            self.mode_menu,
            rumps.MenuItem("➕ New Scenario...", callback=self._new_scenario),
            rumps.MenuItem("📝 Edit Current Prompt...", callback=self._edit_prompt),
            None,
            self.stt_menu,
            self.provider_menu,
            self.lang_menu,
            self.hotkey_menu,
            self.mic_menu,
            None,
            rumps.MenuItem("📊 Stats", callback=self._show_stats),
            rumps.MenuItem("📖 Dictionary", callback=self._show_dictionary),
            rumps.MenuItem("➕ Add Word...", callback=self._add_word),
            None,
            self.license_item,
            rumps.MenuItem("🔑 API Keys...", callback=self._manage_keys),
            rumps.MenuItem("🔄 Setup Wizard...", callback=self._rerun_onboarding),
            None,
            rumps.MenuItem(f"WhisprFlow v{VERSION}", callback=None),
        ]

    # --- Warm up ---

    def _warm_up(self):
        stt = settings.get_stt_provider()
        if stt == "local":
            self.status_item.title = "⏳ Loading Whisper..."
            try:
                self.transcriber.warm_up()
            except Exception as e:
                print(f"[WhisprFlow] Whisper: {e}")

        if settings.get_polish_provider() == "ollama":
            self.status_item.title = "⏳ Loading Ollama..."
            try:
                self.polisher.warm_up()
            except Exception as e:
                print(f"[WhisprFlow] Ollama: {e}")

        self.title = "🎙"
        hotkey_desc = HOTKEYS.get(settings.get_hotkey(), "CTRL")
        self.status_item.title = f"✅ Ready — {hotkey_desc}"

    # --- Build submenus ---

    def _build_mode_menu(self):
        all_modes = get_all_modes()
        has_custom = any(k not in DEFAULT_MODES for k in all_modes)

        for key, mode in DEFAULT_MODES.items():
            item = rumps.MenuItem(mode["label"], callback=self._make_mode_cb(key))
            item.state = 1 if key == self.polisher.mode else 0
            self.mode_menu.add(item)

        if has_custom:
            self.mode_menu.add(None)  # separator
            for key, mode in all_modes.items():
                if key not in DEFAULT_MODES:
                    item = rumps.MenuItem(f"⭐ {mode['label']}", callback=self._make_mode_cb(key))
                    item.state = 1 if key == self.polisher.mode else 0
                    self.mode_menu.add(item)

    def _make_mode_cb(self, mode_key):
        def cb(_):
            self.polisher.mode = mode_key
            all_modes = get_all_modes()
            for item in self.mode_menu.values():
                item.state = 0
            label = all_modes[mode_key]["label"]
            if mode_key not in DEFAULT_MODES:
                label = f"⭐ {label}"
            if label in self.mode_menu:
                self.mode_menu[label].state = 1
        return cb

    def _build_stt_menu(self):
        current = settings.get_stt_provider()

        def set_groq(_):
            if not settings.get_groq_key():
                self._prompt_key("groq")
            settings.set_stt_provider("groq")
            self.stt_menu["☁️ Groq (fast)"].state = 1
            self.stt_menu["💻 Local (offline)"].state = 0

        def set_local(_):
            settings.set_stt_provider("local")
            self.stt_menu["☁️ Groq (fast)"].state = 0
            self.stt_menu["💻 Local (offline)"].state = 1
            threading.Thread(target=self.transcriber.warm_up, daemon=True).start()

        g = rumps.MenuItem("☁️ Groq (fast)", callback=set_groq)
        g.state = 1 if current == "groq" else 0
        l = rumps.MenuItem("💻 Local (offline)", callback=set_local)
        l.state = 1 if current == "local" else 0
        self.stt_menu.add(g)
        self.stt_menu.add(l)

    def _build_provider_menu(self):
        current = settings.get_polish_provider()

        def set_anthropic(_):
            if not settings.get_anthropic_key():
                self._prompt_key("anthropic")
            settings.set_polish_provider("anthropic")
            self.provider_menu["☁️ Claude"].state = 1
            self.provider_menu["💻 Ollama (local)"].state = 0

        def set_ollama(_):
            settings.set_polish_provider("ollama")
            self.provider_menu["☁️ Claude"].state = 0
            self.provider_menu["💻 Ollama (local)"].state = 1

        a = rumps.MenuItem("☁️ Claude", callback=set_anthropic)
        a.state = 1 if current == "anthropic" else 0
        o = rumps.MenuItem("💻 Ollama (local)", callback=set_ollama)
        o.state = 1 if current == "ollama" else 0
        self.provider_menu.add(a)
        self.provider_menu.add(o)

    def _build_lang_menu(self):
        current = settings.get_language() or "de"
        for code, name in LANGUAGES.items():
            item = rumps.MenuItem(f"{name}", callback=self._make_lang_cb(code))
            item.state = 1 if code == current else 0
            self.lang_menu.add(item)

    def _make_lang_cb(self, code):
        def cb(_):
            settings.set_language(code if code != "auto" else None)
            for item in self.lang_menu.values():
                item.state = 0
            self.lang_menu[LANGUAGES[code]].state = 1
        return cb

    def _build_hotkey_menu(self):
        current = settings.get_hotkey()
        current_desc = HOTKEYS.get(current, current.upper())

        self.hotkey_current = rumps.MenuItem(f"Current: {current_desc}", callback=None)
        self.hotkey_current.set_callback(None)
        self.hotkey_menu.add(self.hotkey_current)
        self.hotkey_menu.add(rumps.MenuItem("🎯 Press new key...", callback=self._capture_hotkey))

    def _capture_hotkey(self, _):
        rumps.notification("WhisprFlow", "Press your desired hotkey now", "Waiting for keypress...")

        def capture():
            def on_press(key):
                key_name = None
                if key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r:
                    key_name = "ctrl"
                elif key == keyboard.Key.f5:
                    key_name = "f5"
                elif key == keyboard.Key.f6:
                    key_name = "f6"
                elif key == keyboard.Key.f8:
                    key_name = "f8"
                elif key == keyboard.Key.f9:
                    key_name = "f9"
                elif key == keyboard.Key.f10:
                    key_name = "f10"
                elif key == keyboard.Key.f11:
                    key_name = "f11"
                elif key == keyboard.Key.f12:
                    key_name = "f12"
                elif hasattr(key, 'char') and key.char:
                    key_name = key.char

                if key_name:
                    settings.set_hotkey(key_name)
                    desc = HOTKEYS.get(key_name, key_name.upper())
                    self.hotkey_current.title = f"Current: {desc}"
                    rumps.alert("Hotkey Set ✅", f"New hotkey: {desc}\n\nRestart WhisprFlow for the change to take effect.")
                    return False  # stop listener

            listener = keyboard.Listener(on_press=on_press)
            listener.start()
            listener.join(timeout=10)  # 10 second timeout
            if listener.is_alive():
                listener.stop()
                rumps.notification("WhisprFlow", "Timeout", "No key pressed. Hotkey unchanged.")

        threading.Thread(target=capture, daemon=True).start()

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

        d = rumps.MenuItem("System Default", callback=set_default)
        d.state = 1
        self.mic_menu.add(d)
        for dev in devices:
            self.mic_menu.add(rumps.MenuItem(dev["name"], callback=make_cb(dev["index"], dev["name"])))

    # --- Hotkey listener ---

    def _start_hotkey_listener(self):
        hotkey = settings.get_hotkey()
        if hotkey == "ctrl":
            self._start_ctrl_push_to_talk()
        else:
            hotkey_map = {"f5": keyboard.Key.f5, "f6": keyboard.Key.f6, "f8": keyboard.Key.f8}
            target_key = hotkey_map.get(hotkey, keyboard.Key.f5)
            def on_press(key):
                try:
                    if key == target_key and not self.processing:
                        if self.recording:
                            self._stop_and_process()
                        else:
                            self._start_recording()
                except Exception as e:
                    print(f"[WhisprFlow] Hotkey error: {e}")
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
                print(f"[WhisprFlow] on_press: {e}")

        def on_release(key):
            try:
                if key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r:
                    if self.recording and ctrl_held_alone[0]:
                        self._stop_and_process()
                    ctrl_held_alone[0] = True
            except Exception as e:
                print(f"[WhisprFlow] on_release: {e}")

        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.daemon = True
        listener.start()

    # --- Recording / Processing ---

    def _start_recording(self):
        if not can_use():
            rumps.notification("WhisprFlow", "Trial expired",
                              "Enter a license key to continue using WhisprFlow.")
            return

        self._target_app = get_frontmost_app()
        self.recording = True
        self.title = "🔴"
        self.status_item.title = "🔴 Recording..."
        self.recorder.start()

    def _stop_and_process(self):
        self.recording = False
        self.processing = True
        self.title = "⏳"
        self.status_item.title = "⏳ Processing..."
        threading.Thread(target=self._process_audio, daemon=True).start()

    def _process_audio(self):
        start_time = time.time()
        try:
            audio = self.recorder.stop()
            if len(audio) < SAMPLE_RATE * 0.3:
                self._finish("Too short")
                return

            # Transcribe
            t0 = time.time()
            prompt = get_whisper_prompt()
            raw_text = self.transcriber.transcribe(audio, prompt=prompt)
            t_stt = time.time() - t0

            if not raw_text.strip():
                self._finish("No speech detected")
                return

            print(f"[WhisprFlow] RAW: {raw_text}")

            # Polish
            self.status_item.title = "⏳ Polishing..."
            t1 = time.time()
            tone = get_tone_for_app(self._target_app)
            final_text = self.polisher.polish(raw_text, extra_context=tone)
            t_llm = time.time() - t1

            print(f"[WhisprFlow] POLISHED: {final_text}")

            # Paste
            paste_text(final_text)

            # Track
            duration = time.time() - start_time
            log_transcription(raw_text, final_text, duration, self._target_app)
            if not is_licensed():
                settings.increment_trial_uses()
                remaining = remaining_trial()
                if remaining <= 10 and remaining > 0:
                    rumps.notification("WhisprFlow", f"Trial: {remaining} uses left",
                                      "Enter a license key for unlimited access.")
                self._update_license_label()

            all_modes = get_all_modes()
            mode_label = all_modes.get(self.polisher.mode, {}).get("label", "?")
            words = len(final_text.split())
            self._finish(f"✅ {words}w [{mode_label}] {duration:.1f}s")

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
            hotkey_desc = HOTKEYS.get(settings.get_hotkey(), "CTRL")
            self.status_item.title = f"Ready — {hotkey_desc}"

    def _update_license_label(self):
        if is_licensed():
            self.license_item.title = "🔐 Licensed ✅"
        else:
            self.license_item.title = f"🔐 Trial ({remaining_trial()} left)"

    # --- Menu actions ---

    def _new_scenario(self, _):
        name_resp = rumps.Window(
            title="New Polishing Scenario",
            message="Give your scenario a name:",
            default_text="",
            ok="Next",
            cancel="Cancel",
        ).run()
        if not name_resp.clicked or not name_resp.text.strip():
            return

        name = name_resp.text.strip()
        key = name.lower().replace(" ", "_")

        prompt_resp = rumps.Window(
            title=f"Prompt for '{name}'",
            message="Write the system prompt. This tells the AI how to process your text.\n\nExample: 'Rewrite as a professional LinkedIn post. Keep it under 200 words.'",
            default_text="",
            ok="Create",
            cancel="Cancel",
        ).run()
        if not prompt_resp.clicked or not prompt_resp.text.strip():
            return

        settings.add_custom_mode(key, name, prompt_resp.text.strip())
        self.polisher.mode = key

        # Add to menu
        item = rumps.MenuItem(f"⭐ {name}", callback=self._make_mode_cb(key))
        item.state = 1
        for i in self.mode_menu.values():
            i.state = 0
        self.mode_menu.add(item)

        rumps.notification("WhisprFlow", "Scenario created", f"'{name}' is now active")

    def _edit_prompt(self, _):
        all_modes = get_all_modes()
        current = all_modes.get(self.polisher.mode, {})
        current_prompt = current.get("prompt", "")

        if current_prompt is None:
            rumps.alert("Raw Mode", "Raw mode has no prompt to edit.")
            return

        resp = rumps.Window(
            title=f"Edit Prompt: {current.get('label', '?')}",
            message="Modify the system prompt:",
            default_text=current_prompt,
            ok="Save",
            cancel="Cancel",
        ).run()
        if resp.clicked and resp.text.strip():
            # Save as custom mode (override)
            label = current.get("label", self.polisher.mode).lstrip("⭐🧹💼📣💻📧💬✏️ ")
            settings.add_custom_mode(self.polisher.mode, label, resp.text.strip())
            rumps.notification("WhisprFlow", "Prompt updated", f"Changes saved for '{label}'")

    def _show_stats(self, _):
        s = get_stats()
        msg = (
            f"📝 Words today: {s['words_today']}\n"
            f"📅 Words this week: {s['words_week']}\n"
            f"📊 Words total: {s['words_total']}\n"
            f"🔢 Transcriptions: {s['transcription_count']}\n"
            f"⏱️ Avg. processing: {s['avg_duration']}s\n"
            f"⏰ Time saved: ~{s['time_saved_min']} min\n"
        )
        if s["top_apps"]:
            msg += "\n🏆 Top apps:\n"
            for name, count in s["top_apps"]:
                msg += f"   {name}: {count}x\n"
        rumps.alert(f"WhisprFlow Stats", msg)

    def _show_dictionary(self, _):
        words = load_dictionary()
        if words:
            rumps.alert("Custom Dictionary", ", ".join(words))
        else:
            rumps.alert("Custom Dictionary", "No custom words yet.")

    def _add_word(self, _):
        resp = rumps.Window(
            message="Add a word or phrase for better recognition:",
            title="Add to Dictionary",
            default_text="",
            ok="Add",
            cancel="Cancel",
        ).run()
        if resp.clicked and resp.text.strip():
            add_word(resp.text.strip())
            rumps.notification("WhisprFlow", "Added", resp.text.strip())

    def _manage_keys(self, _):
        resp = rumps.alert(
            title="API Keys",
            message="Which key do you want to set?",
            ok="Groq (Speech)",
            cancel="Anthropic (Polish)",
            other="Enter License Key",
        )
        if resp == 1:
            self._prompt_key("groq")
        elif resp == 0:
            self._prompt_key("anthropic")
        elif resp == 2:
            self._prompt_license_key()

    def _prompt_key(self, provider: str):
        if provider == "groq":
            current = settings.get_groq_key() or ""
            title = "Groq API Key"
            hint = "Get free key at console.groq.com/keys"
        else:
            current = settings.get_anthropic_key() or ""
            title = "Anthropic API Key"
            hint = "Get key at console.anthropic.com"

        masked = current[:12] + "..." if len(current) > 12 else current
        resp = rumps.Window(
            title=title,
            message=f"{hint}\n\nCurrent: {masked or 'not set'}",
            default_text="",
            ok="Save",
            cancel="Cancel",
        ).run()
        if resp.clicked and resp.text.strip():
            if provider == "groq":
                settings.set_groq_key(resp.text.strip())
            else:
                settings.set_anthropic_key(resp.text.strip())
            rumps.notification("WhisprFlow", "Key saved", f"{title} updated")

    def _prompt_license_key(self):
        resp = rumps.Window(
            title="Enter License Key",
            message="Format: WF-XXXXX-XXXXX-XXXXX-XXXXX",
            default_text="",
            ok="Activate",
            cancel="Cancel",
        ).run()
        if resp.clicked and resp.text.strip():
            if validate_license(resp.text.strip()):
                settings.set_license_key(resp.text.strip())
                self._update_license_label()
                rumps.alert("License Activated ✅", "Lifetime access unlocked!")
            else:
                rumps.alert("Invalid Key ❌", "Please check and try again.")

    def _rerun_onboarding(self, _):
        run_onboarding()


def main():
    WhisprFlowApp().run()
