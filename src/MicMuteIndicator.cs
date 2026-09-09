using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace MicMuteIndicator
{
    public enum MicState { Unknown, Live, Muted, Disconnected }

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

    #endregion

    /// <summary>
    /// Detects the Audeze Maxwell hardware mute switch.
    ///
    /// The switch is invisible to Windows: it changes no endpoint mute flag and emits no HID
    /// report. What it does do is make the firmware substitute exact digital silence. Measured
    /// on this hardware, a live mic never drops below 1 LSB (0.000061) even in a silent room,
    /// while a muted mic delivers samples that are all exactly 0.0. So the test is presence of
    /// data, not loudness - no amplitude threshold is involved.
    ///
    /// Note that roughly a quarter of the samples in live speech are exactly zero (zero
    /// crossings), so the window must be ENTIRELY zero to count as muted.
    ///
    /// Failure is biased deliberately: any non-zero sample reports Live immediately, while
    /// Muted requires sustained silence. Wrongly claiming "muted" is the dangerous direction.
    /// </summary>
    public sealed class MicMonitor : IDisposable
    {
        const int eCapture = 1;
        const int DEVICE_STATE_ACTIVE = 1;
        const int CLSCTX_ALL = 23;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_BUFFERFLAGS_SILENT = 0x2;

        const int MutedConfirmMs = 400;
        const int StreamStallMs = 3000;
        const int RetryDelayMs = 2000;

        static Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        static Guid IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pvar);

        readonly string deviceFilter;
        readonly Thread worker;
        volatile bool stopping;
        MicState state = MicState.Unknown;

        public event Action<MicState, string> StateChanged;
        public MicState State { get { return state; } }
        public string DeviceName { get; private set; }

        public MicMonitor(string deviceFilter)
        {
            this.deviceFilter = deviceFilter;
            worker = new Thread(Loop);
            worker.IsBackground = true;
            worker.SetApartmentState(ApartmentState.MTA);
        }

        public void Start() { worker.Start(); }

        public void Dispose()
        {
            stopping = true;
            if (worker.IsAlive) worker.Join(1500);
        }

        void SetState(MicState next)
        {
            if (state == next) return;
            state = next;
            var handler = StateChanged;
            if (handler != null) handler(next, DeviceName);
        }

        void Loop()
        {
            while (!stopping)
            {
                IMMDevice device = null;
                IAudioClient client = null;
                IAudioCaptureClient capture = null;

                try
                {
                    device = FindDevice();
                    if (device == null)
                    {
                        DeviceName = null;
                        SetState(MicState.Disconnected);
                        Sleep(RetryDelayMs);
                        continue;
                    }

                    object clientObj;
                    if (device.Activate(ref IID_IAudioClient, CLSCTX_ALL, IntPtr.Zero, out clientObj) != 0)
                        throw new InvalidOperationException("Activate failed");
                    client = (IAudioClient)clientObj;

                    IntPtr fmtPtr;
                    if (client.GetMixFormat(out fmtPtr) != 0)
                        throw new InvalidOperationException("GetMixFormat failed");
                    var fmt = (WaveFormatEx)Marshal.PtrToStructure(fmtPtr, typeof(WaveFormatEx));

                    if (client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10000000L, 0, fmtPtr, IntPtr.Zero) != 0)
                        throw new InvalidOperationException("Initialize failed");

                    object captureObj;
                    if (client.GetService(ref IID_IAudioCaptureClient, out captureObj) != 0)
                        throw new InvalidOperationException("GetService failed");
                    capture = (IAudioCaptureClient)captureObj;

                    if (client.Start() != 0)
                        throw new InvalidOperationException("Start failed");

                    Pump(client, capture, fmt);
                }
                catch
                {
                    // Device vanished, went to sleep, or was grabbed in exclusive mode.
                }
                finally
                {
                    if (client != null) { try { client.Stop(); } catch { } }
                    Release(capture);
                    Release(client);
                    Release(device);
                }

                if (!stopping)
                {
                    DeviceName = null;
                    SetState(MicState.Disconnected);
                    Sleep(RetryDelayMs);
                }
            }
        }

        void Pump(IAudioClient client, IAudioCaptureClient capture, WaveFormatEx fmt)
        {
            int blockAlign = fmt.nBlockAlign;
            bool isFloat = fmt.wBitsPerSample == 32;
            var buffer = new byte[1024 * 1024];

            var clock = System.Diagnostics.Stopwatch.StartNew();
            long lastSignal = clock.ElapsedMilliseconds;
            long lastPacket = clock.ElapsedMilliseconds;

            // Assume live until proven otherwise; never claim muted without evidence.
            SetState(MicState.Live);

            while (!stopping)
            {
                bool sawPacket = false;
                int packetFrames;
                if (capture.GetNextPacketSize(out packetFrames) != 0)
                    throw new InvalidOperationException("GetNextPacketSize failed");

                while (packetFrames > 0)
                {
                    IntPtr dataPtr;
                    int framesRead, flags;
                    long devPos, qpcPos;
                    if (capture.GetBuffer(out dataPtr, out framesRead, out flags, out devPos, out qpcPos) != 0)
                        throw new InvalidOperationException("GetBuffer failed");

                    sawPacket = true;
                    bool silentFlag = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                    int bytes = framesRead * blockAlign;
                    bool signal = false;

                    if (!silentFlag && dataPtr != IntPtr.Zero && bytes > 0 && bytes <= buffer.Length)
                    {
                        Marshal.Copy(dataPtr, buffer, 0, bytes);
                        signal = HasSignal(buffer, bytes, isFloat);
                    }

                    capture.ReleaseBuffer(framesRead);
                    if (signal) lastSignal = clock.ElapsedMilliseconds;

                    if (capture.GetNextPacketSize(out packetFrames) != 0)
                        throw new InvalidOperationException("GetNextPacketSize failed");
                }

                long now = clock.ElapsedMilliseconds;
                if (sawPacket) lastPacket = now;

                if (now - lastPacket > StreamStallMs)
                    throw new InvalidOperationException("stream stalled");

                SetState(now - lastSignal >= MutedConfirmMs ? MicState.Muted : MicState.Live);

                Thread.Sleep(50);
            }
        }

        static bool HasSignal(byte[] buffer, int bytes, bool isFloat)
        {
            if (isFloat)
            {
                for (int i = 0; i + 4 <= bytes; i += 4)
                    if (BitConverter.ToSingle(buffer, i) != 0f) return true;
            }
            else
            {
                for (int i = 0; i + 2 <= bytes; i += 2)
                    if (BitConverter.ToInt16(buffer, i) != 0) return true;
            }
            return false;
        }

        IMMDevice FindDevice()
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDeviceCollection collection = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                if (enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out collection) != 0)
                    return null;

                int count;
                collection.GetCount(out count);

                for (int i = 0; i < count; i++)
                {
                    IMMDevice dev;
                    collection.Item(i, out dev);
                    string name = GetFriendlyName(dev);
                    if (name != null && name.IndexOf(deviceFilter, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        DeviceName = name;
                        return dev;
                    }
                    Release(dev);
                }
                return null;
            }
            catch { return null; }
            finally
            {
                Release(collection);
                Release(enumerator);
            }
        }

        static string GetFriendlyName(IMMDevice dev)
        {
            IPropertyStore store = null;
            try
            {
                if (dev.OpenPropertyStore(0, out store) != 0 || store == null) return null;
                var key = new PropertyKey
                {
                    fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
                    pid = 14
                };
                PropVariant pv;
                if (store.GetValue(ref key, out pv) != 0) return null;
                string name = pv.pointerValue == IntPtr.Zero ? null : Marshal.PtrToStringUni(pv.pointerValue);
                PropVariantClear(ref pv);
                return name;
            }
            catch { return null; }
            finally { Release(store); }
        }

        static void Release(object comObject)
        {
            if (comObject != null && Marshal.IsComObject(comObject))
            {
                try { Marshal.ReleaseComObject(comObject); } catch { }
            }
        }

        void Sleep(int ms)
        {
            int waited = 0;
            while (waited < ms && !stopping)
            {
                Thread.Sleep(100);
                waited += 100;
            }
        }
    }

    public static class Palette
    {
        public static Color For(MicState state)
        {
            switch (state)
            {
                case MicState.Live: return Color.FromArgb(46, 204, 96);
                case MicState.Muted: return Color.FromArgb(220, 48, 48);
                default: return Color.FromArgb(120, 124, 132);
            }
        }

        public static string Label(MicState state)
        {
            switch (state)
            {
                case MicState.Live: return "MIC LIVE";
                case MicState.Muted: return "MUTED";
                case MicState.Disconnected: return "NO HEADSET";
                default: return "STARTING";
            }
        }
    }

    public sealed class OverlayForm : Form
    {
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
        const int WM_NCLBUTTONDOWN = 0xA1;
        const int HTCAPTION = 0x2;

        MicState state = MicState.Unknown;

        public OverlayForm(ContextMenuStrip menu)
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.FromArgb(18, 18, 20);
            ClientSize = new Size(170, 190);
            StartPosition = FormStartPosition.Manual;
            DoubleBuffered = true;
            ContextMenuStrip = menu;
            Location = DefaultLocation();

            MouseDown += (s, e) =>
            {
                if (e.Button != MouseButtons.Left) return;
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            };
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        static Point DefaultLocation()
        {
            var screen = Screen.PrimaryScreen;
            foreach (var s in Screen.AllScreens)
            {
                if (!s.Primary) { screen = s; break; }
            }
            var wa = screen.WorkingArea;
            return new Point(wa.Right - 210, wa.Top + 40);
        }

        public void SetState(MicState next)
        {
            state = next;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);

            var color = Palette.For(state);
            var circle = new Rectangle(25, 20, 120, 120);

            using (var glow = new GraphicsPath())
            {
                glow.AddEllipse(circle);
                using (var brush = new PathGradientBrush(glow))
                {
                    brush.CenterColor = ControlPaint.Light(color);
                    brush.SurroundColors = new[] { color };
                    g.FillEllipse(brush, circle);
                }
            }

            using (var pen = new Pen(Color.FromArgb(200, 255, 255, 255), 2f))
                g.DrawEllipse(pen, circle);

            using (var font = new Font("Segoe UI", 13f, FontStyle.Bold))
            using (var brush = new SolidBrush(Color.White))
            using (var format = new StringFormat { Alignment = StringAlignment.Center })
                g.DrawString(Palette.Label(state), font, brush, new RectangleF(0, 150, ClientSize.Width, 30), format);
        }
    }

    public sealed class TrayContext : ApplicationContext
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool DestroyIcon(IntPtr handle);

        readonly NotifyIcon tray;
        readonly MicMonitor monitor;
        readonly OverlayForm overlay;
        readonly Control marshaler;
        readonly ToolStripMenuItem overlayItem;
        Icon currentIcon;

        public TrayContext()
        {
            marshaler = new Control();
            marshaler.CreateControl();

            var menu = new ContextMenuStrip();
            overlayItem = new ToolStripMenuItem("Show overlay on screen");
            overlayItem.CheckOnClick = true;
            overlayItem.Click += (s, e) =>
            {
                if (overlayItem.Checked) overlay.Show(); else overlay.Hide();
            };
            menu.Items.Add(overlayItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, (s, e) => ExitApp());

            overlay = new OverlayForm(menu);

            tray = new NotifyIcon();
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            ApplyState(MicState.Unknown, null);

            monitor = new MicMonitor("Maxwell");
            monitor.StateChanged += OnStateChanged;
            monitor.Start();
        }

        void OnStateChanged(MicState state, string deviceName)
        {
            if (marshaler.IsDisposed) return;
            try
            {
                marshaler.BeginInvoke((Action)(() => ApplyState(state, deviceName)));
            }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { }
        }

        void ApplyState(MicState state, string deviceName)
        {
            var previous = currentIcon;
            currentIcon = BuildIcon(Palette.For(state));
            tray.Icon = currentIcon;
            if (previous != null) previous.Dispose();

            string text = state == MicState.Disconnected
                ? "Maxwell not connected"
                : "Maxwell mic: " + Palette.Label(state);
            tray.Text = text.Length > 62 ? text.Substring(0, 62) : text;

            overlay.SetState(state);
        }

        static Icon BuildIcon(Color color)
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    var rect = new Rectangle(3, 3, 26, 26);
                    using (var brush = new SolidBrush(color))
                        g.FillEllipse(brush, rect);
                    using (var pen = new Pen(Color.FromArgb(210, 255, 255, 255), 2.5f))
                        g.DrawEllipse(pen, rect);
                }

                IntPtr handle = bmp.GetHicon();
                try
                {
                    using (var temp = Icon.FromHandle(handle))
                        return (Icon)temp.Clone();
                }
                finally { DestroyIcon(handle); }
            }
        }

        void ExitApp()
        {
            tray.Visible = false;
            monitor.Dispose();
            tray.Dispose();
            if (currentIcon != null) currentIcon.Dispose();
            overlay.Dispose();
            marshaler.Dispose();
            ExitThread();
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool isNew;
            using (var mutex = new Mutex(true, "MicMuteIndicator.SingleInstance", out isNew))
            {
                if (!isNew) return;

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayContext());
            }
        }
    }
}
