# clean-attrib.ps1 —— 把歸因 CSV 裡「不可能成立」的列標出來並排除，再與物理寫入對帳。
#
# 為什麼需要這一步：
#   collector 用 (pid, FileObject) 對照表解檔名，而 FileObject 指標會被核心回收再配給
#   別的檔案。實測（2026-11-15）代價很大：Robocopy 在 F: 的 22.9 GB 被記成 C: 底下
#   四個根本不存在的路徑（C:\Users\ufft4\.claude\ide 等），讓 C: 的歸因總量
#   變成物理量的 1.9 倍。
#   根因（FileKey 交叉驗證）之後再修；這支腳本先用「路徑可信度」把可疑列扣掉，
#   並把扣掉多少、扣了哪些明確印出來，不偷偷丟資料。
#
# 分類規則：
#   ok       路徑存在且是檔案                     -> 可信
#   ok       路徑不存在，但在暫存／快取路徑下      -> 可信（本來就會被刪）
#   probe    本工具自己的診斷探針（cwatch-probe*）  -> 排除，單獨列出（不是「誰在寫」
#            的答案，是我們自己造成的）
#   dir      路徑是目錄（目錄不是寫入目標）        -> 可疑
#   missing  路徑不存在且不是暫存路徑              -> 可疑
#
# 用法：
#   pwsh -File clean-attrib.ps1                     # 今天
#   pwsh -File clean-attrib.ps1 2026-11-14          # 指定日期
#   pwsh -File clean-attrib.ps1 -Since 04:31        # 只看今天 04:31 之後（避開舊版 collector）

param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$Root = 'D:\dev\disk-monitor',
    [int]$Top = 15,
    # 只看 HH:mm 之後的資料（用來避開舊版 collector 寫的列）
    [string]$Since = '',
    # 本工具自己的診斷探針檔名關鍵字：這些是自己寫的，不該算進「誰在寫 C:」
    [string[]]$ProbePattern = @('cwatch-probe', 'cwatch-mmf', 'cwatch-selftest')
)

$ErrorActionPreference = 'Stop'
$attribFile = Join-Path $Root "data\attrib\$Date.csv"
$physFile = Join-Path $Root "data\phys\$Date.csv"

if (-not (Test-Path -LiteralPath $attribFile)) { "missing: $attribFile"; exit 2 }

# ---------- 讀歸因 CSV ----------
# 檔名可能含逗號，所以從右邊解：最後兩個欄位是 bytes, ops。
$rows = New-Object System.Collections.ArrayList
foreach ($ln in [IO.File]::ReadAllLines($attribFile, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    if ($ln.StartsWith('minute,')) { continue }
    $f = $ln.Split(',')
    if ($f.Length -lt 7) { continue }
    if ($Since -ne '' -and [string]::CompareOrdinal($f[0], $Date + ' ' + $Since) -lt 0) { continue }
    $n = $f.Length
    $path = ($f[4..($n - 3)] -join ',')
    [void]$rows.Add([pscustomobject]@{
        minute = $f[0]
        pid    = $f[1]
        proc   = $f[2]
        vol    = $f[3]
        path   = $path
        bytes  = [int64]$f[$n - 2]
        ops    = [int64]$f[$n - 1]
    })
}

# ---------- 路徑分類（每個路徑只查一次）----------
$ephemeral = '\\Temp\\|\\Temporary Internet Files\\|\\INetCache\\|\\Cache\\|\\Sessions\\|\\Crashpad\\|\\Code Cache\\|\\GPUCache\\|\\Logs?\\|\.tmp$|\.log$|\.etl$|\.dmp$'
$verdict = @{}
function Get-Verdict([string]$p) {
    if ($p -eq '(其他)') { return 'ok' }
    if ($verdict.ContainsKey($p)) { return $verdict[$p] }
    foreach ($pp in $ProbePattern) {
        if ($p.IndexOf($pp, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $verdict[$p] = 'probe'; return 'probe' }
    }
    $v = 'missing'
    try {
        $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ($i.PSIsContainer) { $v = 'dir' } else { $v = 'ok' }
    } catch {
        if ($p -match $ephemeral) { $v = 'ok' }
    }
    $verdict[$p] = $v
    return $v
}

# ---------- 彙總 ----------
$byVolProc = @{}    # "vol|proc" -> @{ ok; bad; probe; opsOk; opsBad }
$suspect = @{}      # "vol|proc|path|reason" -> bytes
$probes = @{}       # "vol|proc|path" -> bytes
$clean = @{}        # "vol|proc" -> bytes
$checks = 0
foreach ($r in $rows) {
    $v = Get-Verdict $r.path
    $checks++
    $key = $r.vol + '|' + $r.proc
    if (-not $byVolProc.ContainsKey($key)) {
        $byVolProc[$key] = @{ ok = [int64]0; bad = [int64]0; probe = [int64]0; opsOk = [int64]0; opsBad = [int64]0 }
    }
    if ($v -eq 'ok') {
        $byVolProc[$key].ok += $r.bytes
        $byVolProc[$key].opsOk += $r.ops
        if (-not $clean.ContainsKey($key)) { $clean[$key] = [int64]0 }
        $clean[$key] += $r.bytes
    } elseif ($v -eq 'probe') {
        $byVolProc[$key].probe += $r.bytes
        $pk = $r.vol + '|' + $r.proc + '|' + $r.path
        if (-not $probes.ContainsKey($pk)) { $probes[$pk] = [int64]0 }
        $probes[$pk] += $r.bytes
    } else {
        $byVolProc[$key].bad += $r.bytes
        $byVolProc[$key].opsBad += $r.ops
        $sk = $r.vol + '|' + $r.proc + '|' + $r.path + '|' + $v
        if (-not $suspect.ContainsKey($sk)) { $suspect[$sk] = [int64]0 }
        $suspect[$sk] += $r.bytes
    }
}

# ---------- 物理寫入（phys CSV 是累計值 -> 逐「實體碟」取差值，不拆多磁碟區）----------
# 注意：phys 是累計值，-Since 不能只是「濾掉前面的列」，否則第一筆會缺少基準點。
#      所以先記住截止點前最後一筆當 baseline，之後才算差值。
$cutoff = ''
if ($Since -ne '') { $cutoff = $Date + ' ' + $Since }
$devices = @{}
$devicesMeta = @{}
$physFrom = ''; $physTo = ''
if (Test-Path -LiteralPath $physFile) {
    $prev = @{}
    foreach ($ln in [IO.File]::ReadAllLines($physFile, [Text.Encoding]::UTF8)) {
        $f = $ln.Split(',')
        if ($f.Length -lt 8 -or $f[0] -eq 'ts') { continue }
        $ts = $f[0]
        $devKey = $f[1] + '|' + $f[2]
        $cur = [int64]$f[6]
        if (-not $devices.ContainsKey($devKey)) { $devices[$devKey] = [int64]0 }
        $devicesMeta[$devKey] = $devKey
        if ($cutoff -eq '' -or [string]::CompareOrdinal($ts, $cutoff) -ge 0) {
            if ($prev.ContainsKey($devKey)) {
                $d = $cur - [int64]$prev[$devKey]
                if ($d -gt 0) { $devices[$devKey] += $d }
            }
            if ($physFrom -eq '' -or [string]::CompareOrdinal($ts, $physFrom) -lt 0) { $physFrom = $ts }
            if ($physTo -eq '' -or [string]::CompareOrdinal($ts, $physTo) -gt 0) { $physTo = $ts }
        }
        $prev[$devKey] = $cur
    }
}

# ETW 依磁碟區彙總
$volAgg = @{}
foreach ($k in $byVolProc.Keys) {
    $v = $k.Split('|')[0]
    if (-not $volAgg.ContainsKey($v)) { $volAgg[$v] = @{ ok = [int64]0; bad = [int64]0; probe = [int64]0 } }
    $volAgg[$v].ok += $byVolProc[$k].ok
    $volAgg[$v].bad += $byVolProc[$k].bad
    $volAgg[$v].probe += $byVolProc[$k].probe
}

# ---------- 輸出 ----------
"日期      : $Date$(if ($Since -ne '') { '  (只看 ' + $Since + ' 之後)' })"
"歸因列數  : {0:N0}  不同路徑 {1:N0}" -f $rows.Count, $verdict.Count
if ($physFrom -ne '') { "物理區間  : $physFrom  ~  $physTo" }
""
"=== 各實體碟：物理寫入 vs 可信歸因（分母已扣掉本工具的診斷探針）==="
'{0,-14} {1,10} {2,9} {3,9} {4,9} {5,9}' -f 'dev / 磁碟區', '物理寫入', '診斷探針', '可信歸因', '可疑列', '可信/(物理-探針)'
foreach ($devKey in ($devices.Keys | Sort-Object)) {
    $devVols = $devKey.Split('|')[1]
    $volList = @($devVols -split '\s+' | Where-Object { $_ -match '^[A-Z]:$' })
    $ok = [int64]0; $bad = [int64]0; $pr = [int64]0
    foreach ($v in $volList) {
        if ($volAgg.ContainsKey($v)) { $ok += $volAgg[$v].ok; $bad += $volAgg[$v].bad; $pr += $volAgg[$v].probe }
    }
    $p = $devices[$devKey]
    $net = $p - $pr
    if ($net -lt 1) { $net = 1 }
    $ratio = $ok / [double]$net
    $flag = ''
    if ($ratio -gt 1.05) { $flag = '  ← 不可能的數字：這個時間窗含舊版 collector 的重複計數，請用 -Since 限定' }
    '{0,-14} {1,7:N2} GB {2,6:N1} MB {3,7:N2} GB {4,7:N2} GB {5,10:N0}%{6}' -f ($devKey -replace '\|', ' '), ($p / 1GB), ($pr / 1MB), ($ok / 1GB), ($bad / 1GB), ($ratio * 100), $flag
}
if ($devices.Keys.Count -eq 0) { "（沒有 phys CSV，略過物理對帳）" }
if ($volAgg.ContainsKey('(device)')) {
    "（另有舊版格式 volume=(device) {0:N2} GB —— 不屬於任何磁碟區，新版已不再產生）" -f ($volAgg['(device)'].bad / 1GB)
}
if ($probes.Count -gt 0) {
    ""
    "=== 已排除的診斷探針（本工具自己寫的測試檔）==="
    $probes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        $q = $_.Key.Split('|')
        '  {0,8:N1} MB  {1,-10} {2}' -f ($_.Value / 1MB), $q[1], $q[2]
    }
}

# ---------- C: 名單 ----------
""
"=== C: 可信名單（依程式，前 $Top）==="
$cproc = @{}
foreach ($k in $clean.Keys) {
    if (-not $k.StartsWith('C:|')) { continue }
    $cproc[$k.Split('|')[1]] = $clean[$k]
}
$cTotal = 0
foreach ($v in $cproc.Values) { $cTotal += $v }
$cBad = 0
foreach ($k in $byVolProc.Keys) { if ($k.StartsWith('C:|')) { $cBad += $byVolProc[$k].bad } }
if ($cTotal -gt 0) {
    $cproc.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
        '  {0,-18} {1,9:N1} MB  {2,5:N1}%（僅 C: 的寫入）' -f $_.Key, ($_.Value / 1MB), ($_.Value / [double]$cTotal * 100)
    }
}
"  C: 可信合計 {0:N2} GB / 可疑 {1:N2} GB" -f ($cTotal / 1GB), ($cBad / 1GB)
""
"=== C: 可疑列（前 $Top，這些是「不可能成立」的路徑）==="
$cs = @{}
foreach ($k in $suspect.Keys) {
    if (-not $k.StartsWith('C:|')) { continue }
    $cs[$k] = $suspect[$k]
}
$cs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    $p = $_.Key.Split('|')
    $pp = $p[2]
    if ($pp.Length -gt 62) { $pp = $pp.Substring(0, 59) + '...' }
    '  {0,9:N1} MB  {1,-9} {2,-14} {3}' -f ($_.Value / 1MB), $p[3], $p[1], $pp
}

# ---------- C: 熱分鐘（用物理量，不依賴歸因）----------
# 這一段回答「C: 是被常態寫入撐大的，還是被幾次尖峰撐大的」——實測是後者，
# 所以優先處理少數幾個來源，比逐一歸因常態寫入有效得多。
$cDev = $null
foreach ($k in $devicesMeta.Keys) {
    if ((@($k.Split('|')[1] -split '\s+') -contains 'C:')) { $cDev = $k; break }
}
if ($cDev -ne $null -and (Test-Path -LiteralPath $physFile)) {
    $perMin = New-Object System.Collections.ArrayList
    $prevT = $null; $prevV = $null
    $cutDT = $null
    if ($cutoff -ne '') { $cutDT = [datetime]::ParseExact($cutoff, 'yyyy-MM-dd HH:mm', $null) }
    foreach ($ln in [IO.File]::ReadAllLines($physFile, [Text.Encoding]::UTF8)) {
        if ($ln.StartsWith('ts,')) { continue }
        $f = $ln.Split(',')
        if (($f[1] + '|' + $f[2]) -ne $cDev) { continue }
        $t = [datetime]::ParseExact($f[0], 'yyyy-MM-dd HH:mm:ss', $null)
        $v = [int64]$f[6]
        if ($null -ne $prevT -and ($null -eq $cutDT -or $t -gt $cutDT)) {
            [void]$perMin.Add([pscustomobject]@{ end = $t; bytes = ($v - $prevV) })
        }
        $prevT = $t; $prevV = $v
    }
    # 依分鐘索引 C: 的歸因列（用來替熱分鐘指名）
    $cIdx = @{}
    foreach ($r in $rows) {
        if ($r.vol -ne 'C:') { continue }
        $mm = $r.minute
        if (-not $cIdx.ContainsKey($mm)) { $cIdx[$mm] = New-Object System.Collections.ArrayList }
        [void]$cIdx[$mm].Add($r)
    }
    $tot = [int64]0
    foreach ($x in $perMin) { $tot += $x.bytes }
    if ($perMin.Count -gt 0 -and $tot -gt 0) {
        $sorted = $perMin | Sort-Object bytes
        $med = $sorted[[int]($sorted.Count / 2)].bytes
        $p90 = $sorted[[Math]::Min($sorted.Count - 1, [int]($sorted.Count * 0.9))].bytes
        $hot = @($perMin | Where-Object { $_.bytes -ge 200MB })
        $hotSum = [int64]0
        foreach ($h in $hot) { $hotSum += $h.bytes }
        ""
        "=== C: 物理寫入的形狀（$($perMin.Count) 個分鐘樣本）==="
        "  合計        : {0:N2} GB" -f ($tot / 1GB)
        "  中位數/分   : {0:N1} MB   ← 常態基線" -f ($med / 1MB)
        "  P90/分      : {0:N1} MB" -f ($p90 / 1MB)
        "  平均/分     : {0:N1} MB" -f (($tot / $perMin.Count) / 1MB)
        "  熱分鐘(>=200MB): {0} 個，合計 {1:N2} GB（佔 {2:N0}%）" -f $hot.Count, ($hotSum / 1GB), ($hotSum / [double]$tot * 100)
        ""
        "=== C: 熱分鐘明細（前 $Top），以及當時最大的歸因列 ==="
        '{0,-9} {1,10}  {2}' -f '分鐘', '物理寫入', '最大歸因（該分鐘的 C: 列）'
        foreach ($h in ($hot | Sort-Object bytes -Descending | Select-Object -First $Top)) {
            $best = $null
            foreach ($off in @(-30, -90, -150)) {
                $mm = $h.end.AddSeconds($off).ToString('yyyy-MM-dd HH:mm')
                if ($cIdx.ContainsKey($mm)) {
                    $cand = $cIdx[$mm] | Sort-Object bytes -Descending | Select-Object -First 1
                    if ($null -eq $best -or $cand.bytes -gt $best.bytes) { $best = $cand }
                }
            }
            $who = '（無歸因：核心內部寫入）'
            if ($null -ne $best -and $best.bytes -gt 0) {
                $nm = $best.path
                if ($nm.Length -gt 60) { $nm = '...' + $nm.Substring($nm.Length - 57) }
                $who = '{0} {1:N0} MB  {2}' -f $best.proc, ($best.bytes / 1MB), $nm
            }
            '  {0,-9} {1,7:N0} MB  {2}' -f $h.end.AddSeconds(-60).ToString('HH:mm'), ($h.bytes / 1MB), $who
        }
    }
}
