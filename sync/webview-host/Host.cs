// EventHelper Sync: the native window around the tool's local web page.
//
// A frameless WinForms window with one WebView2 control. The page's own header
// is the title bar: it asks this host to move, resize, minimize and close the
// window via window.chrome.webview.postMessage (see lib/webui-page.js).
//
// Built by scripts/buildHost.js with the .NET Framework 4 csc.exe (C# 5: no
// string interpolation, no ?. operator) against the WebView2 NuGet package, and
// started by lib/webviewHost.js:
//
//   EventHelperSyncWindow.exe --url <url> --parent-pid <pid> [--width <css px>] [--height <css px>] [--debug]
//
// Exit codes: 0 closed normally, 2 bad arguments, 3 WebView2 could not start
// (the tool then falls back to Edge/Chrome --app, then to a browser tab),
// 4 a window for this sync process was already open and has been brought back.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace EventHelperSync
{
    internal sealed class Options
    {
        public string Url;
        public int ParentPid;
        public double Width = 560;
        public double Height = 680;
        public bool Debug;

        public static Options Parse(string[] args)
        {
            Options o = new Options();
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                string next = i + 1 < args.Length ? args[i + 1] : null;
                if (a == "--url" && next != null) { o.Url = next; i++; }
                else if (a == "--parent-pid" && next != null) { int.TryParse(next, out o.ParentPid); i++; }
                else if (a == "--width" && next != null) { o.Width = ParseSize(next, o.Width); i++; }
                else if (a == "--height" && next != null) { o.Height = ParseSize(next, o.Height); i++; }
                else if (a == "--debug") { o.Debug = true; }
            }
            Uri uri;
            if (string.IsNullOrEmpty(o.Url) || !Uri.TryCreate(o.Url, UriKind.Absolute, out uri)) return null;
            // Only the tool's own page on this machine.
            if (uri.Scheme != Uri.UriSchemeHttp || !uri.IsLoopback) return null;
            if (o.ParentPid <= 0) return null;
            return o;
        }

        private static double ParseSize(string s, double fallback)
        {
            double v;
            if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return fallback;
            return Math.Max(200, Math.Min(4000, v));
        }
    }

    internal static class Program
    {
        public const int ExitOk = 0;
        public const int ExitUsage = 2;
        public const int ExitWebViewFailed = 3;
        public const int ExitHandedOver = 4;

        [STAThread]
        private static int Main(string[] args)
        {
            Options options = Options.Parse(args);
            if (options == null) return ExitUsage;

            Native.EnableDpiAwareness();

            // One window per sync process: a second start (the .exe double-clicked
            // again while the window is open) brings the first window back instead.
            string name = "EventHelperSync.Window." + options.ParentPid;
            bool created;
            using (Mutex mutex = new Mutex(true, @"Local\" + name, out created))
            {
                if (!created)
                {
                    EventWaitHandle other;
                    if (EventWaitHandle.TryOpenExisting(@"Local\" + name + ".Show", out other))
                    {
                        // This process was started by the user's double-click, so
                        // it may hand the foreground on to the existing window.
                        Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                        other.Set();
                        other.Dispose();
                    }
                    return ExitHandedOver;
                }

                using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\" + name + ".Show"))
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    HostForm form = new HostForm(options);
                    RegisteredWaitHandle wait = ThreadPool.RegisterWaitForSingleObject(show, delegate
                    {
                        try { form.BeginInvoke(new Action(form.Reveal)); } catch (InvalidOperationException) { }
                    }, null, Timeout.Infinite, false);
                    Application.Run(form);
                    wait.Unregister(null);
                    return form.ExitCode;
                }
            }
        }

        public static void LogError(string text)
        {
            // A GUI program has no console; this file is what lib/webviewHost.js
            // points to when the window could not start.
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EventHelperSync");
                Directory.CreateDirectory(dir);
                string file = Path.Combine(dir, "window.log");
                if (File.Exists(file) && new FileInfo(file).Length > 256 * 1024) File.Delete(file);
                File.AppendAllText(file, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + text + Environment.NewLine);
            }
            catch (Exception)
            {
                // Nothing else to tell it to.
            }
        }
    }

    internal sealed class HostForm : Form
    {
        // The page's background (--bg in lib/webui-page.js): no white flash while loading.
        private static readonly Color Background = Color.FromArgb(0x16, 0x18, 0x1d);
        private const double MinCssWidth = 420;
        private const double MinCssHeight = 320;

        private readonly Options options;
        private readonly Uri start;
        private readonly WebView2 web;
        private readonly System.Windows.Forms.Timer parentTimer;
        private readonly System.Windows.Forms.Timer resizeTimer;
        private Process parent;
        private bool fitted;
        private string resizeEdge;
        private Point resizeFrom;
        private Rectangle resizeBounds;

        public int ExitCode;

        public HostForm(Options options)
        {
            this.options = options;
            start = new Uri(options.Url);

            Text = "EventHelper Sync";
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.Manual;
            BackColor = Background;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }

            // Start size like the old --window-size, centred on the screen with the mouse.
            Point cursor = Cursor.Position;
            Rectangle area = Screen.FromPoint(cursor).WorkingArea;
            double scale = Native.DpiForPoint(cursor) / 96.0;
            UpdateMinimumSize(scale);
            int w = Math.Min(area.Width, (int)Math.Round(options.Width * scale));
            int h = Math.Min(area.Height, (int)Math.Round(options.Height * scale));
            Bounds = new Rectangle(area.Left + (area.Width - w) / 2, area.Top + (area.Height - h) / 2, w, h);

            web = new WebView2();
            web.Dock = DockStyle.Fill;
            web.DefaultBackgroundColor = Background;
            Controls.Add(web);

            // The window lives as long as the sync process: when that ends (✕ in
            // the page, an update restarting it, the process killed), so does this.
            try { parent = Process.GetProcessById(options.ParentPid); } catch (ArgumentException) { parent = null; }
            parentTimer = new System.Windows.Forms.Timer();
            parentTimer.Interval = 2000;
            parentTimer.Tick += delegate { if (ParentGone()) Close(); };

            resizeTimer = new System.Windows.Forms.Timer();
            resizeTimer.Interval = 15;
            resizeTimer.Tick += delegate { OnResizeTick(); };
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                // Without a caption, these keep the taskbar button working:
                // click to minimize and restore, right-click "Close window".
                cp.Style |= Native.WS_MINIMIZEBOX | Native.WS_SYSMENU;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.StyleWindow(Handle);
        }

        protected override async void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (ParentGone())
            {
                Close();
                return;
            }
            parentTimer.Start();
            await StartWebView();
        }

        private bool ParentGone()
        {
            try { return parent == null || parent.HasExited; } catch (Exception) { return true; }
        }

        private async Task StartWebView()
        {
            try
            {
                string userData = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "EventHelperSync", "webview2");
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, userData, null);
                await web.EnsureCoreWebView2Async(env);
            }
            catch (Exception ex)
            {
                Program.LogError("WebView2 could not start: " + ex.GetType().Name + ": " + ex.Message);
                ExitCode = Program.ExitWebViewFailed;
                Close();
                return;
            }

            CoreWebView2 core = web.CoreWebView2;
            CoreWebView2Settings s = core.Settings;
            // Each in its own try: an older runtime may not know every setting.
            Try(delegate { s.AreDefaultContextMenusEnabled = options.Debug; });
            Try(delegate { s.AreDevToolsEnabled = options.Debug; });
            Try(delegate { s.AreBrowserAcceleratorKeysEnabled = options.Debug; });
            Try(delegate { s.IsStatusBarEnabled = false; });
            Try(delegate { s.IsZoomControlEnabled = false; });
            Try(delegate { s.IsPinchZoomEnabled = false; });
            Try(delegate { s.IsSwipeNavigationEnabled = false; });
            Try(delegate { s.IsPasswordAutosaveEnabled = false; });
            Try(delegate { s.IsGeneralAutofillEnabled = false; });
            Try(delegate { s.AreHostObjectsAllowed = false; });
            Try(delegate { s.IsWebMessageEnabled = true; });

            core.NavigationStarting += OnNavigationStarting;
            core.NewWindowRequested += OnNewWindowRequested;
            core.WindowCloseRequested += delegate { Close(); };
            core.WebMessageReceived += OnWebMessage;
            core.ProcessFailed += OnProcessFailed;
            core.Navigate(start.AbsoluteUri);
        }

        private static void Try(Action action)
        {
            try { action(); } catch (Exception) { }
        }

        private bool IsOwnPage(string url)
        {
            Uri u;
            if (!Uri.TryCreate(url, UriKind.Absolute, out u)) return false;
            return u.Scheme == start.Scheme && u.Host == start.Host && u.Port == start.Port;
        }

        private static void OpenInBrowser(string url)
        {
            Uri u;
            if (!Uri.TryCreate(url, UriKind.Absolute, out u)) return;
            if (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps) return;
            try
            {
                ProcessStartInfo info = new ProcessStartInfo(u.AbsoluteUri);
                info.UseShellExecute = true;
                Process.Start(info);
            }
            catch (Exception) { }
        }

        // The window shows the tool's own page and nothing else: anything else
        // goes to the default browser.
        private void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
        {
            if (IsOwnPage(e.Uri)) return;
            e.Cancel = true;
            OpenInBrowser(e.Uri);
        }

        private void OnNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
            if (!IsOwnPage(e.Uri)) OpenInBrowser(e.Uri);
        }

        private void OnProcessFailed(object sender, CoreWebView2ProcessFailedEventArgs e)
        {
            if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
            {
                Program.LogError("WebView2 browser process exited.");
                ExitCode = Program.ExitWebViewFailed;
                Close();
                return;
            }
            if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessExited
                || e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
            {
                Try(delegate { web.CoreWebView2.Reload(); });
            }
        }

        private void OnWebMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            if (!IsOwnPage(e.Source)) return;
            Dictionary<string, object> msg;
            try
            {
                msg = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(e.WebMessageAsJson);
            }
            catch (Exception)
            {
                return;
            }
            if (msg == null) return;
            object type;
            if (!msg.TryGetValue("type", out type)) return;

            switch (type as string)
            {
                case "drag":
                    BeginMove();
                    break;
                case "edge":
                    BeginResize(StringField(msg, "edge"));
                    break;
                case "minimize":
                    WindowState = FormWindowState.Minimized;
                    break;
                case "close":
                    Close();
                    break;
                case "resize":
                    FitTo(Number(msg, "width"), Number(msg, "height"));
                    break;
            }
        }

        private static string StringField(Dictionary<string, object> msg, string key)
        {
            object v;
            return msg.TryGetValue(key, out v) ? v as string : null;
        }

        private static double Number(Dictionary<string, object> msg, string key)
        {
            object v;
            if (!msg.TryGetValue(key, out v) || v == null) return 0;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch (Exception) { return 0; }
        }

        // Hand the mouse to Windows' own move loop, as if the press had been on
        // a title bar. Posted, not sent: the loop is modal and must not run
        // inside a WebView2 event handler.
        private void BeginMove()
        {
            if (WindowState != FormWindowState.Normal) return;
            Native.ReleaseCapture();
            Point p = Cursor.Position;
            Native.PostMessage(Handle, Native.WM_NCLBUTTONDOWN, (IntPtr)Native.HTCAPTION, Native.MakeLParam(p.X, p.Y));
        }

        // Resizing: Windows' size loop refuses a window without a sizing frame
        // (and a frame would show), so follow the mouse here until the button
        // is released. The page keeps the mouse captured meanwhile.
        private void BeginResize(string edge)
        {
            if (WindowState != FormWindowState.Normal || string.IsNullOrEmpty(edge)) return;
            if (edge.IndexOf("left", StringComparison.Ordinal) < 0 && edge.IndexOf("right", StringComparison.Ordinal) < 0
                && edge.IndexOf("top", StringComparison.Ordinal) < 0 && edge.IndexOf("bottom", StringComparison.Ordinal) < 0) return;
            resizeEdge = edge;
            resizeFrom = Cursor.Position;
            resizeBounds = Bounds;
            resizeTimer.Start();
        }

        private void OnResizeTick()
        {
            if (!Native.PrimaryButtonDown())
            {
                resizeTimer.Stop();
                return;
            }
            Point p = Cursor.Position;
            int dx = p.X - resizeFrom.X;
            int dy = p.Y - resizeFrom.Y;
            int left = resizeBounds.Left, top = resizeBounds.Top, right = resizeBounds.Right, bottom = resizeBounds.Bottom;
            if (resizeEdge.IndexOf("left", StringComparison.Ordinal) >= 0) left = Math.Min(left + dx, right - MinimumSize.Width);
            if (resizeEdge.IndexOf("right", StringComparison.Ordinal) >= 0) right = Math.Max(right + dx, left + MinimumSize.Width);
            if (resizeEdge.IndexOf("top", StringComparison.Ordinal) >= 0) top = Math.Min(top + dy, bottom - MinimumSize.Height);
            if (resizeEdge.IndexOf("bottom", StringComparison.Ordinal) >= 0) bottom = Math.Max(bottom + dy, top + MinimumSize.Height);
            Rectangle next = new Rectangle(left, top, right - left, bottom - top);
            if (next != Bounds) Bounds = next;
        }

        private double CurrentScale()
        {
            return Native.DpiForWindow(Handle) / 96.0;
        }

        private void UpdateMinimumSize(double scale)
        {
            MinimumSize = new Size((int)Math.Round(MinCssWidth * scale), (int)Math.Round(MinCssHeight * scale));
        }

        // fitWindow() in the page: the size of its content in CSS pixels.
        private void FitTo(double cssWidth, double cssHeight)
        {
            if (cssWidth <= 0 || cssHeight <= 0 || WindowState != FormWindowState.Normal) return;
            double scale = CurrentScale();
            Rectangle area = Screen.FromHandle(Handle).WorkingArea;
            int w = Math.Min(area.Width, Math.Max(MinimumSize.Width, (int)Math.Round(cssWidth * scale)));
            int h = Math.Min(area.Height, Math.Max(MinimumSize.Height, (int)Math.Round(cssHeight * scale)));
            int x = Left;
            // The first fit keeps the window centred where it opened.
            int y = fitted ? Top : Top + (Height - h) / 2;
            fitted = true;
            if (x + w > area.Right) x = Math.Max(area.Left, area.Right - w);
            if (y + h > area.Bottom) y = Math.Max(area.Top, area.Bottom - h);
            if (y < area.Top) y = area.Top;
            SetBounds(x, y, w, h);
        }

        public void Reveal()
        {
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Show();
            Activate();
            Native.SetForegroundWindow(Handle);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_DPICHANGED)
            {
                // Moved to a monitor with another scale: take the size Windows suggests.
                int dpi = (int)((long)m.WParam & 0xFFFF);
                UpdateMinimumSize(dpi / 96.0);
                Native.RECT r = (Native.RECT)Marshal.PtrToStructure(m.LParam, typeof(Native.RECT));
                Native.SetWindowPos(Handle, IntPtr.Zero, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
                    Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
                m.Result = IntPtr.Zero;
                return;
            }
            if (m.Msg == Native.WM_SYSCOMMAND && ((int)((long)m.WParam & 0xFFF0)) == Native.SC_MAXIMIZE)
            {
                // No maximized state: the page is laid out for a narrow window.
                return;
            }
            base.WndProc(ref m);
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            parentTimer.Stop();
            resizeTimer.Stop();
            base.OnFormClosed(e);
        }
    }

    internal static class Native
    {
        public const int WS_MINIMIZEBOX = 0x00020000;
        public const int WS_SYSMENU = 0x00080000;
        public const int WM_NCLBUTTONDOWN = 0x00A1;
        public const int WM_SYSCOMMAND = 0x0112;
        public const int WM_DPICHANGED = 0x02E0;
        public const int SC_MAXIMIZE = 0xF030;
        public const int HTCAPTION = 2;
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint ASFW_ANY = 0xFFFFFFFF;

        private const int DWMWA_NCRENDERING_POLICY = 2;
        private const int DWMNCRP_ENABLED = 2;
        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWCP_ROUND = 2;

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MARGINS { public int Left, Right, Top, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X, Y; }

        [DllImport("user32.dll")] public static extern bool ReleaseCapture();
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint processId);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
        [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int value);
        [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hWnd, int attr, ref int value, int size);
        [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr hWnd, ref MARGINS margins);

        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);

        // The physical button that acts as the left one (swapped for left-handed setups).
        public static bool PrimaryButtonDown()
        {
            int key = SystemInformation.MouseButtonsSwapped ? 0x02 /* VK_RBUTTON */ : 0x01 /* VK_LBUTTON */;
            return (GetAsyncKeyState(key) & 0x8000) != 0;
        }

        public static IntPtr MakeLParam(int x, int y)
        {
            return (IntPtr)((y << 16) | (x & 0xFFFF));
        }

        // Normally already done by the manifest (scripts/buildHost.js); this
        // covers a host built without it. Per-monitor v2 first (Windows 10
        // 1703+), then the older variants.
        public static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch (Exception) { }
            try { if (SetProcessDpiAwareness(2) == 0) return; } catch (Exception) { }
            try { SetProcessDPIAware(); } catch (Exception) { }
        }

        public static uint DpiForWindow(IntPtr hWnd)
        {
            try
            {
                uint dpi = GetDpiForWindow(hWnd);
                if (dpi > 0) return dpi;
            }
            catch (Exception) { }
            using (Graphics g = Graphics.FromHwnd(hWnd)) return (uint)Math.Round(g.DpiX);
        }

        public static uint DpiForPoint(Point p)
        {
            try
            {
                POINT pt;
                pt.X = p.X;
                pt.Y = p.Y;
                IntPtr monitor = MonitorFromPoint(pt, 2 /* MONITOR_DEFAULTTONEAREST */);
                uint x, y;
                if (GetDpiForMonitor(monitor, 0 /* MDT_EFFECTIVE_DPI */, out x, out y) == 0 && x > 0) return x;
            }
            catch (Exception) { }
            return 96;
        }

        // Windows 11: rounded corners. Plus the DWM shadow for a window without
        // a frame. Both are harmless no-ops where not supported (Windows 10
        // ignores the corner preference).
        public static void StyleWindow(IntPtr hWnd)
        {
            try
            {
                int corner = DWMWCP_ROUND;
                DwmSetWindowAttribute(hWnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, 4);
            }
            catch (Exception) { }
            try
            {
                int policy = DWMNCRP_ENABLED;
                DwmSetWindowAttribute(hWnd, DWMWA_NCRENDERING_POLICY, ref policy, 4);
                MARGINS margins = new MARGINS();
                margins.Bottom = 1;
                DwmExtendFrameIntoClientArea(hWnd, ref margins);
            }
            catch (Exception) { }
        }
    }
}
