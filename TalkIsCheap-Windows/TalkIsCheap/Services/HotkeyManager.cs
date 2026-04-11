using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    /// <summary>
    /// Global hotkey manager with Push-to-Talk, Hands-Free, and Voice Search modes.
    /// Uses low-level keyboard hook (WH_KEYBOARD_LL) for modifier key detection.
    /// </summary>
    public class HotkeyManager : IDisposable
    {
        private static HotkeyManager? _instance;
        private static readonly object _lock = new();

        public static HotkeyManager Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new HotkeyManager();
                    }
                }
                return _instance;
            }
        }

        // Callbacks
        public Action? OnKeyDown { get; set; }
        public Action? OnKeyUp { get; set; }
        public Action? OnCancel { get; set; }
        public Action? OnSearchKeyDown { get; set; }
        public Action? OnSearchKeyUp { get; set; }

        // P/Invoke
        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;

        // Virtual key codes
        private const int VK_LCONTROL = 0xA2;
        private const int VK_RCONTROL = 0xA3;
        private const int VK_LSHIFT = 0xA0;
        private const int VK_RSHIFT = 0xA1;
        private const int VK_SHIFT = 0x10;
        private const int VK_F5 = 0x74;
        private const int VK_F6 = 0x75;
        private const int VK_F8 = 0x77;

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelKeyboardProc? _hookCallback;

        // State
        private bool _controlIsDown;
        private bool _otherKeyPressed;
        private bool _dictationStarted;
        private bool _isHandsFreeMode;
        private bool _isSearchRecording;
        private long _pushStartTicks;
        private long _lastCtrlReleaseTicks;
        private bool _disposed;

        // Timing constants (in ticks, 10000 ticks = 1ms)
        private const long DoubleTapWindowTicks = 4000000;  // 0.4s
        private const long HoldThresholdTicks = 3000000;     // 0.3s

        private int TargetKeyCode => AppSettings.Shared.HotkeyCode;
        private bool IsModifierHotkey => TargetKeyCode == VK_LCONTROL || TargetKeyCode == VK_RCONTROL
            || TargetKeyCode == 162 || TargetKeyCode == 163;

        public bool IsHandsFree => _isHandsFreeMode;

        public void Start()
        {
            Stop();

            _hookCallback = HookCallback;
            using var process = Process.GetCurrentProcess();
            using var module = process.MainModule!;
            _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _hookCallback, GetModuleHandle(module.ModuleName!), 0);

            if (_hookId == IntPtr.Zero)
            {
                Logger.Write($"Failed to set keyboard hook: {Marshal.GetLastWin32Error()}");
            }
            else
            {
                Logger.Write($"Keyboard hook installed (keyCode: {TargetKeyCode}, modifier: {IsModifierHotkey})");
            }
        }

        public void Stop()
        {
            if (_hookId != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
                Logger.Write("Keyboard hook removed");
            }
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                var hookStruct = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                int vkCode = (int)hookStruct.vkCode;
                int msg = wParam.ToInt32();
                bool isKeyDown = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                bool isKeyUp = msg == WM_KEYUP || msg == WM_SYSKEYUP;

                if (IsModifierHotkey)
                {
                    // Handle Ctrl key events
                    if (vkCode == VK_LCONTROL || vkCode == VK_RCONTROL)
                    {
                        bool shiftDown = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;

                        if (isKeyDown)
                        {
                            HandleCtrlDown(shiftDown);
                        }
                        else if (isKeyUp)
                        {
                            HandleCtrlUp(shiftDown);
                        }
                    }
                    else if (_controlIsDown && isKeyDown)
                    {
                        // Another key pressed while Ctrl held
                        _otherKeyPressed = true;
                    }
                }
                else
                {
                    // Non-modifier hotkey (F5, F6, F8)
                    if (vkCode == TargetKeyCode)
                    {
                        if (isKeyDown)
                        {
                            ThreadPool.QueueUserWorkItem(_ => OnKeyDown?.Invoke());
                        }
                        else if (isKeyUp)
                        {
                            ThreadPool.QueueUserWorkItem(_ => OnKeyUp?.Invoke());
                        }
                        return (IntPtr)1; // consume the key
                    }
                }
            }

            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }

        private void HandleCtrlDown(bool shiftDown)
        {
            if (_controlIsDown) return;

            // Ctrl+Shift = Hands-Free dictation
            if (shiftDown)
            {
                _isHandsFreeMode = true;
                _controlIsDown = true;
                _otherKeyPressed = false;
                Logger.Write("HANDS-FREE START (Ctrl+Shift)");
                ThreadPool.QueueUserWorkItem(_ => OnKeyDown?.Invoke());
                return;
            }

            _controlIsDown = true;
            _otherKeyPressed = false;
            _dictationStarted = false;
            _pushStartTicks = DateTime.UtcNow.Ticks;

            // Check for double-tap (Voice Search)
            var now = DateTime.UtcNow.Ticks;
            if (now - _lastCtrlReleaseTicks < DoubleTapWindowTicks && _lastCtrlReleaseTicks > 0)
            {
                _isSearchRecording = true;
                _lastCtrlReleaseTicks = 0;
                Logger.Write("SEARCH: START (double-tap)");
                ThreadPool.QueueUserWorkItem(_ => OnSearchKeyDown?.Invoke());
                return;
            }

            // Start dictation immediately
            _dictationStarted = true;
            Logger.Write("DICTATION: START (hold)");
            ThreadPool.QueueUserWorkItem(_ => OnKeyDown?.Invoke());
        }

        private void HandleCtrlUp(bool shiftDown)
        {
            if (!_controlIsDown) return;
            _controlIsDown = false;

            // Released from hands-free
            if (_isHandsFreeMode)
            {
                _isHandsFreeMode = false;
                Logger.Write("HANDS-FREE STOP");
                ThreadPool.QueueUserWorkItem(_ => OnKeyUp?.Invoke());
                return;
            }

            // Search mode: release = stop recording and search
            if (_isSearchRecording)
            {
                _isSearchRecording = false;
                Logger.Write("SEARCH: STOP (released)");
                ThreadPool.QueueUserWorkItem(_ => OnSearchKeyUp?.Invoke());
                return;
            }

            if (_otherKeyPressed)
            {
                if (_dictationStarted)
                {
                    _dictationStarted = false;
                    Logger.Write("DICTATION: CANCEL (other key pressed)");
                    ThreadPool.QueueUserWorkItem(_ => OnCancel?.Invoke());
                }
                return;
            }

            var now = DateTime.UtcNow.Ticks;
            var holdDuration = now - _pushStartTicks;

            if (holdDuration < HoldThresholdTicks)
            {
                // Short tap -- cancel dictation, remember for double-tap
                if (_dictationStarted)
                {
                    _dictationStarted = false;
                    Logger.Write($"DICTATION: CANCEL (short tap {holdDuration / 10000}ms)");
                    ThreadPool.QueueUserWorkItem(_ => OnCancel?.Invoke());
                }
                _lastCtrlReleaseTicks = now;
            }
            else
            {
                // Long hold release -- stop dictation normally
                _dictationStarted = false;
                _lastCtrlReleaseTicks = 0;
                Logger.Write("DICTATION: STOP (hold released)");
                ThreadPool.QueueUserWorkItem(_ => OnKeyUp?.Invoke());
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Stop();
            GC.SuppressFinalize(this);
        }
    }
}
