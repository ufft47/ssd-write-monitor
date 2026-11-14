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
// Key facts (verified 2026-11-15 with a raw event dump):
//   * FileIOWrite events are delivered only when Keywords.FileIOInit is enabled.
//   * Each write produces exactly ONE FileIOWrite event (no duplication); the
//     event carries IoSize + FileObject, but its FileName is EMPTY (TraceEvent
//     decodes the kernel event dynamically, id=65535), so the file path must come
//     from our own FileIOCreate map, keyed by (PID, FileObject).
//   * IrpPtr is NOT unique per request (FastIO path), so it cannot be used to
//     deduplicate. There is nothing to deduplicate anyway.

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
    private static long _evWrite;
    private static long _evCreate;
    private static long _bytesTotal;
    private static long _unresolvedBytes;
    private static long _zeroSizeWrites;
    private static volatile bool _stop;

    // FileObject -> 檔案路徑。FileIOWrite 事件不帶檔名（只有 FileIOCreate 帶），
    // 沒有這張表就歸不到任何磁碟區。
    // 鍵必須含 PID：同一個 FileObject 指標會被不同進程重用，只用指標當鍵會產生
    // 「1.5 GB 寫到某個根本不存在的檔案」這種假答案。
    private static readonly Dictionary<string, object[]> _fileMap = new Dictionary<string, object[]>();
    private static readonly object _fileMapLock = new object();
    private const int MaxFileMapEntries = 50000;
    private static readonly TimeSpan FileMapTtl = TimeSpan.FromMinutes(30);
    private static long _resolvedMap;
    private static long _resolvedKey;
    private static long _nameEvents;
    private static long _rundownEntries;
    private static long _unresolvedOps;
    // 落地層（無法解析路徑）的位元組按程式統計，只寫進心跳，用來解釋殘差。
    private static readonly Dictionary<string, long> _unresolvedByProc = new Dictionary<string, long>();

    // FileKey -> 檔案路徑。FileKey 是「檔案身分」（同一個檔案的多個手柄共用同一個值），
    // 由 FileIOName / FileIOFileRundown 提供。它補的是 FileIOCreate 看不到的那一段：
    // session 開始前就已經開好的手柄（登錄檔 hive、pagefile、系統記錄檔…）。
    private static readonly Dictionary<ulong, object[]> _fileKeyMap = new Dictionary<ulong, object[]>();
    private static readonly object _fileKeyLock = new object();
    private const int MaxFileKeyEntries = 100000;
    private static readonly TimeSpan FileKeyTtl = TimeSpan.FromMinutes(30);

    private static string MapKey(int pid, ulong fileObject)
    {
        return pid.ToString(CultureInfo.InvariantCulture) + "|" + fileObject.ToString(CultureInfo.InvariantCulture);
    }

    // FileIOName / FileIOFileRundown 給的名字常是「裝置路徑」
    // （\Device\HarddiskVolume3\Users\...），先換回磁碟代號，
    // 這樣 CSV 的 path 欄位才可讀，junction 解析也才作用得上。
    private static string ToDosPath(string p)
    {
        if (string.IsNullOrEmpty(p)) return p;
        if (!p.StartsWith(@"\Device\", StringComparison.OrdinalIgnoreCase)) return p;
        int next = p.IndexOf('\\', 8);
        if (next <= 0) return p;
        string dev = p.Substring(0, next);
        string letter;
        if (_deviceMap.TryGetValue(dev, out letter)) return letter + p.Substring(next);
        return p;
    }

    // 呼叫端必須持有 _fileKeyLock
    private static void EvictExpiredFileKeys()
    {
        DateTime cutoff = DateTime.UtcNow - FileKeyTtl;
        List<ulong> dead = new List<ulong>();
        foreach (KeyValuePair<ulong, object[]> kv in _fileKeyMap)
        {
            if (new DateTime((long)kv.Value[1], DateTimeKind.Utc) < cutoff) dead.Add(kv.Key);
        }
        foreach (ulong k in dead) _fileKeyMap.Remove(k);
    }

    private static void LearnFileKey(ulong fileKey, string path)
    {
        if (fileKey == 0 || string.IsNullOrEmpty(path)) return;
        path = ToDosPath(path);
        lock (_fileKeyLock)
        {
            if (_fileKeyMap.Count >= MaxFileKeyEntries) EvictExpiredFileKeys();
            if (_fileKeyMap.Count >= MaxFileKeyEntries) _fileKeyMap.Clear();
            _fileKeyMap[fileKey] = new object[] { path, DateTime.UtcNow.Ticks };
        }
    }

    private static string LookupFileKey(ulong fileKey)
    {
        lock (_fileKeyLock)
        {
            object[] entry;
            if (!_fileKeyMap.TryGetValue(fileKey, out entry)) return null;
            if (DateTime.UtcNow - new DateTime((long)entry[1], DateTimeKind.Utc) > FileKeyTtl)
            {
                _fileKeyMap.Remove(fileKey);
                return null;
            }
            return (string)entry[0];
        }
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
        string p = path;
        if (p.Length >= 2 && p[1] == ':')
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

    private static void Record(int pid, string procName, ulong fileObject, ulong fileKey, int ioSize)
    {
        string path = null;
        string source = null;

        // 1) 自己記錄的 FileIOCreate 對照表（鍵含 PID、有時效、Close 時移除）。
        //    不採信 TraceEvent 的 d.FileName：它只用 FileObject 當鍵、沒有 PID、沒有時效，
        //    指標一被回收就會回傳別的程式的路徑。
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

        // 2) FileKey 對照表（檔案身分，同一檔案的所有手柄共用）。
        //    補上 session 開始前就已經開好的手柄。
        if (path == null && fileKey != 0)
        {
            path = LookupFileKey(fileKey);
            if (path != null) source = "filekey";
        }

        // 3) 解不到路徑 = 「落地層」事件（writeback / paging I/O）或核心內部寫入
        //    （登錄檔 hive、NTFS 日誌與 MFT、pagefile）。
        //    實測（2026-11-15，三次對照實驗）：一筆緩衝式寫入會產生兩個事件 ——
        //    邏輯層解得到路徑、落地層解不到，而物理碟只算一次。若把落地層也加進
        //    總量，數字就會變成物理量的 2 倍。所以它只能留下計數供診斷。
        if (path == null)
        {
            string anon = ProcNameOf(pid, procName);
            lock (_lock)
            {
                _unresolvedOps++;
                if (ioSize > 0)
                {
                    _unresolvedBytes += ioSize;
                    long cur;
                    if (_unresolvedByProc.TryGetValue(anon, out cur) || _unresolvedByProc.Count < 300)
                        _unresolvedByProc[anon] = cur + ioSize;
                }
                else _zeroSizeWrites++;
            }
            return;
        }

        // 這次解到的路徑，順手補進 FileKey 表，讓同一個檔案的其他手柄也能解析。
        if (fileKey != 0 && source == "map") LearnFileKey(fileKey, path);

        string volume = VolumeOfPath(path);
        string minute = DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        string proc = ProcNameOf(pid, procName);

        lock (_lock)
        {
            if (source == "filekey") _resolvedKey++;
            else _resolvedMap++;

            PidVolAgg a = GetAgg(minute, pid, proc, volume);
            a.Ops++;
            if (ioSize > 0)
            {
                a.Bytes += ioSize;
                _bytesTotal += ioSize;
            }
            else
            {
                a.UnknownOps++;
                _zeroSizeWrites++;
            }

            string fkey = path;
            FileAgg f;
            if (a.Files.TryGetValue(fkey, out f))
            {
                f.Bytes += Math.Max(0, ioSize);
                f.Ops++;
            }
            else if (a.Files.Count < MaxPathsPerPidVolume)
            {
                f = new FileAgg();
                f.Bytes = Math.Max(0, ioSize);
                f.Ops = 1;
                a.Files[fkey] = f;
            }
            else
            {
                a.Other.Bytes += Math.Max(0, ioSize);
                a.Other.Ops++;
            }
        }
    }

    // ---------- CSV ----------
    private static string JsonStr(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        StringBuilder sb = new StringBuilder(s.Length + 8);
        foreach (char c in s)
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c == '\r' || c == '\n' || c == '\t') sb.Append(' ');
            else sb.Append(c);
        }
        return sb.ToString();
    }

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

            // 注意：a.Bytes 已包含 a.Other.Bytes，所以這裡不能再加一次。
            // 舊版寫成「a.Bytes - emittedBytes + a.Other.Bytes」，把 Other 算了兩次，
            // 造成「一次寫幾千個檔」的行程（如 Robocopy）流量翻倍。
            long restBytes = a.Bytes - emittedBytes;
            long restOps = a.Ops - emittedOps;
            if (restBytes < 0) restBytes = 0;
            if (restOps < 0) restOps = 0;
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
            long evW, evC, bytes, zero, unresolved, unsolvedOps, rm, rk, ne, rundo, jr;
            List<KeyValuePair<string, long>> topUnres = new List<KeyValuePair<string, long>>();
            lock (_lock)
            {
                evW = _evWrite; evC = _evCreate; bytes = _bytesTotal; zero = _zeroSizeWrites;
                unresolved = _unresolvedBytes; unsolvedOps = _unresolvedOps;
                rm = _resolvedMap; rk = _resolvedKey;
                ne = Interlocked.Read(ref _nameEvents); rundo = Interlocked.Read(ref _rundownEntries);
                jr = Interlocked.Read(ref _junctionResolved);
                topUnres.AddRange(_unresolvedByProc);
            }
            topUnres.Sort(delegate(KeyValuePair<string, long> x, KeyValuePair<string, long> y)
            {
                return y.Value.CompareTo(x.Value);
            });
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("{");
            sb.AppendLine("  \"state\": \"" + state + "\",");
            sb.AppendLine("  \"updated\": \"" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "\",");
            sb.AppendLine("  \"session\": \"" + SessionName + "\",");
            sb.AppendLine("  \"pid\": " + Process.GetCurrentProcess().Id + ",");
            sb.AppendLine("  \"events_write\": " + evW + ",");
            sb.AppendLine("  \"events_create\": " + evC + ",");
            sb.AppendLine("  \"bytes_seen\": " + bytes + ",");
            sb.AppendLine("  \"bytes_unresolved\": " + unresolved + ",");
            sb.AppendLine("  \"ops_unresolved\": " + unsolvedOps + ",");
            sb.AppendLine("  \"resolved_map\": " + rm + ",");
            sb.AppendLine("  \"resolved_filekey\": " + rk + ",");
            sb.AppendLine("  \"name_events\": " + ne + ",");
            sb.AppendLine("  \"rundown_entries\": " + rundo + ",");
            sb.AppendLine("  \"junction_remapped\": " + jr + ",");
            StringBuilder ut = new StringBuilder();
            int un = 0;
            for (int i = 0; i < topUnres.Count && i < 5; i++)
            {
                if (un++ > 0) ut.Append(", ");
                ut.Append("{\"process\": \"").Append(JsonStr(topUnres[i].Key))
                  .Append("\", \"bytes\": ").Append(topUnres[i].Value).Append("}");
            }
            sb.AppendLine("  \"unresolved_top\": [" + ut.ToString() + "],");
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

            // FileKey -> 路徑。FileIOName 是核心在「某個檔案第一次被用到」時宣告的名字；
            // FileIOFileRundown 是 session 開始時的傾印，補上已經開著的手柄。
            // 兩者都帶 FileKey（檔案身分），而 FileIOWrite 也帶 FileKey，
            // 所以即使 FileIOCreate 發生在 session 開始之前，照樣能解出檔案路徑。
            kernel.FileIOName += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIONameTraceData d)
            {
                Interlocked.Increment(ref _nameEvents);
                try { LearnFileKey(d.FileKey, NormalizePath(d.FileName)); }
                catch { }
            };

            kernel.FileIOFileRundown += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIONameTraceData d)
            {
                Interlocked.Increment(ref _rundownEntries);
                try { LearnFileKey(d.FileKey, NormalizePath(d.FileName)); }
                catch { }
            };

            kernel.FileIOWrite += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOReadWriteTraceData d)
            {
                Interlocked.Increment(ref _evWrite);
                try { Record(d.ProcessID, d.ProcessName, d.FileObject, d.FileKey, d.IoSize); }
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
        kernel.FileIOCreate += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOCreateTraceData d)
        {
            Interlocked.Increment(ref _evCreate);
            string p = NormalizePath(d.FileName);
            if (p == null) return;
            lock (_fileMapLock)
            {
                if (_fileMap.Count >= MaxFileMapEntries) EvictExpiredEntries();
                _fileMap[MapKey(d.ProcessID, d.FileObject)] = new object[] { p, DateTime.UtcNow.Ticks };
            }
        };
        kernel.FileIOName += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIONameTraceData d)
        {
            Interlocked.Increment(ref _nameEvents);
            try { LearnFileKey(d.FileKey, NormalizePath(d.FileName)); }
            catch { }
        };
        kernel.FileIOFileRundown += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIONameTraceData d)
        {
            Interlocked.Increment(ref _rundownEntries);
            try { LearnFileKey(d.FileKey, NormalizePath(d.FileName)); }
            catch { }
        };
        kernel.FileIOWrite += delegate(Microsoft.Diagnostics.Tracing.Parsers.Kernel.FileIOReadWriteTraceData d)
        {
            Interlocked.Increment(ref _evWrite);
            try { Record(d.ProcessID, d.ProcessName, d.FileObject, d.FileKey, d.IoSize); }
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

        long total, unres, nname, nrundown;
        lock (_lock) { total = _bytesTotal; unres = _unresolvedBytes; }
        nname = Interlocked.Read(ref _nameEvents);
        nrundown = Interlocked.Read(ref _rundownEntries);
        Console.WriteLine("events    : write=" + _evWrite + " create=" + _evCreate + " name=" + nname + " rundown=" + nrundown);
        Console.WriteLine("bytes seen: " + total.ToString("N0", CultureInfo.InvariantCulture));
        Console.WriteLine("unresolved: " + unres.ToString("N0", CultureInfo.InvariantCulture));

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
