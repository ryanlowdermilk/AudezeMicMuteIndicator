<#
.SYNOPSIS
    Guided, self-analyzing test to determine how the Audeze Maxwell hardware mute switch
    can be detected from Windows.
.DESCRIPTION
    Runs four timed phases and asks you to KEEP TALKING through all of them, alternating the
    hardware mute switch. Talking is essential: an idle live mic and a muted mic look identical,
    so the only way to tell them apart is to make noise and see whether it gets through.

    While it runs it simultaneously watches three possible signals:
      1. Core Audio endpoint mute flag
      2. Actual captured sample levels (and the WASAPI "silent buffer" flag)
      3. HID feature reports on the Audeze vendor-defined collection

    At the end it prints a verdict saying which method works.
    A full CSV is written to mute-test-log.csv.
#>

param(
    [string]$NameFilter = 'Maxwell',
    [int]$PhaseSeconds = 8,
    [int]$PrepareSeconds = 4
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace MuteTest
{
    #region Core Audio interop

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
    public struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
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
    public struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    #endregion

    #region HID interop

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    public static class Native
    {
        public const int DIGCF_PRESENT = 0x02;
        public const int DIGCF_DEVICEINTERFACE = 0x10;
        public const uint GENERIC_READ = 0x80000000;
        public const uint GENERIC_WRITE = 0x40000000;
        public const uint FILE_SHARE_READ = 0x1;
        public const uint FILE_SHARE_WRITE = 0x2;
        public const uint OPEN_EXISTING = 3;

        [DllImport("hid.dll")]
        public static extern void HidD_GetHidGuid(out Guid guid);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool HidD_GetPreparsedData(SafeFileHandle handle, out IntPtr preparsed);

        [DllImport("hid.dll")]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool HidD_FreePreparsedData(IntPtr preparsed);

        [DllImport("hid.dll")]
        public static extern int HidP_GetCaps(IntPtr preparsed, out HIDP_CAPS caps);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool HidD_GetFeature(SafeFileHandle handle, byte[] buffer, int bufferLength);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator,
                                                        IntPtr hwndParent, int flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetupDiEnumDeviceInterfaces(IntPtr devInfo, IntPtr devInfoData,
                                                              ref Guid interfaceClassGuid, int memberIndex,
                                                              ref SP_DEVICE_INTERFACE_DATA interfaceData);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr devInfo,
                                                                  ref SP_DEVICE_INTERFACE_DATA interfaceData,
                                                                  IntPtr detailData, int detailSize,
                                                                  out int requiredSize, IntPtr devInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetupDiDestroyDeviceInfoList(IntPtr devInfo);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(string fileName, uint access, uint share,
                                                       IntPtr security, uint creation, uint flags,
                                                       IntPtr template);
    }

    #endregion

    public class PhaseResult
    {
        public string Name;
        public bool ExpectMuted;
        public float MaxLevel;
        public double MeanLevel;
        public int Windows;
        public int SilentPackets;
        public long ZeroSamples;
        public long TotalSamples;
        public HashSet<bool> EndpointMuted = new HashSet<bool>();
        public Dictionary<byte, byte[]> LastFeature = new Dictionary<byte, byte[]>();
    }

    public static class Runner
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
            var key = new PropertyKey { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };
            PropVariant pv;
            if (store.GetValue(ref key, out pv) != 0) { Marshal.ReleaseComObject(store); return "<unknown>"; }
            string name = pv.pointerValue == IntPtr.Zero ? "<unknown>" : Marshal.PtrToStringUni(pv.pointerValue);
            PropVariantClear(ref pv);
            Marshal.ReleaseComObject(store);
            return name;
        }

        // ---- HID feature-report probing -------------------------------------------------

        static SafeFileHandle hidHandle;
        static int hidFeatureLength;
        static List<byte> hidReportIds = new List<byte>();

        static void OpenVendorHid()
        {
            Guid hidGuid;
            Native.HidD_GetHidGuid(out hidGuid);
            IntPtr devInfo = Native.SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero,
                                Native.DIGCF_PRESENT | Native.DIGCF_DEVICEINTERFACE);
            if (devInfo == IntPtr.Zero || devInfo == new IntPtr(-1)) return;

            var iface = new SP_DEVICE_INTERFACE_DATA();
            iface.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

            for (int i = 0; Native.SetupDiEnumDeviceInterfaces(devInfo, IntPtr.Zero, ref hidGuid, i, ref iface); i++)
            {
                int required;
                Native.SetupDiGetDeviceInterfaceDetail(devInfo, ref iface, IntPtr.Zero, 0, out required, IntPtr.Zero);
                if (required <= 0) continue;
                IntPtr detail = Marshal.AllocHGlobal(required);
                string path = null;
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    int req2;
                    if (Native.SetupDiGetDeviceInterfaceDetail(devInfo, ref iface, detail, required, out req2, IntPtr.Zero))
                        path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                }
                finally { Marshal.FreeHGlobal(detail); }
                iface.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

                if (path == null || path.IndexOf("vid_3329", StringComparison.OrdinalIgnoreCase) < 0) continue;

                var h = Native.CreateFile(path, Native.GENERIC_READ | Native.GENERIC_WRITE,
                            Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero,
                            Native.OPEN_EXISTING, 0, IntPtr.Zero);
                if (h.IsInvalid) continue;

                IntPtr pre;
                if (!Native.HidD_GetPreparsedData(h, out pre)) { h.Dispose(); continue; }
                HIDP_CAPS caps;
                Native.HidP_GetCaps(pre, out caps);
                Native.HidD_FreePreparsedData(pre);

                if (caps.UsagePage >= 0xFF00 && caps.FeatureReportByteLength > 0)
                {
                    hidHandle = h;
                    hidFeatureLength = caps.FeatureReportByteLength;
                    Console.WriteLine(string.Format("HID    : vendor collection open, feature report length {0}",
                        hidFeatureLength));

                    for (int id = 0; id < 256; id++)
                    {
                        var buf = new byte[hidFeatureLength];
                        buf[0] = (byte)id;
                        if (Native.HidD_GetFeature(h, buf, buf.Length)) hidReportIds.Add((byte)id);
                    }
                    Console.WriteLine("HID    : readable feature report IDs: " +
                        (hidReportIds.Count == 0 ? "(none)" :
                         string.Join(", ", hidReportIds.Select(x => "0x" + x.ToString("X2")).ToArray())));
                    break;
                }
                h.Dispose();
            }
            Native.SetupDiDestroyDeviceInfoList(devInfo);
        }

        static void SampleFeatures(PhaseResult phase)
        {
            if (hidHandle == null || hidHandle.IsInvalid) return;
            foreach (var id in hidReportIds)
            {
                var buf = new byte[hidFeatureLength];
                buf[0] = id;
                if (Native.HidD_GetFeature(hidHandle, buf, buf.Length))
                    phase.LastFeature[id] = buf;
            }
        }

        // ---- main -----------------------------------------------------------------------

        public static void Run(string nameFilter, int phaseSeconds, int prepareSeconds, string csvPath)
        {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDeviceCollection col;
            enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out col);
            int count;
            col.GetCount(out count);

            IMMDevice target = null;
            string targetName = null;
            for (int i = 0; i < count; i++)
            {
                IMMDevice dev;
                col.Item(i, out dev);
                string name = GetFriendlyName(dev);
                if (name.IndexOf(nameFilter, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    target = dev; targetName = name; break;
                }
                Marshal.ReleaseComObject(dev);
            }

            if (target == null)
            {
                Console.WriteLine("No active capture device matching '" + nameFilter + "'.");
                Console.WriteLine("Turn the headset on, wait for it to connect, then run this again.");
                return;
            }

            Console.WriteLine("Device : " + targetName);

            object volObj;
            target.Activate(ref IID_IAudioEndpointVolume, CLSCTX_ALL, IntPtr.Zero, out volObj);
            var vol = (IAudioEndpointVolume)volObj;

            object clientObj;
            if (target.Activate(ref IID_IAudioClient, CLSCTX_ALL, IntPtr.Zero, out clientObj) != 0) return;
            var client = (IAudioClient)clientObj;

            IntPtr fmtPtr;
            if (client.GetMixFormat(out fmtPtr) != 0) return;
            var fmt = (WaveFormatEx)Marshal.PtrToStructure(fmtPtr, typeof(WaveFormatEx));
            Console.WriteLine(string.Format("Format : {0} Hz, {1} ch, {2}-bit",
                fmt.nSamplesPerSec, fmt.nChannels, fmt.wBitsPerSample));

            OpenVendorHid();

            if (client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10000000L, 0, fmtPtr, IntPtr.Zero) != 0) return;

            object captureObj;
            if (client.GetService(ref IID_IAudioCaptureClient, out captureObj) != 0) return;
            var capture = (IAudioCaptureClient)captureObj;
            if (client.Start() != 0) return;

            var phases = new List<PhaseResult>
            {
                new PhaseResult { Name = "LIVE  #1 (switch DOWN)",  ExpectMuted = false },
                new PhaseResult { Name = "MUTED #1 (switch UP)",    ExpectMuted = true  },
                new PhaseResult { Name = "LIVE  #2 (switch DOWN)",  ExpectMuted = false },
                new PhaseResult { Name = "MUTED #2 (switch UP)",    ExpectMuted = true  },
            };

            var csv = new StringBuilder();
            csv.AppendLine("timestamp,phase,expect_muted,max_level,silent_packets,zero_samples,total_samples,endpoint_muted");

            int blockAlign = fmt.nBlockAlign;
            bool isFloat = fmt.wBitsPerSample == 32;
            var buffer = new byte[4 * 1024 * 1024];

            Console.WriteLine();
            Console.WriteLine("==================================================================");
            Console.WriteLine(" IMPORTANT: TALK CONTINUOUSLY DURING EVERY PHASE, INCLUDING MUTED.");
            Console.WriteLine(" Count out loud, read this text aloud, whatever - just keep going.");
            Console.WriteLine();
            Console.WriteLine(" There are 4 phases. Before each one you get a beep and a countdown:");
            Console.WriteLine("   high beep = set switch DOWN (live)");
            Console.WriteLine("   low  beep = set switch UP   (muted)");
            Console.WriteLine("==================================================================");
            Console.WriteLine();
            Console.Write(" Press ENTER when you are ready to begin...");
            Console.ReadLine();
            Console.WriteLine();

            foreach (var phase in phases)
            {
                Console.WriteLine();
                Console.WriteLine("------------------------------------------------------------------");
                Console.WriteLine("  NEXT: " + phase.Name);
                Console.WriteLine("------------------------------------------------------------------");
                try { Console.Beep(phase.ExpectMuted ? 440 : 880, 250); } catch { }

                for (int s = prepareSeconds; s > 0; s--)
                {
                    Console.Write("\r  Set the switch and start talking... " + s + "   ");
                    DrainCapture(capture, buffer, blockAlign, isFloat, null);
                    Thread.Sleep(1000);
                }
                Console.WriteLine("\r  MEASURING - keep talking!                     ");

                DrainCapture(capture, buffer, blockAlign, isFloat, null);

                var sw = System.Diagnostics.Stopwatch.StartNew();
                long lastWindow = 0;
                float windowMax = 0f;

                while (sw.Elapsed.TotalSeconds < phaseSeconds)
                {
                    float m = DrainCapture(capture, buffer, blockAlign, isFloat, phase);
                    if (m > windowMax) windowMax = m;

                    if (sw.ElapsedMilliseconds - lastWindow >= 250)
                    {
                        lastWindow = sw.ElapsedMilliseconds;
                        bool muted;
                        vol.GetMute(out muted);
                        phase.EndpointMuted.Add(muted);
                        SampleFeatures(phase);

                        if (windowMax > phase.MaxLevel) phase.MaxLevel = windowMax;
                        phase.MeanLevel += windowMax;
                        phase.Windows++;

                        int barLen = (int)Math.Round(Math.Min(1f, windowMax * 8f) * 24);
                        Console.Write("\r  level " + windowMax.ToString("F6") + "  " +
                                      new string('#', barLen).PadRight(24, '.') + "  ");

                        csv.AppendLine(string.Join(",",
                            DateTime.Now.ToString("HH:mm:ss.fff"),
                            "\"" + phase.Name + "\"",
                            phase.ExpectMuted.ToString(),
                            windowMax.ToString("F8", CultureInfo.InvariantCulture),
                            phase.SilentPackets.ToString(),
                            phase.ZeroSamples.ToString(),
                            phase.TotalSamples.ToString(),
                            muted.ToString()));

                        windowMax = 0f;
                    }
                    Thread.Sleep(10);
                }

                if (phase.Windows > 0) phase.MeanLevel /= phase.Windows;
                Console.WriteLine();
            }

            client.Stop();
            File.WriteAllText(csvPath, csv.ToString());

            PrintVerdict(phases, csvPath);
        }

        static float DrainCapture(IAudioCaptureClient capture, byte[] buffer, int blockAlign,
                                  bool isFloat, PhaseResult phase)
        {
            float maxAbs = 0f;
            int packetFrames;
            capture.GetNextPacketSize(out packetFrames);

            while (packetFrames > 0)
            {
                IntPtr dataPtr;
                int framesRead, flags;
                long devPos, qpcPos;
                if (capture.GetBuffer(out dataPtr, out framesRead, out flags, out devPos, out qpcPos) != 0) break;

                if (phase != null && (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) phase.SilentPackets++;

                int bytes = framesRead * blockAlign;
                if (dataPtr != IntPtr.Zero && bytes > 0 && bytes <= buffer.Length)
                {
                    Marshal.Copy(dataPtr, buffer, 0, bytes);
                    int step = isFloat ? 4 : 2;
                    for (int i = 0; i + step <= bytes; i += step)
                    {
                        float s = isFloat
                            ? Math.Abs(BitConverter.ToSingle(buffer, i))
                            : Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f);
                        if (s > maxAbs) maxAbs = s;
                        if (phase != null)
                        {
                            phase.TotalSamples++;
                            if (s == 0f) phase.ZeroSamples++;
                        }
                    }
                }

                capture.ReleaseBuffer(framesRead);
                capture.GetNextPacketSize(out packetFrames);
            }
            return maxAbs;
        }

        static void PrintVerdict(List<PhaseResult> phases, string csvPath)
        {
            Console.WriteLine();
            Console.WriteLine("==================================================================");
            Console.WriteLine("  RESULTS");
            Console.WriteLine("==================================================================");
            Console.WriteLine();
            Console.WriteLine("  Phase                    MaxLevel    MeanLevel   ZeroSamples  Silent  EndpointMuted");
            Console.WriteLine("  ----------------------   ---------   ---------   -----------  ------  -------------");

            foreach (var p in phases)
            {
                string zeroPct = p.TotalSamples > 0
                    ? (100.0 * p.ZeroSamples / p.TotalSamples).ToString("F1") + "%"
                    : "n/a";
                string endpoint = string.Join("/", p.EndpointMuted.Select(b => b ? "MUTED" : "live").ToArray());
                Console.WriteLine(string.Format("  {0,-22}   {1,9}   {2,9}   {3,11}  {4,6}  {5}",
                    p.Name, p.MaxLevel.ToString("F6"), p.MeanLevel.ToString("F6"),
                    zeroPct, p.SilentPackets, endpoint));
            }

            var live = phases.Where(p => !p.ExpectMuted).ToList();
            var muted = phases.Where(p => p.ExpectMuted).ToList();
            float liveMax = live.Max(p => p.MaxLevel);
            float mutedMax = muted.Max(p => p.MaxLevel);

            Console.WriteLine();
            Console.WriteLine("  VERDICT");
            Console.WriteLine("  -------");

            bool endpointWorks =
                live.All(p => p.EndpointMuted.Count == 1 && !p.EndpointMuted.First()) &&
                muted.All(p => p.EndpointMuted.Count == 1 && p.EndpointMuted.First());

            if (endpointWorks)
            {
                Console.WriteLine("  * BEST: Core Audio endpoint mute tracks the hardware switch exactly.");
                Console.WriteLine("    The app can be fully event-driven with zero polling.");
            }
            else if (mutedMax < liveMax * 0.2f)
            {
                Console.WriteLine("  * Audio-level detection WORKS.");
                Console.WriteLine(string.Format("    Live peaks reached {0:F6}; muted peaks never exceeded {1:F6}.",
                    liveMax, mutedMax));
                Console.WriteLine(string.Format("    Suggested threshold: {0:F6}", (liveMax * 0.05f + mutedMax) / 2f));
                Console.WriteLine("    The app holds an open capture stream and watches the level.");
            }
            else
            {
                Console.WriteLine("  * Audio level did NOT separate the two states.");
                Console.WriteLine(string.Format("    Live max {0:F6} vs muted max {1:F6}.", liveMax, mutedMax));
                Console.WriteLine("    If muted is not clearly quieter, you may not have been talking during");
                Console.WriteLine("    the muted phases - rerun and make sure you keep talking throughout.");
            }

            // Feature report diff
            var ids = phases.SelectMany(p => p.LastFeature.Keys).Distinct().ToList();
            bool foundFeature = false;
            foreach (var id in ids)
            {
                if (!phases.All(p => p.LastFeature.ContainsKey(id))) continue;
                int len = phases[0].LastFeature[id].Length;
                for (int b = 0; b < len; b++)
                {
                    var liveVals = live.Select(p => p.LastFeature[id][b]).Distinct().ToList();
                    var mutedVals = muted.Select(p => p.LastFeature[id][b]).Distinct().ToList();
                    if (liveVals.Count == 1 && mutedVals.Count == 1 && liveVals[0] != mutedVals[0])
                    {
                        if (!foundFeature)
                        {
                            Console.WriteLine();
                            Console.WriteLine("  * HID FEATURE REPORT carries the state:");
                            foundFeature = true;
                        }
                        Console.WriteLine(string.Format(
                            "    Report 0x{0:X2}, byte {1}: live=0x{2:X2}, muted=0x{3:X2}  (xor 0x{4:X2})",
                            id, b, liveVals[0], mutedVals[0], liveVals[0] ^ mutedVals[0]));
                    }
                }
            }
            if (!foundFeature)
                Console.WriteLine("  * No HID feature report byte tracked the switch.");

            Console.WriteLine();
            Console.WriteLine("  Full log written to: " + csvPath);
            Console.WriteLine();
        }
    }
}
'@ -Language CSharp

$csv = Join-Path $PSScriptRoot 'mute-test-log.csv'
[MuteTest.Runner]::Run($NameFilter, $PhaseSeconds, $PrepareSeconds, $csv)
