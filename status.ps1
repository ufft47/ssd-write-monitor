# status.ps1 —— 一句話看 CWatch 的整體狀態
# 用法： & 'D:\dev\disk-monitor\status.ps1'
param([string]$Root = 'D:\dev\disk-monitor', [int]$Top = 10)

$ErrorActionPreference = 'SilentlyContinue'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$now = Get-Date
$today = $now.Date

function Format-Bytes([double]$b) {
    if ([math]::Abs($b) -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ([math]::Abs($b) -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ([math]::Abs($b) -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

Write-Host ''
Write-Host ('CWatch 狀態  {0}' -f $now.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
Write-Host ('-' * 64)

# 排程
foreach ($n in @('DiskMonitor', 'CWatchTray', 'CWatchCollector')) {
    $t = Get-ScheduledTask -TaskName $n
    if (-not $t) { Write-Host ('  {0,-16} 不存在' -f $n) -ForegroundColor Red; continue }
    $i = Get-ScheduledTaskInfo -TaskName $n
    $color = if ($t.State -eq 'Running' -or $i.LastTaskResult -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host ('  {0,-16} {1,-8} 上次執行 {2}  結果 {3}' -f $n, $t.State, $i.LastRunTime, $i.LastTaskResult) -ForegroundColor $color
}

# collector 心跳
$hb = Join-Path $Root 'data\state\collector.json'
if (Test-Path -LiteralPath $hb) {
    $j = Get-Content -LiteralPath $hb -Raw -Encoding UTF8 | ConvertFrom-Json
    $age = [int]($now - [datetime]::ParseExact($j.updated, 'yyyy-MM-dd HH:mm:ss', $inv)).TotalSeconds
    $seen = [double]$j.bytes_seen
    $dev = if ($null -ne $j.bytes_unresolved) { [double]$j.bytes_unresolved } else { 0 }
    $color = if ($age -lt 90) { 'Green' } else { 'Red' }
    Write-Host ('  collector       心跳 {0} 秒前  已歸因 {1}  落地層未計入 {2}' -f $age, (Format-Bytes $seen), (Format-Bytes $dev)) -ForegroundColor $color
} else {
    Write-Host '  collector       心跳檔不存在（尚未啟動過）' -ForegroundColor Red
}

# 今日落盤量
$pf = Join-Path $Root ('data\phys\' + $today.ToString('yyyy-MM-dd') + '.csv')
if (Test-Path -LiteralPath $pf) {
    $lines = [IO.File]::ReadAllLines($pf, [Text.Encoding]::UTF8)
    $devSum = @{}
    $prev = @{}
    for ($i = 1; $i -lt $lines.Length; $i++) {
        $p = $lines[$i].Split(',')
        if ($p.Length -lt 11) { continue }
        $d = $p[1]; $wb = [int64]$p[6]
        if (-not $devSum.ContainsKey($d)) { $devSum[$d] = [double]0 }
        if ($prev.ContainsKey($d) -and $wb -ge $prev[$d]) { $devSum[$d] += ($wb - $prev[$d]) }
        $prev[$d] = $wb
    }
    $c = if ($devSum.ContainsKey('0')) { $devSum['0'] } else { 0 }
    $dv = if ($devSum.ContainsKey('3')) { $devSum['3'] } else { 0 }
    Write-Host ('  今日落盤        C: {0}   D: {1}' -f (Format-Bytes $c), (Format-Bytes $dv))
}

# 今日 C: 寫入排行
$af = Join-Path $Root ('data\attrib\' + $today.ToString('yyyy-MM-dd') + '.csv')
if (Test-Path -LiteralPath $af) {
    $agg = @{}
    foreach ($ln in [IO.File]::ReadAllLines($af, [Text.Encoding]::UTF8)) {
        if ($ln.StartsWith('minute,') -or [string]::IsNullOrWhiteSpace($ln)) { continue }
        $p = $ln.Split(',')
        if ($p.Length -lt 7 -or $p[3] -ne 'C:') { continue }
        $n = $p[2]
        if (-not $agg.ContainsKey($n)) { $agg[$n] = [pscustomobject]@{ B = [double]0; O = [double]0; Top = @{} } }
        $b = [double]$p[$p.Length - 2]
        $agg[$n].B += $b
        $agg[$n].O += [double]$p[$p.Length - 1]
        $path = (($p[4..($p.Length - 3)] -join ',')).Trim('"')
        if ($path -ne '(其他)' -and $path -ne '(device)') {
            if (-not $agg[$n].Top.ContainsKey($path)) { $agg[$n].Top[$path] = [double]0 }
            $agg[$n].Top[$path] += $b
        }
    }
    Write-Host ''
    Write-Host ('  今日 C: 寫入排行（ETW 歸因）') -ForegroundColor Cyan
    Write-Host ('  {0,-22} {1,12} {2,9}  {3}' -f '進程', '寫入 C:', '次數', '最大檔案')
    $agg.GetEnumerator() | Sort-Object { $_.Value.B } -Descending | Select-Object -First $Top | ForEach-Object {
        $tf = @($_.Value.Top.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $ft = ''
        if ($tf.Count -gt 0) { $ft = (Split-Path $tf[0].Key -Leaf) + ' ' + (Format-Bytes $tf[0].Value) }
        Write-Host ('  {0,-22} {1,12} {2,9}  {3}' -f $_.Key, (Format-Bytes $_.Value.B), [int]$_.Value.O, $ft)
    }
}

# 最近報告
$rep = Get-ChildItem (Join-Path $Root 'reports') -Filter 'latest.md' -ErrorAction SilentlyContinue
if ($rep) { Write-Host ('' ); Write-Host ('  最近報告        {0} 前更新（{1}）' -f [int](($now - $rep.LastWriteTime).TotalMinutes), $rep.FullName) }
Write-Host ('-' * 64)
Write-Host '  儀表板 http://localhost:8737/   完整報告 reports\latest.md'
Write-Host ''
