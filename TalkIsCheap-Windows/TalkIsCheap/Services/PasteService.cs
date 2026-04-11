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

                // Simulate Ctrl+V
                SimulateCtrlV();

                Logger.Write($"Pasted {text.Length} chars");
            }
            catch (Exception ex)
            {
                Logger.Write($"Paste failed: {ex.Message}");
            }
        }

        private static void SimulateCtrlV()
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
                Logger.Write($"SendInput returned {result} (expected 4)");
            }
        }
    }
}
