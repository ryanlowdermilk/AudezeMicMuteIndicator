using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace MicMuteIndicator.StreamDeck
{
    /// <summary>
    /// Stream Deck plugin host. Stream Deck launches this with -port/-pluginUUID/-registerEvent,
    /// we open a WebSocket back to it, and push a freshly rendered key image whenever the mute
    /// state changes. Detection is the shared <see cref="MicMonitor"/>, so this works whether or
    /// not the tray app is running.
    /// </summary>
    static class Plugin
    {
        static ClientWebSocket socket;
        static readonly object SendLock = new object();
        static readonly HashSet<string> Contexts = new HashSet<string>();
        static readonly Dictionary<MicState, string> ImageCache = new Dictionary<MicState, string>();
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        static MicState current = MicState.Unknown;

        static int Main(string[] args)
        {
            string port = null, uuid = null, registerEvent = null;

            for (int i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == "-port") port = args[i + 1];
                else if (args[i] == "-pluginUUID") uuid = args[i + 1];
                else if (args[i] == "-registerEvent") registerEvent = args[i + 1];
            }

            if (port == null || uuid == null || registerEvent == null) return 1;

            try
            {
                socket = new ClientWebSocket();
                socket.ConnectAsync(new Uri("ws://127.0.0.1:" + port), CancellationToken.None)
                      .GetAwaiter().GetResult();
            }
            catch { return 2; }

            var register = new Dictionary<string, object>();
            register["event"] = registerEvent;
            register["uuid"] = uuid;
            Send(register);

            var monitor = new MicMonitor("Maxwell");
            monitor.StateChanged += OnStateChanged;
            monitor.Start();

            ReceiveLoop();

            monitor.Dispose();
            return 0;
        }

        static void ReceiveLoop()
        {
            var buffer = new byte[8192];
            var builder = new StringBuilder();

            while (socket.State == WebSocketState.Open)
            {
                WebSocketReceiveResult result;
                try
                {
                    result = socket.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None)
                                   .GetAwaiter().GetResult();
                }
                catch { break; }

                if (result.MessageType == WebSocketMessageType.Close) break;

                builder.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                if (!result.EndOfMessage) continue;

                string message = builder.ToString();
                builder.Length = 0;
                HandleMessage(message);
            }
        }

        static void HandleMessage(string message)
        {
            Dictionary<string, object> parsed;
            try { parsed = Json.Deserialize<Dictionary<string, object>>(message); }
            catch { return; }

            if (parsed == null || !parsed.ContainsKey("event")) return;

            string action = Convert.ToString(parsed["event"]);
            string context = parsed.ContainsKey("context") ? Convert.ToString(parsed["context"]) : null;
            if (context == null) return;

            if (action == "willAppear")
            {
                lock (Contexts) Contexts.Add(context);
                PushImage(context, current);
            }
            else if (action == "willDisappear")
            {
                lock (Contexts) Contexts.Remove(context);
            }
        }

        static void OnStateChanged(MicState state, string deviceName)
        {
            current = state;

            string[] snapshot;
            lock (Contexts)
            {
                snapshot = new string[Contexts.Count];
                Contexts.CopyTo(snapshot);
            }

            foreach (var context in snapshot) PushImage(context, state);
        }

        static void PushImage(string context, MicState state)
        {
            var payload = new Dictionary<string, object>();
            payload["image"] = GetImage(state);
            payload["target"] = 0;

            var message = new Dictionary<string, object>();
            message["event"] = "setImage";
            message["context"] = context;
            message["payload"] = payload;

            Send(message);
        }

        static void Send(Dictionary<string, object> message)
        {
            byte[] bytes;
            try { bytes = Encoding.UTF8.GetBytes(Json.Serialize(message)); }
            catch { return; }

            lock (SendLock)
            {
                try
                {
                    socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true,
                                     CancellationToken.None).GetAwaiter().GetResult();
                }
                catch { }
            }
        }

        static string GetImage(MicState state)
        {
            lock (ImageCache)
            {
                string cached;
                if (ImageCache.TryGetValue(state, out cached)) return cached;

                using (var bitmap = RenderKey(state))
                using (var stream = new MemoryStream())
                {
                    bitmap.Save(stream, ImageFormat.Png);
                    string encoded = "data:image/png;base64," + Convert.ToBase64String(stream.ToArray());
                    ImageCache[state] = encoded;
                    return encoded;
                }
            }
        }

        static Bitmap RenderKey(MicState state)
        {
            const int size = 144;
            var color = Palette.For(state);

            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAlias;

                var bounds = new Rectangle(0, 0, size, size);
                using (var brush = new LinearGradientBrush(bounds,
                           ControlPaint.Light(color, 0.35f), ControlPaint.Dark(color, 0.22f), 90f))
                    g.FillRectangle(brush, bounds);

                using (var pen = new Pen(Color.FromArgb(90, 0, 0, 0), 8f))
                    g.DrawRectangle(pen, 4, 4, size - 8, size - 8);

                DrawFittedText(g, Palette.Label(state), size);
            }
            return bitmap;
        }

        static void DrawFittedText(Graphics g, string text, int size)
        {
            string[] lines = text.Split(' ');
            int margin = 14;
            Font font = null;

            try
            {
                for (float pixels = 34f; pixels >= 9f; pixels -= 1f)
                {
                    font = new Font("Segoe UI", pixels, FontStyle.Bold, GraphicsUnit.Pixel);
                    float widest = 0f, total = 0f;

                    foreach (var line in lines)
                    {
                        var measured = g.MeasureString(line, font);
                        if (measured.Width > widest) widest = measured.Width;
                        total += measured.Height;
                    }

                    if (widest <= size - margin * 2 && total <= size - margin * 2) break;

                    font.Dispose();
                    font = null;
                }

                if (font == null) font = new Font("Segoe UI", 9f, FontStyle.Bold, GraphicsUnit.Pixel);

                float lineHeight = g.MeasureString("Wg", font).Height;
                float y = (size - lineHeight * lines.Length) / 2f;

                using (var shadow = new SolidBrush(Color.FromArgb(130, 0, 0, 0)))
                using (var brush = new SolidBrush(Color.White))
                using (var format = new StringFormat { Alignment = StringAlignment.Center })
                {
                    foreach (var line in lines)
                    {
                        g.DrawString(line, font, shadow, new RectangleF(0, y + 2f, size, lineHeight), format);
                        g.DrawString(line, font, brush, new RectangleF(0, y, size, lineHeight), format);
                        y += lineHeight;
                    }
                }
            }
            finally { if (font != null) font.Dispose(); }
        }
    }
}
