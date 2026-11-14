#Requires -Version 5.1
<#
.SYNOPSIS
    清理 AVG 的垃圾檔，並（可選）把 C:\ProgramData\AVG 搬到 D: 後以 junction 取代。

.DESCRIPTION
    2026-11-15 實測 AVG 在 C: 的狀態：

      C:\ProgramData\AVG\Antivirus\log            3,988 MB  ← 2021–2026 的崩潰傾印 *.mdmp（最大單檔 1.18 GB）
      C:\ProgramData\AVG\Antivirus\bootimescan      479 MB  ← 2023 年的舊 boottimescan.wim
      C:\Program Files\AVG\...\defs\26111106        575 MB  ← 舊版病毒定義，已被 26111410 取代
      C:\ProgramData\AVG（其餘）                    ~200 MB  ← 常態快取，每日約寫入 0.8 GB

    前兩項與舊定義是純垃圾，刪掉可回收約 5.0 GB，且不會被任何更新還原。

    -MoveProgramData 會把 C:\ProgramData\AVG（4.67 GB）搬到 D:\MX500\avg\ProgramData，
    並在原位置建立 junction。這能攔下 AVG 每日約 0.8 GB 的常態寫入。

    注意：本腳本「刻意不處理」C:\Program Files\AVG。
    該目錄由 avgSP.sys（AVG 自我保護驅動，StartMode=System）守著，另有 15 個 AVG 驅動同時執行，
    搬移必須先把 16 個驅動停用 + 重開機 + 在 AVG 啟動前搬完；
    且 AVG 的更新器會重建安裝路徑，目錄層級同樣會被改回去。詳見 README。

.PARAMETER CleanJunk
    刪除崩潰傾印、舊 boottimescan 與過期病毒定義（不可逆，但都是垃圾）。

.PARAMETER MoveProgramData
    把 C:\ProgramData\AVG 搬到 D: 並建立 junction（可逆）。

.PARAMETER All
    等同 -CleanJunk -MoveProgramData。

.PARAMETER DryRun
    只顯示會做什麼，不動任何東西。

.PARAMETER Revert
    把 junction 移除、原名稱改回來（還原 -MoveProgramData）。

.EXAMPLE
    # 先看會做什麼
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-clean-and-move.ps1','-All','-DryRun'

.EXAMPLE
    # 實際執行
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-clean-and-move.ps1','-All'

.EXAMPLE
    # 只還原搬移
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-clean-and-move.ps1','-Revert'
#>
param(
    [switch]$CleanJunk,
    [switch]$MoveProgramData,
    [switch]$All,
    [switch]$DryRun,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
if ($All) { $CleanJunk = $true; $MoveProgramData = $true }
if (-not ($CleanJunk -or $MoveProgramData -or $Revert)) {
    Write-Host '請至少指定 -CleanJunk / -MoveProgramData / -All / -Revert 其中一個。' -ForegroundColor Yellow
    Write-Host '加 -DryRun 可先預覽。'
    exit 0
}

# ---------- 常數 ----------
$dataSrc   = 'C:\ProgramData\AVG'
$dataDst   = 'D:\MX500\avg\ProgramData'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak       = "$dataSrc.bak-$stamp"
$logDir    = 'D:\dev\disk-monitor\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile   = Join-Path $logDir "avg-clean-move-$stamp.log"
$avgSvcs   = @('AVG Antivirus', 'AVG Tools', 'AvgWscReporter', 'avgbIDSAgent')

$script:step = 0
function Say([string]$m, [string]$color = 'Gray') {
    $script:step++
    $line = "  [$script:step] $m"
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}
function SayRaw([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8
}
function SizeOf([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $s = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Measure-Object Length -Sum
    return [int64]$s.Sum
}

SayRaw ''
SayRaw "=== AVG 清理 / 搬移  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if ($DryRun) { SayRaw '（DryRun：只顯示，不動任何東西）' 'Yellow' }

# ---------- 前置檢查 ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    SayRaw ''
    SayRaw '需要管理員權限。請改用：' 'Red'
    SayRaw "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-All'"
    exit 1
}

$avgSP = Get-CimInstance Win32_SystemDriver -Filter "Name='avgSP'" -ErrorAction SilentlyContinue
if ($avgSP -and $avgSP.State -eq 'Running') {
    SayRaw ''
    SayRaw '注意：avgSP.sys（AVG 自我保護）正在執行。' 'Yellow'
    SayRaw '      這不影響清理垃圾，但可能阻擋 ProgramData\AVG 的更名。若被阻擋，' 'Yellow'
    SayRaw '      請先在 AVG 主控台關閉自我保護：設定 → 一般 → 疑難排解 → 取消「啟用 AVG 自我保護」。' 'Yellow'
}

# =========================================================
#  Part 1：清理垃圾
# =========================================================
if ($CleanJunk) {
    SayRaw ''
    SayRaw '=== 第一部分：清理垃圾 ===' 'Cyan'

    $targets = New-Object System.Collections.ArrayList

    # 1) 崩潰傾印
    $dumpDir = Join-Path $dataSrc 'Antivirus\log'
    if (Test-Path -LiteralPath $dumpDir) {
        # 注意：-Include 只對「路徑結尾是 \*」或搭配 -Recurse 有效，用 -LiteralPath 會被靜默忽略
        Get-ChildItem -Path (Join-Path $dumpDir '*') -File -Force -Include '*.mdmp', '*.dmp' -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$targets.Add([pscustomobject]@{ Path = $_.FullName; Size = $_.Length; What = '崩潰傾印' }) }
    }

    # 2) 舊 boottimescan
    $btDir = Join-Path $dataSrc 'Antivirus\bootimescan'
    if (Test-Path -LiteralPath $btDir) {
        Get-ChildItem -Path (Join-Path $btDir '*') -File -Force -Include '*.wim' -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$targets.Add([pscustomobject]@{ Path = $_.FullName; Size = $_.Length; What = '舊 boottimescan' }) }
    }

    # 3) 過期病毒定義（保留「最新一個完整版」，只刪比它舊的完整版；*_stream 小目錄不動）
    $defsDir = 'C:\Program Files\AVG\Antivirus\defs'
    if (Test-Path -LiteralPath $defsDir) {
        $full = Get-ChildItem -LiteralPath $defsDir -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{ Dir = $_; Name = $_.Name; MB = [math]::Round((SizeOf $_.FullName) / 1MB, 1) }
            } | Where-Object { $_.Name -notlike '*_stream' -and $_.MB -ge 100 } |
            Sort-Object Name -Descending
        if ($full.Count -gt 1) {
            foreach ($d in ($full | Select-Object -Skip 1)) {
                [void]$targets.Add([pscustomobject]@{ Path = $d.Dir.FullName; Size = (SizeOf $d.Dir.FullName); What = '過期定義' })
            }
            Say ("保留現行定義：{0}（{1:N1} MB）" -f $full[0].Name, $full[0].MB)
        } elseif ($full.Count -eq 1) {
            Say ("只有一個完整定義版本 {0}，不刪。" -f $full[0].Name)
        }
    }

    if ($targets.Count -eq 0) {
        Say '沒有找到可清理的項目。' 'Green'
    } else {
        $total = ($targets | Measure-Object Size -Sum).Sum
        Say ("找到 {0} 個項目，合計 {1:N0} MB：" -f $targets.Count, ($total / 1MB))
        foreach ($t in ($targets | Sort-Object Size -Descending | Select-Object -First 12)) {
            SayRaw ("      {0,9:N1} MB  {1,-12} {2}" -f ($t.Size / 1MB), $t.What, $t.Path) 'DarkGray'
        }
        if ($targets.Count -gt 12) { SayRaw ("      …另有 {0} 個項目" -f ($targets.Count - 12)) 'DarkGray' }

        if ($DryRun) {
            Say ("（DryRun）不會刪除，可回收 {0:N0} MB" -f ($total / 1MB)) 'Yellow'
        } else {
            $freed = [int64]0
            $failed = 0
            foreach ($t in $targets) {
                try {
                    Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
                    $freed += $t.Size
                } catch {
                    $failed++
                    SayRaw ("      刪除失敗：{0}（{1}）" -f $t.Path, $_.Exception.Message) 'Red'
                }
            }
            Say ("實際刪除 {0:N0} MB（失敗 {1} 項）" -f ($freed / 1MB), $failed) `
                $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
        }
    }
}

# =========================================================
#  Part 2：搬 C:\ProgramData\AVG -> D: 並建 junction
# =========================================================
if ($MoveProgramData) {
    SayRaw ''
    SayRaw '=== 第二部分：搬 C:\ProgramData\AVG 到 D: ===' 'Cyan'

    $srcItem = Get-Item -LiteralPath $dataSrc -Force -ErrorAction SilentlyContinue
    if (-not $srcItem) { Say "找不到 $dataSrc" 'Red'; exit 2 }
    if ($srcItem.LinkType) { Say "$dataSrc 已經是 $($srcItem.LinkType)，無需搬移。" 'Yellow'; exit 0 }
    if (Test-Path -LiteralPath $dataDst) { Say "目標已存在：$dataDst（請先確認並清掉）" 'Red'; exit 2 }

    $srcBytes = SizeOf $dataSrc
    $dFree = (Get-PSDrive -Name D).Free
    Say ("來源 {0:N0} MB；D: 可用 {1:N1} GB" -f ($srcBytes / 1MB), ($dFree / 1GB))
    if ($dFree -lt ($srcBytes * 1.2)) { Say 'D: 空間不足（需要約來源的 1.2 倍）' 'Red'; exit 2 }

    $before = @{}
    foreach ($n in $avgSvcs) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $before[$n] = $s.Status.ToString() }
    }
    Say ("AVG 服務現況：{0}" -f (($before.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))

    if ($DryRun) {
        Say '（DryRun）會做：停服務 → robocopy → 逐檔比對 → 原名稱改 .bak → mklink /J → 寫入測試 → 起服務' 'Yellow'
    } else {
        $junctionMade = $false
        $renamed = $false
        try {
            # 1) 停止 AVG 服務（避免搬移期間的檔案鎖與半寫入）
            Say '停止 AVG 服務'
            foreach ($n in $avgSvcs) {
                if ($before.ContainsKey($n)) {
                    Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
                }
            }
            Start-Sleep -Seconds 3
            foreach ($n in $avgSvcs) {
                $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                if ($s) { SayRaw ("      {0,-18} {1}" -f $n, $s.Status) 'DarkGray' }
            }

            # 2) 複製（不用 /MOVE；驗證通過才處理來源）
            Say "複製到 $dataDst"
            New-Item -ItemType Directory -Path $dataDst -Force | Out-Null
            $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList @(
                "`"$dataSrc`"", "`"$dataDst`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ',
                '/R:2', '/W:3', '/NFL', '/NDL', '/NP', "/LOG:`"$logFile.robocopy`""
            )
            Say ("robocopy 結束碼 {0}（0–7 代表成功）" -f $rc.ExitCode)
            if ($rc.ExitCode -ge 8) { throw "robocopy 失敗，結束碼 $($rc.ExitCode)，請看 $logFile.robocopy" }

            # 3) 逐檔比對（跳過 reparse point；只比路徑與大小，不比時間）
            Say '逐檔比對來源與目標'
            $srcMap = @{}
            Get-ChildItem -LiteralPath $dataSrc -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                ForEach-Object { $srcMap[$_.FullName.Substring($dataSrc.Length)] = $_.Length }
            $missing = 0; $diff = 0; $checked = 0
            foreach ($rel in $srcMap.Keys) {
                $checked++
                $dstFile = $dataDst + $rel
                if (-not (Test-Path -LiteralPath $dstFile)) { $missing++; continue }
                if ((Get-Item -LiteralPath $dstFile -Force).Length -ne $srcMap[$rel]) { $diff++ }
            }
            Say ("比對 {0:N0} 檔：缺 {1}、大小不同 {2}" -f $checked, $missing, $diff) `
                $(if (($missing + $diff) -eq 0) { 'Green' } else { 'Red' })
            if (($missing + $diff) -ne 0) { throw "複製不完整（缺 $missing、大小不同 $diff），已中止，未動來源" }

            # 4) 原名稱改名（這一步會被 avgSP 檢查）
            Say "改名 $dataSrc -> $bak"
            try {
                Rename-Item -LiteralPath $dataSrc -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
                $renamed = $true
            } catch {
                throw ("改名被阻擋：{0}`n      這是 AVG 自我保護（avgSP.sys）造成的。" -f $_.Exception.Message)
            }

            # 5) 建立 junction（不用 /s 刪除；建立用 mklink /J）
            Say "建立 junction $dataSrc -> $dataDst"
            $mk = & cmd.exe /c mklink /J "$dataSrc" "$dataDst" 2>&1
            SayRaw ("      $mk") 'DarkGray'
            $li = Get-Item -LiteralPath $dataSrc -Force
            if (-not $li.LinkType) { throw "junction 沒有建立成功（LinkType 為空）" }
            $junctionMade = $true

            # 6) 寫入測試：從 C: 路徑寫，確認檔案落在 D:
            Say '寫入測試（從 C: 路徑寫入，應出現在 D:）'
            $probeName = ".dm-writetest-$stamp"
            $probeC = Join-Path $dataSrc $probeName
            $probeD = Join-Path $dataDst $probeName
            [IO.File]::WriteAllText($probeC, 'junction-test', [Text.Encoding]::UTF8)
            $landed = Test-Path -LiteralPath $probeD
            Remove-Item -LiteralPath $probeC -Force -ErrorAction SilentlyContinue
            Say ("寫入落地 D:：{0}" -f $(if ($landed) { '是' } else { '否' })) $(if ($landed) { 'Green' } else { 'Red' })
            if (-not $landed) { throw '寫入測試失敗：檔案沒有落在 D:' }

            # 7) 啟動 AVG 服務
            Say '啟動 AVG 服務'
            foreach ($n in $avgSvcs) {
                if ($before.ContainsKey($n) -and $before[$n] -eq 'Running') {
                    Start-Service -Name $n -ErrorAction SilentlyContinue
                }
            }
            Start-Sleep -Seconds 4

            # 8) 結果驗證
            SayRaw ''
            SayRaw '--- 驗證 ---' 'Cyan'
            $li2 = Get-Item -LiteralPath $dataSrc -Force
            SayRaw ("      {0}" -f $dataSrc) 'DarkGray'
            SayRaw ("        LinkType : {0}" -f $li2.LinkType) 'DarkGray'
            SayRaw ("        Target   : {0}" -f ($li2.Target -join ', ')) 'DarkGray'
            foreach ($n in $avgSvcs) {
                $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                if ($s) {
                    SayRaw ("        {0,-18} {1}" -f $n, $s.Status) `
                        $(if ($s.Status -eq 'Running' -or $before[$n] -ne 'Running') { 'DarkGray' } else { 'Red' })
                }
            }
            $psi = Join-Path $dataSrc 'Antivirus\psi.db'
            SayRaw ("        psi.db 可讀 : {0}" -f $(if (Test-Path -LiteralPath $psi) { '是' } else { '否（要確認 AVG 是否正常）' })) 'DarkGray'
            SayRaw ''
            Say '完成。請開 AVG 主控台確認「病毒定義版本」正常，並手動按一次「更新」。' 'Green'
            Say '然後看 D:\MX500\avg\ProgramData 的檔案時間是否在動 —— 那代表寫入已經改落在 D:。' 'Green'
            SayRaw ("原始目錄備份保留在：$bak（確認穩定幾天後再刪）") 'DarkGray'
        } catch {
            SayRaw ''
            SayRaw ("失敗：{0}" -f $_.Exception.Message) 'Red'
            SayRaw '--- 開始回滾 ---' 'Yellow'
            try {
                if ($junctionMade) {
                    & cmd.exe /c rmdir "$dataSrc" 2>&1 | Out-Null
                    Say '已移除 junction'
                }
                if ($renamed -and -not (Test-Path -LiteralPath $dataSrc)) {
                    Rename-Item -LiteralPath $bak -NewName (Split-Path $dataSrc -Leaf) -ErrorAction Stop
                    Say '已把原名稱改回來'
                }
                foreach ($n in $avgSvcs) {
                    if ($before.ContainsKey($n) -and $before[$n] -eq 'Running') {
                        Start-Service -Name $n -ErrorAction SilentlyContinue
                    }
                }
                Say '已嘗試重新啟動 AVG 服務'
                if (Test-Path -LiteralPath $dataDst) {
                    SayRaw ("D: 上的複本仍在：$dataDst（確認無用後可手動刪除）") 'DarkGray'
                }
            } catch {
                SayRaw ("回滾時也出錯：{0}" -f $_.Exception.Message) 'Red'
                SayRaw ("請手動處理：來源備份在 $bak") 'Red'
            }
            SayRaw ''
            SayRaw ("完整日誌：$logFile") 'DarkGray'
            exit 3
        }
    }
}

# =========================================================
#  Part 3：還原
# =========================================================
if ($Revert) {
    SayRaw ''
    SayRaw '=== 還原：把 ProgramData\AVG 搬回 C: ===' 'Cyan'
    $li = Get-Item -LiteralPath $dataSrc -Force -ErrorAction SilentlyContinue
    if (-not $li) { Say "$dataSrc 不存在，無法還原" 'Red'; exit 2 }
    if (-not $li.LinkType) { Say "$dataSrc 不是 junction，無需還原" 'Yellow'; exit 0 }
    $target = @($li.Target)[0]
    Say "目前 junction 指向：$target"

    $newestBak = Get-ChildItem -LiteralPath 'C:\ProgramData' -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'AVG.bak-*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newestBak) { Say '找不到 AVG.bak-* 備份目錄，無法還原（D: 上的資料仍在）' 'Red'; exit 2 }
    Say "將還原自：$($newestBak.FullName)"

    if ($DryRun) {
        Say '（DryRun）會做：停服務 → rmdir junction → 改名回來 → 起服務' 'Yellow'
    } else {
        foreach ($n in $avgSvcs) { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
        & cmd.exe /c rmdir "$dataSrc" 2>&1 | Out-Null
        Say '已移除 junction'
        Rename-Item -LiteralPath $newestBak.FullName -NewName 'AVG' -ErrorAction Stop
        Say '已把原名稱改回來'
        foreach ($n in $avgSvcs) { Start-Service -Name $n -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
        foreach ($n in $avgSvcs) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s) { SayRaw ("      {0,-18} {1}" -f $n, $s.Status) 'DarkGray' }
        }
        $li2 = Get-Item -LiteralPath $dataSrc -Force
        Say ("LinkType = {0}（空白代表已是實體目錄）" -f $li2.LinkType)
        Say '還原完成。' 'Green'
        SayRaw ("D: 上的資料仍在：$target（確認無用後可手動刪除）") 'DarkGray'
    }
}

SayRaw ''
SayRaw ("日誌：$logFile") 'DarkGray'
SayRaw ''
