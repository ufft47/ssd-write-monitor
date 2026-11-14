<#
    disk-sample.ps1 —— 取一次樣本，寫入原始 CSV。

    兩個層級的計數器都要收，因為它們回答不同問題：

      Win32_PerfRawData_PerfDisk_PhysicalDisk
        -> 真正寫到裝置的位元組（唯一代表「落盤量」的來源）
      Win32_PerfRawData_PerfDisk_LogicalDisk
        -> 檔案系統層：哪個磁碟區被寫、剩餘空間（含快取與延遲回寫，會與落盤量不同步）
      Win32_LogicalDisk
        -> 各磁碟區容量
      Win32_PerfRawData_PerfProc_Process
        -> 各進程累計 IO（**邏輯** I/O，含 pipe/socket/快取命中，不可當落盤量）

    所有數值都是「開機以來累計值」，由 disk-report.ps1 用前後差值換算。
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor',
    [int]$RetentionDays = 120,
    [int64]$ProcMinBytes = 1048576,
    [int]$ProcTopN = 8
)

$ErrorActionPreference = 'Stop'

$rawDir   = Join-Path $Root 'data\raw'
$physDir  = Join-Path $Root 'data\phys'
$procDir  = Join-Path $Root 'data\proc'
$stateDir = Join-Path $Root 'data\state'
foreach ($d in @($rawDir, $physDir, $procDir, $stateDir, (Join-Path $Root 'logs'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$inv       = [System.Globalization.CultureInfo]::InvariantCulture

# 讀 CrystalDiskInfo 的 Smart.ini：只取「=」分隔的鍵值，且只讀指定區段
function Read-IniSection([string]$path, [string]$section) {
    $cur = ''
    $out = @{}
    foreach ($ln in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $t = $ln.Trim()
        if ($t -match '^\[(.+)\]$') { $cur = $Matches[1]; continue }
        if ($cur -ne $section) { continue }
        if ($t -match '^([^=]+)=(.*)$') { $out[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    if ($out.Count -eq 0) { return $null }
    return $out
}

$now     = Get-Date
$tsLocal = $now.ToString('yyyy-MM-dd HH:mm:ss')
$today   = $now.ToString('yyyy-MM-dd')

# ---------------------------------------------------------------- 磁碟區（LogicalDisk）
$disks = Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_LogicalDisk
$vols  = @{}
Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $vols[$_.DeviceID] = @{ Free = [int64]$_.FreeSpace; Size = [int64]$_.Size }
}

$rawPath = Join-Path $rawDir ($today + '.csv')
if (-not (Test-Path -LiteralPath $rawPath)) {
    [IO.File]::AppendAllText($rawPath, "ts,disk,ts_perf,freq_perf,read_bytes,write_bytes,reads,writes,busy_100ns,queue,free_bytes,size_bytes`r`n", $utf8NoBom)
}

$sb = New-Object System.Text.StringBuilder
$diskCount = 0
foreach ($d in $disks) {
    if ($d.Name -notmatch '^[A-Z]:$') { continue }
    $free = ''
    $size = ''
    if ($vols.ContainsKey($d.Name)) { $free = [string]$vols[$d.Name].Free; $size = [string]$vols[$d.Name].Size }
    $null = $sb.AppendLine(('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11}' -f `
        $tsLocal, $d.Name, $d.Timestamp_PerfTime, $d.Frequency_PerfTime,
        $d.DiskReadBytesPerSec, $d.DiskWriteBytesPerSec,
        $d.DiskReadsPerSec, $d.DiskWritesPerSec,
        $d.PercentDiskTime, $d.CurrentDiskQueueLength, $free, $size))
    $diskCount++
}
[IO.File]::AppendAllText($rawPath, $sb.ToString(), $utf8NoBom)

# ---------------------------------------------------------------- 實體裝置（PhysicalDisk）
$physPath = Join-Path $physDir ($today + '.csv')
if (-not (Test-Path -LiteralPath $physPath)) {
    [IO.File]::AppendAllText($physPath, "ts,dev,volumes,ts_perf,freq_perf,read_bytes,write_bytes,reads,writes,busy_100ns,queue`r`n", $utf8NoBom)
}

$sbp2 = New-Object System.Text.StringBuilder
$physCount = 0
$devLetters = @{}
foreach ($p in (Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk)) {
    if ($p.Name -eq '_Total') { continue }
    $dev = $p.Name
    $volsTxt = ''
    if ($p.Name -match '^(\d+)\s*(.*)$') { $dev = $Matches[1]; $volsTxt = $Matches[2].Trim() }
    $devLetters[[int]$dev] = ($volsTxt -replace '\s+', '|')
    # volumes 內含空白（'I: F: G:'），不含逗號，可直接寫入 CSV
    $null = $sbp2.AppendLine(('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f `
        $tsLocal, $dev, $volsTxt, $p.Timestamp_PerfTime, $p.Frequency_PerfTime,
        $p.DiskReadBytesPerSec, $p.DiskWriteBytesPerSec,
        $p.DiskReadsPerSec, $p.DiskWritesPerSec,
        $p.PercentDiskTime, $p.CurrentDiskQueueLength))
    $physCount++
}
[IO.File]::AppendAllText($physPath, $sbp2.ToString(), $utf8NoBom)

# ---------------------------------------------------------------- SMART（CrystalDiskInfo 的 Smart.ini）
# 不需要管理員：CrystalDiskInfo 本身以管理員權限讀 SMART，並把結果寫進 Smart.ini。
# HostWrites 就是「開機以來以外的」終身累計寫入量（單位 GB，由 CDI 換算）。
$cdiSmart = 'C:\soft\disk\CrystalDiskInfo8_1_0\Smart'
$smartDir = Join-Path $Root 'data\smart'
if (-not (Test-Path -LiteralPath $smartDir)) { New-Item -ItemType Directory -Path $smartDir -Force | Out-Null }
$smartPath = Join-Path $smartDir ($today + '.csv')
if (-not (Test-Path -LiteralPath $smartPath)) {
    [IO.File]::AppendAllText($smartPath, "ts,drive,key,smart_date,life,host_writes,host_reads,temp,power_on_hours,power_on_count,health`r`n", $utf8NoBom)
}

$smartCount = 0
if (Test-Path -LiteralPath $cdiSmart) {
    $models = @{}
    Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
        $models[[int]$_.Index] = ([string]$_.Model).Trim()
    }

    $sbS = New-Object System.Text.StringBuilder
    foreach ($dir in (Get-ChildItem -LiteralPath $cdiSmart -Directory -ErrorAction SilentlyContinue)) {
        $ini = Join-Path $dir.FullName 'Smart.ini'
        if (-not (Test-Path -LiteralPath $ini)) { continue }
        $vals = Read-IniSection $ini $dir.Name
        if ($null -eq $vals -or -not $vals.ContainsKey('Date')) { continue }
        $sd = $null
        try { $sd = [datetime]::ParseExact($vals['Date'], 'yyyy/MM/dd HH:mm:ss', $inv) } catch { continue }
        if (($now - $sd).TotalDays -gt 2) { continue }   # 已不存在的舊硬碟不要記

        # 用磁碟型號對應到實體裝置索引，再對應到磁碟機代號
        $drive = ''
        foreach ($idx in $models.Keys) {
            $m = $models[$idx]
            if ($m -and $dir.Name.StartsWith($m) -and $devLetters.ContainsKey($idx)) { $drive = $devLetters[$idx]; break }
        }
        if (-not $drive) { continue }

        $pick = { param($k) if ($vals.ContainsKey($k)) { $vals[$k] } else { '' } }
        $null = $sbS.AppendLine(('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f `
            $tsLocal, $drive, $dir.Name, $vals['Date'],
            (& $pick 'Life'), (& $pick 'HostWrites'), (& $pick 'HostReads'), (& $pick 'Temperature'),
            (& $pick 'PowerOnHours'), (& $pick 'PowerOnCount'), (& $pick 'HealthStatus')))
        $smartCount++
    }
    if ($smartCount -gt 0) { [IO.File]::AppendAllText($smartPath, $sbS.ToString(), $utf8NoBom) }
}

# ---------------------------------------------------------------- 進程（邏輯 I/O）
$prevPath = Join-Path $stateDir 'proc-prev.json'
$prev = @{}
if (Test-Path -LiteralPath $prevPath) {
    try {
        # 注意：把 ConvertFrom-Json 接到管線尾端，輸出會是「包著整個陣列的單一物件」，
        # 之後 @() 就會變成巢狀陣列（Count=1）。一律用 -InputObject 直接取陣列。
        $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $prevPath -Raw -Encoding UTF8)
        foreach ($p in $parsed) {
            if ($null -ne $p -and $null -ne $p.pid) { $prev[[int]$p.pid] = $p }
        }
    } catch { $prev = @{} }
}

$procs = Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process | Where-Object { $_.IDProcess -gt 4 }
$cur    = New-Object System.Collections.Generic.List[object]
$deltas = New-Object System.Collections.Generic.List[object]

foreach ($p in $procs) {
    $procId = [int]$p.IDProcess
    $pname  = ($p.Name -replace '#\d+$', '')
    $w      = [int64]$p.IOWriteBytesPersec
    $r      = [int64]$p.IOReadBytesPersec
    $cur.Add([pscustomobject]@{ pid = $procId; n = $pname; w = $w; r = $r })

    if ($prev.ContainsKey($procId)) {
        $dw = $w - [int64]$prev[$procId].w
        $dr = $r - [int64]$prev[$procId].r
        # 計數器重置或 PID 重用 -> 差值為負，視為 0 而非爆量
        if ($dw -lt 0) { $dw = 0 }
        if ($dr -lt 0) { $dr = 0 }
        if ($dw -ge $ProcMinBytes) {
            $deltas.Add([pscustomobject]@{ pid = $procId; n = $pname; dw = $dw; dr = $dr })
        }
    }
}

$procPath = Join-Path $procDir ($today + '.csv')
if (-not (Test-Path -LiteralPath $procPath)) {
    [IO.File]::AppendAllText($procPath, "ts,pid,name,write_bytes,read_bytes`r`n", $utf8NoBom)
}
if ($deltas.Count -gt 0) {
    $sbp = New-Object System.Text.StringBuilder
    foreach ($x in ($deltas | Sort-Object dw -Descending | Select-Object -First $ProcTopN)) {
        $null = $sbp.AppendLine(('{0},{1},{2},{3},{4}' -f $tsLocal, $x.pid, $x.n, $x.dw, $x.dr))
    }
    [IO.File]::AppendAllText($procPath, $sbp.ToString(), $utf8NoBom)
}

# 注意：ConvertTo-Json -InputObject 直接吃 List[object] 會丟 ArgumentException，先轉成陣列
$json = ConvertTo-Json -InputObject $cur.ToArray() -Compress -Depth 3
[IO.File]::WriteAllText($prevPath, $json, $utf8NoBom)

# ---------------------------------------------------------------- 保留期限清理（每小時一次）
if ($now.Minute -eq 0) {
    $limit = $now.AddDays(-$RetentionDays)
    foreach ($dir in @($rawDir, $physDir, $procDir)) {
        Get-ChildItem -LiteralPath $dir -Filter '*.csv' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath (Join-Path $Root 'reports') -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $now.AddDays(-365) } | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Output ("sampled logical={0} physical={1} smart={2} proc-deltas={3}" -f $diskCount, $physCount, $smartCount, $deltas.Count)
