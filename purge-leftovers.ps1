#Requires -Version 5.1
<#
.SYNOPSIS
    清理今天搬移留下的 AVG / ASUS 殘留（逐項嘗試並回報結果）。

.DESCRIPTION
    2026-11-15 的殘留清單：

      C:\ProgramData\ASUS\AsusIME\log.bak-20261115-061446   259.8 MB  ASUS 日誌搬家時的舊副本
      C:\ProgramData\AVG.bak-20261115-075503              1,057.1 MB  舊 AVG ProgramData
      D:\MX500\avg\ProgramData                            1,056.5 MB  AVG 重建後留下的孤兒
      %USERPROFILE%\AppData\Local\AVG\Browser              360.8 MB  AVG Browser 已被移除，留下的 User Data

    為什麼需要這支腳本（一個實測修正）：
    先前把「刪不掉」全部歸因於 AVG 自我保護（avgSP）。實際上**至少兩項只是權限問題** ——
    助手是以 `<user>`（非管理員）執行，而：

      C:\ProgramData\ASUS\...\log.bak-...    Users = ReadAndExecute + Write（**沒有 Delete**）
      C:\ProgramData\AVG.bak-...             Users = ReadAndExecute（沒有 Delete）

    所以那兩項只要**提權**就能刪，不必進安全模式。
    真正可能被 avgSP 擋的是 `AppData\Local\AVG\Browser`（自己的目錄，非管理員也該能刪，卻失敗）
    與 `D:\MX500\avg\ProgramData`（Users 有 Modify，卻卡在 vault.db）。
    這兩項提權後再試一次就能分辨「權限」還是「自我保護」。

    腳本會逐項嘗試、逐項回報，刪不掉的會說明下一步（安全模式）。

.PARAMETER KeepProgramFilesBackup
    保留 `C:\Program Files\AVG.bak-*`（預設就是保留，此參數只讓意圖更明確）。

.PARAMETER DryRun
    只列出會刪什麼，不動任何東西（不需管理員）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\purge-leftovers.ps1 -DryRun

.EXAMPLE
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\purge-leftovers.ps1'
#>
param(
    [switch]$KeepProgramFilesBackup,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$targets = @(
    @{ Path = 'C:\ProgramData\ASUS\AsusIME\log.bak-20261115-061446'; Why = 'ASUS 日誌搬家時的舊副本（現行 log 已是 junction → D:）' },
    @{ Path = 'C:\ProgramData\AVG.bak-20261115-075503';               Why = '舊 AVG ProgramData（AVG 已重建新目錄）' },
    @{ Path = 'D:\MX500\avg\ProgramData';                             Why = 'AVG 重建後留下的孤兒（無任何程式引用）' },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'AVG\Browser');             Why = 'AVG Browser 已被 AVG 移除，留下的 User Data' }
)

$logDir  = 'D:\dev\disk-monitor\logs'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "purge-leftovers-$stamp.log"
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    try { Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8 -ErrorAction Stop } catch { }
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
function Get-ReparsePoints([string]$root) {
    return @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
}

Say ''
Say "=== 清理殘留  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Say ("  身分 : {0} / 管理員={1}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, (IsAdmin)) 'DarkGray'
if ($DryRun) { Say '（DryRun：只列出，不動任何東西）' 'Yellow' }

$before = @{}
Get-PSDrive C, D | ForEach-Object { $before[$_.Name] = $_.Free }
$total = 0

foreach ($t in $targets) {
    Say ''
    if (-not (Test-Path -LiteralPath $t.Path)) {
        Say ("  [已不存在] {0}" -f $t.Path) 'Green'
        continue
    }
    $mb = (SizeOf $t.Path) / 1MB
    $rp = Get-ReparsePoints $t.Path
    Say ("  {0:N1} MB  {1}" -f $mb, $t.Path)
    Say ("            {0}" -f $t.Why) 'DarkGray'
    if ($rp.Count -gt 0) {
        Say ("            含 {0} 個嵌套 junction，**跳過**（避免跟進刪掉別人的資料）" -f $rp.Count) 'Red'
        continue
    }
    if ($DryRun) { Say '            （DryRun）會刪除' 'Yellow'; continue }
    if (-not (IsAdmin) -and $t.Path -like 'C:\ProgramData\*') {
        Say '            需要管理員權限（ProgramData 底下 Users 只有 Write，沒有 Delete）' 'Red'
        continue
    }
    try {
        Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
        Say ("            已刪除（{0:N0} MB）" -f $mb) 'Green'
        $total += $mb
    } catch {
        $msg = $_.Exception.Message
        Say ("            刪除失敗：{0}" -f $msg) 'Red'
        if ($msg -match '拒絕存取|Access is denied|denied') {
            Say '            → 若已提權仍失敗，就是 AVG 自我保護（avgSP）擋的，只能在安全模式刪' 'Yellow'
        }
    }
}

Say ''
Say '=== 複查 ==='
foreach ($t in $targets) {
    Say ("  {0,-58} 存在={1}" -f $t.Path, (Test-Path -LiteralPath $t.Path)) `
        $(if (Test-Path -LiteralPath $t.Path) { 'Yellow' } else { 'Green' })
}
Say ''
Say '=== 保留（不刪）==='
Get-ChildItem -LiteralPath 'C:\Program Files' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'AVG.bak-*' } |
    ForEach-Object { Say ("  {0:N1} MB  {1}（正在使用的 junction 的退路，確認 AVG 穩定幾天才刪）" -f ((SizeOf $_.FullName) / 1MB), $_.FullName) 'DarkGray' }

Say ''
Say '=== 空間 ==='
Get-PSDrive C, D | ForEach-Object {
    Say ('  {0}: 可用 {1:N2} GB（+{2:N2} GB）' -f $_.Name, ($_.Free / 1GB), (($_.Free - $before[$_.Name]) / 1GB))
}
Say ('  本次合計刪除 {0:N0} MB' -f $total)
Say ''
Say ("日誌：$logFile") 'DarkGray'
Say ''
