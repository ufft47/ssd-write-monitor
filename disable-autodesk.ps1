#Requires -Version 5.1
<#
.SYNOPSIS
    關閉 Autodesk Access 更新服務（本機沒有安裝任何 Autodesk 產品，它只是在更新自己）。

.DESCRIPTION
    2026-11-15 實測：AdODIS-installer 當日在 C: 寫入 1.87 GB，佔 C: 可歸因寫入的 36%。
    但這台機器只裝了「Autodesk Access 2.4.0.119」（更新器本身）與 Autodesk Identity Manager，
    沒有任何 Autodesk 產品 —— 所以這些寫入沒有實際用途。

    本腳本只動一個服務：
      - 停止執行中的「Autodesk Access Service Host」
      - 把啟動類型改成 Disabled（預設）或 Manual
      - 不刪任何檔案、不動登錄檔、不移除程式

.PARAMETER Mode
    Disabled（預設）：開機不啟動，任何程式也無法按需啟動
    Manual          ：開機不啟動，但有程式要求時仍可被啟動

.PARAMETER DryRun
    只顯示目前狀態與會做什麼，不動任何東西（不需要管理員權限）。

.PARAMETER Revert
    還原成「執行中 + 自動啟動」

.EXAMPLE
    # 提權執行（會跳 UAC）
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\disable-autodesk.ps1'

.EXAMPLE
    # 還原
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\disable-autodesk.ps1','-Revert'
#>
param(
    [switch]$Revert,
    [switch]$DryRun,
    [ValidateSet('Disabled', 'Manual', 'Automatic')]
    [string]$Mode = 'Disabled'
)

$ErrorActionPreference = 'Stop'
$svcName = 'Autodesk Access Service Host'
$root = 'D:\dev\disk-monitor'
$logDir = Join-Path $root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupFile = Join-Path $logDir "autodesk-service-before-$stamp.txt"

function Write-Step([string]$m) { Write-Host "  $m" }

# ---------- 前置檢查 ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host ''
    Write-Host '需要管理員權限。請改用：' -ForegroundColor Red
    Write-Host "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath'" -ForegroundColor Yellow
    Write-Host ''
    exit 1
}
if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) {
    Write-Host "找不到服務：$svcName（可能已移除）" -ForegroundColor Red
    exit 2
}

if ($DryRun) {
    Write-Host ''
    Write-Host '（DryRun：只顯示現況，不動任何東西）' -ForegroundColor Yellow
    $cur = Get-CimInstance Win32_Service -Filter "Name='Autodesk Access Service Host'"
    Write-Host ''
    Write-Host '=== 現況 ===' -ForegroundColor Cyan
    Write-Host ("  服務名稱 : {0}" -f $cur.Name)
    Write-Host ("  狀態     : {0}" -f $cur.State)
    Write-Host ("  啟動類型 : {0}" -f $cur.StartMode)
    Write-Host ("  執行身分 : {0}" -f $cur.StartName)
    Write-Host ("  執行檔   : {0}" -f $cur.PathName)
    $curProc = @(Get-Process -Name 'AdODIS-installer', 'AdskAccessServiceHost', 'AdODIS' -ErrorAction SilentlyContinue)
    Write-Host ("  相關進程 : {0}" -f $(if ($curProc.Count -eq 0) { '無' } else {
        ($curProc | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ' }))
    Write-Host ''
    if ($Revert) {
        Write-Host '會做：啟動類型 -> Automatic、啟動服務' -ForegroundColor DarkGray
    } else {
        Write-Host "會做：結束 AdODIS 相關進程、停止服務、啟動類型 -> $Mode" -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
}

# ---------- 備份現況（台帳用）----------
$before = Get-CimInstance Win32_Service -Filter "Name='Autodesk Access Service Host'"
$snapshot = @"
# Autodesk Access Service Host — 變更前快照
# 時間: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# 執行身分: $($id.Name)

Name        : $($before.Name)
DisplayName : $($before.DisplayName)
State       : $($before.State)
StartMode   : $($before.StartMode)
StartName   : $($before.StartName)
PathName    : $($before.PathName)

# 還原指令（提權）：
#   Set-Service -Name '$svcName' -StartupType Automatic
#   Start-Service -Name '$svcName'
"@
[IO.File]::WriteAllText($backupFile, $snapshot, (New-Object Text.UTF8Encoding($true)))
Write-Host "變更前快照已存: $backupFile" -ForegroundColor DarkGray

# ---------- 執行 ----------
if ($Revert) {
    Write-Host ''
    Write-Host '=== 還原 Autodesk Access Service Host ===' -ForegroundColor Cyan
    Write-Step "啟動類型 -> Automatic"
    Set-Service -Name $svcName -StartupType Automatic
    Write-Step "啟動服務"
    Start-Service -Name $svcName -ErrorAction SilentlyContinue
    $target = 'Automatic'
} else {
    Write-Host ''
    Write-Host "=== 關閉 Autodesk Access Service Host（$Mode）===" -ForegroundColor Cyan
    Write-Step '先結束執行中的 Autodesk 更新進程（若有）'
    foreach ($pn in @('AdODIS-installer', 'AdskAccessServiceHost', 'AdODIS')) {
        Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Step ("  kill {0} (pid {1})" -f $_.ProcessName, $_.Id)
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Step "停止服務"
    Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Step "啟動類型 -> $Mode"
    Set-Service -Name $svcName -StartupType $Mode
    $target = $Mode
}

# ---------- 驗證（看結果，不看動作）----------
Start-Sleep -Seconds 1
$after = Get-CimInstance Win32_Service -Filter "Name='Autodesk Access Service Host'"
$ok = ($after.StartMode -eq $target)
if ($Revert) { $ok = $ok -and ($after.State -eq 'Running') } else { $ok = $ok -and ($after.State -ne 'Running') }

Write-Host ''
Write-Host '=== 驗證 ===' -ForegroundColor Cyan
Write-Host ("  服務狀態 : {0}" -f $after.State)
Write-Host ("  啟動類型 : {0}" -f $after.StartMode)
$left = @(Get-Process -Name 'AdODIS-installer', 'AdskAccessServiceHost', 'AdODIS' -ErrorAction SilentlyContinue)
Write-Host ("  殘留進程 : {0}" -f $(if ($left.Count -eq 0) { '無' } else { ($left | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ' }))
Write-Host ''
if ($ok) {
    Write-Host '結果: 完成' -ForegroundColor Green
} else {
    Write-Host '結果: 未達預期，請看上面的狀態' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '還原方式（提權執行）：' -ForegroundColor DarkGray
Write-Host "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Revert'" -ForegroundColor DarkGray
Write-Host ''
