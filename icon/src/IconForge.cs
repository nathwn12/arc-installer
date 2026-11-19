using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Text;

namespace ArcInstaller.IconForge
{
    internal static class Program
    {
        static Color C(int v) { return Color.FromArgb(255, v, v, v); }
        static Color CA(int a, int v) { return Color.FromArgb(a, v, v, v); }

        static readonly int[] Sizes = new int[] { 16, 24, 32, 48, 64, 128, 256 };
        static readonly int[] PngSizes = new int[] { 128, 256 };

        static int Main(string[] args)
        {
            if (args.Length < 2) { Console.Error.WriteLine(Usage()); return 2; }
            string mode = args[0].ToLowerInvariant();
            try
            {
                if (mode == "candidates") { CmdCandidates(args[1]); return 0; }
                if (mode == "build") { CmdBuild(args[1], args.Length > 2 ? args[2].ToUpperInvariant() : "A"); return 0; }
                if (mode == "enum") { CmdEnum(args[1]); return 0; }
                if (mode == "extract")
                {
                    if (args.Length < 4) { Console.Error.WriteLine(Usage()); return 2; }
                    CmdExtract(args[1], int.Parse(args[2], CultureInfo.InvariantCulture), args[3]);
                    return 0;
                }
                if (mode == "analyze") { CmdAnalyze(args[1]); return 0; }
                if (mode == "ascii") { CmdAscii(args[1]); return 0; }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("FAILED: " + ex);
                return 1;
            }
            Console.Error.WriteLine(Usage());
            return 2;
        }

        static string Usage()
        {
            return "usage: IconForge candidates <outDir> | build <outDir> <A|B|C> | enum <ico> | extract <ico> <size> <out.png> | analyze <png>";
        }


        static void CmdCandidates(string outDir)
        {
            string cdir = Path.Combine(outDir, "candidates");
            Directory.CreateDirectory(cdir);
            string[] names = new string[] { "A", "B", "C" };
            foreach (string n in names)
            {
                using (Bitmap b = Render(256, n))
                {
                    string p = Path.Combine(cdir, "candidate-" + n + ".png");
                    b.Save(p, ImageFormat.Png);
                    Console.WriteLine("candidate " + n + " -> " + p);
                }
                foreach (int s in new int[] { 16, 32 })
                {
                    using (Bitmap b = Render(s, n))
                    {
                        string p = Path.Combine(cdir, "candidate-" + n + "-" + s + ".png");
                        b.Save(p, ImageFormat.Png);
                    }
                }
            }
        }

        static void CmdBuild(string outDir, string variant)
        {
            Directory.CreateDirectory(outDir);
            List<IcoEntry> entries = new List<IcoEntry>();
            foreach (int s in Sizes)
            {
                using (Bitmap b = Render(s, variant))
                {
                    bool png = Array.IndexOf(PngSizes, s) >= 0;
                    entries.Add(new IcoEntry(s, png ? ToPng(b) : ToDib(b), png));
                }
            }
            string ico = Path.Combine(outDir, "ArcInstaller.ico");
            WriteIco(ico, entries);
            Console.WriteLine("wrote " + ico + " (" + entries.Count + " entries, " + new FileInfo(ico).Length + " bytes)");

            foreach (int s in new int[] { 256, 32 })
            {
                using (Bitmap b = ReadIcoEntry(ico, s))
                {
                    string p = Path.Combine(outDir, s == 256 ? "icon-256.png" : "icon-32.png");
                    b.Save(p, ImageFormat.Png);
                    Console.WriteLine("back-render " + s + "px -> " + p);
                }
            }
            using (Bitmap b16 = ReadIcoEntry(ico, 16))
            {
                string p = Path.Combine(outDir, "icon-16-zoom8x.png");
                SaveZoom(b16, p, 8);
                Console.WriteLine("back-render 16px zoom8x -> " + p);
            }
        }

        static void CmdEnum(string icoPath)
        {
            byte[] raw = File.ReadAllBytes(icoPath);
            int count = BitConverter.ToInt16(raw, 4);
            Console.WriteLine("file: " + icoPath);
            Console.WriteLine("bytes: " + raw.Length);
            Console.WriteLine("declared entries: " + count);
            Console.WriteLine("idx  w    h    planes bpp  payload  fmt");
            for (int i = 0; i < count; i++)
            {
                int o = 6 + i * 16;
                int w = raw[o], h = raw[o + 1];
                if (w == 0) w = 256;
                if (h == 0) h = 256;
                int planes = BitConverter.ToInt16(raw, o + 4);
                int bpp = BitConverter.ToInt16(raw, o + 6);
                int len = BitConverter.ToInt32(raw, o + 8);
                int off = BitConverter.ToInt32(raw, o + 12);
                bool png = len > 8 && raw[off] == 0x89 && raw[off + 1] == 0x50 && raw[off + 2] == 0x4E && raw[off + 3] == 0x47;
                Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "{0,-4} {1,-4} {2,-4} {3,-6} {4,-4} {5,-8} {6}",
                    i, w, h, planes, bpp, len, png ? "PNG" : "DIB(32bpp BGRA)"));
            }
        }

        static void CmdExtract(string icoPath, int size, string outPng)
        {
            using (Bitmap b = ReadIcoEntry(icoPath, size))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPng)));
                b.Save(outPng, ImageFormat.Png);
                Console.WriteLine("extracted " + b.Width + "x" + b.Height + " -> " + outPng);
            }
        }

        static void CmdAnalyze(string png)
        {
            using (Bitmap b = new Bitmap(png))
            {
                Analyze(b, png);
            }
        }

        static void CmdAscii(string png)
        {
            using (Bitmap b = new Bitmap(png))
            {
                string ramp = " .:-=+*#%@";
                Console.WriteLine("ascii " + png + " (" + b.Width + "x" + b.Height + ")");
                Console.WriteLine("      " + new string('-', b.Width));
                for (int y = 0; y < b.Height; y++)
                {
                    StringBuilder sb = new StringBuilder();
                    for (int x = 0; x < b.Width; x++)
                    {
                        Color c = b.GetPixel(x, y);
                        if (c.A < 60) { sb.Append('.'); continue; }
                        double l = Lum(c) * (c.A / 255.0);
                        int idx = (int)Math.Round(l / 255.0 * (ramp.Length - 1));
                        if (idx < 0) idx = 0;
                        if (idx > ramp.Length - 1) idx = ramp.Length - 1;
                        sb.Append(ramp[idx]);
                    }
                    Console.WriteLine("  " + y.ToString("00") + "  " + sb.ToString());
                }
                Console.WriteLine("      " + new string('-', b.Width));
            }
        }


        static Bitmap Render(int size, string variant)
        {
            int ss = 4;                                   // supersample, then high-quality downscale
            int big = size * ss;
            Bitmap hi = new Bitmap(big, big, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(hi))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.Clear(Color.Transparent);
                float N = size;                            // geometry is authored in LOGICAL px
                float s = ss;                              // then scaled up to the supersampled canvas
                if (variant == "A") DrawGrid(g, N, s);
                else if (variant == "B") DrawLayers(g, N, s);
                else if (variant == "C") DrawArcA(g, N, s);
                else throw new ArgumentException("unknown variant " + variant);
            }
            Bitmap lo = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(lo))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.Clear(Color.Transparent);
                g.DrawImage(hi, new Rectangle(0, 0, size, size));
            }
            hi.Dispose();
            return lo;
        }

        static GraphicsPath RoundRect(float x, float y, float w, float h, float r)
        {
            GraphicsPath p = new GraphicsPath();
            if (w <= 0 || h <= 0) return p;
            if (r < 0.01f) { p.AddRectangle(new RectangleF(x, y, w, h)); return p; }
            if (r > w / 2f) r = w / 2f;
            if (r > h / 2f) r = h / 2f;
            float d = r * 2f;
            p.AddArc(x, y, d, d, 180f, 90f);
            p.AddArc(x + w - d, y, d, d, 270f, 90f);
            p.AddArc(x + w - d, y + h - d, d, d, 0f, 90f);
            p.AddArc(x, y + h - d, d, d, 90f, 90f);
            p.CloseFigure();
            return p;
        }

        static void SoftShadow(Graphics g, float x, float y, float w, float h, float r, float N, float s)
        {
            float spread = Math.Max(0.7f, 0.032f * N) * s;
            float dy = Math.Max(0.6f, 0.020f * N) * s;
            int steps = 5;
            for (int i = steps; i >= 1; i--)
            {
                float e = spread * i / steps;
                int alpha = 12;
                using (GraphicsPath p = RoundRect(x - e, y - e + dy, w + 2 * e, h + 2 * e, r + e))
                using (SolidBrush b = new SolidBrush(Color.FromArgb(alpha, 0, 0, 0)))
                    g.FillPath(b, p);
            }
        }

        static void DrawGrid(Graphics g, float N, float s)
        {
            float inset = Math.Max(1.0f, 0.070f * N);
            float plateW = N - 2f * inset;
            float plateR = Math.Max(1.6f, 0.220f * plateW);
            SoftShadow(g, inset * s, inset * s, plateW * s, plateW * s, plateR * s, N, s);

            using (GraphicsPath plate = RoundRect(inset * s, inset * s, plateW * s, plateW * s, plateR * s))
            {
                using (LinearGradientBrush b = new LinearGradientBrush(
                    new PointF(inset * s, inset * s * 0.7f),
                    new PointF((inset + plateW) * s, (inset + plateW) * s),
                    C(0x4E), C(0x40)))
                    g.FillPath(b, plate);
                if (N >= 24)
                {
                    using (Pen pen = new Pen(CA(130, 0xA0), Math.Max(0.7f, 0.011f * N) * s))
                        g.DrawPath(pen, plate);
                }
                else
                {
                    using (Pen pen = new Pen(CA(110, 0x9A), 0.9f * s))
                        g.DrawPath(pen, plate);
                }
            }

            float p = Math.Max(1.0f, 0.075f * N);
            float inner = plateW - 2f * p;
            float gap = Math.Max(1.5f, 0.055f * N);
            if (N <= 20) gap = Math.Max(gap, 1.6f);
            float q = (inner - gap) / 2f;
            float qr = Math.Max(0.5f, 0.20f * q);
            int[] lum = new int[] { 0xC0, 0xA8, 0x90, 0x70 };
            float x0 = inset + p;
            for (int i = 0; i < 4; i++)
            {
                int row = i / 2, col = i % 2;
                float x = (x0 + col * (q + gap)) * s;
                float y = (x0 + row * (q + gap)) * s;
                using (GraphicsPath qp = RoundRect(x, y, q * s, q * s, qr * s))
                using (SolidBrush b = new SolidBrush(C(lum[i])))   // flat swatch: stays crisp at 16px
                    g.FillPath(b, qp);
            }
        }

        static void DrawLayers(Graphics g, float N, float s)
        {
            float inset = Math.Max(1.0f, 0.085f * N);
            float off = Math.Max(1.6f, 0.095f * N);
            float w = N - 2f * inset - 2f * off;
            float r = Math.Max(1.4f, 0.185f * w);
            SoftShadow(g, (inset + 2 * off) * s, (inset + 2 * off) * s, w * s, w * s, r * s, N, s);
            int[] lum = new int[] { 0x60, 0x90, 0xC0 };   // back, mid, front
            for (int i = 0; i < 3; i++)
            {
                float x = (inset + (2 - i) * off) * s;
                float y = (inset + i * off) * s;
                using (GraphicsPath p = RoundRect(x, y, w * s, w * s, r * s))
                {
                    using (LinearGradientBrush b = new LinearGradientBrush(
                        new PointF(x, y), new PointF(x + w * s, y + w * s), C(Math.Min(0xC0, lum[i] + 8)), C(Math.Max(0x40, lum[i] - 10))))
                        g.FillPath(b, p);
                    if (i > 0)
                    {
                        using (Pen pen = new Pen(CA(200, 0x40), Math.Max(0.7f, 0.012f * N) * s))
                            g.DrawPath(pen, p);
                    }
                }
            }
        }

        static void DrawArcA(Graphics g, float N, float s)
        {
            float inset = Math.Max(1.0f, 0.058f * N);
            float w = N - 2f * inset;
            float r = Math.Max(1.6f, 0.215f * w);
            SoftShadow(g, inset * s, inset * s, w * s, w * s, r * s, N, s);

            using (GraphicsPath tile = RoundRect(inset * s, inset * s, w * s, w * s, r * s))
            {
                using (LinearGradientBrush b = new LinearGradientBrush(
                    new PointF(inset * s, inset * s), new PointF((inset + w) * s, (inset + w) * s), C(0xC0), C(0x8E)))
                    g.FillPath(b, tile);
            }

            float boxW = 0.52f * w, boxH = 0.54f * w;
            float bx = inset + (w - boxW) / 2f, by = inset + (w - boxH) / 2f - 0.045f * w;
            float legT = 0.20f * boxW;
            Color ink = C(0x40);

            PointF[] left = new PointF[] {
                new PointF((bx + 0.50f * boxW) * s, by * s),
                new PointF((bx + 0.50f * boxW - 0.16f * boxW) * s, by * s),
                new PointF((bx + 0.06f * boxW) * s, (by + boxH) * s),
                new PointF((bx + 0.06f * boxW + legT) * s, (by + boxH) * s)
            };
            PointF[] right = new PointF[] {
                new PointF((bx + 0.50f * boxW) * s, by * s),
                new PointF((bx + 0.50f * boxW + 0.16f * boxW) * s, by * s),
                new PointF((bx + 0.94f * boxW) * s, (by + boxH) * s),
                new PointF((bx + 0.94f * boxW - legT) * s, (by + boxH) * s)
            };
            PointF[] bar = new PointF[] {
                new PointF((bx + 0.395f * boxW) * s, (by + 0.615f * boxH) * s),
                new PointF((bx + 0.605f * boxW) * s, (by + 0.615f * boxH) * s),
                new PointF((bx + 0.605f * boxW) * s, (by + 0.765f * boxH) * s),
                new PointF((bx + 0.395f * boxW) * s, (by + 0.765f * boxH) * s)
            };
            using (SolidBrush b = new SolidBrush(ink))
            {
                g.FillPolygon(b, left);
                g.FillPolygon(b, right);
                g.FillPolygon(b, bar);
            }

            if (N >= 32)   // arc sweep = the "Arc" cue; dropped at tiny sizes where it would muddy
            {
                float ar = 0.295f * w;
                using (Pen pen = new Pen(CA(190, 0x40), Math.Max(1.0f, 0.055f * w) * s))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    g.DrawArc(pen, (inset + w / 2f - ar) * s, (inset + w * 0.735f - ar) * s, 2 * ar * s, 2 * ar * s, 200f, 140f);
                }
            }
        }


        class IcoEntry
        {
            public int Size; public byte[] Data; public bool Png;
            public IcoEntry(int s, byte[] d, bool p) { Size = s; Data = d; Png = p; }
        }

        static byte[] ToPng(Bitmap b)
        {
            using (MemoryStream ms = new MemoryStream())
            {
                b.Save(ms, ImageFormat.Png);
                return ms.ToArray();
            }
        }

        static byte[] ToDib(Bitmap bmp)
        {
            int w = bmp.Width, h = bmp.Height;
            int maskStride = ((w + 31) / 32) * 4;
            int xorSize = w * h * 4;
            int andSize = maskStride * h;
            MemoryStream ms = new MemoryStream(40 + xorSize + andSize);
            BinaryWriter bw = new BinaryWriter(ms);
            bw.Write(40); bw.Write(w); bw.Write(h * 2); bw.Write((short)1); bw.Write((short)32);
            bw.Write(0); bw.Write(xorSize + andSize); bw.Write(0); bw.Write(0); bw.Write(0); bw.Write(0);
            for (int y = h - 1; y >= 0; y--)
                for (int x = 0; x < w; x++)
                {
                    Color c = bmp.GetPixel(x, y);
                    bw.Write(c.B); bw.Write(c.G); bw.Write(c.R); bw.Write(c.A);
                }
            byte[] mask = new byte[andSize];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    Color c = bmp.GetPixel(x, h - 1 - y);
                    if (c.A < 128) mask[y * maskStride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
                }
            bw.Write(mask);
            bw.Flush();
            return ms.ToArray();
        }

        static void WriteIco(string path, List<IcoEntry> entries)
        {
            using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                BinaryWriter bw = new BinaryWriter(fs);
                bw.Write((short)0); bw.Write((short)1); bw.Write((short)entries.Count);
                int offset = 6 + 16 * entries.Count;
                foreach (IcoEntry e in entries)
                {
                    bw.Write((byte)(e.Size >= 256 ? 0 : e.Size));
                    bw.Write((byte)(e.Size >= 256 ? 0 : e.Size));
                    bw.Write((byte)0); bw.Write((byte)0);
                    bw.Write((short)1); bw.Write((short)32);
                    bw.Write(e.Data.Length);
                    bw.Write(offset);
                    offset += e.Data.Length;
                }
                foreach (IcoEntry e in entries) bw.Write(e.Data);
                bw.Flush();
            }
        }

        static int IndexOfSize(byte[] raw, int size)
        {
            int count = BitConverter.ToInt16(raw, 4);
            for (int i = 0; i < count; i++)
            {
                int o = 6 + i * 16;
                int w = raw[o] == 0 ? 256 : raw[o];
                if (w == size) return i;
            }
            throw new InvalidDataException("no entry of size " + size + " in icon");
        }

        static Bitmap ReadIcoEntry(string icoPath, int size)
        {
            byte[] raw = File.ReadAllBytes(icoPath);
            int i = IndexOfSize(raw, size);
            int o = 6 + i * 16;
            int len = BitConverter.ToInt32(raw, o + 8);
            int off = BitConverter.ToInt32(raw, o + 12);
            byte[] data = new byte[len];
            Buffer.BlockCopy(raw, off, data, 0, len);

            if (data.Length > 8 && data[0] == 0x89 && data[1] == 0x50)   // PNG payload
            {
                using (MemoryStream ms = new MemoryStream(data))
                using (Image img = Image.FromStream(ms))
                    return new Bitmap(img);
            }
            int w = BitConverter.ToInt32(data, 4);
            int h = BitConverter.ToInt32(data, 8) / 2;
            Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            int stride = bd.Stride;
            byte[] row = new byte[Math.Abs(stride)];
            int baseOff = 40;
            for (int y = 0; y < h; y++)
            {
                int srcRow = baseOff + (h - 1 - y) * w * 4;   // DIB rows are bottom-up
                for (int x = 0; x < w; x++)
                {
                    row[x * 4 + 0] = data[srcRow + x * 4 + 0];
                    row[x * 4 + 1] = data[srcRow + x * 4 + 1];
                    row[x * 4 + 2] = data[srcRow + x * 4 + 2];
                    row[x * 4 + 3] = data[srcRow + x * 4 + 3];
                }
                System.Runtime.InteropServices.Marshal.Copy(row, 0, (IntPtr)((long)bd.Scan0 + (long)y * stride), stride);
            }
            bmp.UnlockBits(bd);
            return bmp;
        }


        static void SaveZoom(Bitmap b16, string path, int zoom)
        {
            Color[] panels = new Color[] { Color.White, Color.FromArgb(255, 0x80, 0x80, 0x80), Color.FromArgb(255, 0x1E, 0x1E, 0x1E) };
            int pad = 8;
            int cell = b16.Width * zoom;
            int W = panels.Length * (cell + 2 * pad) + pad;
            int H = cell + 2 * pad;
            using (Bitmap outB = new Bitmap(W, H, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(outB))
                {
                    g.Clear(Color.FromArgb(255, 0x30, 0x30, 0x30));
                    for (int i = 0; i < panels.Length; i++)
                    {
                        int x = pad + i * (cell + 2 * pad);
                        using (SolidBrush sb = new SolidBrush(panels[i]))
                            g.FillRectangle(sb, x, pad, cell, cell);
                    }
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    for (int i = 0; i < panels.Length; i++)
                    {
                        int x = pad + i * (cell + 2 * pad);
                        g.DrawImage(b16, new Rectangle(x, pad, cell, cell));
                    }
                }
                outB.Save(path, ImageFormat.Png);
            }
        }

        static double Lum(Color c)
        {
            return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B;
        }

        static void Analyze(Bitmap b, string label)
        {
            int n = b.Width * b.Height;
            int ink = 0, minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
            double sum = 0, minL = 999, maxL = -1;
            int[] quad = new int[4];
            for (int y = 0; y < b.Height; y++)
                for (int x = 0; x < b.Width; x++)
                {
                    Color c = b.GetPixel(x, y);
                    if (c.A >= 128)
                    {
                        ink++;
                        double l = Lum(c);
                        sum += l;
                        if (l < minL) minL = l;
                        if (l > maxL) maxL = l;
                        if (x < minX) minX = x;
                        if (y < minY) minY = y;
                        if (x > maxX) maxX = x;
                        if (y > maxY) maxY = y;
                        int q = (y < b.Height / 2f ? 0 : 2) + (x < b.Width / 2f ? 0 : 1);
                        quad[q]++;
                    }
                }
            double mean = ink > 0 ? sum / ink : 0;
            double var = 0;
            for (int y = 0; y < b.Height; y++)
                for (int x = 0; x < b.Width; x++)
                {
                    Color c = b.GetPixel(x, y);
                    if (c.A >= 128) { double d = Lum(c) - mean; var += d * d; }
                }
            double wcWhite = 255 - mean;      // worst-case ink-vs-bg contrast, light desktop
            double wcDark = mean - 30;        // vs #1E1E1E desktop
            Console.WriteLine("analyze " + label + " (" + b.Width + "x" + b.Height + ")");
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  ink coverage : {0:F1}% of frame", 100.0 * ink / n));
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  ink bbox     : {0}x{1} at ({2},{3})", maxX - minX + 1, maxY - minY + 1, minX, minY));
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  luminance    : mean {0:F1} min {1:F1} max {2:F1} sd {3:F1}", mean, minL, maxL, Math.Sqrt(var / Math.Max(1, ink))));
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  contrast mean: vs white {0:F1}  vs #1E1E1E {1:F1}  worst {2:F1}", wcWhite, wcDark, Math.Min(wcWhite, wcDark)));
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  quadrant ink : TL {0}  TR {1}  BL {2}  BR {3} (of {4})", quad[0], quad[1], quad[2], quad[3], ink));
        }
    }
}
