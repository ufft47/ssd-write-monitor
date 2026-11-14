// CwtDump.cs —— 一次性診斷工具（探針模式）
//
// 目的：回答一個問題 —— 一筆 WriteFile 到底產生幾個 FileIOWrite 事件？
// 若產生兩個，哪個欄位可以區分它們（執行緒？FileObject？IoFlags？時間差？）
//
// 做法：自己在同一個行程裡寫入已知大小的檔案，同時用即時 ETW 擷取，
// 事後只分析「自己這個 PID 對這個檔案的寫入事件」，逐一列出全部欄位並做配對分析。
//
// 需要管理員（kernel ETW session）。不動任何服務設定。

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Session;

internal static class CwtDump
{
    private sealed class Ev
    {
        public long Index;
        public int Tid;
        public int Pid;
        public ulong Irp;
        public ulong Fo;
        public ulong Key;
        public long Off;
        public int Size;
        public int Flags;
        public double Msec;
        public string Source;
    }

    private const string SessionName = "CWatchProbe";
    private const int ChunkMb = 50;

    private static readonly object _lock = new object();
    private static readonly Dictionary<string, string> FoMap = new Dictionary<string, string>();
    private static readonly Dictionary<ulong, string> KeyMap = new Dictionary<ulong, string>();
    private static readonly List<Ev> Mine = new List<Ev>();
    private static long _allCount;
    private static long _allBytes;
    private static long _noneCount;
    private static long _noneBytes;
    private static long _foHit;
    private static long _keyHit;
    private static int _myPid;
    private static string _probePath;

    private static int Main(string[] args)
    {
        int waitSec = args.Length > 0 ? int.Parse(args[0], CultureInfo.InvariantCulture) : 3;
        _myPid = System.Diagnostics.Process.GetCurrentProcess().Id;
        _probePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                  @"Temp\cwtdump-probe.bin");

        if (!(TraceEventSession.IsElevated() ?? false))
        {
            Console.WriteLine("NEED_ADMIN: kernel ETW session requires administrator");
            return 2;
        }

        using (TraceEventSession session = new TraceEventSession(SessionName))
        {
            session.EnableKernelProvider(
                KernelTraceEventParser.Keywords.FileIO |
                KernelTraceEventParser.Keywords.FileIOInit |
                KernelTraceEventParser.Keywords.Process);

            KernelTraceEventParser kernel = session.Source.Kernel;

            kernel.FileIOCreate += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOCreateTraceData d)
            {
                string p = Norm(d.FileName);
                if (p == null) return;
                lock (_lock)
                {
                    FoMap[d.ProcessID.ToString(CultureInfo.InvariantCulture) + "|" + d.FileObject.ToString(CultureInfo.InvariantCulture)] = p;
                }
            };
            kernel.FileIOClose += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOSimpleOpTraceData d)
            {
                lock (_lock) { FoMap.Remove(d.ProcessID.ToString(CultureInfo.InvariantCulture) + "|" + d.FileObject.ToString(CultureInfo.InvariantCulture)); }
            };
            kernel.FileIOName += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIONameTraceData d)
            {
                if (d.FileKey != 0 && !string.IsNullOrEmpty(d.FileName))
                {
                    lock (_lock) { KeyMap[d.FileKey] = Norm(d.FileName); }
                }
            };
            kernel.FileIOFileRundown += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIONameTraceData d)
            {
                if (d.FileKey != 0 && !string.IsNullOrEmpty(d.FileName))
                {
                    lock (_lock) { KeyMap[d.FileKey] = Norm(d.FileName); }
                }
            };

            kernel.FileIOWrite += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOReadWriteTraceData d)
            {
                string src = null;
                if (d.ProcessID == _myPid)
                {
                    lock (_lock)
                    {
                        string p;
                        if (FoMap.TryGetValue(d.ProcessID.ToString(CultureInfo.InvariantCulture) + "|" + d.FileObject.ToString(CultureInfo.InvariantCulture), out p))
                        {
                            src = "fo";
                        }
                        else if (d.FileKey != 0 && KeyMap.TryGetValue(d.FileKey, out p))
                        {
                            src = "fkey";
                        }
                        Ev e = new Ev();
                        e.Index = (long)d.EventIndex;
                        e.Tid = d.ThreadID;
                        e.Pid = d.ProcessID;
                        e.Irp = d.IrpPtr;
                        e.Fo = d.FileObject;
                        e.Key = d.FileKey;
                        e.Off = d.Offset;
                        e.Size = d.IoSize;
                        e.Flags = d.IoFlags;
                        e.Msec = d.TimeStampRelativeMSec;
                        e.Source = src ?? "-";
                        Mine.Add(e);
                    }
                }
                Interlocked.Increment(ref _allCount);
                if (d.IoSize > 0) Interlocked.Add(ref _allBytes, d.IoSize);
            };

            Thread pump = new Thread(delegate() { try { session.Source.Process(); } catch { } });
            pump.IsBackground = true;
            pump.Start();

            Console.WriteLine("probe file : " + _probePath);
            Console.WriteLine("my pid     : " + _myPid);
            Thread.Sleep(2500);

            Console.WriteLine("writing " + ChunkMb + " MB in 1 MB chunks ...");
            byte[] buf = new byte[1024 * 1024];
            for (int i = 0; i < buf.Length; i += 4096) buf[i] = 0x5A;
            double w0 = 0;
            try
            {
                using (FileStream fs = new FileStream(_probePath, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    w0 = System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                    for (int i = 0; i < ChunkMb; i++) fs.Write(buf, 0, buf.Length);
                    fs.Flush(true);
                    double w1 = System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                    Console.WriteLine("write took : " + (w1 - w0).ToString("N0", CultureInfo.InvariantCulture) + " ms");
                }
            }
            catch (Exception e)
            {
                Console.WriteLine("write failed: " + e.Message);
            }
            Thread.Sleep(waitSec * 1000);

            try { session.Dispose(); } catch { }
            Thread.Sleep(600);

            try { File.Delete(_probePath); } catch { }

            lock (_lock) { Report(); }
        }
        return 0;
    }

    private static string Norm(string p)
    {
        if (string.IsNullOrEmpty(p)) return null;
        if (p.StartsWith(@"\\?\")) return p.Substring(4);
        if (p.StartsWith(@"\??\")) return p.Substring(4);
        return p;
    }

    private static void Report()
    {
        int foN = 0, keyN = 0, noneN = 0;
        long foB = 0, keyB = 0, noneB = 0;
        foreach (Ev e in Mine)
        {
            if (e.Source == "fo") { foN++; foB += e.Size; }
            else if (e.Source == "fkey") { keyN++; keyB += e.Size; }
            else { noneN++; noneB += e.Size; }
        }

        Console.WriteLine("");
        Console.WriteLine("=== 本行程的寫入事件 ===");
        Console.WriteLine("total events : " + Mine.Count.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("  via fo map : " + foN.ToString("N0", CultureInfo.InvariantCulture) + " events, " + Mb(foB));
        Console.WriteLine("  via filekey: " + keyN.ToString("N0", CultureInfo.InvariantCulture) + " events, " + Mb(keyB));
        Console.WriteLine("  unresolved : " + noneN.ToString("N0", CultureInfo.InvariantCulture) + " events, " + Mb(noneB));
        Console.WriteLine("expected     : " + ChunkMb + " x 1 MB = " + ChunkMb + " MB");
        Console.WriteLine("");
        Console.WriteLine("=== 全域（所有行程）===");
        Console.WriteLine("events=" + _allCount.ToString("N0", CultureInfo.InvariantCulture) + "  sum=" + Mb(_allBytes));

        Console.WriteLine("");
        Console.WriteLine("=== 本行程事件明細（前 20 筆，依時間）===");
        Mine.Sort(delegate(Ev a, Ev b) { return a.Msec.CompareTo(b.Msec); });
        double t0 = Mine.Count > 0 ? Mine[0].Msec : 0;
        for (int i = 0; i < Mine.Count && i < 20; i++)
        {
            Ev e = Mine[i];
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture,
                "  #{0,3} +{1,8:F3}s tid={2,-6} fo={3} key={4} off={5,-10} size={6,-7} flags=0x{7:X} src={8}",
                i + 1, (e.Msec - t0) / 1000.0, e.Tid, e.Fo, e.Key, e.Off, e.Size, e.Flags, e.Source));
        }

        Console.WriteLine("");
        Console.WriteLine("=== 配對分析：相同 offset+size 的事件（200ms 內）===");
        Dictionary<string, List<Ev>> groups = new Dictionary<string, List<Ev>>();
        foreach (Ev e in Mine)
        {
            string k = e.Off.ToString(CultureInfo.InvariantCulture) + "|" + e.Size.ToString(CultureInfo.InvariantCulture);
            List<Ev> l;
            if (!groups.TryGetValue(k, out l)) { l = new List<Ev>(); groups[k] = l; }
            l.Add(e);
        }
        int g1 = 0, g2 = 0, g3 = 0, sameTid = 0, sameFo = 0, sameFlags = 0, pairs = 0;
        double dtSum = 0;
        List<string> samples = new List<string>();
        foreach (KeyValuePair<string, List<Ev>> kv in groups)
        {
            List<Ev> l = kv.Value;
            l.Sort(delegate(Ev a, Ev b) { return a.Msec.CompareTo(b.Msec); });
            if (l.Count == 1) { g1++; continue; }
            if (l.Count == 2) g2++; else g3++;
            if (l.Count >= 2)
            {
                Ev a = l[0], b = l[1];
                pairs++;
                if (a.Tid == b.Tid) sameTid++;
                if (a.Fo == b.Fo) sameFo++;
                if (a.Flags == b.Flags) sameFlags++;
                double dt = b.Msec - a.Msec;
                dtSum += dt;
                if (samples.Count < 8)
                {
                    samples.Add(string.Format(CultureInfo.InvariantCulture,
                        "  off={0,-10} size={1,-7} dt={2,8:F3}ms  A[tid={3} fo={4} key={5} flags=0x{6:X} src={7}]  B[tid={8} fo={9} key={10} flags=0x{11:X} src={12}]",
                        a.Off, a.Size, dt, a.Tid, a.Fo, a.Key, a.Flags, a.Source, b.Tid, b.Fo, b.Key, b.Flags, b.Source));
                }
            }
        }
        Console.WriteLine("  groups(off+size) : " + groups.Count.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("    1 event        : " + g1.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("    2 events       : " + g2.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("    3+ events      : " + g3.ToString("N0", CultureInfo.InvariantCulture));
        if (pairs > 0)
        {
            Console.WriteLine("  pairs            : " + pairs.ToString("N0", CultureInfo.InvariantCulture));
            Console.WriteLine("    same thread    : " + sameTid.ToString("N0", CultureInfo.InvariantCulture) + " / " + pairs);
            Console.WriteLine("    same FileObject: " + sameFo.ToString("N0", CultureInfo.InvariantCulture) + " / " + pairs);
            Console.WriteLine("    same IoFlags   : " + sameFlags.ToString("N0", CultureInfo.InvariantCulture) + " / " + pairs);
            Console.WriteLine("    mean dt        : " + (dtSum / pairs).ToString("N3", CultureInfo.InvariantCulture) + " ms");
        }
        foreach (string s in samples) Console.WriteLine(s);

        Console.WriteLine("");
        Console.WriteLine("=== 本行程出現過的 IoFlags 值 ===");
        Dictionary<int, int> flags = new Dictionary<int, int>();
        foreach (Ev e in Mine)
        {
            int c;
            flags.TryGetValue(e.Flags, out c);
            flags[e.Flags] = c + 1;
        }
        foreach (KeyValuePair<int, int> kv in flags)
            Console.WriteLine("  0x" + kv.Key.ToString("X") + " -> " + kv.Value.ToString("N0", CultureInfo.InvariantCulture));

        Console.WriteLine("");
        Console.WriteLine("=== 本行程出現過的 distinct FileObject / FileKey 數 ===");
        HashSet<ulong> fos = new HashSet<ulong>();
        HashSet<ulong> keys = new HashSet<ulong>();
        foreach (Ev e in Mine) { fos.Add(e.Fo); keys.Add(e.Key); }
        Console.WriteLine("  distinct fo  : " + fos.Count.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("  distinct key : " + keys.Count.ToString("N0", CultureInfo.InvariantCulture));

        Console.WriteLine("");
        Console.WriteLine("RESULT: expected " + ChunkMb + " MB; via fo=" + Mb(foB) + ", via filekey=" + Mb(keyB) + ", unresolved=" + Mb(noneB));
    }

    private static string Mb(long b)
    {
        return (b / 1048576.0).ToString("N1", CultureInfo.InvariantCulture) + " MB";
    }
}
