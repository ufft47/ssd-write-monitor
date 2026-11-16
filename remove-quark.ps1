#Requires -Version 5.1
<#
.SYNOPSIS
    移除夸克网盘（Quark Cloud Drive），並清掉它留下的資料目錄、自啟項與排程工作。

.DESCRIPTION
    2026-11-15 實測：
      %USERPROFILE%\AppData\Local\Programs\Quark     2,539 MB（程式本體，含 unins000.exe）
      %USERPROFILE%\AppData\Local\Quark              452 MB（快取／User Data，最後寫入 2026-06-27）
      %USERPROFILE%\AppData\Local\QuarkUpdater        48 MB（更新器）
      %USERPROFILE%\AppData\Roaming\Quark             48 MB（設定）
      登錄檔 HKCU\SOFTWARE\Quark                       Brand=clouddrive、InstallTimes=40
      自啟：HKCU\...\Run 的 `quark`（--launch-from=loginitem）與
            `QuarkUpdaterTaskUser1.0.0.18`、排程工作 \QuarkUpdaterUser\QuarkUpdater\
      全天 C: 歸因寫入只有 2.2 MB —— 所以移除它是為了空間（3 GB），不是為了寫入。

    這是**使用者範圍安裝**（在 AppData 底下），所以不需要管理員權限。
    卸載字串（Inno Setup）：
      "%USERPROFILE%\AppData\Local\Programs\Quark\unins000.exe" --brand-clouddrive /SILENT --fake-silent /LOG

    本腳本順序：
      1. 備份 HKCU\SOFTWARE\Quark（reg export）與 Roaming\Quark 到 logs\quark-backup-<時間>\
      2. 執行官方靜默卸載，等它結束（最多 10 分鐘）
      3. 驗證：程式目錄、登錄項目、Run 值、排程工作是否消失
      4. （需 -RemoveLeftovers）刪掉殘留的資料目錄

.PARAMETER RemoveLeftovers
    連 AppData 底下殘留的資料（Local\Quark、Local\QuarkUpdater、Roaming\Quark）一起刪。
    刪之前已備份到 logs\quark-backup-<時間>\。
    **只有在程式目錄確認已移除時才會執行**（除非加 -Force）。

.PARAMETER Force
    即使程式目錄還在（卸載失敗）也照樣刪殘留資料。通常不該用。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西。

.NOTES
    2026-11-15 實測：官方登錄的 `UninstallString` 是
      unins000.exe /SILENT --brand-clouddrive /LOG
    但這樣跑**結束碼 1、完全沒卸載**（程式目錄 2,539 MB 原封不動）。
    改用 Inno Setup 標準參數才成功：
      unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART --brand-clouddrive /LOG=<檔>
    → 結束碼 0，目錄消失，C: 可用空間 124.30 GB → 127.31 GB。
    卸載後仍留下三處懸空引用（Run 值 ×2、排程工作 ×1、HKCU\Classes ×2），本腳本會一併清掉。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\remove-quark.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\remove-quark.ps1 -RemoveLeftovers
#>
param(
    [switch]$RemoveLeftovers,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$progDir   = Join-Path $env:LOCALAPPDATA 'Programs\Quark'
$localData = Join-Path $env:LOCALAPPDATA 'Quark'
$updater   = Join-Path $env:LOCALAPPDATA 'QuarkUpdater'
$roaming   = Join-Path $env:APPDATA 'Quark'
$logDir    = 'D:\dev\disk-monitor\logs'
$backupDir = Join-Path $logDir "quark-backup-$stamp"
$logFile   = Join-Path $logDir "remove-quark-$stamp.log"
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8
}
function SizeOf([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return [int64]0 }
    $s = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum
    return [int64]$s.Sum
}

Say ''
Say "=== 移除夸克网盘  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { Say '（DryRun：只顯示，不動任何東西）' 'Yellow' }

# ---------- 現況 ----------
Say ''
Say '--- 現況 ---' 'Cyan'
$uninst = $null
Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '夸克|Quark' } |
    ForEach-Object {
        $uninst = $_.QuietUninstallString
        if (-not $uninst) { $uninst = $_.UninstallString }
        Say ("  產品        : {0} {1}" -f $_.DisplayName, $_.DisplayVersion)
        Say ("  卸載字串    : {0}" -f $uninst)
    }
if (-not $uninst) { Say '  找不到卸載項目（可能已移除），只會做殘留清理' 'Yellow' }

foreach ($d in @($progDir, $localData, $updater, $roaming)) {
    Say ("  {0,9:N1} MB  {1}" -f ((SizeOf $d)/1MB), $d)
}
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'quark' })
Say ("  執行中      : {0}" -f $(if ($procs.Count -eq 0) { '無' } else {
    ($procs | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ' }))
$task = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Quark' })
Say ("  排程工作    : {0}" -f $(if ($task.Count -eq 0) { '無' } else { ($task.TaskName -join ', ') }))

if ($DryRun) {
    Say ''
    Say '（DryRun）會做：' 'Yellow'
    Say ("  1) 備份 HKCU\SOFTWARE\Quark 與 {0} 到 {1}" -f $roaming, $backupDir) 'DarkGray'
    Say ("  2) 執行靜默卸載：{0}" -f $uninst) 'DarkGray'
    Say '  3) 驗證目錄／登錄／Run 值／排程工作是否消失' 'DarkGray'
    if ($RemoveLeftovers) {
        Say '  4) 刪除殘留：Local\Quark、Local\QuarkUpdater、Roaming\Quark（已先備份）' 'Yellow'
    } else {
        Say '  4) 不動殘留資料（未加 -RemoveLeftovers）' 'DarkGray'
    }
    Say ''
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}

# ---------- 1) 備份設定 ----------
Say ''
Say '--- 備份設定 ---' 'Cyan'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$regFile = Join-Path $backupDir 'HKCU-SOFTWARE-Quark.reg'
& reg.exe export 'HKCU\SOFTWARE\Quark' $regFile /y 2>&1 | Out-Null
Say ("  登錄檔備份 : {0}（{1}）" -f $regFile, $(if (Test-Path -LiteralPath $regFile) { '成功' } else { '失敗' })) `
    $(if (Test-Path -LiteralPath $regFile) { 'Green' } else { 'Yellow' })
if (Test-Path -LiteralPath $roaming) {
    $dstRoam = Join-Path $backupDir 'Roaming-Quark'
    Copy-Item -LiteralPath $roaming -Destination $dstRoam -Recurse -Force -ErrorAction SilentlyContinue
    Say ("  設定目錄備份 : {0}（{1:N1} MB）" -f $dstRoam, ((SizeOf $dstRoam)/1MB)) 'Green'
}

# ---------- 2) 靜默卸載 ----------
Say ''
Say '--- 執行靜默卸載 ---' 'Cyan'
if (-not $uninst) {
    Say '  沒有卸載字串，跳過' 'Yellow'
} else {
    $exePath = $null
    $exeArgs = ''
    if ($uninst -match '^\s*"([^"]+)"\s*(.*)$') { $exePath = $Matches[1]; $exeArgs = $Matches[2] }
    elseif ($uninst -match '^\s*(\S+\.exe)\s*(.*)$') { $exePath = $Matches[1]; $exeArgs = $Matches[2] }
    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) {
        Say ("  找不到卸載程式：{0}" -f $exePath) 'Red'
        exit 3
    }
    Say ("  卸載程式：{0}" -f $exePath)
    # 實測：官方登錄的 `/SILENT --fake-silent` 會直接回結束碼 1、完全沒卸載。
    # 改用 Inno Setup 標準參數才成功（結束碼 0）。
    $brandArg = @()
    if ($uninst -match '--brand-(\S+)') { $brandArg = @("--brand-$($Matches[1])") }
    $useArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') + $brandArg + @("/LOG=$logFile.uninst")
    Say ("  實際參數：{0}" -f ($useArgs -join ' ')) 'DarkGray'
    $p = Start-Process -FilePath $exePath -ArgumentList $useArgs -PassThru -ErrorAction SilentlyContinue
    if ($p) {
        $done = $p.WaitForExit(600000)
        if ($done) { Say ("  卸載程式結束，結束碼 {0}" -f $p.ExitCode) $(if ($p.ExitCode -eq 0) { 'Green' } else { 'Red' }) }
        else { Say '  卸載程式超過 10 分鐘未結束（可能跳出視窗等你確認），請手動完成後重跑' 'Yellow' }
    }
    Start-Sleep -Seconds 3
    # Inno Setup 的卸載器會在結束時刪自己，但常常需要一點時間
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $exePath); $i++) { Start-Sleep -Seconds 2 }
}

# ---------- 3) 驗證 ----------
Say ''
Say '--- 驗證 ---' 'Cyan'
$stillProg = Test-Path -LiteralPath $progDir
Say ("  程式目錄       : {0}" -f $(if ($stillProg) { "仍在（{0:N1} MB）" -f ((SizeOf $progDir)/1MB) } else { '已移除' })) `
    $(if ($stillProg) { 'Yellow' } else { 'Green' })
$reg = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '夸克|Quark' }
Say ("  卸載登錄項目   : {0}" -f $(if ($reg) { '仍在' } else { '已消失' })) $(if ($reg) { 'Yellow' } else { 'Green' })
$runVals = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue)
$runHit = @()
if ($runVals) {
    $runVals.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -match 'Quark' } |
        ForEach-Object { $runHit += $_.Name }
}
Say ("  Run 自啟       : {0}" -f $(if ($runHit.Count -eq 0) { '已無 Quark 項目' } else { ($runHit -join ', ') })) `
    $(if ($runHit.Count -eq 0) { 'Green' } else { 'Yellow' })
$task = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Quark' })
Say ("  排程工作       : {0}" -f $(if ($task.Count -eq 0) { '已消失' } else { ($task.TaskName -join ', ') })) `
    $(if ($task.Count -eq 0) { 'Green' } else { 'Yellow' })

# ---------- 3b) 清掉懸空引用（實測卸載器不會清）----------
Say ''
Say '--- 清除懸空引用 ---' 'Cyan'
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$cleared = 0
foreach ($name in @($runHit)) {
    try { Remove-ItemProperty -Path $runKey -Name $name -ErrorAction Stop; $cleared++; Say ("  已刪除 Run 值：{0}" -f $name) 'Green' }
    catch { Say ("  Run 值刪除失敗 {0}：{1}" -f $name, $_.Exception.Message) 'Yellow' }
}
foreach ($t in $task) {
    try {
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
        $cleared++
        Say ("  已移除排程工作：{0}" -f $t.TaskName) 'Green'
    } catch { Say ("  排程工作移除失敗：{0}" -f $_.Exception.Message) 'Yellow' }
}
$clsHits = @(Get-ChildItem -LiteralPath 'HKCU:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^Quark' })
foreach ($h in $clsHits) {
    try { Remove-Item -LiteralPath $h.PSPath -Recurse -Force -ErrorAction Stop; $cleared++; Say ("  已移除 Class：{0}" -f $h.PSChildName) 'Green' }
    catch { Say ("  Class 移除失敗 {0}" -f $h.PSChildName) 'Yellow' }
}
if ($cleared -eq 0) { Say '  沒有需要清除的懸空引用' 'Green' }

# ---------- 4) 殘留 ----------
Say ''
Say '--- 殘留資料 ---' 'Cyan'
$left = @()
foreach ($d in @($localData, $updater, $roaming)) {
    if (Test-Path -LiteralPath $d) {
        $left += [pscustomobject]@{ Path = $d; MB = [math]::Round((SizeOf $d)/1MB, 1) }
    }
}
if ($left.Count -eq 0) {
    Say '  沒有殘留' 'Green'
} else {
    foreach ($l in $left) { Say ("  {0,9:N1} MB  {1}" -f $l.MB, $l.Path) 'Yellow' }
    if ($RemoveLeftovers -and $stillProg -and -not $Force) {
        Say ''
        Say '  程式目錄還在（卸載沒有成功），**不刪殘留資料** —— 否則會留下一個裝著但沒有快取的半殘狀態。' 'Red'
        Say '  請先讓卸載完成（看上面的結束碼與日誌），或加 -Force 強制刪除。' 'Yellow'
    } elseif ($RemoveLeftovers) {
        foreach ($l in $left) {
            try {
                Remove-Item -LiteralPath $l.Path -Recurse -Force -ErrorAction Stop
                Say ("  已刪除 {0}" -f $l.Path) 'Green'
            } catch {
                Say ("  刪除失敗 {0}：{1}" -f $l.Path, $_.Exception.Message) 'Red'
            }
        }
        # 一併清掉空的 HKCU\SOFTWARE\Quark（已備份）
        if (Test-Path 'HKCU:\SOFTWARE\Quark') {
            Remove-Item -LiteralPath 'HKCU:\SOFTWARE\Quark' -Recurse -Force -ErrorAction SilentlyContinue
            Say '  已移除 HKCU\SOFTWARE\Quark（備份見上）' 'Green'
        }
        $after = 0
        foreach ($d in @($localData, $updater, $roaming)) { $after += (SizeOf $d) }
        Say ("  殘留清理後剩餘：{0:N1} MB" -f ($after/1MB)) $(if ($after -lt 1MB) { 'Green' } else { 'Yellow' })
    } else {
        Say ''
        Say '  （未加 -RemoveLeftovers）這些資料保留。要一起刪請重跑並加 -RemoveLeftovers' 'DarkGray'
    }
}

Say ''
Say '=== 完成 ===' 'Cyan'
Say ("  備份：{0}" -f $backupDir) 'DarkGray'
Say ("  日誌：{0}" -f $logFile) 'DarkGray'
Say ''
