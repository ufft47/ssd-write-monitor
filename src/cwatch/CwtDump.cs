// cwtdump.cs —— 一次性診斷工具：擷取 30 秒的 kernel FileIO 到 .etl，離線印出原始事件。
// 目的：確定「同一個 I/O 是否真的產生兩個事件」，以及可用来區分的欄位是什麼。
// 不動任何服務設定，只建立自己的一次性 ETW session。
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Session;

internal static class CwtDump
{
    private static readonly List<string> Lines = new List<string>();
    private static long _count;
    private static long _bytes;
    private static readonly Dictionary<string, int> ByProc = new Dictionary<string, int>();
    private static readonly Dictionary<string, int> ByShape = new Dictionary<string, int>();
    private static readonly HashSet<ulong> Irps = new HashSet<ulong>();
    private static readonly HashSet<ulong> Fos = new HashSet<ulong>();
    private static int _dumped;

    private static int Main(string[] args)
    {
        int sec = args.Length > 0 ? int.Parse(args[0], CultureInfo.InvariantCulture) : 30;
        string etl = args.Length > 1 ? args[1] : Path.Combine(Path.GetTempPath(), "cwtdump.etl");

        if (!(TraceEventSession.IsElevated() ?? false))
        {
            Console.WriteLine("NEED_ADMIN");
            return 2;
        }

        if (File.Exists(etl)) File.Delete(etl);

        Console.WriteLine("capturing " + sec + "s -> " + etl);
        using (TraceEventSession session = new TraceEventSession("CWatchDump", etl))
        {
            session.EnableKernelProvider(
                KernelTraceEventParser.Keywords.FileIO |
                KernelTraceEventParser.Keywords.FileIOInit |
                KernelTraceEventParser.Keywords.Process);
            Thread.Sleep(sec * 1000);
            session.Dispose();
        }

        Console.WriteLine("captured, parsing offline ...");
        using (ETWTraceEventSource src = new ETWTraceEventSource(etl))
        {
            src.Kernel.FileIOWrite += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOReadWriteTraceData d)
            {
                _count++;
                _bytes += d.IoSize;
                Irps.Add(d.IrpPtr);
                Fos.Add(d.FileObject);

                string proc = d.ProcessName ?? d.ProcessID.ToString(CultureInfo.InvariantCulture);
                int c;
                ByProc.TryGetValue(proc, out c);
                ByProc[proc] = c + 1;

                // 用「欄位組合」統計，找出可區分重複事件的依據
                string shape = "op=" + (int)d.Opcode + " v=" + d.Version + " id=" + (int)d.ID
                             + " fo0=" + (d.FileObject == 0 ? 1 : 0)
                             + " irp0=" + (d.IrpPtr == 0 ? 1 : 0)
                             + " size0=" + (d.IoSize == 0 ? 1 : 0);
                int s;
                ByShape.TryGetValue(shape, out s);
                ByShape[shape] = s + 1;

                if (_dumped < 40)
                {
                    _dumped++;
                    string payload = "";
                    if (d.PayloadNames != null && d.PayloadNames.Length > 0)
                        payload = " payload=[" + string.Join(",", d.PayloadNames) + "]";
                    Lines.Add(string.Format(CultureInfo.InvariantCulture,
                        "#{0} idx={1} op={2}({3}) v={4} tid={5} pid={6} {7} irp={8} fo={9} fkey={10} off={11} size={12} msec={13:F3} name={14}{15}",
                        _dumped, d.EventIndex, (int)d.Opcode, d.OpcodeName, d.Version, d.ThreadID, d.ProcessID, proc,
                        d.IrpPtr, d.FileObject, d.FileKey, d.Offset, d.IoSize, d.TimeStampRelativeMSec,
                        d.FileName ?? "(null)", payload));
                }
            };
            src.Process();
        }

        Console.WriteLine("");
        Console.WriteLine("=== 前 40 個 FileIOWrite 事件 ===");
        foreach (string l in Lines) Console.WriteLine(l);

        Console.WriteLine("");
        Console.WriteLine("=== 統計 ===");
        Console.WriteLine("events      : " + _count.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("sum IoSize  : " + _bytes.ToString("N0", CultureInfo.InvariantCulture) + " bytes (" + (_bytes / 1048576.0).ToString("N1", CultureInfo.InvariantCulture) + " MB)");
        Console.WriteLine("distinct irp: " + Irps.Count.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("distinct fo : " + Fos.Count.ToString("N0", CultureInfo.InvariantCulture));

        Console.WriteLine("");
        Console.WriteLine("=== 事件形狀（用來找可區分的欄位）===");
        List<KeyValuePair<string, int>> shapes = new List<KeyValuePair<string, int>>(ByShape);
        shapes.Sort(delegate(KeyValuePair<string, int> a, KeyValuePair<string, int> b) { return b.Value.CompareTo(a.Value); });
        foreach (KeyValuePair<string, int> kv in shapes) Console.WriteLine("  " + kv.Key + "  ->  " + kv.Value.ToString("N0", CultureInfo.InvariantCulture));

        Console.WriteLine("");
        Console.WriteLine("=== 寫入事件數 前 10 名行程 ===");
        List<KeyValuePair<string, int>> procs = new List<KeyValuePair<string, int>>(ByProc);
        procs.Sort(delegate(KeyValuePair<string, int> a, KeyValuePair<string, int> b) { return b.Value.CompareTo(a.Value); });
        for (int i = 0; i < procs.Count && i < 10; i++)
            Console.WriteLine("  " + procs[i].Key.PadRight(28) + procs[i].Value.ToString("N0", CultureInfo.InvariantCulture));
        return 0;
    }
}
