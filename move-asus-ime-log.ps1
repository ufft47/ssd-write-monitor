#Requires -Version 5.1
<#
.SYNOPSIS
    把 ASUS 輸入法的 ETW 日誌目錄搬到 D: 並以 junction 取代。

.DESCRIPTION
    2026-11-15 實測：
      C:\ProgramData\ASUS\AsusIME\log\asus_ime_service.etl   持續成長
        06:01 時已 227 MB（當日 00:00 起算）
        30 秒採樣 +0.81 MB（換算 97 MB/小時，速率變動大）
      同目錄每天 00:00 會把前一天壓成 .zip（約 4 MB/日）再重新開始
      服務：AsusIMESystemService（Running / Auto）
      行程：AsusIMESystemService、AsusIMEService

    為什麼值得處理：這些寫入在歸因表裡落在「System」（ETW 由核心寫入，不經應用程式
    手柄），當日只記到 49.6 MB，但檔案實際長了 227 MB —— 也就是「無法歸因」那塊的一部分。

    搬到 D: 之後，寫入會直接落在 D:，且不需要安全模式、不需要重開機：
    ASUS 的目錄不受任何自我保護驅動守護，只要停服務即可解鎖。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西（不需要管理員權限）。

.PARAMETER StopTrace
    停掉 ETW 追蹤工作階段（`logman stop AsusIMEService -ets`），讓寫入歸零，
    不動任何檔案、不搬目錄。這是最省的做法：搬走仍是每天約 1 GB，停掉是 0。
    復原方式：`-Revert`（重新啟動服務，服務會自行重開追蹤）。

.PARAMETER Revert
    還原：若是 junction 就搬回 C:；若追蹤被停掉就重啟服務。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\move-asus-ime-log.ps1 -DryRun

.EXAMPLE
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\move-asus-ime-log.ps1'

.EXAMPLE
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\move-asus-ime-log.ps1','-Revert'
#>
param(
    [switch]$DryRun,
    [switch]$StopTrace,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$svc     = 'AsusIMESystemService'
$root    = 'C:\ProgramData\ASUS\AsusIME'
$src     = Join-Path $root 'log'
$dst     = 'D:\MX500\asus-ime-log'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak     = "$src.bak-$stamp"
$logDir  = 'D:\dev\disk-monitor\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "asus-ime-$stamp.log"

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
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Measure-Object Length -Sum
    return [int64]$s.Sum
}
function EtlSize([string]$p) {
    $f = Join-Path $p 'asus_ime_service.etl'
    if (Test-Path -LiteralPath $f) { return (Get-Item -LiteralPath $f -Force).Length }
    return [int64]0
}

Say ''
Say "=== ASUS 輸入法日誌搬到 D:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { Say '（DryRun：只顯示，不動任何東西）' 'Yellow' }

Say ''
Say '--- 現況 ---' 'Cyan'
$srcItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
if (-not $srcItem) { Say "  找不到 $src" 'Red'; exit 2 }
Say ("  目錄      : {0}（{1:N1} MB）" -f $src, ((SizeOf $src) / 1MB))
Say ("  型態      : {0}" -f $(if ($srcItem.LinkType) { "$($srcItem.LinkType) -> $($srcItem.Target -join ',')" } else { '實體目錄' }))
Say ("  目前 .etl : {0:N2} MB" -f ((EtlSize $src) / 1MB))
$s = Get-Service -Name $svc -ErrorAction SilentlyContinue
Say ("  服務      : {0}" -f $(if ($s) { "$($s.Name) = $($s.Status)" } else { '（找不到，可能沒裝 ASUS IME）' })) `
    $(if ($s -and $s.Status -eq 'Running') { 'Green' } else { 'Yellow' })
Say ("  D: 可用   : {0:N1} GB" -f ((Get-PSDrive -Name D).Free / 1GB))

# ---------- StopTrace：直接停掉 ETW 追蹤（最省的做法）----------
if ($StopTrace) {
    Say ''
    Say '--- 停止 AsusIMEService 的 ETW 追蹤工作階段 ---' 'Cyan'
    $e0 = EtlSize $src
    Say ("  目前 .etl : {0:N2} MB" -f ($e0 / 1MB))
    if ($DryRun) {
        Say '  （DryRun）會做：' 'Yellow'
        Say '    logman stop AsusIMEService -ets → 等 30 秒 → 確認 .etl 不再成長' 'DarkGray'
        Say '    不動任何檔案、不搬目錄；寫入歸零而不是換地方寫' 'DarkGray'
        Say '  復原：-Revert（重新啟動服務，服務會自行重開追蹤）' 'DarkGray'
        Say ''
        Say ("日誌：$logFile") 'DarkGray'
        Say ''
        exit 0
    }
    if (-not (IsAdmin)) {
        Say ''
        Say '需要管理員權限。請改用：' 'Red'
        Say ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-StopTrace'") 'Yellow'
        exit 1
    }
    $out = & logman.exe stop AsusIMEService -ets 2>&1
    $txt = (($out | Where-Object { $_ -match '\S' }) -join ' / ')
    Say ("  logman 回應：{0}" -f $txt)
    Start-Sleep -Seconds 30
    $e1 = EtlSize $src
    Say ("  .etl：{0:N2} MB -> {1:N2} MB（+{2:N2} MB）" -f ($e0 / 1MB), ($e1 / 1MB), (($e1 - $e0) / 1MB))
    if (($e1 - $e0) -le 256KB) {
        Say ''
        Say '  追蹤已停止，寫入歸零。' 'Green'
        Say '  請打幾個中文字，確認 ASUS 輸入法仍正常。' 'Green'
        Say ("  若輸入法異常：跑 -Revert 重啟服務即可恢復。") 'DarkGray'
        exit 0
    } else {
        Say ''
        Say '  追蹤仍在寫（服務可能把它重開了）。' 'Yellow'
        Say '  改走搬移：移除 -StopTrace 直接執行（會把 log 目錄 junction 到 D:）。' 'Yellow'
        exit 1
    }
}

if ($srcItem.LinkType -and -not $Revert) {
    Say ''
    Say '  已經是連結了，無需搬移。' 'Yellow'
    Say ("  （要還原請加 -Revert）") 'DarkGray'
    exit 0
}

# ---------- Revert ----------
if ($Revert) {
    Say ''
    Say '--- 還原 ---' 'Cyan'
    $li = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (-not $li) { Say "  $src 不存在，無法還原" 'Red'; exit 2 }
    if (-not $li.LinkType) {
        Say '  目錄不是 junction（沒有搬移過）。' 'Yellow'
        Say '  若是 -StopTrace 停掉了追蹤，這裡會重新啟動服務讓追蹤恢復。' 'Yellow'
        if ($DryRun) { Say '  （DryRun）會重啟服務' 'DarkGray'; exit 0 }
        if (-not (IsAdmin)) { Say '  需要管理員權限。' 'Red'; exit 1 }
        Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Say ("  服務 : {0}" -f (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status) 'Green'
        $tr = & logman.exe query AsusIMEService -ets 2>&1
        Say ("  追蹤 : {0}" -f $(if ($tr -match 'Running') { 'Running（已恢復）' } else { '未在執行（請確認）' })) 'Gray'
        exit 0
    }
    $newestBak = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'log.bak-*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newestBak) { Say '  找不到 log.bak-* 備份，無法還原（D: 上資料仍在）' 'Red'; exit 2 }
    if ($DryRun) { Say ("  （DryRun）會停服務、移除 junction、把 {0} 改名回 log、起服務" -f $newestBak.Name) 'Yellow'; exit 0 }
    if (-not (IsAdmin)) { Say '  需要管理員權限。' 'Red'; exit 1 }

    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    & cmd.exe /c rmdir "$src" 2>&1 | Out-Null
    Say '  已移除 junction'
    Rename-Item -LiteralPath $newestBak.FullName -NewName 'log' -ErrorAction Stop
    Say '  已把 log 改名回來' 'Green'
    Start-Service -Name $svc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Say ("  服務 : {0}" -f (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status)
    Say ("  D: 上資料仍在：{0}（確認無用後可手動刪除）" -f $dst) 'DarkGray'
    exit 0
}

# ---------- DryRun ----------
if ($DryRun) {
    Say ''
    Say '（DryRun）會做：' 'Yellow'
    Say ("  1) 停止服務 {0}（這是唯一需要解鎖的東西，不需要安全模式）" -f $svc) 'DarkGray'
    Say ("  2) robocopy /E /COPY:DAT /XJ  {0} -> {1}" -f $src, $dst) 'DarkGray'
    Say '  3) 逐檔比對（缺檔或大小不同就中止，不動來源）' 'DarkGray'
    Say ("  4) 把 {0} 改名為 log.bak-<時間>" -f $src) 'DarkGray'
    Say ("  5) mklink /J {0} {1}" -f $src, $dst) 'DarkGray'
    Say '  6) 起服務，等 30 秒確認 D: 上的 .etl 有在長（寫入真的落在那裡）' 'DarkGray'
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
if (-not $s) { Say '  找不到服務，中止（避免動到非 ASUS 環境的目錄）。' 'Red'; exit 2 }
if (Test-Path -LiteralPath $dst) { Say ("  目標已存在：{0}（請先清掉或確認是不是上次留下的）" -f $dst) 'Red'; exit 2 }
$dFree = (Get-PSDrive -Name D).Free
if ($dFree -lt (100MB)) { Say '  D: 空間不足' 'Red'; exit 2 }

$beforeSvc = $s.Status.ToString()
$renamed = $false
$junctionMade = $false
try {
    Say ''
    Say '--- 停止服務 ---' 'Cyan'
    Stop-Service -Name $svc -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    Say ("  {0} = {1}" -f $svc, (Get-Service -Name $svc).Status) 'Green'

    Say ''
    Say '--- 複製到 D: ---' 'Cyan'
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    $rcArgs = @("`"$src`"", "`"$dst`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ',
                '/R:2', '/W:3', '/NFL', '/NDL', '/NP', "/LOG:`"$logFile.robocopy`"")
    $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList $rcArgs
    Say ("  robocopy 結束碼 {0}" -f $rc.ExitCode) $(if ($rc.ExitCode -lt 8) { 'Green' } else { 'Red' })
    if ($rc.ExitCode -ge 8) { throw "robocopy 失敗，結束碼 $($rc.ExitCode)" }

    Say '--- 逐檔比對 ---' 'Cyan'
    $srcMap = @{}
    Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $srcMap[$_.FullName.Substring($src.Length)] = $_.Length }
    $missing = 0; $diffs = 0
    foreach ($rel in $srcMap.Keys) {
        $df = $dst + $rel
        if (-not (Test-Path -LiteralPath $df)) { $missing++; continue }
        if ((Get-Item -LiteralPath $df -Force).Length -ne $srcMap[$rel]) { $diffs++ }
    }
    Say ("  比對 {0} 檔：缺 {1}、大小不同 {2}" -f $srcMap.Count, $missing, $diffs) `
        $(if (($missing + $diffs) -eq 0) { 'Green' } else { 'Red' })
    if (($missing + $diffs) -ne 0) { throw "複製不完整（缺 $missing、大小不同 $diffs），未動來源" }

    Say ''
    Say '--- 改名並建立 junction ---' 'Cyan'
    Rename-Item -LiteralPath $src -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
    $renamed = $true
    Say ("  已改名為 {0}" -f (Split-Path $bak -Leaf)) 'Green'
    $mk = & cmd.exe /c mklink /J "$src" "$dst" 2>&1
    Say ("  {0}" -f $mk) 'DarkGray'
    $li = Get-Item -LiteralPath $src -Force
    if (-not $li.LinkType) { throw 'junction 沒有建立成功' }
    $junctionMade = $true

    Say ''
    Say '--- 起服務並確認寫入落在 D: ---' 'Cyan'
    Start-Service -Name $svc -ErrorAction Stop
    Start-Sleep -Seconds 5
    Say ("  {0} = {1}" -f $svc, (Get-Service -Name $svc).Status) 'Green'
    $e0 = EtlSize $dst
    Say ("  D: 上 .etl 起始 {0:N2} MB，等 30 秒觀察是否成長…" -f ($e0 / 1MB))
    Start-Sleep -Seconds 30
    $e1 = EtlSize $dst
    $grew = ($e1 -gt $e0)
    Say ("  D: 上 .etl 現在 {0:N2} MB（+{1:N2} MB）" -f ($e1 / 1MB), (($e1 - $e0) / 1MB)) `
        $(if ($grew) { 'Green' } else { 'Yellow' })
    Say ("  寫入已落在 D: : {0}" -f $(if ($grew) { '是' } else { '未觀察到成長（可能是這段時間沒有輸入行為，可稍後再看）' })) `
        $(if ($grew) { 'Green' } else { 'Yellow' })

    # 從 C: 路徑讀，確認同一個檔案
    $viaC = EtlSize $src
    Say ("  從 C: 路徑讀同一個檔案：{0:N2} MB（應與 D: 相同）" -f ($viaC / 1MB)) `
        $(if ([math]::Abs($viaC - $e1) -le 1MB) { 'Green' } else { 'Yellow' })

    Say ''
    Say '=== 完成 ===' 'Cyan'
    Say ("  {0} -> {1}" -f $src, $dst) 'Green'
    Say ("  原始目錄保留：{0}（確認 ASUS 輸入法正常後再刪）" -f $bak) 'DarkGray'
    Say '  請打幾個中文字，確認輸入法功能正常。' 'Green'
} catch {
    Say ''
    Say ("失敗：{0}" -f $_.Exception.Message) 'Red'
    Say '--- 回滾 ---' 'Yellow'
    try {
        if ($junctionMade) { & cmd.exe /c rmdir "$src" 2>&1 | Out-Null; Say '  已移除 junction' }
        if ($renamed -and -not (Test-Path -LiteralPath $src)) {
            Rename-Item -LiteralPath $bak -NewName 'log' -ErrorAction Stop
            Say '  已把 log 改名回來'
        }
        if ($beforeSvc -eq 'Running') { Start-Service -Name $svc -ErrorAction SilentlyContinue }
        Say ("  服務 : {0}" -f (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status)
        Say ("  D: 上複本仍在：{0}（確認無用後可手動刪除）" -f $dst) 'DarkGray'
    } catch {
        Say ("  回滾也出錯：{0}" -f $_.Exception.Message) 'Red'
        Say ("  請手動處理：備份在 {0}" -f $bak) 'Red'
    }
    exit 3
}

Say ''
Say ("日誌：$logFile") 'DarkGray'
Say ''
