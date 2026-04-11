using System;
using System.IO;
using NAudio.Wave;

namespace TalkIsCheap.Services
{
    public class AudioRecorder : IDisposable
    {
        private WaveInEvent? _waveIn;
        private MemoryStream? _memoryStream;
        private WaveFileWriter? _writer;
        private bool _disposed;

        public bool IsRecording { get; private set; }

        // Record at 16kHz mono 16-bit PCM (ideal for Whisper)
        private readonly WaveFormat _format = new(16000, 16, 1);

        /// <summary>
        /// Returns a list of available recording devices (index, name).
        /// </summary>
        public static List<(int Index, string Name)> GetDevices()
        {
            var devices = new List<(int, string)>();
            for (int i = 0; i < WaveInEvent.DeviceCount; i++)
            {
                var caps = WaveInEvent.GetCapabilities(i);
                devices.Add((i, caps.ProductName));
            }
            return devices;
        }

        public void Start()
        {
            if (IsRecording) return;

            _memoryStream = new MemoryStream();
            _writer = new WaveFileWriter(_memoryStream, _format);

            var deviceIndex = Models.AppSettings.Shared.MicrophoneDevice;
            _waveIn = new WaveInEvent
            {
                DeviceNumber = deviceIndex,
                WaveFormat = _format,
                BufferMilliseconds = 100
            };

            _waveIn.DataAvailable += (s, e) =>
            {
                _writer?.Write(e.Buffer, 0, e.BytesRecorded);
            };

            _waveIn.RecordingStopped += (s, e) =>
            {
                // Handled in Stop()
            };

            try
            {
                _waveIn.StartRecording();
                IsRecording = true;
                Logger.Write("AudioRecorder: started");
            }
            catch (Exception ex)
            {
                Logger.Write($"AudioRecorder: failed to start: {ex.Message}");
                Cleanup();
            }
        }

        /// <summary>
        /// Stop recording and return WAV data as byte array.
        /// </summary>
        public byte[] Stop()
        {
            if (!IsRecording || _waveIn == null || _writer == null || _memoryStream == null)
            {
                IsRecording = false;
                return Array.Empty<byte>();
            }

            try
            {
                _waveIn.StopRecording();
                IsRecording = false;

                _writer.Flush();
                // We need to finalize the WAV header. WaveFileWriter writes to the MemoryStream,
                // but we need to rewrite the header with correct data length.
                _writer.Dispose();
                _writer = null;

                var data = _memoryStream.ToArray();
                Logger.Write($"AudioRecorder: stopped, {data.Length} bytes");

                _memoryStream.Dispose();
                _memoryStream = null;

                _waveIn.Dispose();
                _waveIn = null;

                return data;
            }
            catch (Exception ex)
            {
                Logger.Write($"AudioRecorder: error stopping: {ex.Message}");
                Cleanup();
                return Array.Empty<byte>();
            }
        }

        private void Cleanup()
        {
            IsRecording = false;
            _writer?.Dispose();
            _writer = null;
            _memoryStream?.Dispose();
            _memoryStream = null;
            _waveIn?.Dispose();
            _waveIn = null;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Cleanup();
            GC.SuppressFinalize(this);
        }
    }
}
