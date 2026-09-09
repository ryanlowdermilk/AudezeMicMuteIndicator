<#
.SYNOPSIS
    Dumps raw HID input reports from the Audeze Maxwell dongle so we can locate the mute-switch bit.
.DESCRIPTION
    Opens every HID collection belonging to VID_3329 (Audeze) and prints each input report
    that differs from the previous one, as hex.

    Procedure:
      1. Turn the headset ON and wait for it to connect.
      2. Start this script. Note the reports that appear while idle.
      3. Flip the hardware mute switch UP (muted). Note the new report.
      4. Flip it DOWN (live). Note the report.
      5. Repeat a couple of times to confirm the pattern is consistent.

    Paste the output back and I will decode which byte/bit represents the mute state.
    Ctrl+C to stop.
#>

param(
    [string]$VendorId = 'vid_3329'
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace HidDump
{
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
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
        public const uint FILE_SHARE_READ = 0x1;
        public const uint FILE_SHARE_WRITE = 0x2;
        public const uint OPEN_EXISTING = 3;
        public const uint FILE_FLAG_OVERLAPPED = 0x40000000;

        [DllImport("hid.dll")]
        public static extern void HidD_GetHidGuid(out Guid guid);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool HidD_GetAttributes(SafeFileHandle handle, ref HIDD_ATTRIBUTES attributes);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool HidD_GetPreparsedData(SafeFileHandle handle, out IntPtr preparsed);

        [DllImport("hid.dll")]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool HidD_FreePreparsedData(IntPtr preparsed);

        [DllImport("hid.dll")]
        public static extern int HidP_GetCaps(IntPtr preparsed, out HIDP_CAPS caps);

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

    public static class Dumper
    {
        public static List<string> FindPaths(string filter)
        {
            var results = new List<string>();
            Guid hidGuid;
            Native.HidD_GetHidGuid(out hidGuid);

            IntPtr devInfo = Native.SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero,
                                Native.DIGCF_PRESENT | Native.DIGCF_DEVICEINTERFACE);
            if (devInfo == IntPtr.Zero || devInfo == new IntPtr(-1)) return results;

            var iface = new SP_DEVICE_INTERFACE_DATA();
            iface.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

            for (int i = 0; Native.SetupDiEnumDeviceInterfaces(devInfo, IntPtr.Zero, ref hidGuid, i, ref iface); i++)
            {
                int required;
                Native.SetupDiGetDeviceInterfaceDetail(devInfo, ref iface, IntPtr.Zero, 0, out required, IntPtr.Zero);
                if (required <= 0) continue;

                IntPtr detail = Marshal.AllocHGlobal(required);
                try
                {
                    // cbSize of SP_DEVICE_INTERFACE_DETAIL_DATA_W: 8 on x64, 6 on x86
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    int req2;
                    if (Native.SetupDiGetDeviceInterfaceDetail(devInfo, ref iface, detail, required, out req2, IntPtr.Zero))
                    {
                        string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                        if (path != null && path.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0)
                            results.Add(path);
                    }
                }
                finally { Marshal.FreeHGlobal(detail); }

                iface.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
            }

            Native.SetupDiDestroyDeviceInfoList(devInfo);
            return results;
        }

        static readonly object ConsoleLock = new object();
        static readonly HashSet<string> Active = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        static int Counter = 0;

        static string UsagePageName(ushort page)
        {
            switch (page)
            {
                case 0x01: return "Generic Desktop";
                case 0x0B: return "Telephony";
                case 0x0C: return "Consumer";
                default: return page >= 0xFF00 ? "Vendor-defined" : "0x" + page.ToString("X2");
            }
        }

        public static void Run(string filter)
        {
            Console.WriteLine("Scanning for HID collections matching '" + filter + "'.");
            Console.WriteLine("The dongle re-enumerates when the headset powers on, so this rescans continuously.");
            Console.WriteLine("Flip the hardware mute switch a few times. Ctrl+C to stop.");
            Console.WriteLine("--------------------------------------------------------------");

            while (true)
            {
                foreach (var path in FindPaths(filter))
                {
                    lock (Active)
                    {
                        if (Active.Contains(path)) continue;
                        Active.Add(path);
                    }
                    if (!TryStart(path))
                    {
                        lock (Active) Active.Remove(path);
                    }
                }
                Thread.Sleep(1500);
            }
        }

        static bool TryStart(string path)
        {
            var handle = Native.CreateFile(path, Native.GENERIC_READ,
                            Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero,
                            Native.OPEN_EXISTING, Native.FILE_FLAG_OVERLAPPED, IntPtr.Zero);

            if (handle.IsInvalid) return false;

            IntPtr preparsed;
            if (!Native.HidD_GetPreparsedData(handle, out preparsed))
            {
                handle.Dispose();
                return false;
            }

            HIDP_CAPS caps;
            Native.HidP_GetCaps(preparsed, out caps);
            Native.HidD_FreePreparsedData(preparsed);

            if (caps.InputReportByteLength == 0)
            {
                handle.Dispose();
                return false;
            }

            string label = "HID#" + Interlocked.Increment(ref Counter);
            string shortPath = ShortenPath(path);

            lock (ConsoleLock)
            {
                Console.WriteLine();
                Console.WriteLine(string.Format(">> OPENED {0}  UsagePage 0x{1:X2} ({2}), Usage 0x{3:X2}, ReportLen {4}",
                    label, caps.UsagePage, UsagePageName(caps.UsagePage), caps.Usage, caps.InputReportByteLength));
                Console.WriteLine("   " + shortPath);
            }

            var stream = new FileStream(handle, FileAccess.Read, caps.InputReportByteLength, true);
            var thread = new Thread(() => ReadLoop(stream, caps.InputReportByteLength, label, shortPath, path));
            thread.IsBackground = true;
            thread.Start();
            return true;
        }

        static string ShortenPath(string path)
        {
            int start = path.IndexOf("hid#", StringComparison.OrdinalIgnoreCase);
            if (start < 0) return path;
            int end = path.IndexOf('{');
            if (end < 0) end = path.Length;
            return path.Substring(start, end - start).TrimEnd('#');
        }

        static void ReadLoop(FileStream stream, int reportLength, string label, string shortPath, string fullPath)
        {
            var buffer = new byte[reportLength];
            string previous = null;

            try
            {
                while (true)
                {
                    int read = stream.Read(buffer, 0, reportLength);
                    if (read <= 0) continue;

                    var hex = BitConverter.ToString(buffer, 0, read).Replace("-", " ");
                    if (hex == previous) continue;
                    previous = hex;

                    lock (ConsoleLock)
                    {
                        Console.WriteLine(string.Format("[{0}] {1}  {2}",
                            DateTime.Now.ToString("HH:mm:ss.fff"), label, hex));
                    }
                }
            }
            catch (Exception ex)
            {
                lock (ConsoleLock)
                    Console.WriteLine(string.Format("<< CLOSED {0} ({1})", label, ex.Message.Trim()));
            }
            finally
            {
                try { stream.Dispose(); } catch { }
                lock (Active) Active.Remove(fullPath);
            }
        }
    }
}
'@ -Language CSharp

[HidDump.Dumper]::Run($VendorId)
