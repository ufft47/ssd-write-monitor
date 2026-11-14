<#
    cwatch-tray.ps1 —— 系統匣常駐（一般權限）

    顯示 C: 目前寫入速率（綠／黃／紅），點擊開儀表板。
    另外負責「確保儀表板有在跑」，但不會碰 collector（那需要管理員，由排程工作負責）。

    用法：powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File cwatch-tray.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor',
    [int]$Port = 8737,
    [switch]$NoDashboard
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$script:Root = $Root
$script:Port = $Port
$script:DashProc = $null

function Format-Bytes([double]$b) {
    if ([math]::Abs($b) -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ([math]::Abs($b) -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ([math]::Abs($b) -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

function Get-CurrentRate {
    $day = (Get-Date).Date
    $f = Join-Path $script:Root ('data\phys\' + $day.ToString('yyyy-MM-dd') + '.csv')
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
    $c = @()
    for ($i = $lines.Length - 1; $i -ge 1 -and $c.Count -lt 4; $i--) {
        $p = $lines[$i].Split(',')
        if ($p.Length -lt 11) { continue }
        if ($p[1] -ne '0') { continue }
        $c += [pscustomobject]@{ ts = $p[0]; perf = [int64]$p[3]; freq = [int64]$p[4]; wb = [int64]$p[6] }
    }
    if ($c.Count -lt 2) { return $null }
    $a = $c[1]; $b = $c[0]
    $el = ($b.perf - $a.perf) / [double]$a.freq
    if ($el -le 0) { return $null }
    return [pscustomobject]@{
        Rate = [math]::Max(0, $b.wb - $a.wb) / $el
        Ts = $b.ts
    }
}

function Get-TodayTotal {
    $day = (Get-Date).Date
    $f = Join-Path $script:Root ('data\phys\' + $day.ToString('yyyy-MM-dd') + '.csv')
    if (-not (Test-Path -LiteralPath $f)) { return 0.0 }
    $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
    $prev = $null
    $sum = 0.0
    for ($i = 1; $i -lt $lines.Length; $i++) {
        $p = $lines[$i].Split(',')
        if ($p.Length -lt 11) { continue }
        if ($p[1] -ne '0') { continue }
        $wb = [int64]$p[6]
        if ($null -ne $prev -and $wb -ge $prev) { $sum += ($wb - $prev) }
        $prev = $wb
    }
    return $sum
}

function Get-CollectorState {
    $f = Join-Path $script:Root 'data\state\collector.json'
    if (-not (Test-Path -LiteralPath $f)) { return @{ Text = '未啟動'; Age = -1 } }
    try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = [int]((Get-Date) - [datetime]::ParseExact($j.updated, 'yyyy-MM-dd HH:mm:ss', $inv)).TotalSeconds
        if ($age -lt 90) { return @{ Text = '執行中'; Age = $age } }
        return @{ Text = ('停住 {0} 秒' -f $age); Age = $age }
    } catch { return @{ Text = '讀取失敗'; Age = -1 } }
}

function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(60, 60, 60)), 1
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    $brush.Dispose(); $pen.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($h)
}

function Test-PortOpen([int]$p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(300)
        if ($ok) { $c.EndConnect($iar) }
        $c.Close()
        return $ok
    } catch { return $false }
}

function Start-Dashboard {
    if ($script:NoDashboard) { return }
    if (Test-PortOpen $script:Port) { return }
    $script = Join-Path $script:Root 'src\dashboard\cwatch-dashboard.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -Port {2}' -f $script, $script:Root, $script:Port)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:DashProc = [System.Diagnostics.Process]::Start($psi)
}

# ---------- 建立托盤 ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-DotIcon ([System.Drawing.Color]::FromArgb(139, 148, 158))
$notify.Text = 'CWatch'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('開啟儀表板')
$miReport = $menu.Items.Add('開啟最新報告')
$null = $menu.Items.Add('-')
$miPause = $menu.Items.Add('暫停 collector')
$miResume = $menu.Items.Add('恢復 collector')
$null = $menu.Items.Add('-')
$miExit = $menu.Items.Add('結束托盤')

$miOpen.add_Click({
    Start-Dashboard
    Start-Sleep -Milliseconds 300
    Start-Process ('http://localhost:{0}/' -f $script:Port)
})
$miReport.add_Click({
    $f = Join-Path $script:Root 'reports\latest.md'
    if (Test-Path -LiteralPath $f) { Start-Process $f } else { [System.Windows.Forms.MessageBox]::Show('還沒有報告') }
})
$miPause.add_Click({
    $f = Join-Path $script:Root 'data\state\collector.stop'
    $dir = Split-Path $f -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $f -Value 'stop' -Encoding ASCII
    [System.Windows.Forms.MessageBox]::Show('已要求 collector 停止（下一個 tick 生效）。')
})
$miResume.add_Click({
    $f = Join-Path $script:Root 'data\state\collector.stop'
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    try { Start-ScheduledTask -TaskName 'CWatchCollector' -ErrorAction Stop }
    catch { [System.Windows.Forms.MessageBox]::Show('無法啟動 CWatchCollector（需要管理員排程）。') }
})
$miExit.add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$notify.ContextMenuStrip = $menu
$notify.add_DoubleClick({ Start-Dashboard; Start-Sleep -Milliseconds 300; Start-Process ('http://localhost:{0}/' -f $script:Port) })

# ---------- 更新計時器 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 10000
$timer.add_Tick({
    try {
        $r = Get-CurrentRate
        $total = Get-TodayTotal
        $cs = Get-CollectorState
        $rateTxt = if ($null -ne $r) { ('{0}/s' -f (Format-Bytes $r.Rate)) } else { '—' }
        $color = [System.Drawing.Color]::FromArgb(63, 185, 80)
        if ($null -ne $r) {
            if ($r.Rate -gt 5MB) { $color = [System.Drawing.Color]::FromArgb(210, 153, 34) }
            if ($r.Rate -gt 20MB) { $color = [System.Drawing.Color]::FromArgb(248, 81, 73) }
        }
        $old = $notify.Icon
        $notify.Icon = New-DotIcon $color
        if ($null -ne $old) { $old.Dispose() }
        $tip = ('C: {0} · 今日 {1} · collector {2}' -f $rateTxt, (Format-Bytes $total), $cs.Text)
        if ($tip.Length -gt 120) { $tip = $tip.Substring(0, 120) }
        $notify.Text = $tip
        if ($cs.Age -lt 0) { $miPause.Enabled = $false; $miResume.Enabled = $true }
        else { $miPause.Enabled = $true; $miResume.Enabled = $true }
    } catch { }
})

Start-Dashboard
$timer.Start()
$notify.ShowBalloonTip(3000, 'CWatch', '監控已啟動。按這裡或雙擊圖示開啟儀表板。', [System.Windows.Forms.ToolTipIcon]::Info)
[System.Windows.Forms.Application]::Run()
