using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;

namespace TalkIsCheap.Services
{
    public static class PasteService
    {
        // SendInput P/Invoke structures
        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint Type;
            public INPUTUNION Data;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct INPUTUNION
        {
            [FieldOffset(0)] public KEYBDINPUT KeyboardInput;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort VirtualKey;
            public ushort ScanCode;
            public uint Flags;
            public uint Time;
            public IntPtr ExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const ushort VK_CONTROL = 0x11;
        private const ushort VK_V = 0x56;

        /// <summary>
        /// Copy text to clipboard and simulate Ctrl+V to paste it.
        /// Temporarily pauses the hotkey hook to avoid the simulated Ctrl
        /// from re-triggering dictation.
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
                Thread.Sleep(100);

                // Pause hotkey hook so simulated Ctrl+V doesn't trigger dictation
                HotkeyManager.Shared.Stop();
                Thread.Sleep(50);

                // Simulate Ctrl+V
                SimulateCtrlV();

                // Wait for paste to complete, then re-enable hook
                Thread.Sleep(150);
                HotkeyManager.Shared.Start();

                Logger.Write($"Pasted {text.Length} chars");
            }
            catch (Exception ex)
            {
                Logger.Write($"Paste failed: {ex.Message}");
                // Always re-enable hook
                try { HotkeyManager.Shared.Start(); } catch { }
            }
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        private static void SimulateCtrlV()
        {
            // Attach to foreground window's thread to ensure SendInput works
            var hwnd = GetForegroundWindow();
            GetWindowThreadProcessId(hwnd, out _);
            var foregroundThread = GetWindowThreadProcessId2(hwnd);
            var currentThread = GetCurrentThreadId();

            bool attached = false;
            if (foregroundThread != currentThread)
            {
                attached = AttachThreadInput(currentThread, foregroundThread, true);
            }

            try
            {
                var inputs = new INPUT[4];

                // Ctrl down
                inputs[0].Type = INPUT_KEYBOARD;
                inputs[0].Data.KeyboardInput.VirtualKey = VK_CONTROL;

                // V down
                inputs[1].Type = INPUT_KEYBOARD;
                inputs[1].Data.KeyboardInput.VirtualKey = VK_V;

                // V up
                inputs[2].Type = INPUT_KEYBOARD;
                inputs[2].Data.KeyboardInput.VirtualKey = VK_V;
                inputs[2].Data.KeyboardInput.Flags = KEYEVENTF_KEYUP;

                // Ctrl up
                inputs[3].Type = INPUT_KEYBOARD;
                inputs[3].Data.KeyboardInput.VirtualKey = VK_CONTROL;
                inputs[3].Data.KeyboardInput.Flags = KEYEVENTF_KEYUP;

                var result = SendInput(4, inputs, Marshal.SizeOf<INPUT>());
                if (result != 4)
                {
                    Logger.Write($"SendInput returned {result} (expected 4), last error: {Marshal.GetLastWin32Error()}");
                }
            }
            finally
            {
                if (attached)
                {
                    AttachThreadInput(currentThread, foregroundThread, false);
                }
            }
        }

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);

        private static uint GetWindowThreadProcessId2(IntPtr hwnd)
        {
            return GetWindowThreadProcessId(hwnd, IntPtr.Zero);
        }
    }
}
