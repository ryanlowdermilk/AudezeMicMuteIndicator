<#
.SYNOPSIS
    Opens a real WASAPI capture stream on the Audeze Maxwell mic and reports actual sample levels.
.DESCRIPTION
    The previous probe read the peak meter without any active stream, so it always reported 0.0000.
    This one actually captures audio, which is the only way the peak meter means anything.

    Run it, then:
      1. Talk / tap the mic with the switch OFF (mic live)  -> Level should be clearly non-zero
      2. Flip the switch to muted, talk again               -> watch what happens

    Outcomes:
      * Level goes to 0.000000 and stays there  -> hardware mute = digital silence, we can detect it
      * "Silent" flag count starts climbing     -> even better, the driver flags it explicitly
      * Level keeps showing your voice          -> the mute is downstream of Windows; we need HID
    Ctrl+C to stop.
#>

param(
    [string]$NameFilter = 'Maxwell'
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace CaptureProbe
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                                   [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr cb);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr cb);
        [PreserveSig] int GetChannelCount(out int count);
        [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float level);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(int ch, float level, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(int ch, float level, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(int ch, out float level);
        [PreserveSig] int GetChannelVolumeLevelScalar(int ch, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    [Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration,
                                     long periodicity, IntPtr format, IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out int bufferFrameCount);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out int padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out int numFramesToRead, out int flags,
                                    out long devicePosition, out long qpcPosition);
        [PreserveSig] int ReleaseBuffer(int numFramesRead);
        [PreserveSig] int GetNextPacketSize(out int numFramesInNextPacket);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    public static class Capture
    {
        const int eCapture = 1;
        const int DEVICE_STATE_ACTIVE = 1;
        const int CLSCTX_ALL = 23;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_BUFFERFLAGS_SILENT = 0x2;

        static Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        static Guid IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");
        static Guid IID_IAudioEndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pvar);

        static string GetFriendlyName(IMMDevice dev)
        {
            IPropertyStore store;
            if (dev.OpenPropertyStore(0, out store) != 0 || store == null) return "<unknown>";
            var key = new PropertyKey
            {
                fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
                pid = 14
            };
            PropVariant pv;
            if (store.GetValue(ref key, out pv) != 0) { Marshal.ReleaseComObject(store); return "<unknown>"; }
            string name = pv.pointerValue == IntPtr.Zero ? "<unknown>" : Marshal.PtrToStringUni(pv.pointerValue);
            PropVariantClear(ref pv);
            Marshal.ReleaseComObject(store);
            return name;
        }

        public static void Monitor(string nameFilter)
        {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDeviceCollection col;
            enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out col);
            int count;
            col.GetCount(out count);

            IMMDevice target = null;
            string targetName = null, targetId = null;
            for (int i = 0; i < count; i++)
            {
                IMMDevice dev;
                col.Item(i, out dev);
                string name = GetFriendlyName(dev);
                if (name.IndexOf(nameFilter, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    target = dev;
                    targetName = name;
                    dev.GetId(out targetId);
                    break;
                }
                Marshal.ReleaseComObject(dev);
            }

            if (target == null)
            {
                Console.WriteLine("No active capture device matching '" + nameFilter + "'.");
                Console.WriteLine("Make sure the headset is on and the dongle is plugged in.");
                return;
            }

            Console.WriteLine("Device : " + targetName);
            Console.WriteLine("Id     : " + targetId);
            Console.WriteLine();

            object volObj;
            target.Activate(ref IID_IAudioEndpointVolume, CLSCTX_ALL, IntPtr.Zero, out volObj);
            var vol = (IAudioEndpointVolume)volObj;

            object clientObj;
            int hr = target.Activate(ref IID_IAudioClient, CLSCTX_ALL, IntPtr.Zero, out clientObj);
            if (hr != 0) { Console.WriteLine("Activate(IAudioClient) failed: 0x" + hr.ToString("X8")); return; }
            var client = (IAudioClient)clientObj;

            IntPtr fmtPtr;
            hr = client.GetMixFormat(out fmtPtr);
            if (hr != 0) { Console.WriteLine("GetMixFormat failed: 0x" + hr.ToString("X8")); return; }
            var fmt = (WaveFormatEx)Marshal.PtrToStructure(fmtPtr, typeof(WaveFormatEx));
            Console.WriteLine(string.Format("Format : {0} Hz, {1} ch, {2}-bit (tag {3})",
                fmt.nSamplesPerSec, fmt.nChannels, fmt.wBitsPerSample, fmt.wFormatTag));
            Console.WriteLine();

            hr = client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10000000L, 0, fmtPtr, IntPtr.Zero);
            if (hr != 0) { Console.WriteLine("Initialize failed: 0x" + hr.ToString("X8")); return; }

            object captureObj;
            hr = client.GetService(ref IID_IAudioCaptureClient, out captureObj);
            if (hr != 0) { Console.WriteLine("GetService failed: 0x" + hr.ToString("X8")); return; }
            var capture = (IAudioCaptureClient)captureObj;

            hr = client.Start();
            if (hr != 0) { Console.WriteLine("Start failed: 0x" + hr.ToString("X8")); return; }

            Console.WriteLine("Capturing. Talk or tap the mic, then flip the hardware switch.");
            Console.WriteLine("Ctrl+C to stop.");
            Console.WriteLine();
            Console.WriteLine("  Time      EndpointMuted   Level      Bar                        SilentPkts");
            Console.WriteLine("  --------  -------------   --------   ------------------------   ----------");

            int blockAlign = fmt.nBlockAlign;
            bool isFloat = fmt.wBitsPerSample == 32;
            var buffer = new byte[1024 * 1024];

            var sw = System.Diagnostics.Stopwatch.StartNew();
            float windowMax = 0f;
            int silentPackets = 0;
            long lastPrint = 0;

            while (true)
            {
                int packetFrames;
                capture.GetNextPacketSize(out packetFrames);

                while (packetFrames > 0)
                {
                    IntPtr dataPtr;
                    int framesRead, flags;
                    long devPos, qpcPos;
                    hr = capture.GetBuffer(out dataPtr, out framesRead, out flags, out devPos, out qpcPos);
                    if (hr != 0) break;

                    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) silentPackets++;

                    int bytes = framesRead * blockAlign;
                    if (dataPtr != IntPtr.Zero && bytes > 0 && bytes <= buffer.Length)
                    {
                        Marshal.Copy(dataPtr, buffer, 0, bytes);
                        if (isFloat)
                        {
                            for (int i = 0; i + 4 <= bytes; i += 4)
                            {
                                float s = Math.Abs(BitConverter.ToSingle(buffer, i));
                                if (s > windowMax) windowMax = s;
                            }
                        }
                        else
                        {
                            for (int i = 0; i + 2 <= bytes; i += 2)
                            {
                                float s = Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f);
                                if (s > windowMax) windowMax = s;
                            }
                        }
                    }

                    capture.ReleaseBuffer(framesRead);
                    capture.GetNextPacketSize(out packetFrames);
                }

                if (sw.ElapsedMilliseconds - lastPrint >= 250)
                {
                    lastPrint = sw.ElapsedMilliseconds;
                    bool muted;
                    vol.GetMute(out muted);

                    int barLen = (int)Math.Round(Math.Min(1f, windowMax * 8f) * 24);
                    string bar = new string('#', barLen).PadRight(24, '.');

                    Console.WriteLine(string.Format("  {0}  {1}   {2}   {3}   {4}",
                        DateTime.Now.ToString("HH:mm:ss"),
                        muted ? "MUTED        " : "live         ",
                        windowMax.ToString("F6"),
                        bar,
                        silentPackets));

                    windowMax = 0f;
                }

                Thread.Sleep(20);
            }
        }
    }
}
'@ -Language CSharp

[CaptureProbe.Capture]::Monitor($NameFilter)
