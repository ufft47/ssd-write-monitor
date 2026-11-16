#Requires -Version 5.1
<#
.SYNOPSIS
    移除 AVG Secure Browser，並清掉它留下的孤兒 junction 與排程工作。

.DESCRIPTION
    2026-11-15 實測：
      C:\Program Files (x86)\AVG\Browser                    1,245 MB（程式本體）
      %USERPROFILE%\AppData\Local\AVG\Browser\User Data    junction -> D:\MX500\avg-browser\User Data
      D:\MX500\avg-browser\User Data                        2,049 MB（9,647 檔，含 Profile 1 904 MB）
      排程工作 AVGBrowserProtectS-1-5-21-...-1001
        -> C:\Program Files (x86)\AVG\Browser\Application\AVGBrowserProtect.exe --runonce
           每 10 分鐘執行一次（實測上次 05:40:40、下次 05:50:50）

    也就是說它不是「閒置的程式」，而是有背景工作在定期碰它（當日仍有 12.7 MB 寫入 C:）。

    本腳本：
      1. 呼叫 AVG 官方的卸載程式（登錄檔裡的 UninstallString，不自己拼參數）
      2. 卸載後驗證：目錄、服務、排程工作是否都消失
      3. 清掉 User Data 的孤兒 junction
      4. （需 -RemoveProfile）刪掉 D: 上的 profile，但**先備份**書籤與已存密碼

    注意：User Data 是「junction -> D:」，卸載程式不會刪它。
    刪 junction 只能用 cmd /c rmdir，**不能加 /s**（會跟進刪掉 D: 上的目標資料）。

.PARAMETER RemoveProfile
    連 D: 上的 profile（2,049 MB）一起刪。刪之前會先把
    Bookmarks / Login Data / History / Web Data / Preferences 複製到
    D:\MX500\avg-browser\_backup-<時間>\（約 0.5 MB）。
    不加這個參數的話，只移除 C: 上的 junction，D: 的資料原封不動。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西（不需要管理員權限）。

.EXAMPLE
    # 先看會做什麼
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\remove-avg-browser.ps1 -DryRun

.EXAMPLE
    # 移除程式 + 清 junction，但保留 D: 上的 profile
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\remove-avg-browser.ps1'

.EXAMPLE
    # 連 profile 一起刪（會先備份書籤與密碼）
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\remove-avg-browser.ps1','-RemoveProfile'
#>
param(
    [switch]$RemoveProfile,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$browserDir = 'C:\Program Files (x86)\AVG\Browser'
$appDir     = Join-Path $browserDir 'Application'
$userData   = Join-Path $env:LOCALAPPDATA 'AVG\Browser\User Data'
$profileD   = 'D:\MX500\avg-browser\User Data'
$backupRoot = 'D:\MX500\avg-browser'
$logDir     = 'D:\dev\disk-monitor\logs'
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile    = Join-Path $logDir "remove-avg-browser-$stamp.log"

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8
}
function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function SizeOf([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return [int64]0 }
    $s = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum
    return [int64]$s.Sum
}

Say ''
Say "=== 移除 AVG Secure Browser  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { Say '（DryRun：只顯示，不動任何東西）' 'Yellow' }

# ---------- 現況 ----------
Say ''
Say '--- 現況 ---' 'Cyan'
$uninstall = $null
$keys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'AVG Secure Browser' } |
    ForEach-Object {
        $uninstall = $_.UninstallString
        Say ("  產品        : {0} {1}" -f $_.DisplayName, $_.DisplayVersion)
        Say ("  卸載字串    : {0}" -f $_.UninstallString)
    }
if (-not $uninstall) {
    Say '  找不到 AVG Secure Browser 的卸載項目（可能已移除）' 'Yellow'
}

Say ("  程式目錄    : {0:N0} MB  {1}" -f ((SizeOf $browserDir) / 1MB), $browserDir)
$udItem = Get-Item -LiteralPath $userData -Force -ErrorAction SilentlyContinue
if ($udItem) {
    Say ("  User Data   : {0}" -f $(if ($udItem.LinkType) { "$($udItem.LinkType) -> $($udItem.Target -join ',')" } else { '實體目錄（不是 junction）' })) 'Yellow'
} else {
    Say '  User Data   : （不存在）'
}
if (Test-Path -LiteralPath $profileD) {
    Say ("  D: profile  : {0:N0} MB" -f ((SizeOf $profileD) / 1MB))
}

$task = Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -like 'AVGBrowserProtect*' } | Select-Object -First 1
if ($task) {
    $inf = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue
    Say ("  排程工作    : {0}（{1}，上次 {2}，下次 {3}）" -f $task.TaskName, $task.State, $inf.LastRunTime, $inf.NextRunTime) 'Yellow'
} else {
    Say '  排程工作    : 無'
}
$browserProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -like '*AVG\Browser*' })
Say ("  執行中行程  : {0}" -f $(if ($browserProcs.Count -eq 0) { '無' } else {
    ($browserProcs | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ', ' }))

# ---------- DryRun ----------
if ($DryRun) {
    Say ''
    Say '（DryRun）會做：' 'Yellow'
    Say '  1) 停掉排程工作、結束 AVG Browser 行程' 'DarkGray'
    Say ("  2) 執行卸載程式：{0}" -f $uninstall) 'DarkGray'
    Say '  3) 驗證目錄／服務／排程工作是否消失' 'DarkGray'
    Say ("  4) 移除 User Data 的孤兒 junction（cmd /c rmdir，不加 /s）") 'DarkGray'
    if ($RemoveProfile) {
        Say ("  5) 先備份書籤與密碼到 {0}\_backup-<時間>\" -f $backupRoot) 'Yellow'
        Say ("     再刪除 D: profile：{0}" -f $profileD) 'Yellow'
    } else {
        Say '  5) 不動 D: 上的 profile（未加 -RemoveProfile）' 'DarkGray'
    }
    Say ''
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}

if (-not (IsAdmin)) {
    Say ''
    Say '需要管理員權限。請改用：' 'Red'
    Say ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath'" +
        $(if ($RemoveProfile) { ",'-RemoveProfile'" } else { '' })) 'Yellow'
    exit 2
}

# ---------- 1) 停排程工作與行程 ----------
Say ''
Say '--- 停止背景工作與行程 ---' 'Cyan'
if ($task) {
    try {
        Stop-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
        Say ("  已停止排程工作：{0}" -f $task.TaskName) 'Green'
    } catch {
        Say ("  停止排程工作失敗：{0}" -f $_.Exception.Message) 'Red'
    }
    try {
        Disable-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop | Out-Null
        Say '  已停用排程工作' 'Green'
    } catch {
        Say ("  停用排程工作失敗：{0}" -f $_.Exception.Message) 'Yellow'
    }
}
foreach ($p in $browserProcs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Say ("  已結束 {0}({1})" -f $p.Name, $p.ProcessId) 'Green'
    } catch {
        Say ("  結束 {0}({1}) 失敗：{2}" -f $p.Name, $p.ProcessId, $_.Exception.Message) 'Yellow'
    }
}

# ---------- 2) 執行官方卸載程式 ----------
Say ''
Say '--- 執行 AVG 官方卸載程式 ---' 'Cyan'
if (-not $uninstall) {
    Say '  沒有卸載字串，跳過卸載步驟（只做殘留清理）' 'Yellow'
} else {
    # 卸載字串形如： "C:\...\AVGBrowserUninstall.exe" /run_source=cp
    $exePath = $null
    $exeArgs = ''
    if ($uninstall -match '^\s*"([^"]+)"\s*(.*)$') {
        $exePath = $Matches[1]; $exeArgs = $Matches[2]
    } elseif ($uninstall -match '^\s*(\S+\.exe)\s*(.*)$') {
        $exePath = $Matches[1]; $exeArgs = $Matches[2]
    }
    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) {
        Say ("  找不到卸載執行檔：{0}" -f $exePath) 'Red'
        Say '  請改用「設定 → 應用程式 → AVG Secure Browser → 解除安裝」' 'Yellow'
        exit 3
    }
    Say ("  執行：{0} {1}" -f $exePath, $exeArgs)
    Say '  （卸載精靈可能會跳出視窗，請依畫面完成；最多等 10 分鐘）' 'Yellow'
    $proc = Start-Process -FilePath $exePath -ArgumentList $exeArgs -PassThru -ErrorAction SilentlyContinue
    if ($proc) {
        $done = $proc.WaitForExit(600000)
        if (-not $done) {
            Say '  卸載程式超過 10 分鐘沒有結束，請手動完成後重跑本腳本（會從清理步驟繼續）' 'Yellow'
        } else {
            Say ("  卸載程式結束，結束碼 {0}" -f $proc.ExitCode) $(if ($proc.ExitCode -eq 0) { 'Green' } else { 'Yellow' })
        }
    }
    Start-Sleep -Seconds 3
}

# ---------- 3) 驗證（看結果，不看動作）----------
Say ''
Say '--- 驗證 ---' 'Cyan'
$stillThere = Test-Path -LiteralPath $browserDir
$appMB = (SizeOf $browserDir) / 1MB
Say ("  程式目錄      : {0}" -f $(if ($stillThere) { "仍在（{0:N0} MB）" -f $appMB } else { '已移除' })) `
    $(if ($stillThere) { 'Yellow' } else { 'Green' })

$leftSvc = @(Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('avg', 'avgm', 'AVGSecureBrowserElevationService') })
Say ("  AVG Browser 服務: {0}" -f $(if ($leftSvc.Count -eq 0) { '已消失' } else {
    (($leftSvc | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ') })) `
    $(if ($leftSvc.Count -eq 0) { 'Green' } else { 'Yellow' })

$leftTask = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'AVGBrowserProtect*' })
Say ("  排程工作      : {0}" -f $(if ($leftTask.Count -eq 0) { '已消失' } else { ($leftTask.TaskName -join ', ') })) `
    $(if ($leftTask.Count -eq 0) { 'Green' } else { 'Yellow' })

if ($stillThere) {
    Say ''
    Say '  程式目錄沒被刪掉，可能卸載沒完成。請手動到「設定 → 應用程式」再移除一次，' 'Yellow'
    Say '  或重開機後重跑本腳本（殘留清理的步驟是獨立的）。' 'Yellow'
}

# ---------- 4) 孤兒 junction ----------
Say ''
Say '--- 清理 User Data 的孤兒 junction ---' 'Cyan'
$udItem = Get-Item -LiteralPath $userData -Force -ErrorAction SilentlyContinue
if (-not $udItem) {
    Say '  User Data 不存在，無需處理' 'Green'
} elseif (-not $udItem.LinkType) {
    Say '  User Data 是實體目錄（不是 junction），不動它' 'Yellow'
} else {
    Say ("  目前：{0} -> {1}" -f $udItem.LinkType, ($udItem.Target -join ','))
    # 只刪連結本身，絕不加 /s
    $r = & cmd.exe /c rmdir "$userData" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Say '  已移除 junction（D: 上的資料未動）' 'Green'
    } else {
        Say ("  移除 junction 失敗（結束碼 {0}）：{1}" -f $LASTEXITCODE, ($r -join ' ')) 'Red'
    }
    if (Test-Path -LiteralPath $profileD) {
        Say ("  D: 上的 profile 仍在：{0}（{1:N0} MB）" -f $profileD, ((SizeOf $profileD) / 1MB)) 'DarkGray'
    }
}

# ---------- 5) 刪 profile（需明確指定）----------
if ($RemoveProfile) {
    Say ''
    Say '--- 刪除 D: 上的 profile ---' 'Cyan'
    if (-not (Test-Path -LiteralPath $profileD)) {
        Say '  profile 不存在，無需刪除' 'Green'
    } else {
        # 先備份小檔案（書籤、已存密碼、歷史、Web Data、設定）
        $bkDir = Join-Path $backupRoot "_backup-$stamp"
        New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
        $small = @('Default\Bookmarks', 'Default\Login Data', 'Default\History',
                   'Default\Web Data', 'Default\Preferences', 'Local State')
        $copied = 0
        foreach ($f in $small) {
            $s = Join-Path $profileD $f
            if (Test-Path -LiteralPath $s) {
                $d = Join-Path $bkDir ($f -replace '\\', '_')
                try { Copy-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop; $copied++ } catch { }
            }
        }
        Say ("  已備份 {0} 個小檔案到：{1}" -f $copied, $bkDir) 'Green'
        Say '  （書籤 / 已存密碼 / 歷史 / 設定；如果那些密碼還有用，先匯出再刪 profile）' 'Yellow'

        $mb = (SizeOf $profileD) / 1MB
        try {
            Remove-Item -LiteralPath $profileD -Recurse -Force -ErrorAction Stop
            Say ("  已刪除 D: profile（{0:N0} MB）" -f $mb) 'Green'
        } catch {
            Say ("  刪除失敗：{0}" -f $_.Exception.Message) 'Red'
            Say '  可能有檔案仍被握著，重開機後再跑一次本腳本' 'Yellow'
        }
        # 若目錄已空，順手清掉上層
        $parent = Split-Path $profileD -Parent
        if ((Test-Path -LiteralPath $parent) -and
            @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
            Say ("  已移除空的父目錄：{0}" -f $parent) 'DarkGray'
        }
    }
} else {
    Say ''
    Say '（未加 -RemoveProfile）D: 上的 profile 保留原狀。' 'DarkGray'
    Say '  要一起刪：重跑本腳本並加 -RemoveProfile（會先備份書籤與密碼）' 'DarkGray'
}

# ---------- 總結 ----------
Say ''
Say '=== 完成 ===' 'Cyan'
Say ("日誌：$logFile") 'DarkGray'
Say ''
