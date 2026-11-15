#Requires -Version 5.1
<#
.SYNOPSIS
    把 Edge 的 User Data 搬到 D:，並在原位置建立 junction（含 DryRun / Verify / Revert）。

.DESCRIPTION
    2026-11-16 實測（本機）：

      C:\Users\ufft4\AppData\Local\Microsoft\Edge\User Data
        1.89 GB / 18,663 個檔案
        LinkType 空（實體目錄，尚未搬過）
        msedge.exe 進程 0 個（搬移時仍會重新檢查）
      D:\MX500\edge 不存在（要建立）；D: 可用 208.8 GB

      同類既有案例（照這個模式做，已穩定運作）：
        C:\Users\ufft4\AppData\Local\Google\Chrome\User Data
          已是 Junction -> D:\MX500\chrome\User Data

    為什麼要搬：Edge 的 profile（Cache、Code Cache、GPU Cache、Service Worker…）
    每天持續寫 C:，搬到 D: 可以把這部分落盤移到 MX500。

    與 AVG 的差別（先講重點）：AVG 是**服務層自我保護**（avgSP.sys）會把 junction
    拆掉、重建實體目錄；Chromium 的 user data 位置是**使用者層設定**，沒有驅動程式
    守著它，Chrome 用同樣做法已經穩定，因此 Edge 預期可以維持。
    但仍請搬完後 `-Verify`，並觀察一天（Edge 更新後再看一次）。

    本腳本不改登錄、不改 Edge 設定、不動 EdgeWebView、不建排程、不刪任何備份。

.PARAMETER DryRun
    只顯示現況、前置檢查與預計步驟，不改任何東西。
    可與 -Apply / -Verify / -Revert 併用，當成該動作的預覽。

.PARAMETER Apply
    實際搬移，順序固定：
      robocopy（/E /COPY:DAT /XJ /R:1 /W:1，不用 /MOVE、不用 /COPYALL）
      → 逐檔比對（兩邊都跳過 reparse point，比對相對路徑 + 檔案大小）
      → 改名 User Data → User Data.bak-<yyyyMMdd-HHmmss>
      → mklink /J 建立 junction
      → 從 C: 路徑寫入測試檔，確認它出現在 D: 再刪掉
    比對不完整就中止並保留現場，不改名、不建 junction。

.PARAMETER Verify
    不搬移，只檢查：junction 存在且指向正確、從 C: 寫入會落在 D:、列出備份目錄。
    結論為 OK（結束碼 0）或 PROBLEM（結束碼 1）。

.PARAMETER Revert
    還原：移除 junction（`cmd /c rmdir`，不用 Remove-Item -Recurse，避免跟進刪掉 D: 的資料）
    → 把最新的 User Data.bak-* 改名回 User Data。
    D: 上的資料保留不動，只提示你確認後自行刪除。

.PARAMETER Root
    日誌根目錄，預設 D:\dev\disk-monitor；日誌寫在 <Root>\logs\move-edge-ud-<時間>.log。

.EXAMPLE
    # 先看會做什麼（不需要任何權限）
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\move-edge-ud.ps1 -DryRun

.EXAMPLE
    # 實際搬移（請先完全關閉 Edge）
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\move-edge-ud.ps1 -Apply

.EXAMPLE
    # 搬完檢查
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\move-edge-ud.ps1 -Verify

.EXAMPLE
    # 還原
    powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\move-edge-ud.ps1 -Revert
#>
param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$Verify,
    [switch]$Revert,
    [string]$Root = 'D:\dev\disk-monitor'
)

$ErrorActionPreference = 'Stop'

# ---------- 常數 ----------
$edgeRoot  = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge'
$src       = Join-Path $edgeRoot 'User Data'
$dst       = 'D:\MX500\edge\User Data'
$dstParent = 'D:\MX500\edge'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak       = "$src.bak-$stamp"
$logDir    = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile   = Join-Path $logDir "move-edge-ud-$stamp.log"

# ---------- 參數檢查：沒有開關時只印說明就結束，避免手滑 ----------
if (-not ($DryRun -or $Apply -or $Verify -or $Revert)) {
    Write-Host '請指定 -DryRun / -Apply / -Verify / -Revert 其中一個（沒有任何開關時不做任何事）。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  -DryRun   只顯示現況、前置檢查與預計步驟（不改任何東西）'
    Write-Host '  -Apply    實際搬移 Edge\User Data 到 D: 並建立 junction'
    Write-Host '  -Verify   檢查搬移結果（結論 OK / PROBLEM）'
    Write-Host '  -Revert   移除 junction，把 User Data.bak-* 改回原名'
    Write-Host ''
    Write-Host ('  例：powershell -ExecutionPolicy Bypass -File "{0}" -DryRun' -f $PSCommandPath)
    exit 2
}
$actions = 0
if ($Apply)  { $actions++ }
if ($Verify) { $actions++ }
if ($Revert) { $actions++ }
if ($actions -gt 1) {
    Write-Host '-Apply / -Verify / -Revert 一次只能指定一個（-DryRun 可搭配任一動作預覽）。' -ForegroundColor Red
    exit 2
}

# ---------- 工具函式 ----------
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
# 檔案數與大小；跳過 reparse point（不要跟進 junction／符號連結）
function Get-TreeInfo([string]$p) {
    $info = [pscustomobject]@{ Bytes = [int64]0; Files = 0 }
    if (-not (Test-Path -LiteralPath $p)) { return $info }
    $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    $info.Files = $files.Count
    $sum = ($files | Measure-Object Length -Sum).Sum
    if ($null -ne $sum) { $info.Bytes = [int64]$sum }
    return $info
}
# 相對路徑 -> 大小（同樣跳過 reparse point）
function Get-FileMap([string]$p) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $p)) { return $map }
    Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $map[$_.FullName.Substring($p.Length)] = $_.Length }
    return $map
}
function Get-EdgeProcs {
    return @(Get-Process -Name msedge -ErrorAction SilentlyContinue)
}
function Get-Backups {
    return @(Get-ChildItem -LiteralPath $edgeRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'User Data.bak-*' } | Sort-Object Name -Descending)
}
function Get-FreeBytes([string]$path) {
    $letter = (Split-Path -Qualifier $path).TrimEnd(':')
    $drv = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if (-not $drv) { return [int64]-1 }
    return [int64]$drv.Free
}
# 前置檢查：回傳檢查清單（-Apply 時任一不通過就中止）
function Test-Preconditions([int64]$srcBytes) {
    $checks = New-Object System.Collections.Generic.List[object]

    $procs = Get-EdgeProcs
    $detail = '0 個'
    if ($procs.Count -gt 0) {
        $detail = ('{0} 個：PID {1}（請自行關閉 Edge；腳本不會去 kill）' -f $procs.Count, (($procs | ForEach-Object { $_.Id }) -join ','))
    }
    $checks.Add([pscustomobject]@{ Name = 'Edge 進程 msedge.exe = 0'; Ok = ($procs.Count -eq 0); Detail = $detail })

    $item = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    $exists = [bool]$item
    $checks.Add([pscustomobject]@{
        Name   = '來源存在'
        Ok     = $exists
        Detail = $(if ($exists) { $src } else { "找不到 $src" })
    })

    $notLink = ($exists -and -not $item.LinkType)
    $linkDetail = '（來源不存在）'
    if ($notLink) { $linkDetail = '實體目錄' }
    elseif ($exists) { $linkDetail = ('已是 {0} -> {1}' -f $item.LinkType, ($item.Target -join ',')) }
    $checks.Add([pscustomobject]@{ Name = '來源不是 reparse point'; Ok = $notLink; Detail = $linkDetail })

    $free = Get-FreeBytes $dst
    $need = [int64]($srcBytes * 1.2)
    $checks.Add([pscustomobject]@{
        Name   = '目標磁碟可用空間 > 來源 × 1.2'
        Ok     = ($free -gt $need)
        Detail = ('可用 {0:N1} GB，需要 {1:N2} GB' -f ($free / 1GB), ($need / 1GB))
    })

    $dstExists = Test-Path -LiteralPath $dst
    $dstFiles = 0
    if ($dstExists) { $dstFiles = (Get-TreeInfo $dst).Files }
    $dstOk = ((-not $dstExists) -or ($dstFiles -eq 0))
    $dstDetail = '不存在（會建立）'
    if ($dstExists -and $dstFiles -eq 0) { $dstDetail = ('存在但沒有檔案：{0}（會沿用）' -f $dst) }
    elseif ($dstExists) { $dstDetail = ('已存在 {0:N0} 檔：{1}（請先確認／清掉再搬）' -f $dstFiles, $dst) }
    $checks.Add([pscustomobject]@{ Name = '目標沒有殘留資料'; Ok = $dstOk; Detail = $dstDetail })

    return $checks
}

# ---------- 開場與現況 ----------
SayRaw ''
SayRaw ("=== Edge User Data 搬到 D:  {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if ($DryRun) { SayRaw '（DryRun：只顯示，不動任何東西）' 'Yellow' }

SayRaw ''
SayRaw '--- 現況 ---' 'Cyan'
$srcItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
if (-not $srcItem) {
    SayRaw ("  找不到來源：{0}" -f $src) 'Red'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 2
}
$tree = Get-TreeInfo $src
$freeBytes = Get-FreeBytes $dst
SayRaw ("  來源      : {0}" -f $src)
SayRaw ("  大小/檔數 : {0:N2} GB / {1:N0} 檔（已跳過 reparse point）" -f ($tree.Bytes / 1GB), $tree.Files)
SayRaw ("  型態      : {0}" -f $(if ($srcItem.LinkType) { "$($srcItem.LinkType) -> $($srcItem.Target -join ',')" } else { '實體目錄' })) `
    $(if ($srcItem.LinkType) { 'Green' } else { 'Gray' })
SayRaw ("  目標      : {0}" -f $dst)
SayRaw ("  目標磁碟  : {0} 可用 {1:N1} GB" -f (Split-Path -Qualifier $dst), ($freeBytes / 1GB))
$procsNow = Get-EdgeProcs
SayRaw ("  Edge 進程 : {0}" -f $(if ($procsNow.Count -eq 0) { '0 個' } else { ('{0} 個（PID {1}）' -f $procsNow.Count, (($procsNow | ForEach-Object { $_.Id }) -join ',')) })) `
    $(if ($procsNow.Count -eq 0) { 'Gray' } else { 'Yellow' })

# =========================================================
#  -Verify：只檢查，不搬移
# =========================================================
if ($Verify) {
    SayRaw ''
    SayRaw '=== 驗證 ===' 'Cyan'
    $problems = New-Object System.Collections.Generic.List[string]

    $item = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        $problems.Add("來源不存在：$src")
        SayRaw ("  型態     : （來源不存在）") 'Red'
    } elseif (-not $item.LinkType) {
        $problems.Add("不是 junction（LinkType 空）：$src")
        SayRaw ("  型態     : 實體目錄（不是 junction）") 'Red'
    } else {
        $target = @($item.Target)[0]
        SayRaw ("  型態     : {0}" -f $item.LinkType) 'DarkGray'
        SayRaw ("  指向     : {0}" -f $target) 'DarkGray'
        if (-not $target) {
            $problems.Add('junction 沒有 Target')
        } elseif ($target.TrimEnd('\') -ne $dst.TrimEnd('\')) {
            $problems.Add(('Target 不符：{0}（預期 {1}）' -f $target, $dst))
        }
        if ($target -and -not (Test-Path -LiteralPath $target)) {
            $problems.Add(('junction 指向的目標不存在（壞連結）：{0}' -f $target))
        }
    }

    if ($DryRun) {
        SayRaw '  落地測試 : （DryRun）略過' 'DarkGray'
    } else {
        try {
            $probe = '.dm-writetest-' + $stamp
            $probeC = Join-Path $src $probe
            $probeD = Join-Path $dst $probe
            [IO.File]::WriteAllText($probeC, 'junction-test', [Text.Encoding]::UTF8)
            $landed = Test-Path -LiteralPath $probeD
            Remove-Item -LiteralPath $probeC -Force -ErrorAction SilentlyContinue
            if ($landed) {
                SayRaw '  落地測試 : 從 C: 寫入 → 出現在 D:（是）' 'Green'
            } else {
                SayRaw '  落地測試 : 從 C: 寫入 → 沒有出現在 D:（否）' 'Red'
                $problems.Add('從 C: 寫入沒有落在 D:')
            }
        } catch {
            SayRaw ("  落地測試 : 失敗（{0}）" -f $_.Exception.Message) 'Red'
            $problems.Add(('落地測試失敗：{0}' -f $_.Exception.Message))
        }
    }

    $baks = Get-Backups
    if ($baks.Count -eq 0) {
        SayRaw '  備份目錄 : 無' 'DarkGray'
    } else {
        foreach ($b in $baks) {
            $bi = Get-TreeInfo $b.FullName
            SayRaw ("  備份目錄 : {0}（{1:N2} GB / {2:N0} 檔）" -f $b.FullName, ($bi.Bytes / 1GB), $bi.Files) 'DarkGray'
        }
    }
    if (Test-Path -LiteralPath $dst) {
        SayRaw ("  D: 資料  : {0}（{1:N2} GB）" -f $dst, ((Get-TreeInfo $dst).Bytes / 1GB)) 'DarkGray'
    } else {
        SayRaw ("  D: 資料  : 不存在（{0}）" -f $dst) 'Yellow'
    }

    SayRaw ''
    if ($problems.Count -eq 0) {
        SayRaw '結論：OK' 'Green'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 0
    }
    foreach ($p in $problems) { SayRaw ("  - {0}" -f $p) 'Red' }
    SayRaw '結論：PROBLEM' 'Red'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 1
}

# =========================================================
#  -Revert：移除 junction 並把備份改名回來
# =========================================================
if ($Revert) {
    SayRaw ''
    SayRaw '=== 還原 ===' 'Cyan'
    $item = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        SayRaw ("  來源不存在：{0}（無法還原）" -f $src) 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }
    $baks = Get-Backups
    if (-not $item.LinkType) {
        SayRaw '  目前不是 junction，沒有需要還原的連結。' 'Yellow'
        if ($baks.Count -gt 0) {
            SayRaw ("  但仍有備份：{0}（若確定要用它，請自行改名）" -f $baks[0].FullName) 'Yellow'
        }
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 0
    }
    if ($baks.Count -eq 0) {
        SayRaw '  找不到 User Data.bak-* 備份，無法還原（D: 上的資料仍在，不會被動到）' 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }
    $newest = $baks[0]
    SayRaw ("  目前 junction : {0} -> {1}" -f $src, (@($item.Target)[0])) 'DarkGray'
    SayRaw ("  最新備份     : {0}" -f $newest.FullName) 'DarkGray'

    if ($DryRun) {
        SayRaw ''
        SayRaw '（DryRun）會做：' 'Yellow'
        SayRaw ("  1) cmd /c rmdir `"{0}`"（只移除連結，不會跟進刪 D:）" -f $src) 'DarkGray'
        SayRaw ("  2) 把 {0} 改名回 User Data" -f $newest.Name) 'DarkGray'
        SayRaw ("  3) D: 上的資料保留不動：{0}" -f $dst) 'DarkGray'
        $procs = Get-EdgeProcs
        if ($procs.Count -gt 0) {
            SayRaw ("  注意：Edge 正在執行（PID {0}），實際還原前請先關閉。" -f (($procs | ForEach-Object { $_.Id }) -join ',')) 'Yellow'
        }
        SayRaw ''
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 0
    }

    $procs = Get-EdgeProcs
    if ($procs.Count -gt 0) {
        SayRaw ("  Edge 正在執行（PID {0}），請先完全關閉再還原。" -f (($procs | ForEach-Object { $_.Id }) -join ',')) 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }

    SayRaw ''
    SayRaw '--- 移除 junction ---' 'Cyan'
    # 用 rmdir（不加 /s）：只移除連結本身，不會跟進刪掉 D: 的資料
    & cmd.exe /c rmdir "$src" 2>&1 | Out-Null
    if (Test-Path -LiteralPath $src) {
        SayRaw '  移除 junction 失敗（路徑仍然存在），中止（沒有動備份）。' 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }
    Say '已移除 junction（未跟進刪除 D: 的資料）'

    SayRaw ''
    SayRaw '--- 把備份改名回來 ---' 'Cyan'
    Rename-Item -LiteralPath $newest.FullName -NewName (Split-Path $src -Leaf) -ErrorAction Stop
    Say ('已把 {0} 改名回 User Data' -f $newest.Name) 'Green'

    $li = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if ($li -and -not $li.LinkType) {
        Say ('{0} 現在是實體目錄（{1:N2} GB）' -f $src, ((Get-TreeInfo $src).Bytes / 1GB)) 'Green'
    } else {
        Say '改名後型態不正確，請人工確認。' 'Red'
    }
    SayRaw ''
    SayRaw ("D: 上的資料保留不動：{0}" -f $dst) 'DarkGray'
    SayRaw '請開 Edge 確認可正常使用；確認無用後再自行刪除 D: 上的副本。' 'Green'
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 0
}

# =========================================================
#  前置檢查（-Apply 與 -DryRun 共用）
# =========================================================
SayRaw ''
SayRaw '--- 前置檢查 ---' 'Cyan'
$checks = Test-Preconditions $tree.Bytes
$bad = 0
foreach ($c in $checks) {
    $mark = '[OK]  '
    $color = 'Green'
    if (-not $c.Ok) { $mark = '[NG]  '; $color = 'Red'; $bad++ }
    SayRaw ("  {0} {1}：{2}" -f $mark, $c.Name, $c.Detail) $color
}

# =========================================================
#  -Apply -DryRun：只印計畫
# =========================================================
if ($Apply -and $DryRun) {
    SayRaw ''
    if ($bad -gt 0) {
        SayRaw ("（DryRun）有 {0} 項未通過 —— 真正跑 -Apply 時會在這裡中止。" -f $bad) 'Yellow'
    } else {
        SayRaw '（DryRun）前置檢查全部通過。' 'Green'
    }
    SayRaw ''
    SayRaw '（DryRun）會做：' 'Yellow'
    SayRaw ("  1) robocopy /E /COPY:DAT /XJ /R:1 /W:1 `"{0}`" `"{1}`"" -f $src, $dst) 'DarkGray'
    SayRaw '  2) 逐檔比對（相對路徑 + 大小；兩邊都跳過 reparse point）→ 缺檔或大小不同就中止，不改名' 'DarkGray'
    SayRaw ("  3) 把 {0} 改名為 User Data.bak-<時間>" -f $src) 'DarkGray'
    SayRaw ("  4) mklink /J `"{0}`" `"{1}`"" -f $src, $dst) 'DarkGray'
    SayRaw '  5) 從 C: 路徑寫入測試檔，確認出現在 D: 後刪除' 'DarkGray'
    SayRaw '  6) 保留 .bak 與 D: 上的資料，不刪任何東西' 'DarkGray'
    SayRaw ''
    SayRaw ("日誌：$logFile") 'DarkGray'
    exit 0
}

# =========================================================
#  -Apply：實際搬移
# =========================================================
if ($Apply) {
    if ($bad -gt 0) {
        SayRaw ''
        SayRaw ("有 {0} 項前置檢查未通過，中止（沒有動任何東西）。" -f $bad) 'Red'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 2
    }

    $renamed = $false
    $junctionMade = $false
    try {
        SayRaw ''
        SayRaw '--- 1/5 複製到 D: ---' 'Cyan'
        if (-not (Test-Path -LiteralPath $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
            Say ("已建立 {0}" -f $dstParent)
        }
        $rcArgs = @("`"$src`"", "`"$dst`"", '/E', '/COPY:DAT', '/XJ', '/R:1', '/W:1',
                    '/NFL', '/NDL', '/NP', "/LOG:`"$logFile.robocopy`"")
        $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList $rcArgs
        Say ("robocopy 結束碼 {0}（0–7 代表成功）" -f $rc.ExitCode) $(if ($rc.ExitCode -lt 8) { 'Green' } else { 'Red' })
        if ($rc.ExitCode -ge 8) { throw ("robocopy 失敗（結束碼 {0}），詳見 {1}.robocopy" -f $rc.ExitCode, $logFile) }

        SayRaw ''
        SayRaw '--- 2/5 逐檔比對 ---' 'Cyan'
        $srcMap = Get-FileMap $src
        $dstMap = Get-FileMap $dst
        $missing = 0
        $diff = 0
        $extra = 0
        foreach ($rel in $srcMap.Keys) {
            if (-not $dstMap.ContainsKey($rel)) { $missing++; continue }
            if ($dstMap[$rel] -ne $srcMap[$rel]) { $diff++ }
        }
        foreach ($rel in $dstMap.Keys) {
            if (-not $srcMap.ContainsKey($rel)) { $extra++ }
        }
        Say ("來源 {0:N0} 檔 / 目標 {1:N0} 檔：缺 {2}、大小不同 {3}、目標多出 {4}" -f $srcMap.Count, $dstMap.Count, $missing, $diff, $extra) `
            $(if (($missing + $diff) -eq 0) { 'Green' } else { 'Red' })
        if (($missing + $diff) -ne 0) {
            throw ("複製不完整（缺 {0}、大小不同 {1}）：已中止，未改名、未建 junction" -f $missing, $diff)
        }

        SayRaw ''
        SayRaw '--- 3/5 改名為備份 ---' 'Cyan'
        Rename-Item -LiteralPath $src -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
        $renamed = $true
        Say ("{0} -> {1}" -f (Split-Path $src -Leaf), (Split-Path $bak -Leaf)) 'Green'

        SayRaw ''
        SayRaw '--- 4/5 建立 junction ---' 'Cyan'
        $mk = & cmd.exe /c mklink /J "$src" "$dst" 2>&1
        SayRaw ("  {0}" -f $mk) 'DarkGray'
        $li = Get-Item -LiteralPath $src -Force
        if (-not $li.LinkType) { throw 'junction 沒有建立成功（LinkType 為空）' }
        $junctionMade = $true
        Say ("{0} -> {1}" -f $li.LinkType, ($li.Target -join ',')) 'Green'

        SayRaw ''
        SayRaw '--- 5/5 寫入落地測試 ---' 'Cyan'
        $probe = '.dm-writetest-' + $stamp
        [IO.File]::WriteAllText((Join-Path $src $probe), 'junction-test', [Text.Encoding]::UTF8)
        $landed = Test-Path -LiteralPath (Join-Path $dst $probe)
        Remove-Item -LiteralPath (Join-Path $src $probe) -Force -ErrorAction SilentlyContinue
        Say ("從 C: 路徑寫入，檔案出現在 D:：{0}" -f $(if ($landed) { '是' } else { '否' })) `
            $(if ($landed) { 'Green' } else { 'Red' })
        if (-not $landed) { throw '寫入落地測試失敗（檔案沒有出現在 D:）' }

        SayRaw ''
        SayRaw '=== 完成 ===' 'Cyan'
        SayRaw ("  {0} -> {1}" -f $src, $dst) 'Green'
        SayRaw ("  原始資料保留：{0}" -f $bak) 'DarkGray'
        SayRaw '  請開 Edge 確認書籤／登入狀態正常，再用 -Verify 複查。' 'Green'
        SayRaw '  備份不會自動刪除（腳本不刪任何備份），確認穩定幾天後自行處理。' 'DarkGray'
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 0
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
                Rename-Item -LiteralPath $bak -NewName (Split-Path $src -Leaf) -ErrorAction Stop
                Say '已把 User Data 改名回來'
            }
        } catch {
            SayRaw ("回滾也出錯：{0}" -f $_.Exception.Message) 'Red'
            SayRaw ("請手動處理：備份在 {0}" -f $bak) 'Red'
        }
        if (Test-Path -LiteralPath $dst) {
            SayRaw ("D: 上的複本仍在：{0}（確認無用後可手動刪除）" -f $dst) 'DarkGray'
        }
        SayRaw ("日誌：$logFile") 'DarkGray'
        exit 3
    }
}

# =========================================================
#  只有 -DryRun：印計畫
# =========================================================
SayRaw ''
if ($bad -gt 0) {
    SayRaw ("（DryRun）有 {0} 項未通過 —— 真正跑 -Apply 時會在這裡中止。" -f $bad) 'Yellow'
} else {
    SayRaw '（DryRun）前置檢查全部通過。' 'Green'
}
SayRaw ''
SayRaw '（DryRun）會做：' 'Yellow'
SayRaw ("  1) robocopy /E /COPY:DAT /XJ /R:1 /W:1 `"{0}`" `"{1}`"" -f $src, $dst) 'DarkGray'
SayRaw '  2) 逐檔比對（相對路徑 + 大小；兩邊都跳過 reparse point）→ 缺檔或大小不同就中止，不改名' 'DarkGray'
SayRaw ("  3) 把 {0} 改名為 User Data.bak-<時間>" -f $src) 'DarkGray'
SayRaw ("  4) mklink /J `"{0}`" `"{1}`"" -f $src, $dst) 'DarkGray'
SayRaw '  5) 從 C: 路徑寫入測試檔，確認出現在 D: 後刪除' 'DarkGray'
SayRaw '  6) 保留 .bak 與 D: 上的資料，不刪任何東西' 'DarkGray'
SayRaw '  不改登錄、不改 Edge 設定、不動 EdgeWebView、不建排程' 'DarkGray'
SayRaw ''
SayRaw ("日誌：$logFile") 'DarkGray'
SayRaw ''
exit 0
