<#
    disk-report.ps1 —— 由原始 CSV 產生「每小時」報告。

    報告以 **PhysicalDisk（真正落盤）**為主，LogicalDisk 只作為「哪個磁碟區被寫／剩多少空間」的輔助。
    原因：LogicalDisk 是檔案系統層，含快取命中與延遲回寫，與裝置實際寫入量不同步。

    報告涵蓋「上一個完整小時」，並具備補寫能力：若電腦休眠／關機而漏掉某個整點，
    下次執行會把缺的每個小時各補一塊（最多 MaxCatchUpHours 個）。

    輸出：
      reports\yyyy-MM-dd.md   當日累積（每小時追加一塊）
      reports\latest.md       最新一小時 + 今日累計（每次覆寫）
      logs\hourly-summary.log 單行摘要（長期趨勢用）

    用法：
      -NowView   看目前這一小時（不寫任何檔案）
      -Force     重新產出上一個小時（會再追加一塊，不覆蓋舊的）
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor',
    [string]$CdiSmartDir = 'C:\soft\disk\CrystalDiskInfo8_1_0\Smart',
    [int]$MaxCatchUpHours = 48,
    [switch]$Force,
    [switch]$NowView
)

$ErrorActionPreference = 'Stop'

$rawDir    = Join-Path $Root 'data\raw'
$physDir   = Join-Path $Root 'data\phys'
$smartDir  = Join-Path $Root 'data\smart'
$procDir   = Join-Path $Root 'data\proc'
$stateDir  = Join-Path $Root 'data\state'
$reportDir = Join-Path $Root 'reports'
$logDir    = Join-Path $Root 'logs'
foreach ($d in @($reportDir, $logDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$inv       = [System.Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------------ 工具函式
function Format-Bytes([double]$b) {
    if ([math]::Abs($b) -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ([math]::Abs($b) -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ([math]::Abs($b) -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}
function Format-Rate([double]$bps) {
    if ($bps -ge 1MB) { return ('{0:N2} MB/s' -f ($bps / 1MB)) }
    if ($bps -ge 1KB) { return ('{0:N1} KB/s' -f ($bps / 1KB)) }
    return ('{0:N0} B/s' -f $bps)
}
function Get-Percentile($values, [double]$p) {
    $sorted = @($values | Sort-Object)
    if ($sorted.Count -eq 0) { return [double]0 }
    $idx = [int][math]::Floor($sorted.Count * $p)
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    if ($idx -lt 0) { $idx = 0 }
    return [double]$sorted[$idx]
}

function Read-Logical([string]$dir, [datetime]$from, [datetime]$to) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $p = $lines[$i].Split(',')
            if ($p.Length -lt 12) { continue }
            $out.Add([pscustomobject]@{
                ts   = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $inv)
                key  = $p[1]
                perf = [int64]$p[2]
                freq = [int64]$p[3]
                rb   = [int64]$p[4]
                wb   = [int64]$p[5]
                rd   = [int64]$p[6]
                wr   = [int64]$p[7]
                busy = [int64]$p[8]
                q    = [int]$p[9]
                free = $p[10]
                size = $p[11]
                vol  = $p[1]
            })
        }
    }
    return $out
}

function Read-Phys([string]$dir, [datetime]$from, [datetime]$to) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $p = $lines[$i].Split(',')
            if ($p.Length -lt 11) { continue }
            $out.Add([pscustomobject]@{
                ts      = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $inv)
                key     = $p[1]
                volumes = $p[2]
                perf    = [int64]$p[3]
                freq    = [int64]$p[4]
                rb      = [int64]$p[5]
                wb      = [int64]$p[6]
                rd      = [int64]$p[7]
                wr      = [int64]$p[8]
                busy    = [int64]$p[9]
                q       = [int]$p[10]
                free    = ''
                size    = ''
                vol     = $p[2]
            })
        }
    }
    return $out
}

function Read-Proc([string]$dir, [datetime]$from, [datetime]$to) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $p = $lines[$i].Split(',')
            if ($p.Length -lt 5) { continue }
            $out.Add([pscustomobject]@{
                ts          = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $inv)
                pid         = [int]$p[1]
                name        = $p[2]
                write_bytes = [int64]$p[3]
                read_bytes  = [int64]$p[4]
            })
        }
    }
    return $out
}

function Get-IOStats($samples, [datetime]$start, [datetime]$end) {
    $st = [pscustomobject]@{
        ReadBytes    = [double]0
        WriteBytes   = [double]0
        ReadOps      = [double]0
        WriteOps     = [double]0
        Busy         = [double]0
        Elapsed      = [double]0
        PeakWrite    = [double]0
        PeakWriteAt  = $null
        PeakRead     = [double]0
        FreeStart    = $null
        FreeEnd      = $null
        Samples      = 0
        FirstTs      = $null
        LastTs       = $null
        Pairs        = 0
        Resets       = 0
        ZeroWrites   = 0
        LastCumWrite = [double]0
        MedianWrite  = [double]0
        P90Write     = [double]0
        WriteRates   = (New-Object System.Collections.Generic.List[double])
    }
    $prev = $null
    foreach ($s in $samples) {
        if ($s.ts -ge $start -and $s.ts -lt $end) {
            $st.Samples++
            if ($null -eq $st.FirstTs) { $st.FirstTs = $s.ts }
            $st.LastTs = $s.ts
            if ($s.free -ne '') {
                if ($null -eq $st.FreeStart) { $st.FreeStart = [double]$s.free }
                $st.FreeEnd = [double]$s.free
            }
        }
        if ($null -ne $prev) {
            $el = ($s.perf - $prev.perf) / [double]$prev.freq
            if ($s.perf -lt $prev.perf) { $st.Resets++; $el = -1 }
            if ($el -gt 0 -and $prev.ts -ge $start -and $prev.ts -lt $end) {
                $drb = $s.rb - $prev.rb
                $dwb = $s.wb - $prev.wb
                $drd = $s.rd - $prev.rd
                $dwr = $s.wr - $prev.wr
                $dbu = $s.busy - $prev.busy
                if ($drb -lt 0) { $drb = 0 }
                if ($dwb -lt 0) { $dwb = 0 }
                if ($drd -lt 0) { $drd = 0 }
                if ($dwr -lt 0) { $dwr = 0 }
                if ($dbu -lt 0) { $dbu = 0 }
                $st.ReadBytes  += $drb
                $st.WriteBytes += $dwb
                $st.ReadOps    += $drd
                $st.WriteOps   += $dwr
                $st.Busy       += $dbu
                $st.Elapsed    += $el
                $st.Pairs++
                if ($dwb -eq 0) { $st.ZeroWrites++ }
                $rate = $dwb / $el
                $st.WriteRates.Add($rate)
                if ($rate -gt $st.PeakWrite) { $st.PeakWrite = $rate; $st.PeakWriteAt = $s.ts }
                $rrate = $drb / $el
                if ($rrate -gt $st.PeakRead) { $st.PeakRead = $rrate }
            }
        }
        $st.LastCumWrite = [double]$s.wb
        $prev = $s
    }
    $st.MedianWrite = Get-Percentile $st.WriteRates 0.5
    $st.P90Write    = Get-Percentile $st.WriteRates 0.9
    return $st
}

function Get-ProcTotals($procRows, [datetime]$start, [datetime]$end) {
    $agg = @{}
    foreach ($r in $procRows) {
        if ($r.ts -lt $start -or $r.ts -ge $end) { continue }
        $k = $r.name
        if (-not $agg.ContainsKey($k)) {
            $agg[$k] = [pscustomobject]@{ Name = $k; Pid = $r.pid; Write = [double]0; Read = [double]0 }
        }
        $agg[$k].Write += [double]$r.write_bytes
        $agg[$k].Read  += [double]$r.read_bytes
        $agg[$k].Pid   = $r.pid
    }
    return @($agg.Values | Sort-Object Write -Descending)
}

function Read-Smart([string]$dir, [datetime]$from, [datetime]$to) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $p = $lines[$i].Split(',')
            if ($p.Length -lt 11) { continue }
            $out.Add([pscustomobject]@{
                ts              = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $inv)
                drive           = $p[1]
                key             = $p[2]
                smart_date      = $p[3]
                life            = $p[4]
                host_writes     = $p[5]
                host_reads      = $p[6]
                temp            = $p[7]
                power_on_hours  = $p[8]
                power_on_count  = $p[9]
                health          = $p[10]
            })
        }
    }
    return $out
}

# 讀 CrystalDiskInfo 的 HostWrites.csv，算出長期日增量統計。
# 這是唯一能拿到「終身累計寫入」的來源（效能計數器重開機就歸零）。
function Get-CdiDaily([string]$csvPath) {
    if (-not (Test-Path -LiteralPath $csvPath)) { return $null }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($ln in [IO.File]::ReadAllLines($csvPath, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $p = $ln.Split(',')
        if ($p.Length -lt 2) { continue }
        # 少數行前面夾著 NUL（CrystalDiskInfo 寫檔中斷），先清掉否則解析失敗
        $stamp = $p[0] -replace '^[\x00-\x20]+', ''
        if ($stamp -notmatch '^\d{4}/\d{2}/\d{2} ') { continue }
        try { $ts = [datetime]::ParseExact($stamp, 'yyyy/MM/dd HH:mm:ss', $inv) } catch { continue }
        $v = 0.0
        if (-not [double]::TryParse($p[1].Trim(), [ref]$v)) { continue }
        $rows.Add([pscustomobject]@{ ts = $ts; gb = $v })
    }
    if ($rows.Count -lt 2) { return $null }

    $byDay = @{}
    foreach ($r in $rows) {
        $k = $r.ts.Date
        if (-not $byDay.ContainsKey($k) -or $byDay[$k] -lt $r.gb) { $byDay[$k] = $r.gb }
    }
    $days = @($byDay.Keys | Sort-Object)
    $lastDay = $days[$days.Count - 1]
    $firstDay = $days[0]
    $lastVal = [double]$byDay[$lastDay]
    $firstVal = [double]$byDay[$firstDay]

    $stat = [pscustomobject]@{
        FirstDay   = $firstDay
        LastDay    = $lastDay
        FirstVal   = [double]$rows[0].gb
        LastVal    = [double]$rows[$rows.Count - 1].gb
        Days       = [int]($lastDay - $firstDay).TotalDays
        LifetimeGb = 0.0
        AvgPerDay  = 0.0
        YesterdayGb = $null
        Avg7       = $null
        Avg30      = $null
    }
    # 終身累計用「第一筆樣本 → 最後一筆樣本」，不要用每日最大值（第一天可能是資料搬遷日）
    $stat.LifetimeGb = $stat.LastVal - $stat.FirstVal
    if ($stat.Days -gt 0) { $stat.AvgPerDay = $stat.LifetimeGb / $stat.Days }
    $lastVal = $stat.LastVal
    $firstVal = $stat.FirstVal

    # 前一天
    $prevDays = @($days | Where-Object { $_ -lt $lastDay })
    if ($prevDays.Count -gt 0) {
        $pd = $prevDays[$prevDays.Count - 1]
        $stat.YesterdayGb = $lastVal - [double]$byDay[$pd]
    }

    # N 日平均：找「最後一個不晚於 lastDay-N 天」的樣本，除以實際跨越天數
    foreach ($n in @(7, 30)) {
        $target = $lastDay.AddDays(-$n)
        $cand = @($days | Where-Object { $_ -le $target })
        if ($cand.Count -eq 0) { continue }
        $base = $cand[$cand.Count - 1]
        $span = ($lastDay - $base).TotalDays
        if ($span -le 0) { continue }
        $avg = ($lastVal - [double]$byDay[$base]) / $span
        if ($n -eq 7) { $stat.Avg7 = $avg } else { $stat.Avg30 = $avg }
    }
    return $stat
}

function Append-DayBlock([datetime]$hStart, [string]$block) {    $dayFile = Join-Path $reportDir ($hStart.ToString('yyyy-MM-dd') + '.md')
    if (-not (Test-Path -LiteralPath $dayFile)) {
        $head = ("# 磁碟 IO 監控 {0}`r`n`r`n單位：1 MB = 1,048,576 bytes。" +
                 "「實體落盤」= PhysicalDisk 計數器，代表真正寫到裝置的位元組；" +
                 "「檔案系統層」= LogicalDisk，含快取與延遲回寫，兩者不同步是正常的。`r`n`r`n") -f $hStart.ToString('yyyy-MM-dd')
        [IO.File]::AppendAllText($dayFile, $head, $utf8NoBom)
    }
    [IO.File]::AppendAllText($dayFile, $block, $utf8NoBom)
}

# ------------------------------------------------------------------ 決定要產出哪些小時
$now       = Get-Date
$nowHour   = $now.Date.AddHours($now.Hour)
$statePath = Join-Path $stateDir 'last-report.json'

if ($NowView) {
    $readFrom = $nowHour.AddHours(-2)
} else {
    $from = $null
    if ((Test-Path -LiteralPath $statePath) -and -not $Force) {
        try {
            $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $from = [datetime]::ParseExact($st.windowEnd, 'yyyy-MM-dd HH:mm:ss', $inv)
        } catch { $from = $null }
    }
    if ($null -eq $from) { $from = $nowHour.AddHours(-1) }
    if ($from -gt $nowHour) { $from = $nowHour }

    $pending = New-Object System.Collections.Generic.List[datetime]
    for ($t = $from; $t -lt $nowHour; $t = $t.AddHours(1)) { $pending.Add($t) }
    if ($pending.Count -eq 0) { Write-Output 'no pending hours'; exit 0 }
    if ($pending.Count -gt $MaxCatchUpHours) {
        $pending = $pending.GetRange($pending.Count - $MaxCatchUpHours, $MaxCatchUpHours)
    }
    $readFrom = $pending[0].AddHours(-2)
}
$readTo = $nowHour

# ------------------------------------------------------------------ 讀取資料
$physAll = Read-Phys $physDir $readFrom $readTo
$logAll  = Read-Logical $rawDir $readFrom $readTo
$procAll = Read-Proc $procDir $readFrom $readTo
$smartAll = Read-Smart $smartDir $readFrom $readTo

if ($physAll.Count -eq 0 -and $logAll.Count -eq 0) {
    Write-Output 'no raw samples available - report skipped'
    exit 0
}

# 裝置 -> 磁碟區（取最後一筆，因為 volumes 是穩定的）
$volMap = @{}
$devOrder = New-Object System.Collections.Generic.List[string]
foreach ($r in ($physAll | Sort-Object ts)) {
    if (-not $volMap.ContainsKey($r.key)) { $devOrder.Add($r.key) }
    $volMap[$r.key] = $r.volumes
}
$devOrder = @($devOrder | Sort-Object { [int]($_ -replace '\D', '') })

$physByDev = @{}
# 排序一律用「牆上時間」ts，不要用 perf。
# 實測 2026-11-15：ts_perf 是「開機後經過的 100ns」，每次重開機歸零（當天歸零 5 次）。
# 用 perf 排序會把「新開機期（perf 小）」排在「舊開機期（perf 大）」前面，
# 於是跨期的位元組差看起來像一筆巨大的寫入 —— 07:00 與 08:00 各被記成 310 GB。
foreach ($dev in $devOrder) { $physByDev[$dev] = @($physAll | Where-Object { $_.key -eq $dev } | Sort-Object ts) }

$diskNames = @($logAll | ForEach-Object { $_.key } | Sort-Object -Unique)
$diskNames = @($diskNames | Sort-Object @{ Expression = { if ($_ -eq 'C:') { 0 } else { 1 } } }, { $_ })
$logByDisk = @{}
foreach ($dn in $diskNames) { $logByDisk[$dn] = @($logAll | Where-Object { $_.key -eq $dn } | Sort-Object ts) }

# 找到承載 C: 的實體裝置
$cDev = $null
foreach ($dev in $devOrder) {
    $vlist = @(($volMap[$dev] -split '\s+') | Where-Object { $_ -ne '' })
    if ($vlist -contains 'C:') { $cDev = $dev; break }
}

$todayStart = $now.Date

# 今日累計的實際起點：監控可能不是從 00:00 就開始，標示出來避免誤讀。
$todayStartLabel = '00:00'
$todayRows = @($physAll | Where-Object { $_.ts -ge $todayStart })
if ($todayRows.Count -eq 0) { $todayRows = @($logAll | Where-Object { $_.ts -ge $todayStart }) }
if ($todayRows.Count -gt 0) {
    $firstTs = ($todayRows | Measure-Object -Property ts -Minimum).Minimum
    if ($firstTs -gt $todayStart.AddMinutes(5)) { $todayStartLabel = $firstTs.ToString('HH:mm') }
}

# C: 的 SMART 終身寫入歷史（來自 CrystalDiskInfo 的 HostWrites.csv，需要它持續執行才會更新）
$cKey = $null
$cSmartRows = @($smartAll | Where-Object { ($_.drive -split '\|') -contains 'C:' } | Sort-Object ts)
if ($cSmartRows.Count -gt 0) { $cKey = $cSmartRows[$cSmartRows.Count - 1].key }
$cdiHist = $null
if ($cKey) {
    try { $cdiHist = Get-CdiDaily (Join-Path $CdiSmartDir (Join-Path $cKey 'HostWrites.csv')) } catch { $cdiHist = $null }
}

# 摘要行要用的 SMART 現值
$cLife = ''
$cCdi = ''
if ($cSmartRows.Count -gt 0) {
    $lcSmart = $cSmartRows[$cSmartRows.Count - 1]
    $cLife = $lcSmart.life
    $cCdi = $lcSmart.host_writes
}

# ------------------------------------------------------------------ 即時檢視
if ($NowView) {
    $endNow = Get-Date
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine(('# 即時檢視 — 本小時 {0} 起，截至 {1}' -f $nowHour.ToString('HH:mm'), $endNow.ToString('HH:mm:ss')))
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('### 實體落盤（真正寫到裝置的位元組）')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| 裝置 | 磁碟區 | 寫入 | 中位數 | P90 | 最大 | 零寫入 | 讀取 |')
    $null = $sb.AppendLine('|---|---|---|---|---|---|---|---|')
    foreach ($dev in $devOrder) {
        $st = Get-IOStats $physByDev[$dev] $nowHour $endNow
        $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6}/{7} | {8} |' -f `
            $dev, $volMap[$dev], (Format-Bytes $st.WriteBytes), (Format-Rate $st.MedianWrite),
            (Format-Rate $st.P90Write), (Format-Rate $st.PeakWrite), $st.ZeroWrites, $st.Pairs,
            (Format-Bytes $st.ReadBytes)))
    }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('### 檔案系統層（LogicalDisk，按磁碟區；含快取與延遲回寫）')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| 磁碟區 | 寫入 | 中位數 | 峰值 | 剩餘空間 |')
    $null = $sb.AppendLine('|---|---|---|---|---|')
    foreach ($dn in $diskNames) {
        $st = Get-IOStats $logByDisk[$dn] $nowHour $endNow
        $freeTxt = '-'
        if ($null -ne $st.FreeEnd) { $freeTxt = Format-Bytes $st.FreeEnd }
        $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} |' -f `
            $dn, (Format-Bytes $st.WriteBytes), (Format-Rate $st.MedianWrite), (Format-Rate $st.PeakWrite), $freeTxt))
    }
    $tops = @(Get-ProcTotals $procAll $nowHour $endNow | Select-Object -First 8)
    if ($tops.Count -gt 0) {
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('### 進程（**邏輯** I/O，含 pipe/socket/快取命中，不可當落盤量）')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| 進程 | PID | 寫入 |')
        $null = $sb.AppendLine('|---|---|---|')
        foreach ($t in $tops) {
            $null = $sb.AppendLine(('| {0} | {1} | {2} |' -f $t.Name, $t.Pid, (Format-Bytes $t.Write)))
        }
    }
    Write-Output $sb.ToString()
    exit 0
}

# ------------------------------------------------------------------ 逐小時產出
$blocks = New-Object System.Collections.Generic.List[string]
$summaryLines = New-Object System.Collections.Generic.List[string]
$newestBlock = $null

foreach ($hStart in $pending) {
    $hEnd = $hStart.AddHours(1)
    $sb = New-Object System.Text.StringBuilder

    $physStats = @{}
    foreach ($dev in $devOrder) { $physStats[$dev] = Get-IOStats $physByDev[$dev] $hStart $hEnd }
    $logStats = @{}
    foreach ($dn in $diskNames) { $logStats[$dn] = Get-IOStats $logByDisk[$dn] $hStart $hEnd }

    # 覆蓋率以 C: 所在的實體裝置為準（沒有就用第一個有資料的來源）
    $refStat = $null
    if ($null -ne $cDev -and $physStats.ContainsKey($cDev)) { $refStat = $physStats[$cDev] }
    elseif ($diskNames.Count -gt 0 -and $logStats.ContainsKey('C:')) { $refStat = $logStats['C:'] }
    elseif ($devOrder.Count -gt 0) { $refStat = $physStats[$devOrder[0]] }

    $coverage = 0
    if ($null -ne $refStat -and $refStat.Elapsed -gt 0) { $coverage = [math]::Round($refStat.Elapsed / 3600 * 100, 1) }

    $pairSum = 0
    foreach ($dev in $devOrder) { $pairSum += $physStats[$dev].Pairs }
    foreach ($dn in $diskNames) { $pairSum += $logStats[$dn].Pairs }

    if ($pairSum -eq 0) {
        $null = $sb.AppendLine(('## {0} – {1}' -f $hStart.ToString('yyyy-MM-dd HH:mm'), $hEnd.ToString('HH:mm')))
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('> 本小時沒有取樣資料（電腦可能關機、休眠，或監控工作尚未啟動）。')
        $null = $sb.AppendLine('')
        $emptyBlock = $sb.ToString()
        Append-DayBlock $hStart $emptyBlock
        $newestBlock = $emptyBlock
        $summaryLines.Add(('{0} | no samples' -f $hEnd.ToString('yyyy-MM-dd HH:mm')))
        $blocks.Add($emptyBlock)
        continue
    }

    $sampleCount = 0
    if ($null -ne $refStat) { $sampleCount = $refStat.Pairs }
    $null = $sb.AppendLine(('## {0} – {1}（樣本 {2}/60，覆蓋 {3}%）' -f $hStart.ToString('yyyy-MM-dd HH:mm'), $hEnd.ToString('HH:mm'), $sampleCount, $coverage))
    $null = $sb.AppendLine('')

    # ---- 實體落盤
    $null = $sb.AppendLine('### 實體落盤（PhysicalDisk：真正寫到裝置的位元組）')
    $null = $sb.AppendLine('')
    $pRef = $null
    foreach ($dev in $devOrder) { if ($null -eq $pRef -and $physStats[$dev].Pairs -gt 0) { $pRef = $physStats[$dev] } }
    $lRef = $null
    if ($logStats.ContainsKey('C:')) { $lRef = $logStats['C:'] }
    elseif ($diskNames.Count -gt 0) { $lRef = $logStats[$diskNames[0]] }
    $spanP = '無資料'
    if ($null -ne $pRef -and $null -ne $pRef.FirstTs) { $spanP = ('{0}–{1}（{2} 組樣本）' -f $pRef.FirstTs.ToString('HH:mm:ss'), $pRef.LastTs.ToString('HH:mm:ss'), $pRef.Pairs) }
    $spanL = '無資料'
    if ($null -ne $lRef -and $null -ne $lRef.FirstTs) { $spanL = ('{0}–{1}（{2} 組樣本）' -f $lRef.FirstTs.ToString('HH:mm:ss'), $lRef.LastTs.ToString('HH:mm:ss'), $lRef.Pairs) }
    $null = $sb.AppendLine(('統計區間：實體 {0} ／ 檔案系統 {1}' -f $spanP, $spanL))
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| 裝置 | 磁碟區 | 寫入 | 中位數 | P90 | 最大 | 零寫入 | 讀取 | 忙碌率 | 推估/日 |')
    $null = $sb.AppendLine('|---|---|---|---|---|---|---|---|---|---|')
    foreach ($dev in $devOrder) {
        $st = $physStats[$dev]
        $busyPct = 0
        if ($st.Elapsed -gt 0) { $busyPct = $st.Busy / ($st.Elapsed * 1e7) * 100 }
        # 只有覆蓋率 >= 90% 才外推每日量；短窗口外推會嚴重失真（一個尖峰就能翻好幾倍）
        $perDayTxt = '—'
        if ($coverage -ge 90 -and $st.Elapsed -gt 0) {
            $perDayTxt = ('{0:N2} GB' -f ($st.WriteBytes / $st.Elapsed * 86400 / 1GB))
        }
        $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6}/{7} | {8} | {9:N1}% | {10} |' -f `
            $dev, $volMap[$dev], (Format-Bytes $st.WriteBytes), (Format-Rate $st.MedianWrite),
            (Format-Rate $st.P90Write), (Format-Rate $st.PeakWrite), $st.ZeroWrites, $st.Pairs,
            (Format-Bytes $st.ReadBytes), $busyPct, $perDayTxt))
    }
    $null = $sb.AppendLine('')

    # ---- 檔案系統層
    $null = $sb.AppendLine('### 檔案系統層（LogicalDisk：哪個磁碟區被寫；含快取與延遲回寫）')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| 磁碟區 | 寫入 | 讀取 | 中位數 | 峰值 | 剩餘空間 |')
    $null = $sb.AppendLine('|---|---|---|---|---|---|')
    foreach ($dn in $diskNames) {
        $st = $logStats[$dn]
        $freeTxt = '-'
        if ($null -ne $st.FreeEnd) {
            $freeTxt = Format-Bytes $st.FreeEnd
            if ($null -ne $st.FreeStart) {
                $dFree = $st.FreeEnd - $st.FreeStart
                $sign = ''
                if ($dFree -ge 0) { $sign = '+' }
                $freeTxt = ('{0}（{1}{2}）' -f $freeTxt, $sign, (Format-Bytes $dFree))
            }
        }
        $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f `
            $dn, (Format-Bytes $st.WriteBytes), (Format-Bytes $st.ReadBytes),
            (Format-Rate $st.MedianWrite), (Format-Rate $st.PeakWrite), $freeTxt))
    }
    $null = $sb.AppendLine('')

    # ---- SMART
    $smartDrives = @($smartAll | Where-Object { $_.ts -ge $hStart -and $_.ts -lt $hEnd } | ForEach-Object { $_.drive } | Sort-Object -Unique)
    if ($smartDrives.Count -gt 0) {
        $null = $sb.AppendLine('### SMART（終身寫入、健康度）')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| 磁碟 | 機型（含序號） | 終身寫入 | 健康度 | 通電時數 | 溫度 | 本小時增量 |')
        $null = $sb.AppendLine('|---|---|---|---|---|---|---|')
        foreach ($drv in $smartDrives) {
            $rows = @($smartAll | Where-Object { $_.drive -eq $drv } | Sort-Object ts)
            if ($rows.Count -eq 0) { continue }
            $first = $rows[0]
            $last = $rows[$rows.Count - 1]

            $hwLast = $null
            $hwFirst = $null
            foreach ($r in $rows) { if ($r.host_writes -ne '') { $hwFirst = [double]$r.host_writes; break } }
            if ($last.host_writes -ne '') { $hwLast = [double]$last.host_writes }

            $lifetimeTxt = '—'
            if ($null -ne $hwLast) { $lifetimeTxt = ('{0:N0} GB' -f $hwLast) }
            $deltaTxt = '—'
            if ($null -ne $hwLast -and $null -ne $hwFirst) {
                $d = $hwLast - $hwFirst
                if ($d -lt 0) { $d = 0 }
                $deltaTxt = ('+{0:N0} GB' -f $d)
            }
            $healthTxt = '—'
            switch ($last.health) {
                '1' { $healthTxt = '正常' }
                '2' { $healthTxt = '注意' }
                '3' { $healthTxt = '不良' }
            }
            if ($last.life -ne '') { $healthTxt = ('{0}（壽命剩 {1}%）' -f $healthTxt, $last.life) }
            $hoursTxt = '—'
            if ($last.power_on_hours -ne '') { $hoursTxt = ('{0:N0} h' -f [double]$last.power_on_hours) }
            $tempTxt = '—'
            if ($last.temp -ne '') { $tempTxt = ('{0} °C' -f $last.temp) }

            $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
                ($drv -replace '\|', '/'), $last.key, $lifetimeTxt, $healthTxt, $hoursTxt, $tempTxt, $deltaTxt))
        }
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('> SMART 由 CrystalDiskInfo 提供（每 10 分鐘更新一次，解析度 1 GB）。短窗口的增量會很粗略，長期趨勢請看 `reports\latest.md` 的日統計。')
        $null = $sb.AppendLine('')
    }

    # ---- C: 焦點
    if ($null -ne $cDev) {
        $cPhys = $physStats[$cDev]
        $cPrev = Get-IOStats $physByDev[$cDev] $hStart.AddHours(-1) $hStart
        $cToday = Get-IOStats $physByDev[$cDev] $todayStart $hEnd
        $cLog = $null
        if ($logStats.ContainsKey('C:')) { $cLog = $logStats['C:'] }

        $null = $sb.AppendLine(('### C: 寫入焦點（實體裝置 {0}）' -f $cDev))
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine(('- 本小時落盤 **{0}**；中位數 {1}、P90 {2}、最大 {3}' -f `
            (Format-Bytes $cPhys.WriteBytes), (Format-Rate $cPhys.MedianWrite), (Format-Rate $cPhys.P90Write), (Format-Rate $cPhys.PeakWrite)))
        # 讀≈寫的大寫入小時 = 典型排程重組／未緩衝 I/O（ETW 歸因不到）
        if ($cPhys.WriteBytes -ge 5GB -and $cPhys.ReadBytes -gt 0 -and ($cPhys.ReadBytes / $cPhys.WriteBytes) -ge 0.8) {
            $null = $sb.AppendLine(('- ⚠ 本小時讀取 {0}（寫入的 {1:N0}%）→ 疑似重組／未緩衝 I/O（例如 Windows 排程磁碟重組），程式歸因無法覆蓋' -f `
                (Format-Bytes $cPhys.ReadBytes), ($cPhys.ReadBytes / $cPhys.WriteBytes * 100)))
        }
        $zeroNote = ''
        if ($cPhys.Pairs -gt 0 -and ($cPhys.ZeroWrites / $cPhys.Pairs) -ge 0.5) { $zeroNote = ' —— 多數樣本沒有寫入' }
        $null = $sb.AppendLine(('- 零寫入樣本 **{0}/{1}**（{2:N0}%）{3}' -f `
            $cPhys.ZeroWrites, $cPhys.Pairs, $(if ($cPhys.Pairs -gt 0) { $cPhys.ZeroWrites / $cPhys.Pairs * 100 } else { 0 }), $zeroNote))

        if ($cPrev.Elapsed -gt 0 -and $cPrev.WriteBytes -gt 0) {
            $pct = ($cPhys.WriteBytes - $cPrev.WriteBytes) / $cPrev.WriteBytes * 100
            $sign = ''
            if ($pct -ge 0) { $sign = '+' }
            $null = $sb.AppendLine(('- 前一小時落盤 {0} → 變化 {1}{2:N0}%' -f (Format-Bytes $cPrev.WriteBytes), $sign, $pct))
        }
        if ($cToday.Elapsed -gt 0) {
            $null = $sb.AppendLine(('- 今日（{0} 起）累計落盤 **{1}**' -f $todayStartLabel, (Format-Bytes $cToday.WriteBytes)))
        }
        $null = $sb.AppendLine(('- 開機以來累計落盤 {0}' -f (Format-Bytes $cPhys.LastCumWrite)))

        if ($null -ne $cLog) {
            $null = $sb.AppendLine(('- 同磁碟區的檔案系統層寫入 {0}；與落盤量的差額是快取與延遲回寫，**不可用來對時**' -f (Format-Bytes $cLog.WriteBytes)))
            if ($null -ne $cLog.FreeEnd) {
                $freeTxt = Format-Bytes $cLog.FreeEnd
                if ($null -ne $cLog.FreeStart) {
                    $dFree = $cLog.FreeEnd - $cLog.FreeStart
                    $sign = ''
                    if ($dFree -ge 0) { $sign = '+' }
                    $freeTxt = ('{0}（{1}{2}）' -f $freeTxt, $sign, (Format-Bytes $dFree))
                }
                $null = $sb.AppendLine(('- C: 剩餘空間 {0}' -f $freeTxt))
            }
        }

        $tops = @(Get-ProcTotals $procAll $hStart $hEnd | Select-Object -First 8)
        if ($tops.Count -gt 0) {
            $null = $sb.AppendLine('')
            $null = $sb.AppendLine('進程寫入量（**邏輯** I/O：含 pipe／socket／快取命中，可能遠高於實際落盤量）：')
            $null = $sb.AppendLine('')
            $null = $sb.AppendLine('| 進程 | PID | 寫入(邏輯) | 讀取(邏輯) |')
            $null = $sb.AppendLine('|---|---|---|---|')
            foreach ($t in $tops) {
                $null = $sb.AppendLine(('| {0} | {1} | {2} | {3} |' -f $t.Name, $t.Pid, (Format-Bytes $t.Write), (Format-Bytes $t.Read)))
            }
        }

        if ($coverage -lt 90) {
            $null = $sb.AppendLine('')
            $null = $sb.AppendLine(('> 注意：本小時取樣涵蓋率僅 {0}%（電腦休眠／關機，或監控在該小時中途才啟動）。總量仍是區間內的實際累計，但分布統計的樣本數偏少，推估每日量已略過。' -f $coverage))
        }
        if ($cPhys.Resets -gt 0) {
            $null = $sb.AppendLine('')
            $null = $sb.AppendLine(('> 注意：偵測到 {0} 次計數器重置（可能為重開機），該區間差值已略過。' -f $cPhys.Resets))
        }
    }
    $null = $sb.AppendLine('')

    $block = $sb.ToString()
    Append-DayBlock $hStart $block
    $blocks.Add($block)
    $newestBlock = $block

    # 單行摘要
    $cP = $null
    if ($null -ne $cDev) { $cP = $physStats[$cDev] }
    $cL = $null
    if ($logStats.ContainsKey('C:')) { $cL = $logStats['C:'] }
    $sumFree = '-'
    if ($null -ne $cL -and $null -ne $cL.FreeEnd) {
        $sumFree = Format-Bytes $cL.FreeEnd
        if ($null -ne $cL.FreeStart) {
            $dFree = $cL.FreeEnd - $cL.FreeStart
            $sign = ''
            if ($dFree -ge 0) { $sign = '+' }
            $sumFree = ('{0} ({1}{2})' -f $sumFree, $sign, (Format-Bytes $dFree))
        }
    }
    $todayGb = 0
    if ($null -ne $cDev) {
        $cT = Get-IOStats $physByDev[$cDev] $todayStart $hEnd
        $todayGb = $cT.WriteBytes / 1GB
    }
    # 注意：這行的時間戳是「區間結束」($hEnd)，例如 16:00 代表 15:00–16:00。
    # 儀表板的明細是以「起始時刻」過濾 minute 欄位，所以 cwatch-dashboard.ps1 的
    # Get-Hourly 會把這裡的 When 減一小時再給前端，兩邊才對得上。
    $summaryLines.Add(('{0} | C: disk {1} | med {2} | p90 {3} | max {4} | fs {5} | today {6:N2} GB | free {7} | cover {8}% | life {9}% | cdi {10} GB' -f `
        $hEnd.ToString('yyyy-MM-dd HH:mm'),
        (Format-Bytes $(if ($null -ne $cP) { $cP.WriteBytes } else { 0 })),
        (Format-Rate $(if ($null -ne $cP) { $cP.MedianWrite } else { 0 })),
        (Format-Rate $(if ($null -ne $cP) { $cP.P90Write } else { 0 })),
        (Format-Rate $(if ($null -ne $cP) { $cP.PeakWrite } else { 0 })),
        (Format-Bytes $(if ($null -ne $cL) { $cL.WriteBytes } else { 0 })),
        $todayGb, $sumFree, $coverage, $cLife, $cCdi))

    # 其他磁碟區也各寫一行，讓趨勢圖可以切換看不同碟（C: 以外沒有 free/cover/life 的意義，填 -）
    foreach ($dev in $devOrder) {
        if ($dev -eq $cDev) { continue }
        # 用 $physStats[$dev]（本小時已算好的統計），不要在這裡再呼叫 Get-IOStats —— 
        # 這個 scope 的 $nowHour/$hEnd 是迴圈外的舊值，會算出 0。
        $stD = $physStats[$dev]
        if ($null -eq $stD) { continue }
        $volLabel = $volMap[$dev]
        if (-not $volLabel) { $volLabel = $dev }
        $lineTxt = ('{0} | {1} disk {2} | med {3} | p90 {4} | max {5} | fs - | today - | free - | cover - | life - | cdi -' -f `
            $hEnd.ToString('yyyy-MM-dd HH:mm'),
            $volLabel,
            (Format-Bytes $stD.WriteBytes),
            (Format-Rate $stD.MedianWrite),
            (Format-Rate $stD.P90Write),
            (Format-Rate $stD.PeakWrite))
        $summaryLines.Add($lineTxt)
    }
}

# ------------------------------------------------------------------ latest.md
$latestPath = Join-Path $reportDir 'latest.md'
$lb = New-Object System.Text.StringBuilder
$null = $lb.AppendLine(('# 磁碟 IO 監控 — 最新狀態（{0}）' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
$null = $lb.AppendLine('')
$null = $lb.AppendLine(('## 今日累計（{0} 起）' -f $todayStartLabel))
$null = $lb.AppendLine('')
$null = $lb.AppendLine('### 實體落盤（PhysicalDisk）')
$null = $lb.AppendLine('')
$null = $lb.AppendLine('| 裝置 | 磁碟區 | 寫入 | 讀取 |')
$null = $lb.AppendLine('|---|---|---|---|')
$todayEnd = Get-Date
foreach ($dev in $devOrder) {
    $st = Get-IOStats $physByDev[$dev] $todayStart $todayEnd
    $null = $lb.AppendLine(('| {0} | {1} | {2} | {3} |' -f $dev, $volMap[$dev], (Format-Bytes $st.WriteBytes), (Format-Bytes $st.ReadBytes)))
}
$null = $lb.AppendLine('')
$null = $lb.AppendLine('### 檔案系統層（LogicalDisk）')
$null = $lb.AppendLine('')
$null = $lb.AppendLine('| 磁碟區 | 寫入 | 讀取 | 剩餘空間 |')
$null = $lb.AppendLine('|---|---|---|---|')
foreach ($dn in $diskNames) {
    $st = Get-IOStats $logByDisk[$dn] $todayStart $todayEnd
    $freeTxt = '-'
    if ($null -ne $st.FreeEnd) { $freeTxt = Format-Bytes $st.FreeEnd }
    $null = $lb.AppendLine(('| {0} | {1} | {2} | {3} |' -f $dn, (Format-Bytes $st.WriteBytes), (Format-Bytes $st.ReadBytes), $freeTxt))
}
$null = $lb.AppendLine('')
$null = $lb.AppendLine('### SMART 長期寫入（C:）')
$null = $lb.AppendLine('')
$cLatest = $null
if ($cSmartRows.Count -gt 0) { $cLatest = $cSmartRows[$cSmartRows.Count - 1] }
if ($null -ne $cdiHist) {
    $null = $lb.AppendLine(('- 終身累計寫入 **{0:N0} GB**（{1} 起 {2:N0} 天，平均 {3:N1} GB/日）' -f `
        $cdiHist.LifetimeGb, $cdiHist.FirstDay.ToString('yyyy-MM-dd'), $cdiHist.Days, $cdiHist.AvgPerDay))
    $parts = @()
    if ($null -ne $cdiHist.YesterdayGb) { $parts += ('昨天 {0:N0} GB' -f $cdiHist.YesterdayGb) }
    if ($null -ne $cdiHist.Avg7) { $parts += ('近 7 日 {0:N1} GB/日' -f $cdiHist.Avg7) }
    if ($null -ne $cdiHist.Avg30) { $parts += ('近 30 日 {0:N1} GB/日' -f $cdiHist.Avg30) }
    if ($parts.Count -gt 0) { $null = $lb.AppendLine(('- ' + ($parts -join ' ／ '))) }
    if ($null -ne $cLatest) {
        $hTxt = '—'
        switch ($cLatest.health) {
            '1' { $hTxt = '正常' }
            '2' { $hTxt = '注意' }
            '3' { $hTxt = '不良' }
        }
        $null = $lb.AppendLine(('- 健康度 {0}／ 通電 {1:N0} h ／ {2} °C（資料時間 {3}）' -f `
            $hTxt, [double]$cLatest.power_on_hours, $cLatest.temp, $cLatest.smart_date))
    }
} else {
    $null = $lb.AppendLine(('- 找不到 CrystalDiskInfo 的 HostWrites.csv（{0}），終身累計寫入無法取得。' -f $CdiSmartDir))
}
$unhealthy = @($smartAll | Where-Object { $_.health -ne '' -and $_.health -ne '1' } | Group-Object drive)
foreach ($u in $unhealthy) {
    $lastU = @($u.Group | Sort-Object ts) | Select-Object -Last 1
    $null = $lb.AppendLine(('- **注意**：{0} 的 SMART 狀態為 {1}（{2}）' -f ($u.Name -replace '\|', '/'), $lastU.health, $lastU.key))
}
$null = $lb.AppendLine('')
$null = $lb.AppendLine('---')
$null = $lb.AppendLine('')
$null = $lb.Append($newestBlock)
[IO.File]::WriteAllText($latestPath, $lb.ToString(), $utf8Bom)

# ------------------------------------------------------------------ 摘要 + 狀態
$sumPath = Join-Path $logDir 'hourly-summary.log'
foreach ($line in $summaryLines) { [IO.File]::AppendAllText($sumPath, $line + "`r`n", $utf8NoBom) }

$stateJson = ConvertTo-Json -InputObject ([pscustomobject]@{ windowEnd = $nowHour.ToString('yyyy-MM-dd HH:mm:ss'); generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })
[IO.File]::WriteAllText($statePath, $stateJson, $utf8NoBom)

foreach ($line in $summaryLines) { Write-Output $line }
Write-Output ('report blocks written: {0} -> {1}' -f $blocks.Count, $latestPath)
