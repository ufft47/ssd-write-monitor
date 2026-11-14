#Requires -Version 5.1
<#
.SYNOPSIS
    把 C:\Program Files\AVG 搬到 D: 並以 junction 取代（必須在安全模式下執行搬移）。

.DESCRIPTION
    2026-11-15 實測：C:\Program Files\AVG 2.54 GB，當日可信寫入 523 MB（定義更新為主）：
      Program Files\AVG\Antivirus\defs\26111410\*.tmp     300.6 MB
      Program Files\AVG\AvVps\*.ipending                  222.0 MB

    這個目錄由 avgSP.sys（AVG 自我保護驅動）守著，另有 15 個 AVG 驅動同時執行，
    所以在正常開機狀態下改名一定會失敗。

    【為什麼用安全模式，而不是改驅動登錄檔】
      實測 HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal（85 項）與 Network（143 項）
      裡「沒有任何 AVG 服務或驅動」——只有一個名為 avgSP.sys 的殘留項目，
      與真正的服務名 avgSP 對不上。因此安全模式下 AVG 服務與 16 個驅動都不會載入，
      檔案不會被鎖、自我保護也不會作用。
      這比「把 16 個驅動的 Start 改 Disabled → 重開機 → 搬 → 改回來 → 再重開機」安全得多，
      因為那些登錄鍵本身受 AVG 保護，且改壞會讓防毒處於半殘狀態。

    【流程（三個階段）】
      1. -Move    ：僅限安全模式。robocopy 複製 → 逐檔比對 → 改名 .bak → mklink /J → 寫入落地測試
      2. 正常開機 ：跑 -Verify 確認 AVG 正常
      3. 觀察數日 ：確認穩定後，手動刪掉 C: 上的 .bak（空間才會真正釋放）

    【重要】
      - 複製成功前不動來源；改名是瞬間可逆的動作。
      - 搬移後 C: 上的原件仍在（改名為 AVG.bak-<時間>），
        所以在刪掉它之前「不會」省下 2.5 GB 空間 —— 這是刻意設計，用來保命。
      - AVG 更新器可能把目錄重建回 C:（也就是你擔心的「被改回去」）。
        可以用 -Verify 隨時檢查 junction 還在不在。

.PARAMETER Move
    在安全模式下執行搬移（含前置檢查、複製、比對、改名、建 junction、落地測試）。

.PARAMETER Verify
    正常開機時檢查結果：junction 是否還在、AVG 服務是否正常、定義是否可讀、寫入是否落在 D:。

.PARAMETER Revert
    在安全模式下還原：移除 junction、把 AVG.bak-* 改名回 AVG。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西（不需要管理員權限）。

.EXAMPLE
    # 1) 先看現況（不需提權）
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\avg-move-programfiles.ps1 -Verify -DryRun

.EXAMPLE
    # 2) 進入安全模式後，提權執行搬移
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Move'

.EXAMPLE
    # 3) 正常開機後驗證
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Verify'

.EXAMPLE
    # 4) 出事時在安全模式還原
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Revert'

.NOTES
    還原指令（安全模式，提權）：
        cmd /c rmdir "C:\Program Files\AVG"
        Rename-Item -LiteralPath "C:\Program Files\AVG.bak-<時間>" -NewName "AVG"

    注意：刪除 junction 只能用 cmd /c rmdir，絕對不能加 /s（會跟進刪掉 D: 上的目標）。
#>
param(
    [switch]$Move,
    [switch]$Verify,
    [switch]$Revert,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not ($Move -or $Verify -or $Revert)) {
    Write-Host '請指定 -Move（安全模式搬移）/ -Verify（正常開機驗證）/ -Revert（安全模式還原）' -ForegroundColor Yellow
    Write-Host '任何一個都可以加 -DryRun 先預覽。'
    exit 0
}

# ---------- 常數 ----------
$src      = 'C:\Program Files\AVG'
$dst      = 'D:\MX500\avg\ProgramFiles'
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak      = "$src.bak-$stamp"
$logDir   = 'D:\dev\disk-monitor\logs'
$avgSvcs  = @('AVG Antivirus', 'AVG Tools', 'AvgWscReporter', 'avgbIDSAgent')
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile  = Join-Path $logDir "avg-move-pf-$stamp.log"

$script:step = 0
function Say([string]$m, [string]$color = 'Gray') {
    $script:step++
    $line = "  [$script:step] $m"
    Write-Host $line -ForegroundColor $color
    # 寫日誌失敗不可以影響主流程（實測安全模式下曾出現
    # Add-Content: 資料流是不可讀取的，屬非終止錯誤，但會嚇到使用者）
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}
function SayRaw([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    try { Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8 -ErrorAction Stop } catch { }
}
function SizeOf([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return [int64]0 }
    $s = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Measure-Object Length -Sum
    return [int64]$s.Sum
}
function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
# BootupState：正常開機 = 'Normal boot'；安全模式 = 'Fail-safe boot' / 'Fail-safe with network boot'
# （Winmgmt 在 SafeBoot\Minimal 清單內，實測安全模式下 WMI 可用；仍保留 try/catch 以免例外中斷）
function BootState {
    try {
        return (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState
    } catch {
        return 'Unknown'
    }
}
# 用 sc.exe 直接問驅動狀態（不依賴 WMI，作為第二道安全網）
# 注意：PowerShell 的 sc 是 Set-Content 的別名，必須寫 sc.exe
function Get-AvgDriverRunning {
    $names = @('avgSP', 'avgMonFlt', 'avgArPot', 'avgRdr', 'avgSnx', 'avgStm', 'avgVmm', 'avgArDisk')
    $running = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $out = & sc.exe query $n 2>&1
        if ($out -match 'RUNNING') { [void]$running.Add($n) }
    }
    return $running
}
# 回傳「還有 AVG 行程在跑」的清單
function Get-AvgProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(avg|asw|AVGBrowser)' })
}
# 回傳「AVG 目錄裡的檔案是否仍被鎖住」（開一個檔案要求獨佔寫入權）
function Test-FilesLocked {
    $probe = Get-ChildItem -Path (Join-Path $src '*') -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.exe', '.dll') } | Select-Object -First 1
    if (-not $probe) {
        $probe = Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $probe) { return $null }   # 找不到可測的檔案
    try {
        $fs = [IO.File]::Open($probe.FullName, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

SayRaw ''
SayRaw "=== AVG Program Files 搬移  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { SayRaw '（DryRun：只顯示，不動任何東西）' 'Yellow' }
SayRaw ("  開機狀態 : {0}" -f (BootState)) 'DarkGray'
SayRaw ("  目前身分 : {0} / 管理員={1}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, (IsAdmin)) 'DarkGray'

# =========================================================
#  -Verify：正常開機時檢查（唯讀）
# =========================================================
if ($Verify) {
    SayRaw ''
    SayRaw '=== 驗證搬移結果 ===' 'Cyan'

    $i = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (-not $i) {
        Say "$src 不存在！AVG 可能已被移除或路徑異常。" 'Red'
        exit 2
    }
    $isJunction = [bool]$i.LinkType
    Say ("C:\Program Files\AVG 型態 : {0}" -f $(if ($isJunction) { "$($i.LinkType) -> $($i.Target -join ',')" } else { '實體目錄（尚未搬移）' })) `
        $(if ($isJunction) { 'Green' } else { 'Yellow' })

    if ($isJunction) {
        # 1) 從 C: 路徑讀得到 AVG 的執行檔
        $exe = Join-Path $src 'Antivirus\AVGSvc.exe'
        Say ("從 C: 路徑讀取 AVGSvc.exe : {0}" -f $(if (Test-Path -LiteralPath $exe) { "可讀（$((Get-Item -LiteralPath $exe).Length) bytes）" } else { '讀不到' })) `
            $(if (Test-Path -LiteralPath $exe) { 'Green' } else { 'Red' })

        # 2) 寫入落地測試（需要管理員才寫得進 Program Files）
        if (IsAdmin -and -not $DryRun) {
            $probeName = ".dm-writetest-$stamp"
            try {
                [IO.File]::WriteAllText((Join-Path $src $probeName), 'junction-test', (New-Object Text.UTF8Encoding($false)))
                $landed = Test-Path -LiteralPath (Join-Path $dst $probeName)
                Remove-Item -LiteralPath (Join-Path $src $probeName) -Force -ErrorAction SilentlyContinue
                Say ("寫入落地到 D: : {0}" -f $(if ($landed) { '是' } else { '否' })) $(if ($landed) { 'Green' } else { 'Red' })
            } catch {
                Say ("寫入測試失敗：{0}" -f $_.Exception.Message) 'Red'
            }
        } elseif (-not (IsAdmin)) {
            Say '寫入測試需要管理員權限，已跳過（請用提權的 PowerShell 重跑 -Verify）' 'Yellow'
        }
    }

    # 3) AVG 服務與行程
    SayRaw ''
    foreach ($n in $avgSvcs) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) {
            SayRaw ("      {0,-18} {1}" -f $n, $s.Status) $(if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' })
        } else {
            SayRaw ("      {0,-18} （服務不存在）" -f $n) 'DarkGray'
        }
    }
    $procs = Get-AvgProcesses
    SayRaw ("      行程 : {0}" -f $(if ($procs.Count -eq 0) { '無' } else {
        ($procs | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ' })) 'DarkGray'
    $drvRun = Get-AvgDriverRunning
    SayRaw ("      載入中驅動 : {0}" -f $(if ($drvRun.Count -eq 0) { '無' } else { ($drvRun -join ', ') })) `
        $(if ($drvRun.Count -gt 0) { 'Green' } else { 'Red' })

    # 4) 病毒定義是否可讀、版本是否合理
    $defsDir = Join-Path $src 'Antivirus\defs'
    if (Test-Path -LiteralPath $defsDir) {
        $latest = Get-ChildItem -LiteralPath $defsDir -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_stream' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $cnt = @(Get-ChildItem -LiteralPath $latest.FullName -File -Force -ErrorAction SilentlyContinue).Count
            Say ("      最新定義 : {0}（{1} 檔，{2:yyyy-MM-dd HH:mm}）" -f $latest.Name, $cnt, $latest.LastWriteTime) `
                $(if ($cnt -gt 100) { 'Green' } else { 'Yellow' })
        }
    }

    # 5) C: 上的備份是否還在（提醒空間尚未釋放）
    $baks = @(Get-ChildItem -LiteralPath 'C:\Program Files' -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'AVG.bak-*' })
    if ($baks.Count -gt 0) {
        SayRaw ''
        foreach ($b in $baks) {
            $mb = (SizeOf $b.FullName) / 1MB
            SayRaw ("      備份仍在 C: ：{0}  {1:N0} MB（確認 AVG 穩定後再刪，那時空間才會釋放）" -f $b.Name, $mb) 'DarkGray'
        }
    }

    SayRaw ''
    Say '請開 AVG 主控台（AVGUI）確認首頁沒有紅字，並手動按一次「更新」。' 'Green'
    SayRaw ''
    SayRaw ("日誌：$logFile") 'DarkGray'
    SayRaw ''
    exit 0
}

# =========================================================
#  -Move：安全模式搬移
# =========================================================
if ($Move) {
    SayRaw ''
    SayRaw '=== 搬移 C:\Program Files\AVG -> D: ===' 'Cyan'

    if (-not (IsAdmin) -and -not $DryRun) {
        SayRaw ''
        SayRaw '需要管理員權限。請改用：' 'Red'
        SayRaw ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Move'") 'Yellow'
        exit 1
    }

    # 互鎖：一定要在安全模式（DryRun 例外）
    $boot = BootState
    if ($boot -notlike 'Fail-safe*' -and $boot -ne 'Unknown' -and -not $DryRun) {
        SayRaw ''
        SayRaw ("現在開機狀態是「{0}」，不是安全模式。搬移必須在安全模式下做。" -f $boot) 'Red'
        if ($boot -eq 'Normal boot') {
            SayRaw '' 
            SayRaw '進入安全模式的方式（Windows 10）：' 'Yellow'
            SayRaw '  1) 按住 Shift 不放，點「開始 → 電源 → 重新啟動」' 'Yellow'
            SayRaw '  2) 疑難排解 → 進階選項 → 啟動設定 → 重新啟動' 'Yellow'
            SayRaw '  3) 按 4（啟用安全模式）或 5（安全模式含網路功能）' 'Yellow'
            SayRaw '  4) 進入安全模式後，用提權的 PowerShell 重跑本腳本的 -Move' 'Yellow'
        }
        SayRaw ''
        SayRaw '（不會有任何變更，已中止）' 'DarkGray'
        exit 1
    }

    $srcItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (-not $srcItem) { Say "找不到 $src" 'Red'; exit 2 }
    if ($srcItem.LinkType) {
        Say "已經是 $($srcItem.LinkType) -> $($srcItem.Target -join ',')，無需搬移。" 'Yellow'
        exit 0
    }

    # 前置檢查：AVG 真的沒在跑嗎（三重：行程、服務、驅動，最後才是檔案鎖）
    $procs = Get-AvgProcesses
    $running = @($avgSvcs | ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_ -and $_.Status -eq 'Running' })
    $drvRun = Get-AvgDriverRunning
    Say ("AVG 行程數 : {0}" -f $procs.Count) $(if ($procs.Count -eq 0) { 'Green' } else { 'Red' })
    Say ("AVG 執行中服務 : {0}" -f $(if ($running.Count -eq 0) { '無' } else { ($running.Name -join ', ') })) `
        $(if ($running.Count -eq 0) { 'Green' } else { 'Red' })
    Say ("AVG 載入中驅動 : {0}" -f $(if ($drvRun.Count -eq 0) { '無' } else { ($drvRun -join ', ') })) `
        $(if ($drvRun.Count -eq 0) { 'Green' } else { 'Red' })

    $locked = Test-FilesLocked
    Say ("檔案是否仍被鎖住 : {0}" -f $(if ($null -eq $locked) { '無法判定（找不到測試檔）' }
        elseif ($locked) { '是（AVG 仍在作用）' } else { '否（可以搬）' })) `
        $(if ($locked -eq $false) { 'Green' } elseif ($null -eq $locked) { 'Yellow' } else { 'Red' })

    if ((-not $DryRun) -and ($procs.Count -gt 0 -or $running.Count -gt 0 -or $locked -ne $false)) {
        SayRaw ''
        SayRaw 'AVG 仍在執行（行程／服務）或檔案仍被鎖住，搬移會失敗。' 'Red'
        SayRaw '已中止，沒有動任何東西。' 'Red'
        SayRaw '請確認真的進入了安全模式（不是「正常開機」），必要時用「安全模式含網路功能」。' 'Yellow'
        exit 3
    }

    # 仍在載入的驅動：只警告，不阻擋。
    # 實測（2026-11-15 07:35，安全模式 Fail-safe boot）：avgArDisk（StartMode=Boot）
    # 在安全模式下仍會被核心載入，但「獨佔開檔測試」顯示 AVG 的檔案並沒有被鎖住。
    # 真正的判準是下方「改名探針」——直接問作業系統「這個目錄能不能改名」。
    if ($drvRun.Count -gt 0) {
        SayRaw ''
        SayRaw ("  注意：下列 AVG 驅動仍在載入（開機型驅動在安全模式仍會載入）：{0}" -f ($drvRun -join ', ')) 'Yellow'
        SayRaw '  它們沒有握住 AVG 的檔案（上面測試已證明），所以不阻擋；下一步用改名探針確認。' 'DarkGray'
    }

    # 改名探針：唯一能直接回答「目錄能不能改名」的實驗，而且立刻可逆。
    if (-not $DryRun) {
        $leaf = Split-Path $src -Leaf
        $parent = Split-Path $src -Parent
        $probeName = "$leaf.dm-renameprobe"
        $probePath = Join-Path $parent $probeName
        Say ("改名探針：{0} -> {1}（隨即改回）" -f $leaf, $probeName)
        try {
            Rename-Item -LiteralPath $src -NewName $probeName -ErrorAction Stop
            Rename-Item -LiteralPath $probePath -NewName $leaf -ErrorAction Stop
            Say '  改名成功並已改回 → 可以搬' 'Green'
        } catch {
            Say ("  改名失敗：{0}" -f $_.Exception.Message) 'Red'
            if (Test-Path -LiteralPath $probePath) {
                SayRaw ''
                SayRaw ("  注意：目錄目前名稱是 {0}，請手動改回：" -f $probeName) 'Red'
                SayRaw ("    Rename-Item -LiteralPath '{0}' -NewName '{1}'" -f $probePath, $leaf) 'Red'
            }
            SayRaw ''
            SayRaw '  已中止，沒有動任何其他東西。' 'Red'
            exit 4
        }
    }

    if (Test-Path -LiteralPath $dst) {
        Say "目標已存在：$dst（請先確認內容並清掉，或改用 -Verify 檢查看是不是上次留下的）" 'Red'
        exit 2
    }

    $srcBytes = SizeOf $src
    $dFree = (Get-PSDrive -Name D).Free
    Say ("來源大小 : {0:N0} MB" -f ($srcBytes / 1MB))
    Say ("D: 可用 : {0:N1} GB" -f ($dFree / 1GB)) $(if ($dFree -gt ($srcBytes * 1.2)) { 'Green' } else { 'Red' })
    if ($dFree -lt ($srcBytes * 1.2)) { Say 'D: 空間不足（需要約來源的 1.2 倍）' 'Red'; exit 2 }

    if ($DryRun) {
        SayRaw ''
        SayRaw '（DryRun）會做：' 'Yellow'
        SayRaw '    robocopy /E /COPY:DAT /XJ  ->  逐檔比對  ->  改名 AVG.bak-<時間>' 'Yellow'
        SayRaw '    ->  mklink /J  ->  寫入落地測試  ->  印出驗證資訊' 'Yellow'
        SayRaw ("    來源：{0}" -f $src) 'DarkGray'
        SayRaw ("    目標：{0}" -f $dst) 'DarkGray'
        SayRaw ''
        SayRaw ("日誌：$logFile") 'DarkGray'
        SayRaw ''
        exit 0
    }

    $renamed = $false
    $junctionMade = $false
    try {
        # 1) 複製（不用 /MOVE；驗證通過才處理來源）
        Say "複製到 $dst"
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        $rcArgs = @(
            "`"$src`"", "`"$dst`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ',
            '/R:2', '/W:3', '/NFL', '/NDL', '/NP', "/LOG:`"$logFile.robocopy`""
        )
        $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList $rcArgs
        Say ("robocopy 結束碼 {0}（0–7 代表成功）" -f $rc.ExitCode) $(if ($rc.ExitCode -lt 8) { 'Green' } else { 'Red' })
        if ($rc.ExitCode -ge 8) { throw "robocopy 失敗，結束碼 $($rc.ExitCode)，請看 $logFile.robocopy" }

        # 2) 逐檔比對（比相對路徑與大小；跳過 reparse point）
        Say '逐檔比對'
        $srcMap = @{}
        Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object { $srcMap[$_.FullName.Substring($src.Length)] = $_.Length }
        $checked = 0; $missing = 0; $diffs = 0
        foreach ($rel in $srcMap.Keys) {
            $checked++
            $df = $dst + $rel
            if (-not (Test-Path -LiteralPath $df)) { $missing++; continue }
            if ((Get-Item -LiteralPath $df -Force).Length -ne $srcMap[$rel]) { $diffs++ }
        }
        Say ("比對 {0:N0} 檔：缺少 {1}、大小不同 {2}" -f $checked, $missing, $diffs) `
            $(if (($missing + $diffs) -eq 0) { 'Green' } else { 'Red' })
        if (($missing + $diffs) -ne 0) { throw "複製不完整（缺少 $missing、大小不同 $diffs），已中止，未動來源" }

        # 3) 改名（安全模式下應可成功）
        Say "改名 $src -> $bak"
        Rename-Item -LiteralPath $src -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
        $renamed = $true
        Say '已改名' 'Green'

        # 4) 建立 junction
        Say "建立 junction $src -> $dst"
        $mk = & cmd.exe /c mklink /J "$src" "$dst" 2>&1
        SayRaw ("      $mk") 'DarkGray'
        $li = Get-Item -LiteralPath $src -Force
        if (-not $li.LinkType) { throw 'junction 沒有建立成功（LinkType 為空）' }
        $junctionMade = $true
        Say ("junction 已建立：{0}" -f $li.LinkType) 'Green'

        # 5) 寫入落地測試
        Say '寫入落地測試（從 C: 路徑寫入，應出現在 D:）'
        $probeName = ".dm-writetest-$stamp"
        [IO.File]::WriteAllText((Join-Path $src $probeName), 'junction-test', (New-Object Text.UTF8Encoding($false)))
        $landed = Test-Path -LiteralPath (Join-Path $dst $probeName)
        Remove-Item -LiteralPath (Join-Path $src $probeName) -Force -ErrorAction SilentlyContinue
        Say ("寫入落地 D: : {0}" -f $(if ($landed) { '是' } else { '否' })) $(if ($landed) { 'Green' } else { 'Red' })
        if (-not $landed) { throw '寫入測試失敗：檔案沒有落在 D:' }

        # 6) 結果
        SayRaw ''
        SayRaw '--- 完成 ---' 'Cyan'
        SayRaw ("      {0}" -f $src) 'DarkGray'
        SayRaw ("        LinkType : {0}" -f $li.LinkType) 'DarkGray'
        SayRaw ("        Target   : {0}" -f ($li.Target -join ', ')) 'DarkGray'
        SayRaw ("        搬到 D: 的檔數：{0:N0}" -f $checked) 'DarkGray'
        SayRaw ''
        Say '接下來：' 'Green'
        Say '  1) 正常重新開機（不要停在安全模式）' 'Green'
        Say '  2) 開機後跑 -Verify：Start-Process powershell -Verb RunAs -ArgumentList ''-NoExit'',''-ExecutionPolicy'',''Bypass'',''-File'',''D:\dev\disk-monitor\avg-move-programfiles.ps1'',''-Verify''' 'Green'
        Say '  3) 開 AVG 主控台按一次「更新」，確認定義能正常下載' 'Green'
        SayRaw ''
        SayRaw ("原始目錄已改名保留：$bak（確認穩定幾天才刪，那時空間才會釋放）") 'DarkGray'
    } catch {
        SayRaw ''
        SayRaw ("失敗：{0}" -f $_.Exception.Message) 'Red'
        SayRaw '--- 回滾 ---' 'Yellow'
        try {
            if ($junctionMade) {
                & cmd.exe /c rmdir "$src" 2>&1 | Out-Null
                Say '已移除 junction'
            }
            if ($renamed -and -not (Test-Path -LiteralPath $src)) {
                Rename-Item -LiteralPath $bak -NewName 'AVG' -ErrorAction Stop
                Say '已把 AVG 改名回來'
            }
            SayRaw ("D: 上的複本仍在：$dst（確認無用後可手動刪除）") 'DarkGray'
        } catch {
            SayRaw ("回滾也出錯：{0}" -f $_.Exception.Message) 'Red'
            SayRaw ("請手動處理：來源備份在 $bak，D: 複本在 $dst") 'Red'
        }
        SayRaw ''
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 3
    }

    SayRaw ''
    SayRaw ("日誌：$logFile") 'DarkGray'
    SayRaw ''
    exit 0
}

# =========================================================
#  -Revert：安全模式還原
# =========================================================
if ($Revert) {
    SayRaw ''
    SayRaw '=== 還原：把 Program Files\AVG 搬回 C: ===' 'Cyan'

    if (-not (IsAdmin) -and -not $DryRun) {
        SayRaw ''
        SayRaw '需要管理員權限（而且必須在安全模式下）。請改用：' 'Red'
        SayRaw ("  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Revert'") 'Yellow'
        exit 1
    }

    $boot = BootState
    if ($boot -notlike 'Fail-safe*' -and $boot -ne 'Unknown' -and -not $DryRun) {
        SayRaw ("現在是「{0}」，不是安全模式。還原請在安全模式下執行。" -f $boot) 'Red'
        exit 1
    }
    if ($boot -eq 'Unknown') { Say '無法判定開機狀態（WMI 無回應），仍繼續嘗試；若改名失敗就是 AVG 還在使用中。' 'Yellow' }

    $li = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (-not $li) { Say "$src 不存在，無法還原" 'Red'; exit 2 }
    if (-not $li.LinkType) { Say "$src 不是 junction（已經是實體目錄），無需還原" 'Yellow'; exit 0 }
    $target = @($li.Target)[0]
    Say "目前 junction 指向：$target"

    $newestBak = Get-ChildItem -LiteralPath 'C:\Program Files' -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'AVG.bak-*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newestBak) { Say '找不到 AVG.bak-* 備份目錄，無法還原（D: 上的資料仍在）' 'Red'; exit 2 }
    Say "將還原自：$($newestBak.FullName)"

    if ($DryRun) {
        Say '（DryRun）會做：rmdir junction → 把 AVG.bak-* 改名回 AVG' 'Yellow'
        SayRaw ("D: 上的資料仍在：$target（確認無用後可手動刪除）") 'DarkGray'
        exit 0
    }

    & cmd.exe /c rmdir "$src" 2>&1 | Out-Null
    Say '已移除 junction'
    Rename-Item -LiteralPath $newestBak.FullName -NewName 'AVG' -ErrorAction Stop
    Say '已把 AVG 改名回來' 'Green'

    $li2 = Get-Item -LiteralPath $src -Force
    Say ("LinkType = 「{0}」（空白代表已是實體目錄）" -f $li2.LinkType)
    Say '還原完成，請正常重新開機。' 'Green'
    SayRaw ("D: 上的資料仍在：$target（確認無用後可手動刪除）") 'DarkGray'
    SayRaw ''
    SayRaw ("日誌：$logFile") 'DarkGray'
    SayRaw ''
    exit 0
}
