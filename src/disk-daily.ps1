<#
    disk-daily.ps1 —— 每日寫入對照（C: / D:）。

    目的：追蹤「把 C: 的寫入密集目錄搬到 D:」前後的每日寫入量變化。

    資料來源有兩條，互補：
      1. CrystalDiskInfo 的 HostWrites.csv —— SMART 終身寫入的歷史，可回溯數年，
         解析度 1 GB。用來建立「遷移前」的基線。
      2. 本監控自己的 data\phys\*.csv —— PhysicalDisk 累計值差值，位元組級精確。
         從 2026-11-10 開始才有，用來做「遷移後」的精確量測。

    重要：SMART 的取樣並非每天都有（CrystalDiskInfo 沒跑就沒記）。所以日增量一律換算成
    「GB/日」再平均，並標示有效天數，避免把「缺資料」誤讀成「沒寫入」。

    輸出：
      reports\daily.md        對照表（每次重建）
      logs\daily-summary.log  每日一行（永久累積）
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor',
    [string]$CdiSmartDir = 'C:\soft\disk\CrystalDiskInfo8_1_0\Smart',
    [int]$Days = 30,
    [int]$BaselineDays = 90,
    [switch]$IncludeToday
)

$ErrorActionPreference = 'Stop'

$physDir   = Join-Path $Root 'data\phys'
$smartDir  = Join-Path $Root 'data\smart'
$stateDir  = Join-Path $Root 'data\state'
$reportDir = Join-Path $Root 'reports'
$logDir    = Join-Path $Root 'logs'
foreach ($d in @($reportDir, $logDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$inv       = [System.Globalization.CultureInfo]::InvariantCulture

function Format-Bytes([double]$b) {
    if ([math]::Abs($b) -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ([math]::Abs($b) -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ([math]::Abs($b) -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

# ---------- PhysicalDisk：某一天的落盤量 ----------
function Read-PhysRange([datetime]$from, [datetime]$to) {
    $out = New-Object System.Collections.Generic.List[object]
    $idx = 0   # 檔案讀入順序（時間相同時當排序的次要鍵，避免排序不穩定）
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $physDir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $p = $lines[$i].Split(',')
            if ($p.Length -lt 11) { continue }
            $idx++
            $out.Add([pscustomobject]@{
                idx     = $idx
                ts      = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $inv)
                dev     = $p[1]
                volumes = $p[2]
                perf    = [int64]$p[3]
                freq    = [int64]$p[4]
                wb      = [int64]$p[6]
            })
        }
    }
    return $out
}

function Get-PhysDaily([datetime]$day) {
    # 以「磁碟區標籤字串」為鍵，逐「相鄰兩筆」累加。
    #
    # 為什麼不用 dev（裝置編號）：重開機後 PhysicalDisk 的裝置編號會對調
    # （實際案例 2026-11-15 07:41 之後 dev2 由 I:F: 變成 D:、dev3 由 D: 變成 I:F:），
    # 用 dev 分組會把兩個不同磁碟一整天的量併成一組，再貼上最後一筆的標籤 → 數字暴增。
    #
    # 斷開區段的條件（任一成立就不累加該區間）：
    #   1. prev.ts 不在目標日內
    #   2. 裝置不同
    #   3. prev.volumes 與 cur.volumes 不完全相同（標籤變了＝裝置重排）
    #   4. cur.perf 沒有大於 prev.perf（計數器重置／重開機）
    #   5. delta <= 0
    # 回傳值：key = volumes 原文（例如 'C:' / 'D:' / 'I: F:'），value.Bytes = 當日該區段的寫入總量。
    # 多重標籤的裝置（如 'I: F:'）分不出是哪個分割區，呼叫端只認完全相符的 'C:' / 'D:'。
    $rows = Read-PhysRange $day.AddHours(-3) $day.AddDays(1)
    $res = @{}
    if ($rows.Count -eq 0) { return $res }
    $dayEnd = $day.AddDays(1)
    foreach ($dev in @($rows | ForEach-Object { $_.dev } | Sort-Object -Unique)) {
        $list = @($rows | Where-Object { $_.dev -eq $dev } | Sort-Object ts, idx)
        $prev = $null
        foreach ($r in $list) {
            if ($null -ne $prev -and
                $prev.ts -ge $day -and $prev.ts -lt $dayEnd -and
                $prev.volumes -ceq $r.volumes -and
                $r.perf -gt $prev.perf) {
                $delta = $r.wb - $prev.wb
                if ($delta -gt 0) {
                    if (-not $res.ContainsKey($prev.volumes)) {
                        $res[$prev.volumes] = [pscustomobject]@{ Bytes = [double]0 }
                    }
                    $res[$prev.volumes].Bytes += $delta
                }
            }
            $prev = $r
        }
    }
    return $res
}

# ---------- SMART 對帳：(落盤 - SMART) / SMART ----------
# SMART 以 GB 為單位（CDI 顯示值）；落盤是位元組。SMART < 5 GB 時百分比沒有意義（取整誤差太大），不判。
function Get-Recon($cdiGB, $physBytes) {
    if ($cdiGB -eq '' -or $physBytes -eq '') { return $null }
    if ([double]$cdiGB -lt 5) { return $null }
    $smartBytes = [double]$cdiGB * 1GB
    $pct = (([double]$physBytes - $smartBytes) / $smartBytes) * 100
    $bad = ([math]::Abs($pct) -gt 20)
    $mark = '✓'
    if ($bad) { $mark = ('⚠ {0:+#;-#}%' -f [math]::Round($pct)) }
    return [pscustomobject]@{ Pct = $pct; Bad = $bad; Mark = $mark }
}

# ---------- SMART：每日最後一筆的值 → 每日 GB/日 ----------
function Get-SmartSeries([string]$csvPath) {
    $byDay = @{}
    if (-not (Test-Path -LiteralPath $csvPath)) { return $byDay }
    foreach ($ln in [IO.File]::ReadAllLines($csvPath, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $p = $ln.Split(',')
        if ($p.Length -lt 2) { continue }
        # 少數行前面夾著 NUL（CDI 寫檔中斷），先清掉否則解析失敗
        $stamp = $p[0] -replace '^[\x00-\x20]+', ''
        if ($stamp -notmatch '^\d{4}/\d{2}/\d{2} ') { continue }
        try { $ts = [datetime]::ParseExact($stamp, 'yyyy/MM/dd HH:mm:ss', $inv) } catch { continue }
        $v = 0.0
        if (-not [double]::TryParse($p[1].Trim(), [ref]$v)) { continue }
        $k = $ts.Date
        if (-not $byDay.ContainsKey($k) -or $byDay[$k] -lt $v) { $byDay[$k] = $v }
    }
    return $byDay
}

# 由每日值算出「每日 GB」；遇到 CDI 斷檔就用跨日平均補成 GB/日
function ConvertTo-DailyRate($byDay) {
    $rates = @{}
    $days = @($byDay.Keys | Sort-Object)
    for ($i = 1; $i -lt $days.Count; $i++) {
        $cur = $days[$i]
        $prevDay = $days[$i - 1]
        $gap = ($cur - $prevDay).TotalDays
        if ($gap -le 0) { continue }
        $delta = [double]$byDay[$cur] - [double]$byDay[$prevDay]
        if ($delta -lt 0) { $delta = 0 }
        $rates[$cur] = $delta / $gap
    }
    return $rates
}

function Get-RangeAvg($rates, [datetime]$from, [datetime]$to) {
    $vals = @()
    foreach ($k in $rates.Keys) {
        if ($k -ge $from -and $k -le $to) { $vals += [double]$rates[$k] }
    }
    if ($vals.Count -eq 0) { return $null }
    $sum = 0.0
    foreach ($v in $vals) { $sum += $v }
    return [pscustomobject]@{ Avg = ($sum / $vals.Count); Count = $vals.Count }
}

# 由本監控自己的 smart 快照取得「磁碟機 -> CDI 資料夾」
function Get-SmartKeyMap([datetime]$from, [datetime]$to) {
    $map = @{}
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $smartDir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $p = $lines[$i].Split(',')
            if ($p.Length -lt 11) { continue }
            foreach ($letter in ($p[1] -split '\|')) { if ($letter) { $map[$letter] = $p[2] } }
        }
    }
    return $map
}

$now       = Get-Date
$today     = $now.Date
$yesterday = $today.AddDays(-1)

# ---------- 遷移日 ----------
$cutoverPath = Join-Path $stateDir 'cutover.json'
$cutover = $null
$cutoverNote = ''
if (Test-Path -LiteralPath $cutoverPath) {
    try {
        $c = Get-Content -LiteralPath $cutoverPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cutover = [datetime]::ParseExact($c.date, 'yyyy-MM-dd', $inv)
        $cutoverNote = [string]$c.note
    } catch { $cutover = $null }
}

# ---------- SMART 序列 ----------
$keyMap = Get-SmartKeyMap $today.AddDays(-3) $today
$ratesC = @{}
$ratesD = @{}
if ($keyMap.ContainsKey('C:')) {
    $ratesC = ConvertTo-DailyRate (Get-SmartSeries (Join-Path $CdiSmartDir (Join-Path $keyMap['C:'] 'HostWrites.csv')))
}
if ($keyMap.ContainsKey('D:')) {
    $ratesD = ConvertTo-DailyRate (Get-SmartSeries (Join-Path $CdiSmartDir (Join-Path $keyMap['D:'] 'HostWrites.csv')))
}

# ---------- 統計窗口 ----------
$baseFrom = $today.AddDays(-$BaselineDays)
$beforeFrom = $baseFrom
$beforeTo = $today
$afterFrom = $today
if ($null -ne $cutover) {
    $beforeFrom = $cutover.AddDays(-$BaselineDays)
    $beforeTo = $cutover.AddDays(-1)
    $afterFrom = $cutover
}
$before30From = $beforeTo.AddDays(-29)

$stat = [pscustomobject]@{
    Before90C = (Get-RangeAvg $ratesC $beforeFrom $beforeTo)
    Before90D = (Get-RangeAvg $ratesD $beforeFrom $beforeTo)
    Before30C = (Get-RangeAvg $ratesC $before30From $beforeTo)
    Before30D = (Get-RangeAvg $ratesD $before30From $beforeTo)
    Before7C  = (Get-RangeAvg $ratesC $beforeTo.AddDays(-6) $beforeTo)
    Before7D  = (Get-RangeAvg $ratesD $beforeTo.AddDays(-6) $beforeTo)
    AfterC    = (Get-RangeAvg $ratesC $afterFrom $yesterday)
    AfterD    = (Get-RangeAvg $ratesD $afterFrom $yesterday)
    AfterInclC = (Get-RangeAvg $ratesC $afterFrom $yesterday)
    AfterInclD = (Get-RangeAvg $ratesD $afterFrom $yesterday)
}

# ---------- 每日明細 ----------
$firstRowDay = $today.AddDays(-$Days)
if ($null -ne $cutover -and $cutover -lt $firstRowDay) { $firstRowDay = $cutover }
$lastRowDay = $yesterday
if ($IncludeToday) { $lastRowDay = $today }

$rows = New-Object System.Collections.Generic.List[object]
$warns = New-Object System.Collections.Generic.List[string]
for ($d = $firstRowDay; $d -le $lastRowDay; $d = $d.AddDays(1)) {
    $cRate = ''
    $dRate = ''
    if ($ratesC.ContainsKey($d)) { $cRate = $ratesC[$d] }
    if ($ratesD.ContainsKey($d)) { $dRate = $ratesD[$d] }

    $physC = ''
    $physD = ''
    $pd = Get-PhysDaily $d
    # 只認「標籤恰好等於 C: / D:」的區段；'I: F:' 這類多重標籤分不出分割區，不計入。
    if ($pd.ContainsKey('C:')) { $physC = $pd['C:'].Bytes }
    if ($pd.ContainsKey('D:')) { $physD = $pd['D:'].Bytes }

    $rc = Get-Recon $cRate $physC
    $rd = Get-Recon $dRate $physD
    $reconParts = @()
    if ($null -ne $rc) { $reconParts += ('C ' + $rc.Mark) }
    if ($null -ne $rd) { $reconParts += ('D ' + $rd.Mark) }
    $recon = '—'
    if ($reconParts.Count -gt 0) { $recon = ($reconParts -join ' / ') }

    $stamp = $d.ToString('yyyy-MM-dd')
    if ($null -ne $rc -and $rc.Bad) {
        $warns.Add(('WARN {0} C: 落盤 {1} vs SMART {2} GB（{3}）' -f $stamp, (Format-Bytes $physC), ('{0:N0}' -f $cRate), ('{0:+#;-#}%' -f [math]::Round($rc.Pct))))
    }
    if ($null -ne $rd -and $rd.Bad) {
        $warns.Add(('WARN {0} D: 落盤 {1} vs SMART {2} GB（{3}）' -f $stamp, (Format-Bytes $physD), ('{0:N0}' -f $dRate), ('{0:+#;-#}%' -f [math]::Round($rd.Pct))))
    }

    $rows.Add([pscustomobject]@{ Date = $d; CdiC = $cRate; CdiD = $dRate; PhysC = $physC; PhysD = $physD; Recon = $recon })
}

# ---------- 輸出 ----------
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine('# 每日寫入對照（C: / D:）')
$null = $sb.AppendLine('')
$null = $sb.AppendLine(('產生時間：{0}' -f $now.ToString('yyyy-MM-dd HH:mm:ss')))
$null = $sb.AppendLine('')
if ($null -ne $cutover) {
    $null = $sb.AppendLine(('**遷移日：{0}** — {1}' -f $cutover.ToString('yyyy-MM-dd'), $cutoverNote))
    $null = $sb.AppendLine('')
}
$null = $sb.AppendLine('`SMART` = CrystalDiskInfo 的 HostWrites 日增量（1 GB 解析度，可回溯數年）；')
$null = $sb.AppendLine('`落盤` = 本監控的 PhysicalDisk 實測（位元組級，2026-11-10 起才有）。')
$null = $sb.AppendLine('')

$null = $sb.AppendLine('## 遷移前後平均（SMART，GB/日）')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('| 期間 | 有效天數 | C: | D: |')
$null = $sb.AppendLine('|---|---|---|---|')
$fmt = { param($s) if ($null -eq $s) { '—' } else { '{0:N1}' -f $s.Avg } }
$cnt = { param($s) if ($null -eq $s) { 0 } else { $s.Count } }
$null = $sb.AppendLine(('| 遷移前 {0} 日 | {1} | {2} | {3} |' -f $BaselineDays, (& $cnt $stat.Before90C), (& $fmt $stat.Before90C), (& $fmt $stat.Before90D)))
$null = $sb.AppendLine(('| 遷移前 30 日 | {0} | {1} | {2} |' -f (& $cnt $stat.Before30C), (& $fmt $stat.Before30C), (& $fmt $stat.Before30D)))
$null = $sb.AppendLine(('| 遷移前 7 日 | {0} | {1} | {2} |' -f (& $cnt $stat.Before7C), (& $fmt $stat.Before7C), (& $fmt $stat.Before7D)))
$null = $sb.AppendLine(('| 遷移後（不含遷移當日） | {0} | {1} | {2} |' -f (& $cnt $stat.AfterC), (& $fmt $stat.AfterC), (& $fmt $stat.AfterD)))
if ($null -ne $stat.Before30C -and $null -ne $stat.AfterC -and $stat.Before30C.Avg -gt 0) {
    $chgC = ($stat.AfterC.Avg - $stat.Before30C.Avg) / $stat.Before30C.Avg * 100
    $chgD = 0
    if ($null -ne $stat.Before30D -and $null -ne $stat.AfterD -and $stat.Before30D.Avg -gt 0) {
        $chgD = ($stat.AfterD.Avg - $stat.Before30D.Avg) / $stat.Before30D.Avg * 100
    }
    $null = $sb.AppendLine(('| **相對遷移前 30 日的變化** | | {0:+0.0;-0.0}% | {1:+0.0;-0.0}% |' -f $chgC, $chgD))
}
$null = $sb.AppendLine('')
$null = $sb.AppendLine('> 有效天數少的期間不要下結論。至少要累積 7 個有效天數，單日尖峰才不會主導平均。')
$null = $sb.AppendLine('')

$null = $sb.AppendLine('## 每日明細')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('| 日期 | C: SMART | C: 落盤 | D: SMART | D: 落盤 | 對帳 |')
$null = $sb.AppendLine('|---|---|---|---|---|---|')
foreach ($r in $rows) {
    $mark = ''
    if ($r.Date -eq $today) { $mark = ' ← 今日未完整' }
    elseif ($null -ne $cutover -and $r.Date -eq $cutover) { $mark = ' ← 遷移日' }
    $null = $sb.AppendLine(('| {0}{1} | {2} | {3} | {4} | {5} | {6} |' -f `
        $r.Date.ToString('yyyy-MM-dd'), $mark,
        $(if ($r.CdiC -ne '') { '{0:N0}' -f $r.CdiC } else { '—' }),
        $(if ($r.PhysC -ne '') { Format-Bytes $r.PhysC } else { '—' }),
        $(if ($r.CdiD -ne '') { '{0:N0}' -f $r.CdiD } else { '—' }),
        $(if ($r.PhysD -ne '') { Format-Bytes $r.PhysD } else { '—' }),
        $r.Recon))
}
$null = $sb.AppendLine('')
$null = $sb.AppendLine('## 已知偏差')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('- 本監控的資料寫在 D:（`D:\MX500\monitoring`）：raw/phys/proc/state 合計約 **26 MB/日**，')
$null = $sb.AppendLine('  其中 `data\state\proc-prev.json`（約 18 KB × 1440 次）佔絕大部分。看 D: 的細微變化要扣掉這 26 MB。')
$null = $sb.AppendLine('- SMART 單位是 CrystalDiskInfo 顯示的 GB、解析度 1 GB；單日 1–2 GB 的差異可能只是取整。')
$null = $sb.AppendLine('- CDI 沒在跑的日子沒有資料（表中顯示 —），那些天不列入平均。')
$null = $sb.AppendLine('- 「對帳」欄 = `(落盤 − SMART) / SMART`：兩邊都有值且 SMART ≥ 5 GB 才計算，`|差距| > 20%` 標 `⚠`。')
$null = $sb.AppendLine('  用途是抓「落盤量與 SMART 對不上」的日子（裝置編號對調、計數器重置、資料缺口都會造成）。')
$null = $sb.AppendLine('  落在門檻內顯示 `✓`，資料不足顯示 `—`；遷移日當天只有半天資料，出現 `⚠` 屬正常。')
$null = $sb.AppendLine('- 落盤量以「磁碟區標籤」分組，不採裝置編號：重開機後裝置編號可能對調（曾發生 dev2/dev3 互換）。')
$null = $sb.AppendLine('  標籤為 `I: F:` 這類多重磁碟區的裝置分不出寫入落在哪個分割區，一律不計入 C: / D:。')
$null = $sb.AppendLine('')

[IO.File]::WriteAllText((Join-Path $reportDir 'daily.md'), $sb.ToString(), $utf8Bom)

# ---------- 每日一行摘要 ----------
$lastDailyPath = Join-Path $stateDir 'last-daily.json'
$appendFrom = $yesterday
if (Test-Path -LiteralPath $lastDailyPath) {
    try {
        $ld = Get-Content -LiteralPath $lastDailyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ld.lastDate) { $appendFrom = [datetime]::ParseExact($ld.lastDate, 'yyyy-MM-dd', $inv).AddDays(1) }
    } catch { }
}
$sumPath = Join-Path $logDir 'daily-summary.log'
$newest = $null
foreach ($r in $rows) {
    if ($r.Date -lt $appendFrom -or $r.Date -gt $yesterday) { continue }
    $line = ('{0} | C: smart {1} GB | C: disk {2} | D: smart {3} GB | D: disk {4}' -f `
        $r.Date.ToString('yyyy-MM-dd'),
        $(if ($r.CdiC -ne '') { '{0:N0}' -f $r.CdiC } else { '—' }),
        $(if ($r.PhysC -ne '') { Format-Bytes $r.PhysC } else { '—' }),
        $(if ($r.CdiD -ne '') { '{0:N0}' -f $r.CdiD } else { '—' }),
        $(if ($r.PhysD -ne '') { Format-Bytes $r.PhysD } else { '—' }))
    [IO.File]::AppendAllText($sumPath, $line + "`r`n", $utf8NoBom)
    $newest = $r.Date
}
if ($null -ne $newest) {
    [IO.File]::WriteAllText($lastDailyPath, ('{"lastDate":"' + $newest.ToString('yyyy-MM-dd') + '"}'), $utf8NoBom)
}

foreach ($w in $warns) { Write-Output $w }

Write-Output ('daily report: {0} rows, cutover={1}' -f $rows.Count, $(if ($null -ne $cutover) { $cutover.ToString('yyyy-MM-dd') } else { 'none' }))
Write-Output ('  before {0}d  C: {1}  D: {2}' -f $BaselineDays, (& $fmt $stat.Before90C), (& $fmt $stat.Before90D))
Write-Output ('  before  30d  C: {0}  D: {1}' -f (& $fmt $stat.Before30C), (& $fmt $stat.Before30D))
Write-Output ('  after        C: {0}  D: {1}  (days: C={2} D={3})' -f (& $fmt $stat.AfterC), (& $fmt $stat.AfterD), (& $cnt $stat.AfterC), (& $cnt $stat.AfterD))
