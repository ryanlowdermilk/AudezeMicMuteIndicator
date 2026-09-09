<#
.SYNOPSIS
    Live probe of every active capture (microphone) endpoint: mute state + peak level.
.DESCRIPTION
    Run this with the Maxwell connected, then flip the hardware mute switch a few times
    and watch which column changes. That tells us how to detect the switch:
      * "Muted" column flips        -> use the Core Audio endpoint mute state (best: event-driven)
      * only "Peak" drops to 0.000  -> use peak-meter detection (needs something capturing the mic)
      * neither changes             -> we fall back to reading raw HID reports from the dongle
    Press Ctrl+C to stop.
#>

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CoreAudioProbe
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

    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    public class Snapshot
    {
        public string Name;
        public string Id;
        public bool Muted;
        public float Peak;
        public float Volume;
    }

    public static class Probe
    {
        const int eCapture = 1;
        const int eRender = 0;
        const int DEVICE_STATE_ACTIVE = 1;
        const int CLSCTX_ALL = 23;

        static Guid IID_IAudioEndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        static Guid IID_IAudioMeterInformation = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pvar);

        static string GetFriendlyName(IMMDevice dev)
        {
            IPropertyStore store;
            if (dev.OpenPropertyStore(0 /*STGM_READ*/, out store) != 0 || store == null) return "<unknown>";
            var key = new PropertyKey
            {
                fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
                pid = 14 // PKEY_Device_FriendlyName
            };
            PropVariant pv;
            if (store.GetValue(ref key, out pv) != 0) return "<unknown>";
            string name = pv.pointerValue == IntPtr.Zero ? "<unknown>" : Marshal.PtrToStringUni(pv.pointerValue);
            PropVariantClear(ref pv);
            Marshal.ReleaseComObject(store);
            return name;
        }

        public static Snapshot[] Read(bool capture)
        {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDeviceCollection col;
            enumerator.EnumAudioEndpoints(capture ? eCapture : eRender, DEVICE_STATE_ACTIVE, out col);
            int count;
            col.GetCount(out count);

            var results = new Snapshot[count];
            for (int i = 0; i < count; i++)
            {
                IMMDevice dev;
                col.Item(i, out dev);

                string id;
                dev.GetId(out id);

                object volObj, meterObj;
                dev.Activate(ref IID_IAudioEndpointVolume, CLSCTX_ALL, IntPtr.Zero, out volObj);
                dev.Activate(ref IID_IAudioMeterInformation, CLSCTX_ALL, IntPtr.Zero, out meterObj);

                var vol = (IAudioEndpointVolume)volObj;
                var meter = (IAudioMeterInformation)meterObj;

                bool muted; vol.GetMute(out muted);
                float peak; meter.GetPeakValue(out peak);
                float level; vol.GetMasterVolumeLevelScalar(out level);

                results[i] = new Snapshot { Name = GetFriendlyName(dev), Id = id, Muted = muted, Peak = peak, Volume = level };

                Marshal.ReleaseComObject(volObj);
                Marshal.ReleaseComObject(meterObj);
                Marshal.ReleaseComObject(dev);
            }
            Marshal.ReleaseComObject(col);
            Marshal.ReleaseComObject(enumerator);
            return results;
        }
    }
}
'@ -Language CSharp

$previous = @{}
$log = [System.Collections.Generic.List[string]]::new()

while ($true) {
    $snapshots = [CoreAudioProbe.Probe]::Read($true)

    foreach ($s in $snapshots) {
        if ($previous.ContainsKey($s.Id) -and $previous[$s.Id] -ne $s.Muted) {
            $state = if ($s.Muted) { 'MUTED' } else { 'LIVE' }
            $log.Add(("[{0}] {1} -> {2}" -f (Get-Date -Format 'HH:mm:ss'), $s.Name, $state))
            $log.Add("          $($s.Id)")
        }
        $previous[$s.Id] = $s.Muted
    }

    $table = $snapshots | ForEach-Object {
        [pscustomobject]@{
            Device = $_.Name
            Muted  = $_.Muted
            Volume = '{0:P0}' -f $_.Volume
            Peak   = '{0:F4}' -f $_.Peak
        }
    }

    Clear-Host
    Write-Host 'Watching active CAPTURE endpoints. Flip the Maxwell hardware mute switch a few times.' -ForegroundColor Cyan
    Write-Host 'Ctrl+C to stop.' -ForegroundColor DarkGray
    $table | Format-Table -AutoSize
    Write-Host ("Last update: {0}" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray

    if ($log.Count -gt 0) {
        Write-Host "`nDetected mute changes:" -ForegroundColor Yellow
        $log | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }

    Start-Sleep -Milliseconds 300
}
