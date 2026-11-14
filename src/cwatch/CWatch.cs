// CWatch collector - per-process / per-volume write attribution via ETW kernel FileIO.
// Target: .NET Framework 4.8, compiled with csc (C# 5 syntax only).
//
// Modes:
//   cwatch.exe collect  [root]   - resident collector (requires administrator)
//   cwatch.exe selftest [root]   - one-shot verification (requires administrator)
//
// Output:
//   data\attrib\YYYY-MM-DD.csv   minute,pid,process,volume,path,bytes,ops
//   data\state\collector.json    heartbeat
//
// Volume is derived from the file path, so a row here means "this process wrote
// these bytes to this path", which is the only reliable way to answer "who writes C:".

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Session;

internal static class CWatch
{
    private const string SessionName = "CWatch-Kernel";
    private const int MaxPathsPerPidVolume = 200;
    private const int TopFilesPerPidVolume = 5;

    private static string _root = @"D:\dev\disk-monitor";
    private static readonly object _lock = new object();
    private static readonly Dictionary<string, MinuteAgg> _minutes = new Dictionary<string, MinuteAgg>();
    private static readonly Dictionary<string, string> _procNameCache = new Dictionary<string, string>();
    private static readonly Dictionary<string, string> _exePathCache = new Dictionary<string, string>();
    private static long _evWrite;
    private static long _evCreate;
    private static long _bytesTotal;
    private static long _unresolvedBytes;
    private static long _zeroSizeWrites;
    private static volatile bool _stop;

    // FileObject -> 檔案路徑。FileIO 的 Write 事件常常不帶檔名（只有 Create 帶），
    // 沒有這張表就會有一半的位元組歸不到任何磁碟區。
    // 鍵必須含 PID：同一個 FileObject 指標會被不同進程重用，只用指標當鍵會產生
    // 「1.5 GB 寫到某個根本不存在的檔案」這種假答案。
    private static readonly Dictionary<string, object[]> _fileMap = new Dictionary<string, object[]>();
    private static readonly object _fileMapLock = new object();
    private const int MaxFileMapEntries = 50000;
    private static readonly TimeSpan FileMapTtl = TimeSpan.FromMinutes(30);
    private static long _resolvedMap;
    private static long _resolvedTrace;
    private static long _resolvedDevice;

    // FileIOInit 會讓每筆 I/O 產生「開始 + 完成」兩個事件（TraceEvent 文件明載）。
    // 實測：拿掉 FileIOInit 就完全收不到 FileIOWrite，所以必須開著，
    // 改成只採計「非 Start」的那一個，另外用極短窗的 IRP 比對當保險。
    private static readonly Dictionary<ulong, long[]> _irpSeen = new Dictionary<ulong, long[]>();
    private static readonly object _irpLock = new object();
    private static long _dupesSkipped;
    private static long _skippedStart;
    private static long _opcodeSamples;
    private const long DupeWindowTicks = 30000;   // 3 毫秒（100ns 單位）

    private static void PruneIrp(long nowQpc)
    {
        List<ulong> dead = null;
        foreach (KeyValuePair<ulong, long[]> kv in _irpSeen)
        {
            if (nowQpc - kv.Value[0] > 10000000)   // 1 秒前的都清掉
            {
                if (dead == null) dead = new List<ulong>();
                dead.Add(kv.Key);
            }
        }
        if (dead != null)
        {
            for (int i = 0; i < dead.Count; i++) _irpSeen.Remove(dead[i]);
        }
    }

    private static bool IsStartEvent(Microsoft.Diagnostics.Tracing.TraceEvent e)
    {
        if (e.Opcode == Microsoft.Diagnostics.Tracing.TraceEventOpcode.Start) return true;
        string n = e.OpcodeName;
        return n != null && n.Equals("Start", StringComparison.OrdinalIgnoreCase);
    }

    private static string MapKey(int pid, ulong fileObject)
    {
        return pid.ToString(CultureInfo.InvariantCulture) + "|" + fileObject.ToString(CultureInfo.InvariantCulture);
    }

    // 呼叫端必須持有 _fileMapLock
    private static void EvictExpiredEntries()
    {
        DateTime cutoff = DateTime.UtcNow - FileMapTtl;
        List<string> dead = new List<string>();
        foreach (KeyValuePair<string, object[]> kv in _fileMap)
        {
            DateTime when = new DateTime((long)kv.Value[1], DateTimeKind.Utc);
            if (when < cutoff) dead.Add(kv.Key);
        }
        foreach (string k in dead) _fileMap.Remove(k);
    }

    // ---------- DOS device map ----------
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int QueryDosDevice(string lpDeviceName, StringBuilder lpTargetPath, int ucchMax);

    private static Dictionary<string, string> BuildDeviceMap()
    {
        Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        StringBuilder sb = new StringBuilder(1024);
        for (char c = 'A'; c <= 'Z'; c++)
        {
            string letter = c + ":";
            sb.Length = 0;
            int n = QueryDosDevice(letter, sb, sb.Capacity);
            if (n > 0)
            {
                string target = sb.ToString();
                if (!map.ContainsKey(target)) map[target] = letter;
            }
        }
        return map;
    }

    private static Dictionary<string, string> _deviceMap = BuildDeviceMap();

    private static string NormalizePath(string raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        string p = raw;
        if (p.StartsWith(@"\\?\")) p = p.Substring(4);
        if (p.StartsWith(@"\??\")) p = p.Substring(4);
        return p;
    }

    private static string VolumeOf(string path)
    {
        if (string.IsNullOrEmpty(path)) return "(device)";
        if (path == "(device)") return "(device)";
        string p = path;        if (p.Length >= 2 && p[1] == ':')
        {
            return (char.ToUpperInvariant(p[0])) + ":";
        }
        if (p.StartsWith(@"\Device\", StringComparison.OrdinalIgnoreCase))
        {
            int next = p.IndexOf('\\', 8);
            string dev = next > 0 ? p.Substring(0, next) : p;
            string letter;
            if (_deviceMap.TryGetValue(dev, out letter)) return letter;
            return dev;
        }
        if (p.StartsWith(@"\\", StringComparison.Ordinal)) return "UNC";
        return "(device)";
    }

    // junction / symlink 會讓「程式使用的路徑」與「實際落盤的磁碟區」不同
    // （例如 C:\Users\ufft4\.local\share\opencode → D:\MX500\opencode\data）。
    // 只對 C: 路徑做解析，並以目錄為單位快取，避免在 ETW 回呼裡做大量檔案系統查詢。
    // 值 = object[]{ volume, ticks }，含時效：junction 可能在程式執行期間才建立/移除，
    // 沒有時效的快取會讓「已搬到別的碟」的目錄一直被算成原本的碟。
    private static readonly Dictionary<string, object[]> _volCache = new Dictionary<string, object[]>(StringComparer.OrdinalIgnoreCase);
    private static readonly TimeSpan VolCacheTtl = TimeSpan.FromMinutes(10);
    private static readonly object _volCacheLock = new object();
    private static long _junctionResolved;

    private static string VolumeOfPath(string path)
    {
        string vol = VolumeOf(path);
        if (vol != "C:") return vol;

        string dir = null;
        try { dir = Path.GetDirectoryName(path); } catch { return vol; }
        if (string.IsNullOrEmpty(dir)) return vol;

        lock (_volCacheLock)
        {
            object[] cached;
            if (_volCache.TryGetValue(dir, out cached))
            {
                if (DateTime.UtcNow - new DateTime((long)cached[1], DateTimeKind.Utc) <= VolCacheTtl)
                    return (string)cached[0];
                _volCache.Remove(dir);
            }
        }

        string resolved = ResolveJunctions(dir);
        lock (_volCacheLock)
        {
            if (_volCache.Count < 20000) _volCache[dir] = new object[] { resolved, DateTime.UtcNow.Ticks };
        }
        if (resolved != "C:") Interlocked.Increment(ref _junctionResolved);
        return resolved;
    }

    private static string ResolveJunctions(string dir)
    {
        string real = FinalPathOf(dir);
        if (real == null) return VolumeOf(dir);
        return VolumeOf(real);
    }

    // 用作業系統自己的解析（GetFinalPathNameByHandle）把 junction／symlink／mount point 展開
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(IntPtr hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private static string FinalPathOf(string path)
    {
        IntPtr h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == new IntPtr(-1)) return null;
        try
        {
            StringBuilder sb = new StringBuilder(1024);
            uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (n == 0 || n >= sb.Capacity) return null;
            string r = sb.ToString();
            if (r.StartsWith(@"\\?\")) r = r.Substring(4);
            return r;
        }
        finally { CloseHandle(h); }
    }

    private static string ProcNameOf(int pid, string hint)
    {
        if (!string.IsNullOrEmpty(hint)) return hint;
        string key = pid.ToString(CultureInfo.InvariantCulture);
        lock (_lock)
        {
            string cached;
            if (_procNameCache.TryGetValue(key, out cached)) return cached;
        }
        string name = "?";
        try
        {
            using (Process p = Process.GetProcessById(pid)) { name = p.ProcessName; }
        }
        catch { }
        lock (_lock) { _procNameCache[key] = name; }
        return name;
    }

    private static string ExeOf(int pid)
    {
        string key = pid.ToString(CultureInfo.InvariantCulture);
        lock (_lock)
        {
            string cached;
            if (_exePathCache.TryGetValue(key, out cached)) return cached;
        }
        string exe = "";
        try
        {
            using (Process p = Process.GetProcessById(pid)) { exe = p.MainModule.FileName; }
        }
        catch { }
        lock (_lock) { _exePathCache[key] = exe; }
        return exe;
    }

    // ---------- aggregation ----------
    private sealed class FileAgg
    {
        public long Bytes;
        public long Ops;
    }

    private sealed class PidVolAgg
    {
        public int Pid;
        public string Process;
        public string Volume;
        public long Bytes;
        public long Ops;
        public long UnknownOps;
        public readonly Dictionary<string, FileAgg> Files = new Dictionary<string, FileAgg>(StringComparer.OrdinalIgnoreCase);
        public FileAgg Other = new FileAgg();
    }

    private sealed class MinuteAgg
    {
        public readonly Dictionary<string, PidVolAgg> Items = new Dictionary<string, PidVolAgg>();
    }

    private static PidVolAgg GetAgg(string minute, int pid, string proc, string volume)
    {
        MinuteAgg m;
        if (!_minutes.TryGetValue(minute, out m))
        {
            m = new MinuteAgg();
            _minutes[minute] = m;
        }
        string key = pid.ToString(CultureInfo.InvariantCulture) + "|" + volume;
        PidVolAgg a;
        if (!m.Items.TryGetValue(key, out a))
        {
            a = new PidVolAgg();
            a.Pid = pid;
            a.Process = proc;
            a.Volume = volume;
            m.Items[key] = a;
        }
        return a;
    }

    private static void Record(int pid, string procName, ulong fileObject, string fileName, int ioSize, ulong irp, long qpc)
    {
        // 保險用的去重：同一 irp + 同檔案物件 + 同大小，且相距 3 毫秒內 → 視為同一筆。
        // 視窗必須極短：核心會快速回收 IRP 位址，2 秒窗實測會把 96% 的真實寫入誤判成重複。
        if (irp != 0)
        {
            lock (_irpLock)
            {
                long[] prev;
                if (_irpSeen.TryGetValue(irp, out prev)
                    && Math.Abs(qpc - prev[0]) <= DupeWindowTicks
                    && prev[1] == (long)fileObject
                    && prev[2] == (long)ioSize)
                {
                    _dupesSkipped++;
                    return;
                }
                if (_irpSeen.Count > 200000) PruneIrp(qpc);
                _irpSeen[irp] = new long[] { qpc, (long)fileObject, (long)ioSize };
            }
        }

        string path = null;
        string source = "none";

        // 1) 優先用「自己記錄的 Create」：鍵含 PID，且有時效，避免指標重用造成的假路徑
        if (fileObject != 0)
        {
            string key = MapKey(pid, fileObject);
            lock (_fileMapLock)
            {
                object[] entry;
                if (_fileMap.TryGetValue(key, out entry))
                {
                    DateTime when = new DateTime((long)entry[1], DateTimeKind.Utc);
                    if (DateTime.UtcNow - when <= FileMapTtl)
                    {
                        path = (string)entry[0];
                        source = "map";
                    }
                    else
                    {
                        _fileMap.Remove(key);
                    }
                }
            }
        }

        // 2) 其次用 TraceEvent 自己填的檔名。
        //    但只在事件「有 FileObject」時才採信：沒有 FileObject 的事件，函式庫會回傳
        //    *別的檔案* 的舊路徑，實測造成 Robocopy 的 F: 流量被誤標成 C:/D:。
        if (path == null && fileObject != 0)
        {
            string n = NormalizePath(fileName);
            if (n != null) { path = n; source = "trace"; }
        }

        // 3) 都沒有 → 裝置／pipe／主控台，沒有檔案路徑
        if (path == null) { path = "(device)"; source = "device"; }

        string volume = VolumeOfPath(path);
        string minute = DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        string proc = ProcNameOf(pid, procName);

        lock (_lock)
        {
            if (source == "map") _resolvedMap++;
            else if (source == "trace") _resolvedTrace++;
            else _resolvedDevice++;

            PidVolAgg a = GetAgg(minute, pid, proc, volume);
            a.Ops++;
            if (ioSize > 0)
            {
                a.Bytes += ioSize;
                _bytesTotal += ioSize;
                if (volume == "(device)") _unresolvedBytes += ioSize;
            }
            else
            {
                a.UnknownOps++;
                _zeroSizeWrites++;
            }

            string key = path;
            FileAgg f;
            if (a.Files.TryGetValue(key, out f))
            {
                f.Bytes += Math.Max(0, ioSize);
                f.Ops++;
            }
            else if (a.Files.Count < MaxPathsPerPidVolume)
            {
                f = new FileAgg();
                f.Bytes = Math.Max(0, ioSize);
                f.Ops = 1;
                a.Files[key] = f;
            }
            else
            {
                a.Other.Bytes += Math.Max(0, ioSize);
                a.Other.Ops++;
            }
        }
    }

    // ---------- CSV ----------
    private static string CsvField(string s)
    {
        if (s == null) return "";
        if (s.IndexOfAny(new char[] { ',', '"', '\r', '\n' }) < 0) return s;
        return "\"" + s.Replace("\"", "\"\"") + "\"";
    }

    private static string AttribPath(DateTime day)
    {
        string dir = Path.Combine(_root, @"data\attrib");
        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
        return Path.Combine(dir, day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ".csv");
    }

    private static void FlushMinutes(bool all)
    {
        string currentMinute = DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        List<string> ready = new List<string>();
        lock (_lock)
        {
            foreach (string k in _minutes.Keys)
            {
                if (all || string.CompareOrdinal(k, currentMinute) < 0) ready.Add(k);
            }
            ready.Sort(StringComparer.Ordinal);
        }
        foreach (string minute in ready)
        {
            MinuteAgg m;
            lock (_lock)
            {
                if (!_minutes.TryGetValue(minute, out m)) continue;
                _minutes.Remove(minute);
            }
            WriteMinute(minute, m);
        }
    }

    private static void WriteMinute(string minute, MinuteAgg m)
    {
        if (m.Items.Count == 0) return;
        DateTime day;
        if (!DateTime.TryParseExact(minute, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out day))
            day = DateTime.Now;
        string path = AttribPath(day);
        bool isNew = !File.Exists(path);
        StringBuilder sb = new StringBuilder();

        if (isNew) sb.AppendLine("minute,pid,process,volume,path,bytes,ops");

        foreach (PidVolAgg a in m.Items.Values)
        {
            List<KeyValuePair<string, FileAgg>> list = new List<KeyValuePair<string, FileAgg>>(a.Files);
            list.Sort(delegate(KeyValuePair<string, FileAgg> x, KeyValuePair<string, FileAgg> y)
            {
                return y.Value.Bytes.CompareTo(x.Value.Bytes);
            });

            long emittedBytes = 0;
            long emittedOps = 0;
            for (int i = 0; i < list.Count && i < TopFilesPerPidVolume; i++)
            {
                sb.Append(minute).Append(',').Append(a.Pid).Append(',')
                  .Append(CsvField(a.Process)).Append(',').Append(CsvField(a.Volume)).Append(',')
                  .Append(CsvField(list[i].Key)).Append(',')
                  .Append(list[i].Value.Bytes).Append(',').Append(list[i].Value.Ops).AppendLine();
                emittedBytes += list[i].Value.Bytes;
                emittedOps += list[i].Value.Ops;
            }

            long restBytes = a.Bytes - emittedBytes + a.Other.Bytes;
            long restOps = a.Ops - emittedOps + a.Other.Ops;
            if (restBytes < 0) restBytes = 0;
            if (restOps > 0 || restBytes > 0)
            {
                sb.Append(minute).Append(',').Append(a.Pid).Append(',')
                  .Append(CsvField(a.Process)).Append(',').Append(CsvField(a.Volume)).Append(',')
                  .Append(CsvField("(其他)")).Append(',')
                  .Append(restBytes).Append(',').Append(restOps).AppendLine();
            }
        }

        try
        {
            File.AppendAllText(path, sb.ToString(), new UTF8Encoding(false));
        }
        catch (Exception e)
        {
            Log("write failed: " + e.Message);
        }
    }

    // ---------- heartbeat ----------
    private static void WriteHeartbeat(string state)
    {
        try
        {
            string dir = Path.Combine(_root, @"data\state");
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            long evW, evC, bytes, zero, unresolved, rm, rt, rd, jr, ds, ss, os;
            lock (_lock) { evW = _evWrite; evC = _evCreate; bytes = _bytesTotal; zero = _zeroSizeWrites; unresolved = _unresolvedBytes; rm = _resolvedMap; rt = _resolvedTrace; rd = _resolvedDevice; jr = Interlocked.Read(ref _junctionResolved); ds = Interlocked.Read(ref _dupesSkipped); ss = Interlocked.Read(ref _skippedStart); os = Interlocked.Read(ref _opcodeSamples); }
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("{");
            sb.AppendLine("  \"state\": \"" + state + "\",");
            sb.AppendLine("  \"updated\": \"" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "\",");
            sb.AppendLine("  \"session\": \"" + SessionName + "\",");
            sb.AppendLine("  \"pid\": " + Process.GetCurrentProcess().Id + ",");
            sb.AppendLine("  \"events_write\": " + evW + ",");
            sb.AppendLine("  \"events_create\": " + evC + ",");
            sb.AppendLine("  \"bytes_seen\": " + bytes + ",");
            sb.AppendLine("  \"bytes_device\": " + unresolved + ",");
            sb.AppendLine("  \"resolved_map\": " + rm + ",");
            sb.AppendLine("  \"resolved_trace\": " + rt + ",");
            sb.AppendLine("  \"resolved_device\": " + rd + ",");
            sb.AppendLine("  \"junction_remapped\": " + jr + ",");
            sb.AppendLine("  \"dupes_skipped\": " + ds + ",");
            sb.AppendLine("  \"skipped_start\": " + ss + ",");
            sb.AppendLine("  \"opcode_samples\": " + os + ",");
            sb.AppendLine("  \"writes_without_size\": " + zero);
            sb.AppendLine("}");
            File.WriteAllText(Path.Combine(dir, "collector.json"), sb.ToString(), new UTF8Encoding(false));
        }
        catch { }
    }

    private static void Log(string msg)
    {
        try
        {
            string dir = Path.Combine(_root, "logs");
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "collector.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + msg + "\r\n",
                new UTF8Encoding(false));
        }
        catch { }
    }

    // ---------- main ----------
    private static int RunCollector()
    {
        Log("collector starting, root=" + _root);
        if (!(TraceEventSession.IsElevated() ?? false))
        {
            Console.WriteLine("NEED_ADMIN: collector requires administrator (ETW kernel session)");
            Log("aborted: not elevated");
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
                Interlocked.Increment(ref _evCreate);
                string p = NormalizePath(d.FileName);
                if (p == null) return;
                string key = MapKey(d.ProcessID, d.FileObject);
                lock (_fileMapLock)
                {
                    if (_fileMap.Count >= MaxFileMapEntries) EvictExpiredEntries();
                    if (_fileMap.Count >= MaxFileMapEntries) _fileMap.Clear();
                    _fileMap[key] = new object[] { p, DateTime.UtcNow.Ticks };
                }
            };

            kernel.FileIOClose += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOSimpleOpTraceData d)
            {
                lock (_fileMapLock) { _fileMap.Remove(MapKey(d.ProcessID, d.FileObject)); }
            };

            kernel.FileIOCleanup += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOSimpleOpTraceData d)
            {
                lock (_fileMapLock) { _fileMap.Remove(MapKey(d.ProcessID, d.FileObject)); }
            };

            kernel.FileIOWrite += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOReadWriteTraceData d)
            {
                Interlocked.Increment(ref _evWrite);
                try
                {
                    if (_opcodeSamples < 6)
                    {
                        long n = Interlocked.Increment(ref _opcodeSamples);
                        if (n <= 6) Log("event sample: opcode=" + (int)d.Opcode + "/" + d.OpcodeName + " size=" + d.IoSize + " fo=" + d.FileObject);
                    }
                    if (IsStartEvent(d)) { Interlocked.Increment(ref _skippedStart); return; }
                    Record(d.ProcessID, d.ProcessName, d.FileObject, d.FileName, d.IoSize, d.IrpPtr, (long)(d.TimeStampRelativeMSec * 10000.0));
                }
                catch { }
            };

            Timer flushTimer = new Timer(delegate(object s)
            {
                try
                {
                    FlushMinutes(false);
                    WriteHeartbeat("running");
                    string stopFile = Path.Combine(_root, @"data\state\collector.stop");
                    if (File.Exists(stopFile)) _stop = true;
                }
                catch (Exception e) { Log("tick error: " + e.Message); }
            }, null, 15000, 15000);

            Thread watchdog = new Thread(delegate()
            {
                while (!_stop) Thread.Sleep(1000);
                try { session.Dispose(); } catch { }
            });
            watchdog.IsBackground = true;
            watchdog.Start();

            Log("kernel session started");
            WriteHeartbeat("starting");

            try { session.Source.Process(); }
            catch (Exception e) { Log("source error: " + e.Message); }

            flushTimer.Dispose();
            FlushMinutes(true);
            WriteHeartbeat("stopped");
            Log("collector stopped");
        }
        return 0;
    }

    private static int RunSelfTest()
    {
        Console.WriteLine("root      : " + _root);
        bool elevated = TraceEventSession.IsElevated() ?? false;
        Console.WriteLine("elevated  : " + elevated);
        if (!elevated) { Console.WriteLine("RESULT    : NEED_ADMIN"); return 2; }

        string probePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                        @"Temp\cwatch-selftest.bin");
        const int mb = 64;
        _stop = false;

        TraceEventSession session = new TraceEventSession(SessionName);
        session.EnableKernelProvider(
            KernelTraceEventParser.Keywords.FileIO |
            KernelTraceEventParser.Keywords.FileIOInit |
            KernelTraceEventParser.Keywords.Process);
        KernelTraceEventParser kernel = session.Source.Kernel;
        kernel.FileIOWrite += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOReadWriteTraceData d)
        {
            Interlocked.Increment(ref _evWrite);
            try
            {
                if (IsStartEvent(d)) { Interlocked.Increment(ref _skippedStart); return; }
                Record(d.ProcessID, d.ProcessName, d.FileObject, d.FileName, d.IoSize, d.IrpPtr, (long)(d.TimeStampRelativeMSec * 10000.0));
            }
            catch { }
        };

        Thread pump = new Thread(delegate() { try { session.Source.Process(); } catch { } });
        pump.IsBackground = true;
        pump.Start();
        Thread.Sleep(2500);

        try
        {
            byte[] buf = new byte[1024 * 1024];
            using (FileStream fs = new FileStream(probePath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                for (int i = 0; i < mb; i++) fs.Write(buf, 0, buf.Length);
                fs.Flush(true);
            }
            Console.WriteLine("wrote     : " + mb + " MB to " + probePath);
        }
        catch (Exception e)
        {
            Console.WriteLine("write failed: " + e.Message);
        }
        Thread.Sleep(4000);

        try { session.Dispose(); } catch { }
        Thread.Sleep(500);
        FlushMinutes(true);

        long total;
        lock (_lock) { total = _bytesTotal; }
        Console.WriteLine("events    : write=" + _evWrite);
        Console.WriteLine("bytes seen: " + total.ToString("N0", CultureInfo.InvariantCulture));

        // verify the probe write landed in the attribution rows
        string mine = Path.GetFileName(probePath);
        bool found = false;
        long foundBytes = 0;
        try
        {
            foreach (string f in Directory.GetFiles(Path.Combine(_root, @"data\attrib"), "*.csv"))
            {
                foreach (string line in File.ReadAllLines(f))
                {
                    if (line.IndexOf("cwatch-selftest.bin", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    string[] parts = SplitCsv(line);
                    if (parts.Length < 7) continue;
                    found = true;
                    long b;
                    if (long.TryParse(parts[5], NumberStyles.Any, CultureInfo.InvariantCulture, out b)) foundBytes += b;
                }
            }
        }
        catch { }

        try { File.Delete(probePath); } catch { }

        Console.WriteLine("selftest  : found=" + found + " bytes=" + foundBytes.ToString("N0", CultureInfo.InvariantCulture));
        bool ok = found && foundBytes >= (long)(mb * 1024L * 1024L) * 8L / 10L;
        Console.WriteLine("RESULT    : " + (ok ? "BYTES_OK" : (found ? "BYTES_LOW" : "BYTES_MISSING")));
        return ok ? 0 : 3;
    }

    private static string[] SplitCsv(string line)
    {
        List<string> parts = new List<string>();
        StringBuilder cur = new StringBuilder();
        bool inQuotes = false;
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (inQuotes)
            {
                if (c == '"')
                {
                    if (i + 1 < line.Length && line[i + 1] == '"') { cur.Append('"'); i++; }
                    else inQuotes = false;
                }
                else cur.Append(c);
            }
            else if (c == '"') inQuotes = true;
            else if (c == ',') { parts.Add(cur.ToString()); cur.Length = 0; }
            else cur.Append(c);
        }
        parts.Add(cur.ToString());
        return parts.ToArray();
    }

    private static int Main(string[] args)
    {
        string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        if (args.Length > 1) _root = args[1];

        try
        {
            if (mode == "selftest") return RunSelfTest();
            if (mode == "collect") return RunCollector();
        }
        catch (UnauthorizedAccessException e)
        {
            Console.WriteLine("NEED_ADMIN: " + e.Message);
            Log("aborted: " + e.Message);
            return 2;
        }
        catch (Exception e)
        {
            Console.WriteLine("ERROR: " + e.GetType().Name + ": " + e.Message);
            Log("fatal: " + e.Message);
            return 1;
        }

        Console.WriteLine("usage: cwatch.exe collect|selftest [root]");
        return 1;
    }
}
