#Requires -Version 5.1
<#
.SYNOPSIS
    重置工作列圖示快取（TrayNotify 的 IconStreams / PastIconsStream），修 explorer.exe 持續吃 CPU 的問題。

.DESCRIPTION
    2026-11-16 實測（xperf 含微軟符號）：

      CTrayNotify::_InsertNotify → CTrayItemRegistry::DoesGUIDIconMatchPathOrIdentity
        → TNIdentity::GetIdentity → WINTRUST!WTGetSignatureInfo → SHA-256   (75%)

    explorer.exe 曾經持續吃 41–43% 單核。原因是工作列圖示快取
      HKCU:\...\CurrentVersion\TrayNotify\IconStreams      （83,660 bytes）
      HKCU:\...\CurrentVersion\TrayNotify\PastIconsStream  （929,606 bytes）
    膨脹／壞掉後，程式圖示被反覆重新註冊，每次註冊 explorer 就對那支 exe 重算簽章
    （例：AVGUI.exe 22.9 MB）。刪掉這兩個值並重啟 explorer 後：
    **41–43% → 1–3%**，快取自動重建為 39,380 / 47,384 bytes。

    本腳本只碰這兩個值，不動其他登錄值、不動其他程式、不建排程、不改服務。

    注意：重啟 explorer 會關閉已開的資料夾視窗；工作列圖示的可見性會重設
    （釘選的程式還在，但「顯示隱藏的圖示」那類設定可能回到預設）。
    explorer 由 Windows 托管的 shell，kill 之後通常會自己回來；腳本會檢查並補啟動。

.PARAMETER DryRun
    只印現況（兩個值是否存在與大小、explorer 10 秒 CPU 取樣、是否超過門檻）與接下來會做什麼。
    不改任何東西（只寫自己的日誌檔）。可與 -Apply / -Verify / -Revert 併用當預覽。

.PARAMETER Apply
    實際重置，順序固定：
      1) 先備份兩個值到 <Root>\logs\traynotify-backup-<yyyyMMdd-HHmmss>\<值名>.bin
         （用 [IO.File]::WriteAllBytes；備份失敗就中止，不會刪除任何東西）
      2) 刪除 IconStreams / PastIconsStream
      3) 重啟 explorer（Stop-Process -Force → 等 5 秒 → 沒起來就 Start-Process explorer.exe）
      4) 等 10 秒穩定，量 30 秒 explorer CPU
      5) 印出修正前 CPU、修正後 CPU、重建後的兩個值大小、備份路徑
      6) 全程寫 <Root>\logs\reset-traynotify-<時間>.log（UTF-8 無 BOM）

.PARAMETER Verify
    不修改，只檢查並給結論：
      - 兩個值存在且 PastIconsStream < 200 KB → OK，超過 → WARN
      - explorer CPU（30 秒取樣）< 5% → OK，> 20% → WARN
      - 列出最近的備份目錄
    結論 OK（exit 0）／WARN（exit 1）／PROBLEM（值不存在，快取沒有重建 → exit 2）。

.PARAMETER Revert
    從**最新**的 traynotify-backup-* 目錄把兩個 .bin 寫回（Set-ItemProperty -Type Binary），再重啟 explorer。
    找不到備份就報錯（exit 2）—— 但通常不需要還原：那兩個值刪掉後 Windows 會自己重建。

.PARAMETER Root
    日誌與備份的根目錄，預設 D:\dev\disk-monitor（寫在 <Root>\logs\）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\dev\disk-monitor\reset-traynotify.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\dev\disk-monitor\reset-traynotify.ps1 -Apply

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\dev\disk-monitor\reset-traynotify.ps1 -Verify

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\dev\disk-monitor\reset-traynotify.ps1 -Revert
#>
param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$Verify,
    [switch]$Revert,
    [string]$Root = 'D:\dev\disk-monitor'
)

$ErrorActionPreference = 'Stop'

# ---------- 常數 ----------
$keyPath   = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify'
$names     = @('IconStreams', 'PastIconsStream')
$bigBytes  = 200KB          # PastIconsStream 超過這個大小視為可疑
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir    = Join-Path $Root 'logs'
$logFile   = Join-Path $logDir "reset-traynotify-$stamp.log"
$bakDir    = Join-Path $logDir "traynotify-backup-$stamp"
$encNoBom  = New-Object System.Text.UTF8Encoding($false)

# ---------- 參數檢查：沒有開關時只印用法（含 -Apply 的每一步）就結束 ----------
if (-not ($DryRun -or $Apply -or $Verify -or $Revert)) {
    Write-Host '請指定 -DryRun / -Apply / -Verify / -Revert 其中一個（沒有任何開關時不做任何事）。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  -DryRun   只印現況（值大小、explorer CPU 10 秒取樣、是否超標）與計畫，不改任何東西'
    Write-Host '  -Apply    備份 → 刪除兩個值 → 重啟 explorer → 量 30 秒 CPU → 印前後對照'
    Write-Host '  -Verify   只檢查並給結論（OK / WARN / PROBLEM，exit 0 / 1 / 2）'
    Write-Host '  -Revert   從最新備份把兩個值寫回，再重啟 explorer'
    Write-Host ''
    Write-Host '  -Apply 的固定步驟：'
    Write-Host ('    1) 備份 IconStreams / PastIconsStream 到 {0}\logs\traynotify-backup-<時間>\<值名>.bin' -f $Root)
    Write-Host '       （用 [IO.File]::WriteAllBytes；備份失敗就中止，不會刪任何東西）'
    Write-Host ('    2) 刪除 {0}' -f $keyPath)
    Write-Host '       只刪 IconStreams 與 PastIconsStream，其他值一律不動'
    Write-Host '    3) 重啟 explorer（Stop-Process -Force → 等 5 秒 → 沒起來就 Start-Process explorer.exe）'
    Write-Host '    4) 等 10 秒穩定，量 30 秒 explorer CPU（單核百分比）'
    Write-Host ('    5) 印出修正前/後 CPU、重建後大小、備份路徑；日誌寫 {0}\logs\reset-traynotify-<時間>.log' -f $Root)
    Write-Host ''
    Write-Host '  注意：重啟 explorer 會關閉已開的資料夾視窗，工作列圖示的可見性會重設。'
    Write-Host ('  例：powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -DryRun' -f $PSCommandPath)
    exit 2
}
$actions = 0
if ($Apply)  { $actions++ }
if ($Verify) { $actions++ }
if ($Revert) { $actions++ }
if ($actions -gt 1) {
    Write-Host '-Apply / -Verify / -Revert 一次只能指定一個（-DryRun 可搭配任一動作預覽）。' -ForegroundColor Red
    exit 2
}

# ---------- 日誌：UTF-8 無 BOM（不用 Add-Content -Encoding UTF8，5.1 會加 BOM）----------
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
function Write-LogLine([string]$m) {
    [IO.File]::AppendAllText($logFile, $m + "`r`n", $encNoBom)
}
$script:step = 0
function Say([string]$m, [string]$color = 'Gray') {
    $script:step++
    $line = "  [$script:step] $m"
    Write-Host $line -ForegroundColor $color
    Write-LogLine $line
}
function SayRaw([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Write-LogLine $m
}

# ---------- 工具函式 ----------
function Get-ValueInfo([string]$name) {
    $info = [pscustomobject]@{ Name = $name; Exists = $false; Bytes = [int64]0 }
    if (-not (Test-Path -LiteralPath $keyPath)) { return $info }
    $props = Get-ItemProperty -LiteralPath $keyPath -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $info }
    $p = $props.PSObject.Properties[$name]
    if ($null -eq $p) { return $info }
    $arr = [byte[]]$p.Value
    $info.Exists = $true
    $info.Bytes = [int64]$arr.Length
    return $info
}
function Get-AllValueInfo {
    $out = @{}
    foreach ($n in $names) { $out[$n] = Get-ValueInfo $n }
    return $out
}
# explorer 的單核 CPU 百分比：取樣期間的 CPU 秒數 / 經過秒數 × 100（與 xperf 的「單核 %」同義）
function Measure-ExplorerCpu([int]$seconds) {
    $proc = Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $proc) { return $null }
    $targetPid = $proc.Id
    $t0 = $proc.TotalProcessorTime.TotalSeconds
    Start-Sleep -Seconds $seconds
    $after = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($null -eq $after) { return $null }   # 取樣期間 explorer 重啟了，數字不可比
    $t1 = $after.TotalProcessorTime.TotalSeconds
    return [pscustomobject]@{ Pct = (($t1 - $t0) / [double]$seconds * 100); Pid = $targetPid }
}
function Restart-Explorer {
    $before = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    Say ('停止 explorer（目前 {0} 個進程）' -f $before.Count)
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $now = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    if ($now.Count -eq 0) {
        Say 'explorer 沒有自動回來，手動啟動（Start-Process explorer.exe）'
        Start-Process 'explorer.exe'
        Start-Sleep -Seconds 5
        $now = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    }
    if ($now.Count -eq 0) {
        Say 'explorer 仍然沒有起來。' 'Red'
        return $false
    }
    Say ('explorer 已啟動（PID {0}）' -f $now[0].Id) 'Green'
    return $true
}
function Show-Values([string]$title) {
    SayRaw ''
    SayRaw ("--- {0} ---" -f $title) 'Cyan'
    foreach ($n in $names) {
        $i = Get-ValueInfo $n
        if ($i.Exists) {
            $flag = ''
            if ($n -eq 'PastIconsStream' -and $i.Bytes -gt $bigBytes) { $flag = '  ← 超過 200 KB，可疑' }
            SayRaw ("  {0,-16} {1,9:N0} bytes{2}" -f $n, $i.Bytes, $flag)
        } else {
            SayRaw ("  {0,-16} （不存在）" -f $n)
        }
    }
}
function Get-BackupDirs {
    return @(Get-ChildItem -LiteralPath $logDir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'traynotify-backup-*' } | Sort-Object Name -Descending)
}
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 開場與現況 ----------
SayRaw ''
SayRaw ("=== 工作列圖示快取（TrayNotify）重置  {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if ($DryRun) { SayRaw '（DryRun：只顯示，不改任何東西）' 'Yellow' }

if (-not (Test-Path -LiteralPath $keyPath)) {
    SayRaw ''
    SayRaw ("找不到機碼：{0}" -f $keyPath) 'Red'
    SayRaw '（可能不是互動式使用者帳號，或路徑被改過）' 'Yellow'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 2
}
Show-Values '現況'
$infoNow = Get-AllValueInfo
$exNow = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
SayRaw ("  explorer         {0}" -f $(if ($exNow.Count -gt 0) { ('{0} 個進程（PID {1}）' -f $exNow.Count, $exNow[0].Id) } else { '沒有在執行' }))

# =========================================================
#  -Verify：只檢查
# =========================================================
if ($Verify) {
    SayRaw ''
    SayRaw '=== 驗證 ===' 'Cyan'
    $verdict = 'OK'
    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($n in $names) {
        $i = $infoNow[$n]
        if (-not $i.Exists) {
            SayRaw ("  {0,-16} 不存在 → 快取沒有重建" -f $n) 'Red'
            $verdict = 'PROBLEM'
            $problems.Add(("{0} 不存在（快取沒有重建）" -f $n))
        } else {
            SayRaw ("  {0,-16} {1,9:N0} bytes" -f $n, $i.Bytes)
        }
    }
    if ($infoNow['PastIconsStream'].Exists) {
        if ($infoNow['PastIconsStream'].Bytes -gt $bigBytes) {
            SayRaw ("  PastIconsStream 超過 200 KB（{0:N0} bytes）→ WARN" -f $infoNow['PastIconsStream'].Bytes) 'Yellow'
            if ($verdict -eq 'OK') { $verdict = 'WARN' }
        } else {
            SayRaw ("  PastIconsStream 在 200 KB 內 → OK") 'Green'
        }
    }

    if ($DryRun) {
        SayRaw '  explorer CPU     （DryRun）略過 30 秒取樣' 'DarkGray'
    } elseif ($exNow.Count -eq 0) {
        SayRaw '  explorer CPU     explorer 沒有在執行 → 無法取樣' 'Red'
        $verdict = 'PROBLEM'
        $problems.Add('explorer 沒有在執行')
    } else {
        SayRaw '  量 explorer CPU（30 秒取樣，單核百分比）…'
        $cpu = Measure-ExplorerCpu 30
        if ($null -eq $cpu) {
            SayRaw '  explorer CPU     取樣期間 explorer 重啟，數字不可比 → 請重跑 -Verify' 'Yellow'
            if ($verdict -eq 'OK') { $verdict = 'WARN' }
        } elseif ($cpu.Pct -lt 5) {
            SayRaw ("  explorer CPU     {0:N1}%（< 5%）→ OK" -f $cpu.Pct) 'Green'
        } elseif ($cpu.Pct -gt 20) {
            SayRaw ("  explorer CPU     {0:N1}%（> 20%）→ WARN" -f $cpu.Pct) 'Yellow'
            if ($verdict -eq 'OK') { $verdict = 'WARN' }
        } else {
            SayRaw ("  explorer CPU     {0:N1}%（5–20% 之間，規格未定義，不判 WARN）" -f $cpu.Pct) 'DarkGray'
        }
    }

    $baks = Get-BackupDirs
    SayRaw ''
    if ($baks.Count -eq 0) {
        SayRaw '  最近的備份       無（沒有跑過 -Apply）' 'DarkGray'
    } else {
        SayRaw ("  最近的備份       {0}" -f $baks[0].FullName) 'DarkGray'
        if ($baks.Count -gt 1) { SayRaw ("                   （另有 {0} 個較舊的備份）" -f ($baks.Count - 1)) 'DarkGray' }
    }

    SayRaw ''
    SayRaw ("結論：{0}" -f $verdict) $(if ($verdict -eq 'OK') { 'Green' } elseif ($verdict -eq 'WARN') { 'Yellow' } else { 'Red' })
    if ($verdict -eq 'PROBLEM') {
        foreach ($p in $problems) { SayRaw ("  - {0}" -f $p) 'Red' }
        SayRaw '  處理方式：跑 -Apply 重建快取（或手動重啟 explorer）。' 'Yellow'
    }
    SayRaw ("日誌：$logFile") 'DarkGray'
    if ($verdict -eq 'OK') { exit 0 }
    if ($verdict -eq 'WARN') { exit 1 }
    exit 2
}

# =========================================================
#  -Revert：從最新備份寫回
# =========================================================
if ($Revert) {
    SayRaw ''
    SayRaw '=== 還原（從最新備份寫回）===' 'Cyan'
    $baks = Get-BackupDirs
    if ($baks.Count -eq 0) {
        SayRaw ("找不到 traynotify-backup-* 備份（{0}）" -f $logDir) 'Red'
        SayRaw '這兩個值刪掉後 Windows 會自動重建，通常不需要還原。' 'Yellow'
        SayRaw '若只是 explorer 不正常，直接重跑 -Apply 或重啟 explorer 即可。' 'Yellow'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }
    $newest = $baks[0]
    SayRaw ("  最新備份：{0}" -f $newest.FullName) 'DarkGray'

    $restore = @{}
    foreach ($n in $names) {
        $f = Join-Path $newest.FullName ($n + '.bin')
        if (Test-Path -LiteralPath $f) {
            $bytes = [IO.File]::ReadAllBytes($f)
            $restore[$n] = $bytes
            SayRaw ("  {0,-16} {1,9:N0} bytes（{2}）" -f $n, $bytes.Length, (Split-Path $f -Leaf))
        } else {
            SayRaw ("  {0,-16} 備份檔不存在，跳過" -f $n) 'Yellow'
        }
    }
    if ($restore.Count -eq 0) {
        SayRaw '  備份目錄裡沒有任何 .bin，無法還原。' 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }

    if ($DryRun) {
        SayRaw ''
        SayRaw '（DryRun）會做：' 'Yellow'
        SayRaw ("  1) 用 Set-ItemProperty -Type Binary 把上面 {0} 個值寫回 {1}" -f $restore.Count, $keyPath) 'DarkGray'
        SayRaw '  2) 重啟 explorer（會關閉已開的資料夾視窗）' 'DarkGray'
        SayRaw '  3) 印出寫回後的大小' 'DarkGray'
        SayRaw ''
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 0
    }

    SayRaw ''
    SayRaw '--- 寫回登錄值 ---' 'Cyan'
    foreach ($n in $restore.Keys) {
        Set-ItemProperty -LiteralPath $keyPath -Name $n -Value $restore[$n] -Type Binary -ErrorAction Stop
        Say ("{0} 已寫回（{1:N0} bytes）" -f $n, $restore[$n].Length) 'Green'
    }
    SayRaw ''
    SayRaw '--- 重啟 explorer ---' 'Cyan'
    SayRaw '  注意：這會關閉已開的資料夾視窗，工作列圖示的可見性也會重設。' 'Yellow'
    if (-not (Restart-Explorer)) {
        SayRaw ''
        SayRaw 'explorer 沒有起來：請按 Ctrl+Shift+Esc → 檔案 → 執行新工作 → 輸入 explorer.exe' 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 3
    }
    SayRaw ''
    Show-Values '還原後'
    SayRaw ''
    SayRaw '還原完成。' 'Green'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 0
}

# =========================================================
#  -Apply -DryRun：只印計畫
# =========================================================
if ($DryRun) {
    SayRaw ''
    SayRaw '--- 門檻判定 ---' 'Cyan'
    $ps = $infoNow['PastIconsStream']
    if ($ps.Exists -and $ps.Bytes -gt $bigBytes) {
        SayRaw ("  PastIconsStream {0:N0} bytes > 200 KB → 可疑（建議 -Apply）" -f $ps.Bytes) 'Yellow'
    } elseif ($ps.Exists) {
        SayRaw ("  PastIconsStream {0:N0} bytes ≤ 200 KB → 未超過門檻" -f $ps.Bytes) 'Green'
    } else {
        SayRaw '  PastIconsStream 不存在（快取可能正在重建）' 'Yellow'
    }
    SayRaw '  量 explorer CPU（10 秒取樣，單核百分比）…'
    $cpu = Measure-ExplorerCpu 10
    if ($null -ne $cpu) {
        SayRaw ("  explorer CPU     {0:N1}%（10 秒）" -f $cpu.Pct) $(if ($cpu.Pct -gt 5) { 'Yellow' } else { 'Green' })
    } else {
        SayRaw '  explorer CPU     取樣期間沒有 explorer／重啟了' 'Yellow'
    }
    if (Test-Elevated) {
        SayRaw ('  目前是提權執行：若 explorer 沒自動回來，Start-Process explorer.exe 可能開在提權內容中；' ) 'Yellow'
        SayRaw ('  建議這個腳本用「一般權限」跑（它只寫 HKCU，不需要管理員）。') 'Yellow'
    }
    SayRaw ''
    SayRaw '（DryRun）會做：' 'Yellow'
    SayRaw ("  1) 備份兩個值到 {0}\{1}.bin" -f $bakDir, '<值名>') 'DarkGray'
    SayRaw ('  2) Remove-ItemProperty 刪除 {0}' -f $keyPath) 'DarkGray'
    SayRaw '  3) 重啟 explorer（Stop-Process -Force → 等 5 秒 → 沒起來就 Start-Process explorer.exe）' 'DarkGray'
    SayRaw '  4) 等 10 秒穩定，量 30 秒 explorer CPU' 'DarkGray'
    SayRaw ("  5) 印出修正前/後 CPU、重建後大小；日誌 {0}" -f $logFile) 'DarkGray'
    SayRaw ''
    SayRaw '  注意：重啟 explorer 會關閉已開的資料夾視窗，工作列圖示的可見性會重設。' 'Yellow'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 0
}

# =========================================================
#  -Apply：實際重置
# =========================================================
# 保險：走到這裡一定是 -Apply 且不是 -DryRun。若哪天流程被改壞，寧可中止也不要亂刪。
if (-not $Apply) {
    SayRaw '內部錯誤：進入 -Apply 區塊但沒有指定 -Apply，中止（沒有做任何事）。' 'Red'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 9
}
SayRaw ''
SayRaw '--- 門檻判定 ---' 'Cyan'
$ps = $infoNow['PastIconsStream']
if ($ps.Exists -and $ps.Bytes -gt $bigBytes) {
    SayRaw ("  PastIconsStream {0:N0} bytes > 200 KB → 可疑" -f $ps.Bytes) 'Yellow'
} elseif ($ps.Exists) {
    SayRaw ("  PastIconsStream {0:N0} bytes ≤ 200 KB → 未超過門檻（仍可依需求重置）" -f $ps.Bytes) 'Green'
} else {
    SayRaw '  PastIconsStream 不存在（快取可能正在重建）' 'Yellow'
}
SayRaw '  量修正前的 explorer CPU（10 秒取樣，單核百分比）…'
$cpuBefore = Measure-ExplorerCpu 10
if ($null -ne $cpuBefore) {
    SayRaw ("  修正前 explorer CPU = {0:N1}%（PID {1}）" -f $cpuBefore.Pct, $cpuBefore.Pid) $(if ($cpuBefore.Pct -gt 20) { 'Yellow' } else { 'Green' })
} else {
    SayRaw '  修正前 explorer CPU = （沒有 explorer／取樣期間重啟）' 'Yellow'
}

SayRaw ''
SayRaw '--- 提醒 ---' 'Cyan'
SayRaw '  重啟 explorer 會關閉已開的資料夾視窗；工作列圖示的可見性會重設（釘選的程式不會消失）。' 'Yellow'
if (Test-Elevated) {
    SayRaw '  目前是提權執行：這個腳本只寫 HKCU，不需要管理員；' 'Yellow'
    SayRaw '  若 explorer 沒自動回來，從提權內容啟動的 explorer 可能不在使用者 shell 上。' 'Yellow'
}

# ---- 1) 備份 ----
SayRaw ''
SayRaw '--- 1/5 備份 ----' 'Cyan'
$toBackup = @($names | Where-Object { $infoNow[$_].Exists })
if ($toBackup.Count -eq 0) {
    SayRaw '  兩個值都不存在：沒有東西可備份，快取可能已經被清過。' 'Yellow'
    SayRaw '  不刪任何東西，直接結束（若要重建快取，重啟 explorer 即可）。' 'Yellow'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 0
}
if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
$backedUp = 0
foreach ($n in $toBackup) {
    try {
        $props = Get-ItemProperty -LiteralPath $keyPath -Name $n -ErrorAction Stop
        $bytes = [byte[]]$props.$n
        $f = Join-Path $bakDir ($n + '.bin')
        [IO.File]::WriteAllBytes($f, $bytes)
        if (-not (Test-Path -LiteralPath $f)) { throw '備份檔沒有產生' }
        if ((Get-Item -LiteralPath $f -Force).Length -ne $bytes.Length) { throw '備份檔大小不符' }
        $backedUp++
        Say ("{0} -> {1}.bin（{2:N0} bytes）" -f $n, $n, $bytes.Length) 'Green'
    } catch {
        SayRaw ''
        SayRaw ("備份失敗（{0}）：{1}" -f $n, $_.Exception.Message) 'Red'
        SayRaw '中止：沒有刪除任何登錄值。' 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 3
    }
}
Say ("備份完成 {0}/{1}，目錄：{2}" -f $backedUp, $toBackup.Count, $bakDir) 'Green'

# ---- 2) 刪除 ----
SayRaw ''
SayRaw '--- 2/5 刪除兩個值 ---' 'Cyan'
$removed = 0
foreach ($n in $names) {
    try {
        Remove-ItemProperty -LiteralPath $keyPath -Name $n -ErrorAction Stop
        $removed++
        Say ("已刪除 {0}" -f $n) 'Green'
    } catch {
        if (-not (Get-ValueInfo $n).Exists) {
            Say ("{0} 本來就不存在，略過" -f $n)
        } else {
            Say ("刪除 {0} 失敗：{1}" -f $n, $_.Exception.Message) 'Red'
            Say '中止：備份仍在，可用 -Revert 還原；explorer 沒有被重啟。' 'Red'
            SayRaw ("日誌：$logFile") 'DarkGray'
            exit 3
        }
    }
}

# ---- 3) 重啟 explorer ----
SayRaw ''
SayRaw '--- 3/5 重啟 explorer ---' 'Cyan'
if (-not (Restart-Explorer)) {
    SayRaw ''
    SayRaw 'explorer 沒有起來 —— 桌面與工作列會消失。' 'Red'
    SayRaw '請按 Ctrl+Shift+Esc → 檔案 → 執行新工作 → 輸入 explorer.exe' 'Red'
    SayRaw ("備份仍在：{0}（可用 -Revert 還原）" -f $bakDir) 'Yellow'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 3
}

# ---- 4) 等穩定並量測 ----
SayRaw ''
SayRaw '--- 4/5 等 10 秒穩定，量 30 秒 CPU ---' 'Cyan'
Start-Sleep -Seconds 10
$cpuAfter = Measure-ExplorerCpu 30
if ($null -ne $cpuAfter) {
    Say ("修正後 explorer CPU = {0:N1}%（30 秒，PID {1}）" -f $cpuAfter.Pct, $cpuAfter.Pid) `
        $(if ($cpuAfter.Pct -lt 5) { 'Green' } elseif ($cpuAfter.Pct -gt 20) { 'Yellow' } else { 'Gray' })
} else {
    Say '修正後 explorer CPU = （取樣期間 explorer 重啟，請用 -Verify 再量一次）' 'Yellow'
}

# ---- 5) 結果 ----
SayRaw ''
SayRaw '--- 5/5 結果 ---' 'Cyan'
SayRaw ("  修正前 CPU       : {0}" -f $(if ($null -ne $cpuBefore) { '{0:N1}%' -f $cpuBefore.Pct } else { '（未取樣）' }))
SayRaw ("  修正後 CPU       : {0}" -f $(if ($null -ne $cpuAfter) { '{0:N1}%' -f $cpuAfter.Pct } else { '（未取樣）' }))
Show-Values '重建後（Windows 會自動重建，可能需要幾秒）'
SayRaw ("  備份             : {0}" -f $bakDir)
SayRaw ''
if ($null -ne $cpuBefore -and $null -ne $cpuAfter -and $cpuAfter.Pct -lt 5 -and $cpuBefore.Pct -gt 20) {
    SayRaw ("結果：{0:N1}% → {1:N1}%，看起來已修正。" -f $cpuBefore.Pct, $cpuAfter.Pct) 'Green'
} elseif ($null -ne $cpuAfter -and $cpuAfter.Pct -lt 5) {
    SayRaw ("結果：修正後 {0:N1}%（< 5%）。" -f $cpuAfter.Pct) 'Green'
} else {
    SayRaw '結果：數字沒有明顯改善。若 explorer 仍偏高，先確認是不是別的原因（例如某個圖示持續重新註冊），' 'Yellow'
    SayRaw '      可用 xperf 取樣再看熱點；本腳本只處理 TrayNotify 快取。' 'Yellow'
}
SayRaw '備份不會自動刪除；確認穩定幾天後可自行刪除（它只是登錄值的原始 bytes）。' 'DarkGray'
SayRaw ("日誌：$logFile") 'DarkGray'
exit 0
