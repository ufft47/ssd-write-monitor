#Requires -Version 5.1
<#
.SYNOPSIS
    診斷「能不能在正常開機狀態下搬 C:\Program Files\AVG」—— 停 AVG 服務、逐一嘗試卸載驅動、
    測檔案是否仍被鎖住，然後把所有東西復原。

.DESCRIPTION
    問題：搬 C:\Program Files\AVG 需要「目錄裡沒有被握著的檔案，而且自我保護不作用」。
    能不能只靠「關掉 AVG」達到，不必進安全模式？這支腳本用實測回答，不靠推論。

    它會依序做：
      1. 記錄現況（服務狀態 + 16 個驅動狀態）到 logs\，供還原比對
      2. 停止 4 個 AVG 服務
      3. 對 16 個 AVG 驅動逐一執行 sc.exe stop，並記錄真實結束碼與之後的狀態
      4. 對 C:\Program Files\AVG 裡的檔案做「獨佔開檔」測試（3 次，間隔 300ms，
         避免把掃描器的瞬時握持誤判成永久鎖定）
      5. 復原（預設）：重新啟動剛才停掉的驅動與服務，並比對是否回到原本狀態

    結束碼：
      0 = 檔案沒有被鎖 → 可以在正常模式搬（但自我保護未必肯讓你改名，見下）
      1 = 檔案仍被鎖 → 必須進安全模式
      2 = 需要管理員權限
      3 = 復原未完全成功（請重開機）

.PARAMETER KeepStopped
    不復原（停在「服務與驅動已停」的狀態）。警告：這會讓機器在沒有防毒的情況下運作，
    而且自我保護驅動被停掉時 AVG 可能無法即時反應。除非你馬上就要搬，否則不要用。

.PARAMETER ProbeRename
    額外做「改名探針」：只有在檔案沒被鎖時才會嘗試，會把
    C:\Program Files\AVG 改名成 AVG.renametest，隨即改回來。
    這是唯一能直接回答「自我保護會不會擋改名」的實驗，但它是唯一會動到目錄名稱的步驟。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西（不需要管理員權限）。

.EXAMPLE
    # 先看會做什麼
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\avg-try-stop.ps1 -DryRun

.EXAMPLE
    # 實測（提權）
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-try-stop.ps1'
#>
param(
    [switch]$KeepStopped,
    [switch]$ProbeRename,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'   # 這支是診斷腳本，個別步驟失敗要繼續記錄

$src     = 'C:\Program Files\AVG'
$logDir  = 'D:\dev\disk-monitor\logs'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "avg-try-stop-$stamp.log"

$svcs = @('AVG Antivirus', 'AVG Tools', 'AvgWscReporter', 'avgbIDSAgent')
# 依「先停過濾器、後停核心」的順序；復原時反向
$drivers = @(
    'avgMonFlt', 'avgSnx', 'avgNetHub', 'avgKbd', 'avgRdr', 'avgStm', 'avgVmm',
    'avgArPot', 'avgDrvBrg', 'avgSP',
    'avgArDisk', 'avgElam', 'avgRvrt', 'avgbidsdriver', 'avgbidsh', 'avgbuniv'
)

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8
}
function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
# 回傳 $true / $false；抓不到可測檔案回 $null
function Test-LockedOnce {
    $probe = Get-ChildItem -Path (Join-Path $src '*') -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.exe', '.dll') } | Select-Object -First 1
    if (-not $probe) { return $null }
    try {
        $fs = [IO.File]::Open($probe.FullName, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}
function DriverState([string]$n) {
    $out = & sc.exe query $n 2>&1
    if ($out -match 'RUNNING') { return 'Running' }
    if ($out -match 'STOPPED') { return 'Stopped' }
    if ($out -match 'STOP_PENDING') { return 'StopPending' }
    if ($out -match 'START_PENDING') { return 'StartPending' }
    if ($out -match 'does not exist|不存在的服務|指定的服務並未以已安裝服務的形式存在') { return 'Absent' }
    return 'Unknown'
}

Say ''
Say "=== AVG 能否在不進安全模式的情況下關掉  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { Say '（DryRun：只顯示，不動任何東西）' 'Yellow' }

if (-not (IsAdmin) -and -not $DryRun) {
    Say ''
    Say '需要管理員權限。請改用：' 'Red'
    Say "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath'" 'Yellow'
    Say ''
    Say '（也可以用 -DryRun 在不需要提權的情況下先看現況）' 'DarkGray'
    exit 2
}

# ---------- 1) 記錄現況 ----------
Say ''
Say '--- 現況（變更前）---' 'Cyan'
$beforeSvc = @{}
foreach ($n in $svcs) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    $beforeSvc[$n] = if ($s) { $s.Status.ToString() } else { 'Absent' }
    Say ("  {0,-18} {1}" -f $n, $beforeSvc[$n])
}
$beforeDrv = @{}
foreach ($d in $drivers) {
    $beforeDrv[$d] = DriverState $d
    Say ("  {0,-16} {1}" -f $d, $beforeDrv[$d])
}

if ($DryRun) {
    Say ''
    Say '（DryRun）會做：' 'Yellow'
    Say ("  1) 停止 {0} 個服務：{1}" -f $svcs.Count, ($svcs -join ', ')) 'DarkGray'
    Say ("  2) 逐一 sc stop {0} 個驅動並記錄真實結束碼" -f $drivers.Count) 'DarkGray'
    Say '  3) 對 C:\Program Files\AVG 做 3 次獨佔開檔測試' 'DarkGray'
    Say ("  4) {0}" -f $(if ($KeepStopped) { '不復原（-KeepStopped）' } else { '把停掉的服務與驅動全部起回來' })) 'DarkGray'
    if ($ProbeRename) { Say '  5) 若未被鎖，做一次改名探針（改名後立即改回）' 'Yellow' }
    Say ''
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}

# ---------- 2) 停止服務 ----------
Say ''
Say '--- 停止 AVG 服務 ---' 'Cyan'
foreach ($n in $svcs) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if (-not $s) { Say ("  {0,-18} 不存在，跳過" -f $n) 'DarkGray'; continue }
    if ($s.Status -ne 'Running') { Say ("  {0,-18} 已經是 {1}" -f $n, $s.Status) 'DarkGray'; continue }
    try {
        Stop-Service -Name $n -Force -ErrorAction Stop
        $after = (Get-Service -Name $n).Status
        Say ("  {0,-18} 停止 → {1}" -f $n, $after) $(if ($after -eq 'Stopped') { 'Green' } else { 'Red' })
    } catch {
        Say ("  {0,-18} 停止失敗：{1}" -f $n, $_.Exception.Message) 'Red'
    }
}
Start-Sleep -Seconds 2

# ---------- 3) 逐一嘗試卸載驅動 ----------
Say ''
Say '--- 嘗試卸載 AVG 驅動（記錄真實結果）---' 'Cyan'
$drvResults = @()
foreach ($d in $drivers) {
    if ($beforeDrv[$d] -ne 'Running') {
        Say ("  {0,-16} 原本就不是 Running（{1}），跳過" -f $d, $beforeDrv[$d]) 'DarkGray'
        $drvResults += [pscustomobject]@{ Driver = $d; Before = $beforeDrv[$d]; After = $beforeDrv[$d]; Exit = -1 }
        continue
    }
    $out = & sc.exe stop $d 2>&1
    $code = $LASTEXITCODE
    Start-Sleep -Milliseconds 600
    $st = DriverState $d
    $drvResults += [pscustomobject]@{ Driver = $d; Before = 'Running'; After = $st; Exit = $code }
    $msg = ($out | Where-Object { $_ -match '\S' } | Select-Object -First 2) -join ' / '
    Say ("  {0,-16} stop 結束碼 {1,-3} → {2,-12} {3}" -f $d, $code, $st, $msg) `
        $(if ($st -eq 'Stopped') { 'Green' } elseif ($st -eq 'Running') { 'Yellow' } else { 'Gray' })
}

$stillRunning = @($drvResults | Where-Object { $_.After -eq 'Running' })
Say ''
Say ("仍在執行中的驅動：{0}" -f $(if ($stillRunning.Count -eq 0) { '無' } else { ($stillRunning.Driver -join ', ') })) `
    $(if ($stillRunning.Count -eq 0) { 'Green' } else { 'Red' })

# ---------- 4) 檔案鎖定測試 ----------
Say ''
Say '--- 檔案鎖定測試（獨佔開檔，3 次）---' 'Cyan'
$lockedCount = 0
for ($i = 1; $i -le 3; $i++) {
    $r = Test-LockedOnce
    $txt = if ($null -eq $r) { '無法判定' } elseif ($r) { '被鎖住' } else { '可獨佔開啟' }
    Say ("  第 {0} 次：{1}" -f $i, $txt) $(if ($r -eq $false) { 'Green' } elseif ($null -eq $r) { 'Yellow' } else { 'Red' })
    if ($r -eq $true) { $lockedCount++ }
    if ($i -lt 3) { Start-Sleep -Milliseconds 300 }
}
$allUnlocked = ($lockedCount -eq 0) -and ($stillRunning.Count -eq 0)

# ---------- 4b) 改名探針（可選）----------
$renameOk = $null
if ($ProbeRename -and $allUnlocked) {
    Say ''
    Say '--- 改名探針（自我保護是否會擋）---' 'Cyan'
    try {
        Rename-Item -LiteralPath $src -NewName 'AVG.renametest' -ErrorAction Stop
        Say '  改名成功 → 自我保護沒有作用' 'Green'
        Rename-Item -LiteralPath 'C:\Program Files\AVG.renametest' -NewName 'AVG' -ErrorAction Stop
        Say '  已改回來' 'Green'
        $renameOk = $true
    } catch {
        Say ("  改名失敗：{0}" -f $_.Exception.Message) 'Red'
        Say '  這是自我保護（avgSP）擋的，即使檔案沒被鎖也一樣' 'Yellow'
        $renameOk = $false
    }
} elseif ($ProbeRename) {
    Say ''
    Say '--- 改名探針：跳過（驅動仍在執行或檔案仍被鎖，改名一定失敗）---' 'DarkGray'
}

# ---------- 5) 復原 ----------
if (-not $KeepStopped) {
    Say ''
    Say '--- 復原（把停掉的東西起回來）---' 'Cyan'
    foreach ($d in ($drivers | Sort-Object)) {
        if ($beforeDrv[$d] -eq 'Running' -and (DriverState $d) -eq 'Stopped') {
            $o = & sc.exe start $d 2>&1
            Start-Sleep -Milliseconds 300
            Say ("  {0,-16} start 結束碼 {1} → {2}" -f $d, $LASTEXITCODE, (DriverState $d))
        }
    }
    foreach ($n in $svcs) {
        if ($beforeSvc[$n] -eq 'Running') {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s -and $s.Status -ne 'Running') {
                Start-Service -Name $n -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                Say ("  {0,-18} → {1}" -f $n, (Get-Service -Name $n -ErrorAction SilentlyContinue).Status)
            }
        }
    }
    # 比對是否回到原本狀態
    Say ''
    Say '--- 復原比對 ---' 'Cyan'
    $restoreFail = 0
    foreach ($n in $svcs) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        $now = if ($s) { $s.Status.ToString() } else { 'Absent' }
        if ($now -ne $beforeSvc[$n]) {
            Say ("  {0,-18} 原本 {1} → 現在 {2}（不一致）" -f $n, $beforeSvc[$n], $now) 'Red'
            $restoreFail++
        }
    }
    foreach ($d in $drivers) {
        $now = DriverState $d
        if ($now -ne $beforeDrv[$d]) {
            Say ("  {0,-16} 原本 {1} → 現在 {2}（不一致）" -f $d, $beforeDrv[$d], $now) 'Red'
            $restoreFail++
        }
    }
    if ($restoreFail -eq 0) {
        Say '  全部回到原本狀態' 'Green'
    } else {
        Say ("  {0} 項不一致 —— 請直接重開機，開機時驅動會重新載入" -f $restoreFail) 'Yellow'
    }
} else {
    Say ''
    Say '（-KeepStopped）沒有復原。注意：現在機器沒有即時防毒，做完請立刻重開機。' 'Yellow'
}

# ---------- 6) 結論 ----------
Say ''
Say '=== 結論 ===' 'Cyan'
if ($allUnlocked -and $renameOk -ne $false) {
    if ($renameOk -eq $true) {
        Say '可以：檔案沒被鎖，自我保護也沒擋改名 → 正常模式就能搬。' 'Green'
        Say '（沒有做改名探針的話，這一行仍只是「可能可以」，因為自我保護可能只擋改名不擋讀寫）' 'DarkGray'
        exit 0
    } else {
        Say '部分可以：檔案沒被鎖，但改名會被自我保護擋下。' 'Yellow'
        Say '→ 搬移仍需安全模式（安全模式下 avgSP 不載入）。請用 -ProbeRename 再確認一次。' 'Yellow'
        exit 1
    }
} else {
    Say '不行：驅動仍載入或檔案仍被鎖。' 'Red'
    Say ("  仍在執行的驅動：{0}" -f $(if ($stillRunning.Count -eq 0) { '無' } else { ($stillRunning.Driver -join ', ') })) 'DarkGray'
    Say ("  鎖定測試：3 次中有 {0} 次失敗" -f $lockedCount) 'DarkGray'
    Say '→ 這證明「只關服務不夠」，請改用安全模式搬（avg-move-programfiles.ps1 -Move）。' 'Yellow'
    exit 1
}

Say ''
Say ("日誌：$logFile") 'DarkGray'
Say ''
