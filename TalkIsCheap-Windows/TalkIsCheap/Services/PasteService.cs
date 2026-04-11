using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;

namespace TalkIsCheap.Services
{
    public static class PasteService
    {
        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        private const byte VK_CONTROL = 0x11;
        private const byte VK_V = 0x56;
        private const uint KEYEVENTF_KEYUP = 0x0002;

        /// <summary>
        /// Copy text to clipboard and simulate Ctrl+V to paste it.
        /// </summary>
        public static void Paste(string text)
        {
            if (string.IsNullOrEmpty(text)) return;

            try
            {
                // Must set clipboard on STA thread
                var thread = new Thread(() =>
                {
                    try
                    {
                        Clipboard.SetText(text);
                    }
                    catch (Exception ex)
                    {
                        Logger.Write($"Clipboard error: {ex.Message}");
                    }
                });
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
                thread.Join(2000);

                // Small delay to ensure clipboard is ready
                Thread.Sleep(150);

                // Pause hotkey hook so simulated Ctrl+V doesn't trigger dictation
                HotkeyManager.Shared.Stop();
                Thread.Sleep(50);

                // Simulate Ctrl+V using keybd_event (more reliable than SendInput)
                keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);           // Ctrl down
                keybd_event(VK_V, 0, 0, UIntPtr.Zero);                 // V down
                keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);   // V up
                keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero); // Ctrl up

                // Wait for paste to complete, then re-enable hook
                Thread.Sleep(200);
                HotkeyManager.Shared.Start();

                Logger.Write($"Pasted {text.Length} chars via keybd_event");
            }
            catch (Exception ex)
            {
                Logger.Write($"Paste failed: {ex.Message}");
                // Always re-enable hook
                try { HotkeyManager.Shared.Start(); } catch { }
            }
        }
    }
}
