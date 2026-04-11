using System;
using System.Runtime.InteropServices;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    /// <summary>
    /// Dims system audio volume while recording, restores on stop.
    /// Uses Windows Core Audio API via COM interop (IAudioEndpointVolume).
    /// </summary>
    public class AudioDimmer
    {
        private static AudioDimmer? _instance;
        private static readonly object _lock = new();

        public static AudioDimmer Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new AudioDimmer();
                    }
                }
                return _instance;
            }
        }

        private float? _originalVolume;
        private const float DimFactor = 0.15f;

        // COM interfaces for Windows Core Audio
        [ComImport]
        [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumerator { }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
            int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            int Activate([MarshalAs(UnmanagedType.LPStruct)] Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        }

        [ComImport]
        [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioEndpointVolume
        {
            int RegisterControlChangeNotify(IntPtr pNotify);
            int UnregisterControlChangeNotify(IntPtr pNotify);
            int GetChannelCount(out uint pnChannelCount);
            int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
            int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
            int GetMasterVolumeLevel(out float pfLevelDB);
            int GetMasterVolumeLevelScalar(out float pfLevel);
        }

        private static readonly Guid AudioEndpointVolumeIid = new("5CDF2C82-841E-4546-9722-0CF74078229A");

        public void Dim()
        {
            if (!AppSettings.Shared.DimAudioWhileRecording) return;

            try
            {
                var volume = GetVolume();
                if (volume == null) return;

                _originalVolume = volume.Value;
                var dimmed = volume.Value * DimFactor;
                SetVolume(dimmed);
                Logger.Write($"Audio dimmed: {volume.Value * 100:F0}% -> {dimmed * 100:F0}%");
            }
            catch (Exception ex)
            {
                Logger.Write($"Audio dim failed: {ex.Message}");
            }
        }

        public void Restore()
        {
            if (_originalVolume == null) return;

            try
            {
                SetVolume(_originalVolume.Value);
                Logger.Write($"Audio restored: {_originalVolume.Value * 100:F0}%");
                _originalVolume = null;
            }
            catch (Exception ex)
            {
                Logger.Write($"Audio restore failed: {ex.Message}");
                _originalVolume = null;
            }
        }

        private IAudioEndpointVolume? GetEndpointVolume()
        {
            try
            {
                var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out var device);
                device.Activate(AudioEndpointVolumeIid, 1 /* CLSCTX_ALL */, IntPtr.Zero, out var obj);
                return (IAudioEndpointVolume)obj;
            }
            catch
            {
                return null;
            }
        }

        private float? GetVolume()
        {
            var endpoint = GetEndpointVolume();
            if (endpoint == null) return null;

            endpoint.GetMasterVolumeLevelScalar(out float level);
            return level;
        }

        private void SetVolume(float level)
        {
            var endpoint = GetEndpointVolume();
            if (endpoint == null) return;

            var guid = Guid.Empty;
            endpoint.SetMasterVolumeLevelScalar(Math.Clamp(level, 0f, 1f), ref guid);
        }
    }
}
