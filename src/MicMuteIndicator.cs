using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
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

    /// <summary>
    /// Per-pixel alpha overlay. Rendered with UpdateLayeredWindow rather than OnPaint so the
    /// window has no rectangular background at all - only the pill, its soft shadow, and the
    /// antialiased edges are visible against whatever is underneath.
    /// </summary>
    public sealed class OverlayForm : Form
    {
        const int WS_EX_LAYERED = 0x00080000;
        const int WS_EX_TRANSPARENT = 0x00000020;
        const int WS_EX_TOOLWINDOW = 0x00000080;
        const int WS_EX_NOACTIVATE = 0x08000000;
        const int GWL_EXSTYLE = -20;
        const int WM_NCLBUTTONDOWN = 0xA1;
        const int HTCAPTION = 0x2;
        const byte AC_SRC_OVER = 0;
        const byte AC_SRC_ALPHA = 1;
        const int ULW_ALPHA = 2;

        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct SIZE { public int Cx; public int Cy; }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct BLENDFUNCTION
        {
            public byte BlendOp;
            public byte BlendFlags;
            public byte SourceConstantAlpha;
            public byte AlphaFormat;
        }

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
                                               IntPtr hdcSrc, ref POINT pptSrc, int crKey,
                                               ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObject);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);

        MicState state = MicState.Unknown;
        bool compact;
        bool clickThrough;
        float scale = 1f;

        public OverlayForm(ContextMenuStrip menu)
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            ContextMenuStrip = menu;
            Location = DefaultLocation();

            MouseDown += delegate(object s, MouseEventArgs e)
            {
                if (e.Button != MouseButtons.Left) return;
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            };
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        public bool Compact
        {
            get { return compact; }
            set { compact = value; Render(); }
        }

        public float OverlayScale
        {
            get { return scale; }
            set { scale = value; Render(); }
        }

        /// <summary>When true the window ignores the mouse entirely so clicks reach the app beneath.</summary>
        public bool ClickThrough
        {
            get { return clickThrough; }
            set
            {
                clickThrough = value;
                if (!IsHandleCreated) return;
                int ex = GetWindowLong(Handle, GWL_EXSTYLE);
                ex = value ? (ex | WS_EX_TRANSPARENT) : (ex & ~WS_EX_TRANSPARENT);
                SetWindowLong(Handle, GWL_EXSTYLE, ex);
            }
        }

        public void SetState(MicState next)
        {
            state = next;
            Render();
        }

        static Point DefaultLocation()
        {
            var screen = Screen.PrimaryScreen;
            foreach (var s in Screen.AllScreens)
            {
                if (!s.Primary) { screen = s; break; }
            }
            var wa = screen.WorkingArea;
            return new Point(wa.Right - 300, wa.Top + 40);
        }

        public void Render()
        {
            if (!IsHandleCreated || !Visible) return;
            using (var bmp = compact ? BuildDot() : BuildPill())
            {
                Size = bmp.Size;
                ApplyBitmap(bmp);
            }
        }

        Bitmap BuildPill()
        {
            var color = Palette.For(state);
            string label = Palette.Label(state);

            using (var font = new Font("Segoe UI", 11f * scale, FontStyle.Bold, GraphicsUnit.Point))
            {
                SizeF textSize;
                using (var probe = new Bitmap(1, 1))
                using (var pg = Graphics.FromImage(probe))
                {
                    pg.TextRenderingHint = TextRenderingHint.AntiAlias;
                    textSize = pg.MeasureString(label, font);
                }

                int dotSize = Round(20 * scale);
                int padX = Round(17 * scale);
                int gap = Round(11 * scale);
                int shadow = Round(15 * scale);
                int contentW = padX + dotSize + gap + (int)Math.Ceiling(textSize.Width) + padX;
                int contentH = Round(Math.Max(dotSize + 20 * scale, textSize.Height + 17 * scale));

                var bmp = new Bitmap(contentW + shadow * 2, contentH + shadow * 2, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = TextRenderingHint.AntiAlias;
                    g.Clear(Color.Transparent);

                    var rect = new Rectangle(shadow, shadow, contentW, contentH);
                    int radius = contentH / 2;

                    DrawShadow(g, rect, radius, shadow, Round(2 * scale));

                    using (var path = RoundedRect(rect, radius))
                    {
                        using (var brush = new SolidBrush(Color.FromArgb(216, 16, 17, 21)))
                            g.FillPath(brush, path);
                        using (var pen = new Pen(Color.FromArgb(48, 255, 255, 255), 1f))
                            g.DrawPath(pen, path);
                    }

                    var dotRect = new Rectangle(rect.Left + padX, rect.Top + (contentH - dotSize) / 2, dotSize, dotSize);
                    DrawIndicator(g, dotRect, color, Round(10 * scale));

                    using (var brush = new SolidBrush(Color.FromArgb(242, 255, 255, 255)))
                    using (var fmt = new StringFormat { LineAlignment = StringAlignment.Center })
                    {
                        var textRect = new RectangleF(dotRect.Right + gap, rect.Top, contentW, contentH);
                        g.DrawString(label, font, brush, textRect, fmt);
                    }
                }
                return bmp;
            }
        }

        Bitmap BuildDot()
        {
            var color = Palette.For(state);
            int dotSize = Round(34 * scale);
            int shadow = Round(17 * scale);
            int total = dotSize + shadow * 2;

            var bmp = new Bitmap(total, total, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);

                var dotRect = new Rectangle(shadow, shadow, dotSize, dotSize);

                using (var path = new GraphicsPath())
                {
                    path.AddEllipse(dotRect);
                    DrawShadowPath(g, path, shadow, Round(2 * scale));
                }

                using (var brush = new SolidBrush(Color.FromArgb(150, 10, 11, 14)))
                    g.FillEllipse(brush, Rectangle.Inflate(dotRect, Round(4 * scale), Round(4 * scale)));

                DrawIndicator(g, dotRect, color, Round(12 * scale));
            }
            return bmp;
        }

        static void DrawIndicator(Graphics g, Rectangle dotRect, Color color, int glow)
        {
            var glowRect = Rectangle.Inflate(dotRect, glow, glow);
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(glowRect);
                using (var brush = new PathGradientBrush(path))
                {
                    brush.CenterColor = Color.FromArgb(140, color);
                    brush.SurroundColors = new[] { Color.FromArgb(0, color) };
                    g.FillEllipse(brush, glowRect);
                }
            }

            using (var brush = new SolidBrush(color))
                g.FillEllipse(brush, dotRect);
            using (var pen = new Pen(Color.FromArgb(200, ControlPaint.Light(color)), 1.4f))
                g.DrawEllipse(pen, dotRect);
        }

        static void DrawShadow(Graphics g, Rectangle rect, int radius, int depth, int offsetY)
        {
            using (var path = RoundedRect(rect, radius))
                DrawShadowPath(g, path, depth, offsetY);
        }

        static void DrawShadowPath(Graphics g, GraphicsPath path, int depth, int offsetY)
        {
            for (int i = depth; i > 0; i--)
            {
                double t = 1.0 - (double)i / depth;
                int alpha = (int)(78 * t * t);
                if (alpha <= 0) continue;
                using (var clone = (GraphicsPath)path.Clone())
                using (var pen = new Pen(Color.FromArgb(alpha, 0, 0, 0), i * 2f))
                {
                    pen.LineJoin = LineJoin.Round;
                    var m = new Matrix();
                    m.Translate(0, offsetY);
                    clone.Transform(m);
                    m.Dispose();
                    g.DrawPath(pen, clone);
                }
            }
        }

        static GraphicsPath RoundedRect(Rectangle r, int radius)
        {
            int d = radius * 2;
            var path = new GraphicsPath();
            if (d <= 0) { path.AddRectangle(r); return path; }
            path.AddArc(r.Left, r.Top, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        static int Round(double value) { return (int)Math.Round(value); }

        void ApplyBitmap(Bitmap bitmap)
        {
            Premultiply(bitmap);

            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr hBitmap = IntPtr.Zero;
            IntPtr oldBitmap = IntPtr.Zero;

            try
            {
                hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
                oldBitmap = SelectObject(memDc, hBitmap);

                var size = new SIZE { Cx = bitmap.Width, Cy = bitmap.Height };
                var source = new POINT { X = 0, Y = 0 };
                var dest = new POINT { X = Left, Y = Top };
                var blend = new BLENDFUNCTION
                {
                    BlendOp = AC_SRC_OVER,
                    BlendFlags = 0,
                    SourceConstantAlpha = 255,
                    AlphaFormat = AC_SRC_ALPHA
                };

                UpdateLayeredWindow(Handle, screenDc, ref dest, ref size, memDc, ref source, 0, ref blend, ULW_ALPHA);
            }
            finally
            {
                ReleaseDC(IntPtr.Zero, screenDc);
                if (hBitmap != IntPtr.Zero)
                {
                    SelectObject(memDc, oldBitmap);
                    DeleteObject(hBitmap);
                }
                DeleteDC(memDc);
            }
        }

        /// <summary>UpdateLayeredWindow expects premultiplied alpha; GDI+ produces straight alpha.</summary>
        static void Premultiply(Bitmap bmp)
        {
            var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            try
            {
                int length = Math.Abs(data.Stride) * data.Height;
                var buffer = new byte[length];
                Marshal.Copy(data.Scan0, buffer, 0, length);

                for (int i = 0; i + 3 < length; i += 4)
                {
                    byte a = buffer[i + 3];
                    if (a == 255) continue;
                    if (a == 0) { buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0; continue; }
                    buffer[i] = (byte)(buffer[i] * a / 255);
                    buffer[i + 1] = (byte)(buffer[i + 1] * a / 255);
                    buffer[i + 2] = (byte)(buffer[i + 2] * a / 255);
                }

                Marshal.Copy(buffer, 0, data.Scan0, length);
            }
            finally { bmp.UnlockBits(data); }
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
        readonly ToolStripMenuItem[] sizeItems;
        Icon currentIcon;

        public TrayContext()
        {
            marshaler = new Control();
            marshaler.CreateControl();

            var menu = new ContextMenuStrip();

            overlayItem = new ToolStripMenuItem("Show overlay on screen");
            overlayItem.CheckOnClick = true;
            overlayItem.Click += delegate
            {
                if (overlayItem.Checked) { overlay.Show(); overlay.Render(); }
                else overlay.Hide();
            };
            menu.Items.Add(overlayItem);

            var compactItem = new ToolStripMenuItem("Compact (dot only)");
            compactItem.CheckOnClick = true;
            compactItem.Click += delegate { overlay.Compact = compactItem.Checked; };
            menu.Items.Add(compactItem);

            var clickThroughItem = new ToolStripMenuItem("Click-through (uncheck to move it)");
            clickThroughItem.CheckOnClick = true;
            clickThroughItem.Click += delegate { overlay.ClickThrough = clickThroughItem.Checked; };
            menu.Items.Add(clickThroughItem);

            sizeItems = new[]
            {
                new ToolStripMenuItem("Small"),
                new ToolStripMenuItem("Medium"),
                new ToolStripMenuItem("Large")
            };
            sizeItems[0].Tag = 0.8f;
            sizeItems[1].Tag = 1.0f;
            sizeItems[2].Tag = 1.35f;
            sizeItems[1].Checked = true;

            var sizeMenu = new ToolStripMenuItem("Size");
            foreach (var item in sizeItems)
            {
                item.Click += OnSizeClicked;
                sizeMenu.DropDownItems.Add(item);
            }
            menu.Items.Add(sizeMenu);

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, delegate { ExitApp(); });

            overlay = new OverlayForm(menu);

            tray = new NotifyIcon();
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            ApplyState(MicState.Unknown, null);

            monitor = new MicMonitor("Maxwell");
            monitor.StateChanged += OnStateChanged;
            monitor.Start();
        }

        void OnSizeClicked(object sender, EventArgs e)
        {
            var clicked = (ToolStripMenuItem)sender;
            foreach (var item in sizeItems) item.Checked = ReferenceEquals(item, clicked);
            overlay.OverlayScale = (float)clicked.Tag;
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
