#Requires -Version 5.1
<#
.SYNOPSIS
    指定「下一次開機進入安全模式」，或取消它。

.DESCRIPTION
    為什麼需要這支：本機的 WinRE（修復環境）映像不存在，
      C:\Windows\System32\Recovery\Winre.wim   不存在
      C:\Recovery\WindowsRE\Winre.wim          不存在
    所以「Shift + 開始 → 電源 → 重新啟動 → 疑難排解 → 啟動設定」走不通 ——
    「進階啟動」選單是 WinRE 提供的，映像不在就只會正常重開機。
    （2026-11-15 實測：06:44 / 06:58 / 07:10 三次都是 RuntimeBroker 發起的正常重新啟動）

    【優先建議：用 msconfig，比這支腳本更不容易出錯】
      Win+R → 輸入 msconfig → 「開機」頁 → 勾「安全開機」→ 套用 → 確定 → 重新啟動
      做完事後回去取消勾選，再重新啟動。

    【本腳本的實測限制（重要）】
    這台機器的 bcdedit 對 `{current}` 與 `{default}` 會回「指定的命令列選項無效」，
    只有 `{bootmgr}` 被接受：
        bcdedit /enum {current}            → 指定的命令列選項無效
        bcdedit /enum {default}            → 指定的命令列選項無效
        bcdedit /deletevalue {current} safeboot → 指定的參數識別碼無效
        bcdedit /enum {bootmgr}            → 存取被拒（參數本身可被接受）
    所以本腳本**不使用 {current}**，改成先 `/enum ACTIVE` 讀出開機項目的真實 GUID，
    再用 GUID 下 `/set` 與 `/deletevalue`。
    bcdedit 的輸出在中文版是本地化的，因此解析時只用兩個線索：
      - 36 字元的 GUID 樣式
      - 含 `safeboot` 的那一行
    並且一律把原始輸出印出來，讓人可以自己看。

.PARAMETER Enter
    設定下一次開機進安全模式（預設 minimal，不含網路）。

.PARAMETER Exit
    清除 safeboot（回到正常開機）。

.PARAMETER Status
    只顯示目前狀態（唯讀）。

.PARAMETER Network
    搭配 -Enter：安全模式含網路功能。

.PARAMETER DryRun
    只顯示會執行什麼指令。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\safemode.ps1 -Status

.EXAMPLE
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\safemode.ps1','-Enter'

.EXAMPLE
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\safemode.ps1','-Exit'
#>
param(
    [switch]$Enter,
    [switch]$Exit,
    [switch]$Status,
    [switch]$Network,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$logDir  = 'D:\dev\disk-monitor\logs'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "safemode-$stamp.log"
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8
}
function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function BootState {
    try { return (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState }
    catch { return 'Unknown' }
}
# 讀「使用中的開機項目」：回傳 @{ Ok; Guid; SafeBoot; Raw }
function Get-ActiveEntry {
    $raw = @(& bcdedit.exe /enum ACTIVE 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return [pscustomobject]@{ Ok = $false; Guid = $null; SafeBoot = $null; Raw = $raw; Code = $code }
    }
    $guid = $null
    $sb = $null
    foreach ($line in $raw) {
        if (-not $guid -and $line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $guid = $Matches[1]
        }
        if (-not $sb -and $line -match 'safeboot\s+(\S+)') { $sb = $Matches[1] }
    }
    return [pscustomobject]@{ Ok = $true; Guid = $guid; SafeBoot = $sb; Raw = $raw; Code = $code }
}

if (-not ($Enter -or $Exit -or $Status)) {
    Write-Host '請指定 -Enter（進安全模式）/ -Exit（取消）/ -Status（查看）' -ForegroundColor Yellow
    exit 0
}

Say ''
Say "=== 安全模式開機設定  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Say ("  目前開機狀態 : {0}" -f (BootState)) 'DarkGray'

$active = Get-ActiveEntry
if (-not $active.Ok) {
    Say '  讀取開機設定失敗（非管理員時是預期行為）——原始輸出：' 'Yellow'
    $active.Raw | Select-Object -First 3 | ForEach-Object { Say ("    {0}" -f $_) 'DarkGray' }
} else {
    Say ("  使用中開機項目 : {0}" -f $active.Guid) 'DarkGray'
    Say ("  目前 safeboot  : {0}" -f $(if ($active.SafeBoot) { $active.SafeBoot } else { '（未設定，正常開機）' })) 'DarkGray'
}

if ($Status) {
    if ($active.Ok) {
        Say ''
        Say '  --- bcdedit /enum ACTIVE 原始輸出 ---' 'DarkGray'
        $active.Raw | ForEach-Object { Say ("    {0}" -f $_) 'DarkGray' }
    }
    Say ''
    Say '（-Status 只讀，未做任何變更）' 'DarkGray'
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}

if (-not (IsAdmin) -and -not $DryRun) {
    Say ''
    Say '需要管理員權限。請改用：' 'Red'
    $arg = if ($Enter) { '-Enter' } else { '-Exit' }
    Say ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','$arg'") 'Yellow'
    exit 1
}

if (-not $active.Ok -and -not $DryRun) {
    Say ''
    Say '  連管理員都讀不到開機設定，無法繼續。' 'Red'
    exit 2
}

$guid = $active.Guid

# ---------- 取消 ----------
if ($Exit) {
    $cmd = @('bcdedit.exe', '/deletevalue', $guid, 'safeboot')
    Say ''
    Say ("  要執行：{0}" -f ($cmd -join ' ')) 'DarkGray'
    if ($DryRun) { Say '（DryRun）不會執行' 'Yellow'; exit 0 }
    $out = @(& bcdedit.exe /deletevalue $guid safeboot 2>&1)
    $code = $LASTEXITCODE
    $out | ForEach-Object { Say ("    {0}" -f $_) }
    Say ("  bcdedit 結束碼 {0}" -f $code) $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
    Start-Sleep -Milliseconds 500
    $after = Get-ActiveEntry
    Say ''
    if ($after.Ok -and -not $after.SafeBoot) {
        Say '  已清除 safeboot：下一次開機會是正常模式。' 'Green'
    } elseif ($after.Ok -and $after.SafeBoot) {
        Say ("  safeboot 仍是「{0}」。請把上面的原始輸出貼回來，或改用 msconfig 取消勾選。" -f $after.SafeBoot) 'Red'
    } else {
        Say '  無法驗證（讀不到開機設定）。請用 msconfig 確認「安全開機」沒有被勾選。' 'Yellow'
    }
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}

# ---------- 設定 ----------
if ($Enter) {
    $mode = 'minimal'
    if ($Network) { $mode = 'network' }
    $cmd = @('bcdedit.exe', '/set', $guid, 'safeboot', $mode)
    Say ''
    Say ("  要執行：{0}" -f ($cmd -join ' ')) 'DarkGray'
    Say ("  模式：{0}" -f $(if ($Network) { '安全模式（含網路功能）' } else { '安全模式（不含網路）' })) 'DarkGray'

    $bl = $null
    try { $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop } catch { $bl = $null }
    if ($bl) {
        Say ("  BitLocker：{0} / 保護 {1}" -f $bl.VolumeStatus, $bl.ProtectionStatus) `
            $(if ($bl.ProtectionStatus -eq 'On') { 'Red' } else { 'Green' })
        if ($bl.ProtectionStatus -eq 'On') {
            Say '  注意：BitLocker 保護中，改開機設定後可能要輸入修復金鑰。請先確認拿得到金鑰。' 'Red'
        }
    } else {
        Say '  BitLocker：查不到（通常代表未啟用，或需要管理員權限）' 'DarkGray'
    }

    if ($DryRun) { Say '（DryRun）不會執行' 'Yellow'; exit 0 }
    $out = @(& bcdedit.exe /set $guid safeboot $mode 2>&1)
    $code = $LASTEXITCODE
    $out | ForEach-Object { Say ("    {0}" -f $_) }
    Say ("  bcdedit 結束碼 {0}" -f $code) $(if ($code -eq 0) { 'Green' } else { 'Red' })

    Start-Sleep -Milliseconds 500
    $after = Get-ActiveEntry
    Say ''
    if ($after.Ok -and $after.SafeBoot -eq $mode) {
        Say ("  已設定：下一次開機會直接進安全模式（{0}），不經過「進階啟動」選單。" -f $mode) 'Green'
        Say ''
        Say '  接下來：' 'Cyan'
        Say '   1) 一般重新啟動即可（不用按 Shift）' 'Green'
        Say '   2) 開機後畫面四角會寫「安全模式」，那就是成功' 'Green'
        Say '   3) 在安全模式裡用提權 PowerShell 跑要做的事' 'Green'
        Say '   4) 做完務必清除設定，否則會一直停在安全模式：' 'Yellow'
        Say ("      bcdedit /deletevalue {0} safeboot" -f $guid) 'Yellow'
        Say ("      或跑：Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Exit'") 'Yellow'
    } elseif ($after.Ok) {
        Say ("  讀回的 safeboot 是「{0}」，與預期「{1}」不符。請把上面的原始輸出貼回來。" -f $after.SafeBoot, $mode) 'Red'
        exit 3
    } else {
        Say '  無法驗證結果（讀不到開機設定）。請把上面的原始輸出貼回來。' 'Yellow'
        exit 3
    }
    Say ("日誌：$logFile") 'DarkGray'
    Say ''
    exit 0
}
