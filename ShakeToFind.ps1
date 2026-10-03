$src = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ShakeToFind : Form
{
    // ---- Tunables ----
    const int   MinSegmentPx   = 40;    // min travel between direction reversals
    const int   ReversalsNeeded = 4;    // reversals within window = a shake
    const int   WindowMs       = 600;   // time window for those reversals
    const int   HoldMs         = 500;   // how long cursor stays big after shaking stops
    const float MaxScale       = 5f;    // how big the cursor gets

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE  { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst,
        ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll")] static extern IntPtr CreateCursor(IntPtr hInst, int xHot, int yHot, int w, int h, byte[] andPlane, byte[] xorPlane);
    [DllImport("user32.dll")] static extern bool SetSystemCursor(IntPtr hcur, uint id);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint winIni);

    static readonly uint[] CursorIds = { 32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650 };
    bool realHidden = false;

    void HideRealCursor()
    {
        if (realHidden) return;
        var andMask = new byte[128];
        var xorMask = new byte[128];
        for (int i = 0; i < 128; i++) andMask[i] = 0xFF;   // fully transparent
        foreach (uint id in CursorIds)
            SetSystemCursor(CreateCursor(IntPtr.Zero, 0, 0, 32, 32, andMask, xorMask), id);
        realHidden = true;
    }

    static void RestoreCursors() { SystemParametersInfo(0x57, 0, IntPtr.Zero, 0); }  // SPI_SETCURSORS

    void ShowRealCursor()
    {
        if (!realHidden) return;
        RestoreCursors();
        realHidden = false;
    }

    Timer timer = new Timer();
    NotifyIcon tray = new NotifyIcon();
    List<int> revs = new List<int>();
    float dpi = 1f, scale = 1f;
    bool shown = false, started = false, haveDir = false;
    int lastX, lastY, segX, segY, lastShake = -100000, lastMove;
    double dX, dY;

    public ShakeToFind()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        var h = this.Handle; // force handle creation (window stays hidden)
        
RestoreCursors(); // in case a previous run was killed while the cursor was hidden
        Application.ApplicationExit += (s, e) => RestoreCursors();
        AppDomain.CurrentDomain.ProcessExit += (s, e) => RestoreCursors();

        using (var g = CreateGraphics()) dpi = g.DpiX / 96f;

        var menu = new ContextMenuStrip();
        menu.Items.Add("Exit", null, (s, e) => { tray.Visible = false; Application.Exit(); });
        tray.Icon = SystemIcons.Application;
        tray.Text = "Shake to Find Cursor";
        tray.ContextMenuStrip = menu;
        tray.Visible = true;

        timer.Interval = 10;
        timer.Tick += (s, e) => Tick();
        timer.Start();
    }

    protected override void SetVisibleCore(bool value) { base.SetVisibleCore(false); }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            // layered | transparent (click-through) | toolwindow | noactivate | topmost
            cp.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x08000000 | 0x8;
            return cp;
        }
    }

    void Tick()
    {
        POINT p; GetCursorPos(out p);
        int now = Environment.TickCount;

        if (!started) { lastX = p.X; lastY = p.Y; started = true; }

        int vx = p.X - lastX, vy = p.Y - lastY;
        if (vx * vx + vy * vy >= 9)
        {
            lastMove = now;
            if (!haveDir) { haveDir = true; segX = lastX; segY = lastY; dX = vx; dY = vy; }
            else if (vx * dX + vy * dY >= 0) { dX = vx; dY = vy; }
            else
            {
                double sx = lastX - segX, sy = lastY - segY;
                double min = MinSegmentPx * dpi;
                if (sx * sx + sy * sy >= min * min)
                {
                    revs.Add(now);
                    segX = lastX; segY = lastY; dX = vx; dY = vy;
                }
            }
            lastX = p.X; lastY = p.Y;
        }
        if (now - lastMove > 300) haveDir = false;

        revs.RemoveAll(t => now - t > WindowMs);
        if (revs.Count >= ReversalsNeeded) lastShake = now;

        bool shaking = (now - lastShake) < HoldMs;
        float target = shaking ? MaxScale : 1f;
        scale += (target - scale) * (target > scale ? 0.25f : 0.12f);

                if (scale > 1.1f)
        {
            Render(scale, p.X, p.Y);
            if (!shown) { ShowWindow(Handle, 4); shown = true; } // SW_SHOWNOACTIVATE
            HideRealCursor();
        }
        else if (shown)
        {
            ShowWindow(Handle, 0); shown = false; scale = 1f;
            ShowRealCursor();
        }
    }

    void Render(float s, int cx, int cy)
    {
        float u = s * dpi;
        int pad = 6;
        int w = (int)(12 * u) + pad * 2, h = (int)(19 * u) + pad * 2;

        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                var pts = new PointF[] {
                    new PointF(0,0), new PointF(0,16), new PointF(4,12.5f), new PointF(7,19),
                    new PointF(10,17.8f), new PointF(7.2f,11.3f), new PointF(12,11) };
                for (int i = 0; i < pts.Length; i++)
                    pts[i] = new PointF(pad + pts[i].X * u, pad + pts[i].Y * u);

                g.FillPolygon(Brushes.Black, pts);
                using (var pen = new Pen(Color.White, Math.Max(1.5f, u * 0.9f)))
                {
                    pen.LineJoin = LineJoin.Round;
                    g.DrawPolygon(pen, pts);
                }
            }

            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr hBmp = bmp.GetHbitmap(Color.FromArgb(0));
            IntPtr old = SelectObject(memDc, hBmp);

            POINT dst = new POINT { X = cx - pad, Y = cy - pad };
            SIZE size = new SIZE { cx = w, cy = h };
            POINT src = new POINT { X = 0, Y = 0 };
            BLENDFUNCTION bf = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, 2);

            SelectObject(memDc, old);
            DeleteObject(hBmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    public static void Run()
    {
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.Run(new ShakeToFind());
    }
}
"@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharp
[ShakeToFind]::Run()