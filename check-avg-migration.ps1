#Requires -Version 5.1
<#
.SYNOPSIS
    檢查 AVG 搬到 D: 之後是否穩定，判斷「可以刪掉 C: 上的備份了」沒有。

.DESCRIPTION
    背景（2026-11-15）：
      C:\Program Files\AVG  →  Junction  →  D:\MX500\avg\ProgramFiles   （成功，AVG 正透過它更新定義）
      C:\Program Files\AVG.bak-20261115-075637（1,967.6 MB）← 搬移當時的原件，當退路保留

    「穩定」不能靠感覺，要用可觀測的條件判斷。本腳本檢查五件事：

      1. junction 還在，而且目標正確（AVG 有沒有把目錄重建回 C:）
      2. AVG 服務在跑（AVG Antivirus 至少要是 Running）
      3. 病毒定義是新的（最新非 *_stream 定義目錄的寫入時間在 -MaxDefAgeDays 天內）
      4. 定義真的寫在 D:（不是寫回 C:）
      5. Windows 安全性中心登記的 AVG 執行檔路徑在 D:（最硬的證據）

    三個結論：
      OK        → 觀察期滿且五項全過：可以刪備份（先提權試，被 avgSP 擋再進安全模式）
      WAIT      → 觀察期還沒滿（預設 3 天），列出還差幾天
      PROBLEM   → 有任何一項不成立：**不要刪備份**，先看它指出哪一項壞了

    結束碼：0 = OK、1 = WAIT、2 = PROBLEM

.PARAMETER MinDays
    觀察期天數，預設 3。從備份資料夾名稱裡的時間戳回推搬移日。

.PARAMETER MaxDefAgeDays
    定義檔最多可以幾天沒更新，預設 5。超過就視為「定義停止更新」。

.PARAMETER RegisterTask
    註冊每日檢查排程（預設每天 09:00，工作名 AvgMigrationCheck）。**需要管理員權限。**

.PARAMETER UnregisterTask
    移除該排程工作（需要管理員權限）。刪完備份後就沒必要再檢查了。

.PARAMETER Quiet
    精簡輸出（給排程工作用）：只寫日誌與狀態檔，不印細節。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西。

.EXAMPLE
    # 隨時手動檢查（不需管理員）
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\check-avg-migration.ps1

.EXAMPLE
    # 註冊每日檢查（提權一次）
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\check-avg-migration.ps1','-RegisterTask'

.EXAMPLE
    # 刪完備份後移除排程
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\check-avg-migration.ps1','-UnregisterTask'
#>
param(
    [int]$MinDays = 3,
    [int]$MaxDefAgeDays = 5,
    [switch]$RegisterTask,
    [switch]$UnregisterTask,
    [switch]$Quiet,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$taskName   = 'AvgMigrationCheck'
$linkPath   = 'C:\Program Files\AVG'
$expectedTo = 'D:\MX500\avg\ProgramFiles'
$stateDir   = 'D:\dev\disk-monitor\data\state'
$logDir     = 'D:\dev\disk-monitor\logs'
$stateFile  = Join-Path $stateDir 'avg-migration.json'
$logFile    = Join-Path $logDir 'avg-migration-check.log'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Say([string]$m, [string]$color = 'Gray') {
    if (-not $Quiet) { Write-Host $m -ForegroundColor $color }
    try { Add-Content -LiteralPath $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 -ErrorAction Stop } catch { }
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

# ---------- 排程工作管理 ----------
if ($RegisterTask -or $UnregisterTask) {
    if (-not (IsAdmin) -and -not $DryRun) {
        Write-Host '註冊／移除排程工作需要管理員權限。請改用：' -ForegroundColor Red
        $flag = if ($RegisterTask) { '-RegisterTask' } else { '-UnregisterTask' }
        Write-Host ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','$flag'") -ForegroundColor Yellow
        exit 1
    }
    if ($UnregisterTask) {
        if ($DryRun) { Write-Host "（DryRun）會移除排程工作 $taskName"; exit 0 }
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $t) { Write-Host "排程工作 $taskName 不存在" -ForegroundColor Yellow; exit 0 }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $left = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($left) { Write-Host '移除失敗' -ForegroundColor Red; exit 3 }
        Write-Host "已移除排程工作 $taskName" -ForegroundColor Green
        exit 0
    }
    # 註冊
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Quiet"
    if ($DryRun) {
        Write-Host "（DryRun）會註冊排程工作："
        Write-Host ("  名稱 {0}，每天 09:00" -f $taskName)
        Write-Host ("  執行 powershell.exe {0}" -f $arg)
        exit 0
    }
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger  = New-ScheduledTaskTrigger -Daily -At '09:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Description '檢查 AVG 搬到 D: 後是否穩定，判斷可否刪除 C: 上的備份（1,967.6 MB）' -ErrorAction SilentlyContinue | Out-Null
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host '註冊失敗' -ForegroundColor Red; exit 3 }
    Write-Host ("已註冊排程工作 {0}：每天 09:00（狀態 {1}）" -f $taskName, $t.State) -ForegroundColor Green
    Write-Host '  立即跑一次：' -ForegroundColor DarkGray
    Write-Host ("    powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"") -ForegroundColor DarkGray
    exit 0
}

# ---------- 收集事實 ----------
Say '' 
Say '=== AVG 搬移後續檢查 ===' 'Cyan'
Say ("  觀察期門檻：{0} 天；定義最多 {1} 天未更新就視為異常" -f $MinDays, $MaxDefAgeDays) 'DarkGray'

$results = New-Object System.Collections.ArrayList
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    Say ("  [{0}] {1}：{2}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $name, $detail) `
        $(if ($ok) { 'Green' } else { 'Red' })
}

# 1) junction
$item = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
$isLink = $item -and $item.LinkType
$target = if ($isLink) { @($item.Target)[0] } else { '' }
$linkOk = $isLink -and ($target -and ($target.TrimEnd('\') -ieq $expectedTo))
Add-Check 'junction 存在且目標正確' $linkOk `
    $(if ($isLink) { "$($item.LinkType) -> $target" } elseif ($item) { '實體目錄（AVG 可能重建回 C:）' } else { '路徑不存在（AVG 被移除？）' })

# 2) 服務
$svc = Get-Service -Name 'AVG Antivirus' -ErrorAction SilentlyContinue
$svcOk = $svc -and $svc.Status -eq 'Running'
Add-Check 'AVG 服務執行中' ([bool]$svcOk) $(if ($svc) { $svc.Status.ToString() } else { '服務不存在' })

# 3) 定義新舊（透過 C: 路徑讀 = 透過 junction 讀 D:）
$defRoot = Join-Path $linkPath 'Antivirus\defs'
$newestDef = $null
if (Test-Path -LiteralPath $defRoot) {
    $newestDef = Get-ChildItem -LiteralPath $defRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*_stream' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
$defOk = $false
$defDetail = '找不到定義目錄'
if ($newestDef) {
    $ageDays = ((Get-Date) - $newestDef.LastWriteTime).TotalDays
    $defOk = $ageDays -le $MaxDefAgeDays
    $defDetail = ("{0}，{1:N1} 天前更新" -f $newestDef.Name, $ageDays)
}
Add-Check '病毒定義是最新的' $defOk $defDetail

# 4) 定義實際落在 D:
$defOnD = Join-Path $expectedTo 'Antivirus\defs'
$newestOnD = $null
if (Test-Path -LiteralPath $defOnD) {
    $newestOnD = Get-ChildItem -LiteralPath $defOnD -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
$onDOk = $false
$onDDetail = 'D: 上找不到定義檔'
if ($newestOnD) {
    $dAge = ((Get-Date) - $newestOnD.LastWriteTime).TotalDays
    $onDOk = $dAge -le $MaxDefAgeDays
    $onDDetail = ("{0}（{1:N1} 天前）" -f $newestOnD.Name, $dAge)
}
Add-Check '定義寫在 D:' $onDOk $onDDetail

# 5) 安全性中心登記的路徑
$wscOk = $false
$wscDetail = '查不到安全性中心資訊'
try {
    $av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
        Where-Object { $_.displayName -match 'AVG' } | Select-Object -First 1
    if ($av) {
        $wscOk = $av.pathToSignedProductExe -like "$expectedTo*"
        $wscDetail = $av.pathToSignedProductExe
    }
} catch { }
Add-Check '安全性中心登記路徑在 D:' $wscOk $wscDetail

# ---------- 觀察期 ----------
$baks = @(Get-ChildItem -LiteralPath 'C:\Program Files' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'AVG.bak-*' })
$elapsedDays = $null
if ($baks.Count -gt 0 -and $baks[0].Name -match '(\d{8}-\d{6})') {
    $stampText = $Matches[1]
    $moveTime = [datetime]::ParseExact($stampText, 'yyyyMMdd-HHmmss', $null)
    $elapsedDays = ((Get-Date) - $moveTime).TotalDays
    Say ("  備份存在：{0}（{1:N1} MB），搬移於 {2:yyyy-MM-dd HH:mm}，已過 {3:N1} 天" -f `
        $baks[0].Name, ((SizeOf $baks[0].FullName) / 1MB), $moveTime, $elapsedDays) 'DarkGray'
} elseif ($baks.Count -eq 0) {
    Say '  找不到 AVG.bak-* 備份（已經刪掉了？）' 'Yellow'
}

# ---------- 結論 ----------
$failCount = @($results | Where-Object { -not $_.Ok }).Count
$periodOk = ($null -ne $elapsedDays) -and ($elapsedDays -ge $MinDays)
Say ''
Say '=== 結論 ===' 'Cyan'

$verdict = ''
$exitCode = 1
if ($failCount -gt 0) {
    $verdict = 'PROBLEM'
    $exitCode = 2
    Say ("  PROBLEM：有 {0} 項不成立，**不要刪備份**。" -f $failCount) 'Red'
    $results | Where-Object { -not $_.Ok } | ForEach-Object { Say ("    - {0}：{1}" -f $_.Name, $_.Detail) 'Red' }
    Say ''
    Say '  若 junction 不見了或定義停止更新，代表 AVG 不接受這個擺法，請還原：' 'Yellow'
    Say '    1) 進安全模式' 'Yellow'
    Say ("    2) cmd /c rmdir `"{0}`"" -f $linkPath) 'Yellow'
    Say ("    3) Rename-Item -LiteralPath '{0}' -NewName 'AVG'" -f ($baks[0].FullName)) 'Yellow'
} elseif (-not $periodOk) {
    $verdict = 'WAIT'
    $exitCode = 1
    if ($null -eq $elapsedDays) {
        Say '  WAIT：找不到備份，無法推算觀察期（可能已刪除）。' 'Yellow'
    } else {
        Say ("  WAIT：五項檢查全過，但觀察期還差 {0:N1} 天（已過 {1:N1} / {2} 天）。" -f ($MinDays - $elapsedDays), $elapsedDays, $MinDays) 'Yellow'
        Say ("  最快可以刪的日期：{0:yyyy-MM-dd HH:mm}" -f $moveTime.AddDays($MinDays)) 'DarkGray'
    }
} else {
    $verdict = 'OK'
    $exitCode = 0
    Say ("  OK：五項全過，觀察期已滿（{0:N1} 天）。**可以刪備份了。**" -f $elapsedDays) 'Green'
    foreach ($b in $baks) {
        Say ''
        Say ("  備份：{0}（{1:N1} MB）" -f $b.FullName, ((SizeOf $b.FullName) / 1MB)) 'Green'
        Say '  刪除步驟（avgSP 會保護 AVG 檔案，先提權試，被擋再進安全模式）：' 'DarkGray'
        Say ("    1) 提權後執行： Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $b.FullName) 'DarkGray'
        Say '    2) 若出現「拒絕存取」，進安全模式再執行同一行' 'DarkGray'
        Say '    3) 刪完後移除每日檢查：check-avg-migration.ps1 -UnregisterTask' 'DarkGray'
    }
}

# ---------- 寫狀態檔 ----------
$backupPath = $null
$backupMB = $null
if ($baks.Count -gt 0) {
    $backupPath = $baks[0].FullName
    $backupMB = [math]::Round((SizeOf $baks[0].FullName) / 1MB, 1)
}
$elapsedRounded = $null
if ($null -ne $elapsedDays) { $elapsedRounded = [math]::Round($elapsedDays, 2) }

$state = [pscustomobject]@{
    checkedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    verdict     = $verdict
    elapsedDays = $elapsedRounded
    minDays     = $MinDays
    checks      = @($results | ForEach-Object { [pscustomobject]@{ name = $_.Name; ok = $_.Ok; detail = $_.Detail } })
    backup      = $backupPath
    backupMB    = $backupMB
}
try {
    # PS 5.1 的 ConvertTo-Json 會把 < > & 轉成 \u003c 之類，狀態檔是給人看的，還原成原字元
    $json = $state | ConvertTo-Json -Depth 5
    $json = $json -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
    [IO.File]::WriteAllText($stateFile, $json, (New-Object Text.UTF8Encoding($false)))
    Say ''
    Say ("狀態檔：{0}" -f $stateFile) 'DarkGray'
} catch { }

Say ("日誌：{0}" -f $logFile) 'DarkGray'
exit $exitCode
