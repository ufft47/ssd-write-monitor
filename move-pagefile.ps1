#Requires -Version 5.1
<#
.SYNOPSIS
    把主分頁檔（pagefile.sys）從 C: 搬到 D:，C: 只保留足夠產生小記憶體傾印的大小。

.DESCRIPTION
    2026-11-15 實測本機狀態：
      C:\pagefile.sys            24,576 MB（Initial=Maximum=24576，固定大小、非稀疏 → 實際佔用 24 GB）
      AutomaticManagedPagefile  False（手動固定，不是系統自動管理）
      峰值使用                  5,449 MB
      CrashDumpEnabled          3 = 小記憶體傾印 → 開機磁碟上的分頁檔只需約 2 GB
      C: 所在磁碟               Disk 0 = CT500MX500SSD1（SATA）
      D: 所在磁碟               Disk 3 = GIGABYTE GP-GSM2NE3512GNTD（NVMe）

    因此把主分頁檔移到 D: 可以：
      1. C: 少佔 24,576 - 2,048 = 22,528 MB（約 22 GB）
      2. 分頁 I/O 從 SATA 移到 NVMe
      3. 保留小記憶體傾印能力（C: 仍留 2 GB）

    作法：修改
      HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PagingFiles
    這個值是 REG_MULTI_SZ，每一行形如 "磁碟:\pagefile.sys 初始MB 最大MB"。
    修改後**必須重新開機**才會生效（Windows 在開機時建立／調整分頁檔）。

    注意：本腳本不會、也不能「關閉」分頁檔。C: 永遠保留一個最小的分頁檔，
    因為核心記憶體傾印需要開機磁碟上有分頁檔。

.PARAMETER DryRun
    只顯示目前設定與預計變更，不動任何東西（不需要管理員權限）。

.PARAMETER CDumpMB
    C: 保留的分頁檔大小（MB），預設 2048。小記憶體傾印只需約 2 GB。

.PARAMETER DInitialMB
    D: 分頁檔初始大小（MB），預設 8192（實測峰值 5,449 MB，留餘裕）。

.PARAMETER DMaxMB
    D: 分頁檔上限（MB），預設 16384。

.PARAMETER Verify
    重新開機後檢查實際生效狀態（唯讀）。

.PARAMETER Revert
    還原成變更前的設定（從 logs\pagefile-before-*.txt 讀回），需重新開機。

.EXAMPLE
    # 先看會做什麼
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\move-pagefile.ps1 -DryRun

.EXAMPLE
    # 套用（提權，之後重新開機）
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\move-pagefile.ps1'

.EXAMPLE
    # 重開機後驗證
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\move-pagefile.ps1','-Verify'

.EXAMPLE
    # 還原
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\move-pagefile.ps1','-Revert'
#>
param(
    [switch]$DryRun,
    [switch]$Verify,
    [switch]$Revert,
    [int]$CDumpMB = 2048,
    [int]$DInitialMB = 8192,
    [int]$DMaxMB = 16384
)

$ErrorActionPreference = 'Stop'

$mmKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$logDir    = 'D:\dev\disk-monitor\logs'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile   = Join-Path $logDir "pagefile-$stamp.log"

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8
}
function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Read-PagingFiles {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($mmKeyPath, $false)
    if (-not $k) { return @() }
    $v = $k.GetValue('PagingFiles', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $k.Close()
    if ($null -eq $v) { return @() }
    return [string[]]$v
}
function Write-PagingFiles([string[]]$lines) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($mmKeyPath, $true)
    if (-not $k) { throw "無法開啟登錄鍵：HKLM\$mmKeyPath" }
    $k.SetValue('PagingFiles', [string[]]$lines, [Microsoft.Win32.RegistryValueKind]::MultiString)
    $k.Flush()
    $k.Close()
}
function Get-PagefileUsage {
    return @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
}

Say ''
Say "=== 分頁檔搬到 D:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { Say '（DryRun：只顯示，不動任何東西）' 'Yellow' }

$current = Read-PagingFiles
$autoManaged = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
$dumpMode = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue).CrashDumpEnabled
$dumpMap = @{ 0 = '無'; 1 = '完整記憶體傾印'; 2 = '核心記憶體傾印'; 3 = '小記憶體傾印'; 7 = '自動記憶體傾印' }

Say ''
Say '--- 目前設定 ---' 'Cyan'
Say ("  AutomaticManagedPagefile : {0}" -f $autoManaged)
Say ("  CrashDumpEnabled         : {0}（{1}）" -f $dumpMode, $dumpMap[[int]$dumpMode])
if ($current.Count -eq 0) {
    Say '  PagingFiles              : （空值 —— 表示沒有分頁檔，這不正常）' 'Red'
} else {
    foreach ($l in $current) { Say ("  PagingFiles              : {0}" -f $l) }
}
foreach ($u in (Get-PagefileUsage)) {
    Say ("  實際使用                 : {0} 配置 {1:N0} MB 峰值 {2:N0} MB 目前 {3:N0} MB" -f `
        $u.Name, $u.AllocatedBaseSize, $u.PeakUsage, $u.CurrentUsage) 'DarkGray'
}
$cFree = (Get-PSDrive -Name C).Free
Say ("  C: 可用                  : {0:N1} GB" -f ($cFree / 1GB))

$newLines = @(
    ("c:\pagefile.sys {0} {0}" -f $CDumpMB),
    ("d:\pagefile.sys {0} {1}" -f $DInitialMB, $DMaxMB)
)
$cNowMB = [int64]0
foreach ($l in $current) {
    if ($l -match '^\s*c:\\pagefile\.sys\s+(\d+)') { $cNowMB += [int64]$Matches[1] }
}
$savingMB = $cNowMB - $CDumpMB
if ($savingMB -le 0) { $savingMB = 0 }

# ---------- Verify（重開機後檢查）----------
if ($Verify) {
    Say ''
    Say '--- 驗證（看實際生效狀態，不看設定檔）---' 'Cyan'
    $usages = Get-PagefileUsage
    if ($usages.Count -eq 0) {
        Say '  找不到任何分頁檔！請立刻檢查設定。' 'Red'
        exit 3
    }
    $hasD = $false
    $cAlloc = 0
    foreach ($u in $usages) {
        Say ("  {0,-18} 配置 {1,8:N0} MB   峰值 {2,8:N0} MB   目前 {3,8:N0} MB" -f `
            $u.Name, $u.AllocatedBaseSize, $u.PeakUsage, $u.CurrentUsage) 'Green'
        if ($u.Name -like 'd:*') { $hasD = $true }
        if ($u.Name -like 'c:*') { $cAlloc = [int64]$u.AllocatedBaseSize }
    }
    Say ''
    Say ("  D: 分頁檔存在 : {0}" -f $(if ($hasD) { '是' } else { '否 —— 設定沒生效，重開機了嗎？' })) $(if ($hasD) { 'Green' } else { 'Red' })
    Say ("  C: 分頁檔大小 : {0:N0} MB（預期 {1} MB）" -f $cAlloc, $CDumpMB) $(if ($cAlloc -eq $CDumpMB) { 'Green' } else { 'Yellow' })
    $cFreeNow = (Get-PSDrive -Name C).Free
    Say ("  C: 可用       : {0:N1} GB" -f ($cFreeNow / 1GB))
    if ($hasD -and $cAlloc -eq $CDumpMB) {
        Say ''
        Say '  完成：主分頁檔已在 D:，C: 只留傾印用的最小分頁檔。' 'Green'
        exit 0
    } else {
        Say ''
        Say '  尚未生效。若剛改完設定，請重新開機後再跑一次 -Verify。' 'Yellow'
        exit 1
    }
}

# ---------- Revert ----------
if ($Revert) {
    Say ''
    Say '--- 還原到變更前 ---' 'Cyan'
    $snap = Get-ChildItem -LiteralPath $logDir -Filter 'pagefile-before-*.txt' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $snap) {
        Say '  找不到 logs\pagefile-before-*.txt 備份，無法自動還原。' 'Red'
        Say '  手動還原：把 PagingFiles 設回 c:\pagefile.sys 24576 24576，然後重新開機。' 'Yellow'
        exit 2
    }
    $lines = @(Get-Content -LiteralPath $snap.FullName -Encoding UTF8 | Where-Object { $_ -match '\S' })
    Say ("  從 {0} 讀回：{1}" -f $snap.Name, ($lines -join ' / '))
    if ($DryRun) {
        Say '（DryRun）會把 PagingFiles 設成上面那個值，然後需要重新開機' 'Yellow'
        exit 0
    }
    if (-not (IsAdmin)) { Say '需要管理員權限。' 'Red'; exit 1 }
    Write-PagingFiles $lines
    Say '  已寫回登錄檔。請重新開機讓它生效。' 'Green'
    Say ("  目前值：{0}" -f ((Read-PagingFiles) -join ' / '))
    exit 0
}

# ---------- DryRun ----------
if ($DryRun) {
    Say ''
    Say '--- 預計變更 ---' 'Cyan'
    Say '  PagingFiles 會改成：'
    foreach ($l in $newLines) { Say ("    {0}" -f $l) 'Yellow' }
    Say ''
    Say ("  C: 分頁檔 {0:N0} MB -> {1:N0} MB（省 {2:N0} MB ≈ {3:N1} GB）" -f `
        $cNowMB, $CDumpMB, $savingMB, ($savingMB / 1024))
    Say ("  D: 新增分頁檔 {0:N0} MB（上限 {1:N0} MB）" -f $DInitialMB, $DMaxMB)
    Say ''
    Say '  注意：要重新開機才會生效；重開機後跑 -Verify 確認。' 'Yellow'
    Say ''
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}

# ---------- 套用 ----------
if (-not (IsAdmin)) {
    Say ''
    Say '需要管理員權限。請改用：' 'Red'
    Say ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath'") 'Yellow'
    exit 1
}
if ($autoManaged) {
    Say ''
    Say 'AutomaticManagedPagefile 是 True，Windows 會蓋掉手動設定。' 'Red'
    Say '請先用系統內容 → 進階 → 效能 → 進階 → 虛擬記憶體 取消「自動管理」。' 'Yellow'
    exit 2
}
if (-not (Test-Path -LiteralPath 'D:\')) {
    Say ''
    Say 'D: 不存在，中止。' 'Red'
    exit 2
}
if ($CDumpMB -lt 800) {
    Say ''
    Say ('C: 保留的 {0} MB 太小，小記憶體傾印可能無法產生（建議 >= 800）。' -f $CDumpMB) 'Red'
    exit 2
}

# 備份現況（還原用）
$snapFile = Join-Path $logDir "pagefile-before-$stamp.txt"
[IO.File]::WriteAllText($snapFile, (($current -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
Say ''
Say ("  已備份目前設定：{0}" -f $snapFile) 'DarkGray'

Say ''
Say '--- 寫入新設定 ---' 'Cyan'
Write-PagingFiles $newLines
$after = Read-PagingFiles
Say ("  登錄檔目前值：" ) 'DarkGray'
foreach ($l in $after) { Say ("    {0}" -f $l) 'Green' }

$ok = ($after.Count -eq 2) -and ($after -contains ("c:\pagefile.sys {0} {0}" -f $CDumpMB)) -and
      ($after -contains ("d:\pagefile.sys {0} {1}" -f $DInitialMB, $DMaxMB))
Say ''
if ($ok) {
    Say '  設定已寫入（但還沒生效 —— 分頁檔在開機時才重建）' 'Green'
    Say ''
    Say '接下來：' 'Cyan'
    Say '  1) 重新開機' 'Green'
    Say "  2) 開機後驗證：" 'Green'
    Say "     Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Verify'" 'Green'
    Say ("  預期：C: 少佔 {0:N0} MB（約 {1:N1} GB）" -f $savingMB, ($savingMB / 1024)) 'Green'
    Say ("  還原：把 $snapFile 的值寫回（或跑 -Revert）後重新開機") 'DarkGray'
} else {
    Say '  寫入後讀回的值與預期不符，請檢查上面的實際值。' 'Red'
    Say ("  備份仍在：$snapFile") 'Yellow'
    exit 3
}
Say ''
Say ("日誌：$logFile") 'DarkGray'
Say ''
