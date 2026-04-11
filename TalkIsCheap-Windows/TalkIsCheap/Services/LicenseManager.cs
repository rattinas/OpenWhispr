using System;
using System.Linq;
using System.Management;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    public enum ActivationResult
    {
        Success,
        AlreadyActivated,
        InvalidKey,
        MaxReached,
        Revoked,
        NetworkError
    }

    public class ActivationResponse
    {
        public ActivationResult Result { get; set; }
        public string Token { get; set; } = "";
        public string Message { get; set; } = "";
    }

    public static class LicenseManager
    {
        private static readonly byte[] Secret = Encoding.UTF8.GetBytes("talkischeap-2026-lifetime-key");
        private const string Prefix = "TIC";
        private const string BaseUrl = "https://talkischeap.app/api";
        private static readonly HttpClient HttpClient = new() { Timeout = TimeSpan.FromSeconds(15) };

        // MARK: - Hardware ID

        public static string HardwareId()
        {
            try
            {
                // Try WMI for processor ID + motherboard serial
                var processorId = GetWmiValue("Win32_Processor", "ProcessorId");
                var boardSerial = GetWmiValue("Win32_BaseBoard", "SerialNumber");

                if (!string.IsNullOrEmpty(processorId) || !string.IsNullOrEmpty(boardSerial))
                {
                    return $"{processorId}-{boardSerial}";
                }
            }
            catch (Exception ex)
            {
                Logger.Write($"WMI hardware ID failed: {ex.Message}");
            }

            // Fallback to machine name
            return $"unknown-{Environment.MachineName}";
        }

        private static string GetWmiValue(string wmiClass, string property)
        {
            try
            {
                using var searcher = new ManagementObjectSearcher($"SELECT {property} FROM {wmiClass}");
                foreach (var obj in searcher.Get())
                {
                    var val = obj[property]?.ToString();
                    if (!string.IsNullOrWhiteSpace(val)) return val;
                }
            }
            catch { /* ignore */ }
            return "";
        }

        // MARK: - Format Validation (offline)

        public static bool ValidateFormat(string key)
        {
            key = key.Trim().ToUpperInvariant();
            var parts = key.Split('-');

            if (parts.Length != 5) return false;
            if (parts[0] != Prefix) return false;

            for (int i = 1; i <= 4; i++)
            {
                if (parts[i].Length != 5) return false;
                if (!parts[i].All(c => char.IsLetterOrDigit(c))) return false;
            }

            var payload = $"{parts[1]}-{parts[2]}-{parts[3]}";
            var expectedSig = ComputeSignature(payload);
            return parts[4] == expectedSig;
        }

        // MARK: - Online Activation

        public static async Task<ActivationResponse> Activate(string key)
        {
            key = key.Trim().ToUpperInvariant();

            if (!ValidateFormat(key))
                return new ActivationResponse { Result = ActivationResult.InvalidKey };

            var hwid = HardwareId();
            var machineName = Environment.MachineName;

            var body = JsonConvert.SerializeObject(new
            {
                licenseKey = key,
                hardwareId = hwid,
                machineName = machineName
            });

            try
            {
                var content = new StringContent(body, Encoding.UTF8, "application/json");
                var response = await HttpClient.PostAsync($"{BaseUrl}/activate", content);
                var responseText = await response.Content.ReadAsStringAsync();
                var json = JObject.Parse(responseText);

                switch ((int)response.StatusCode)
                {
                    case 200:
                        var token = json["activationToken"]?.ToString() ?? "";
                        var status = json["status"]?.ToString() ?? "";
                        var settings = AppSettings.Shared;
                        settings.LicenseKey = key;
                        settings.ActivationToken = token;
                        settings.ActivatedAt = json["activatedAt"]?.ToString() ?? "";
                        settings.Save();

                        return new ActivationResponse
                        {
                            Result = status == "activated" ? ActivationResult.Success : ActivationResult.AlreadyActivated,
                            Token = token
                        };

                    case 403:
                        var error = json["error"]?.ToString() ?? "";
                        if (error.Contains("revoked"))
                            return new ActivationResponse { Result = ActivationResult.Revoked };
                        return new ActivationResponse { Result = ActivationResult.MaxReached, Message = error };

                    case 404:
                        return new ActivationResponse { Result = ActivationResult.InvalidKey };

                    default:
                        return new ActivationResponse
                        {
                            Result = ActivationResult.NetworkError,
                            Message = json["error"]?.ToString() ?? $"Server error ({(int)response.StatusCode})"
                        };
                }
            }
            catch (Exception ex)
            {
                return new ActivationResponse
                {
                    Result = ActivationResult.NetworkError,
                    Message = ex.Message
                };
            }
        }

        // MARK: - Deactivation

        public static async Task<bool> Deactivate()
        {
            var settings = AppSettings.Shared;
            var key = settings.LicenseKey;
            var hwid = HardwareId();

            if (string.IsNullOrEmpty(key)) return false;

            var body = JsonConvert.SerializeObject(new { licenseKey = key, hardwareId = hwid });

            try
            {
                var content = new StringContent(body, Encoding.UTF8, "application/json");
                var response = await HttpClient.PostAsync($"{BaseUrl}/deactivate", content);

                if (response.IsSuccessStatusCode)
                {
                    settings.LicenseKey = "";
                    settings.ActivationToken = "";
                    settings.ActivatedAt = "";
                    settings.Save();
                    return true;
                }
                return false;
            }
            catch
            {
                return false;
            }
        }

        // MARK: - Periodic Validation

        public static async Task<bool?> ValidateOnline()
        {
            var settings = AppSettings.Shared;
            var key = settings.LicenseKey;
            var hwid = HardwareId();

            if (string.IsNullOrEmpty(key) || string.IsNullOrEmpty(settings.ActivationToken))
                return false;

            var body = JsonConvert.SerializeObject(new { licenseKey = key, hardwareId = hwid });

            try
            {
                var content = new StringContent(body, Encoding.UTF8, "application/json");
                var response = await HttpClient.PostAsync($"{BaseUrl}/validate", content);

                if (!response.IsSuccessStatusCode)
                    return null; // Network error -- don't invalidate

                var responseText = await response.Content.ReadAsStringAsync();
                var json = JObject.Parse(responseText);
                return json["valid"]?.Value<bool>() ?? false;
            }
            catch
            {
                return null; // Network unreachable -- grace period
            }
        }

        // MARK: - State

        public static bool IsLicensed => !string.IsNullOrEmpty(AppSettings.Shared.ActivationToken);

        public static bool CanUse => IsLicensed || AppSettings.Shared.RemainingTrial > 0;

        // MARK: - Signature

        private static string ComputeSignature(string payload)
        {
            using var hmac = new HMACSHA256(Secret);
            var hash = hmac.ComputeHash(Encoding.UTF8.GetBytes(payload));
            var hex = BitConverter.ToString(hash).Replace("-", "");
            return hex[..5];
        }
    }
}
