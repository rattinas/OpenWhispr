using System.Media;

namespace TalkIsCheap.Services
{
    public static class SoundFeedback
    {
        public static void RecordStart()
        {
            try { SystemSounds.Exclamation.Play(); }
            catch { /* ignore */ }
        }

        public static void RecordStop()
        {
            try { SystemSounds.Asterisk.Play(); }
            catch { /* ignore */ }
        }

        public static void Done()
        {
            try { SystemSounds.Hand.Play(); }
            catch { /* ignore */ }
        }

        public static void Error()
        {
            try { SystemSounds.Beep.Play(); }
            catch { /* ignore */ }
        }
    }
}
