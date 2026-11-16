<#
    cwatch-dashboard.ps1 —— 本機儀表板（http://localhost:8737）

    資料來源全部是既有檔案，不另存一份：
      data\phys\*.csv            實體裝置落盤量（真正寫到裝置的位元組）
      data\attrib\*.csv          ETW 歸因：minute,pid,process,volume,path,bytes,ops
      logs\hourly-summary.log    每小時摘要（畫走勢）
      data\state\collector.json  collector 心跳

    兩個輸出口，資料都來自同一個 Get-DashboardState（不各算一份）：
      GET /            伺服器渲染好的完整 HTML（首次載入就有資料，不必等 JS）
      GET /api/state   同一份資料的 JSON；前端每 15 秒只抓這支、只換 DOM，不整頁重載

    用法：
      -Once            只輸出 reports\dashboard.html 後結束（測試／靜態存檔用）
      -Port 8737       監聽埠（測試請用 8738，不要動托盤顧著的 8737）
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor',
    [int]$Port = 8737,
    [switch]$Once,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Format-Bytes([double]$b) {
    if ([math]::Abs($b) -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ([math]::Abs($b) -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ([math]::Abs($b) -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}
function Format-Rate([double]$bps) {
    if ($bps -ge 1MB) { return ('{0:N2} MB/s' -f ($bps / 1MB)) }
    if ($bps -ge 1KB) { return ('{0:N1} KB/s' -f ($bps / 1KB)) }
    return ('{0:N0} B/s' -f $bps)
}

# ---------- 讀 phys 最後 N 筆（每裝置） ----------
function Get-PhysTail([datetime]$day, [int]$keep) {
    $f = Join-Path $Root ('data\phys\' + $day.ToString('yyyy-MM-dd') + '.csv')
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $lines = [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)
    if ($lines.Length -le 1) { return @() }
    $start = [math]::Max(1, $lines.Length - $keep)
    $out = @()
    for ($i = $start; $i -lt $lines.Length; $i++) {
        $p = $lines[$i].Split(',')
        if ($p.Length -lt 11) { continue }
        $out += [pscustomobject]@{
            ts = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $inv)
            dev = $p[1]; vols = $p[2]
            perf = [int64]$p[3]; freq = [int64]$p[4]
            rb = [int64]$p[5]; wb = [int64]$p[6]
        }
    }
    return $out
}

# 磁碟區相對路徑（\Device\HarddiskVolumeN\...）被冠上磁碟機代號後，會長成
#   C:\Device\HarddiskVolume12\download\...
# 那不是 C: 的檔案（HarddiskVolume12 是另一顆碟），而是「無法對應磁碟機」的路徑。
$devicePathPattern = '^[A-Za-z]:\\Device\\HarddiskVolume\d+|^\\\\\?\\Device\\|^\\Device\\'
# 路徑可信度（與 clean-attrib.ps1 同一套規則）：
#   目錄 = 可疑；不存在且不在暫存／快取路徑下 = 可疑
# 實測 2026-11-15：Robocopy 的幻影列（C:\Users\ufft4\.claude\ide 9.4 GB、
# herdr\client\endpoints.json 7.6 GB、ApplicationInsightsDiagnostics.json 4.6 GB…）
# 都在這裡被擋掉，排行榜與覆蓋率才不會被灌爆。
$ephemeralPath = '\\Temp\\|\\Temporary Internet Files\\|\\INetCache\\|\\Cache\\|\\Sessions\\|\\Crashpad\\|\\Code Cache\\|\\GPUCache\\|\\Logs?\\|\.tmp$|\.log$|\.etl$|\.dmp$'
$script:verdictCache = @{}
function Get-PathTrust([string]$p) {
    # 路徑不明時，「磁碟區」也是猜的（實測：Robocopy 寫 F:，卻被記成 volume=C:、
    # path=(其他)，4.1 GB）。這種列不能算給任何磁碟區，一律歸 (device)。
    if ($p -eq '(其他)' -or $p -eq '(unknown)') { return 'device' }
    if ($p -match $devicePathPattern) { return 'device' }
    if ($script:verdictCache.ContainsKey($p)) { return $script:verdictCache[$p] }
    $v = 'suspect'
    try {
        $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ($i.PSIsContainer) { $v = 'dir' } else { $v = 'ok' }
    } catch {
        if ($p -match $ephemeralPath) { $v = 'ok' }
    }
    $script:verdictCache[$p] = $v
    return $v
}

# 某磁碟區今日累計 + 最近速率
# 注意：要用「磁碟區標籤」查，不要用裝置編號。
# 實測 2026-11-15：裝置編號會在重開機後對調（dev 2 從 I:F: 變成 D:、dev 3 從 D: 變成 I:F:），
# 若用 dev 3 當鍵，會把 D: 與 Robocopy 正在灌的 I:/F: 加在一起（127 GB 假數字）。
function Get-VolumeStat($rows, [string]$vol) {
    $list = @($rows | Where-Object { $_.vols -eq $vol } | Sort-Object ts)
    $r = [pscustomobject]@{ Write = [double]0; Read = [double]0; Rate = 0.0; LastTs = $null; Elapsed = 0.0 }
    if ($list.Count -lt 2) { return $r }
    $prev = $null
    foreach ($x in $list) {
        if ($null -ne $prev) {
            # 裝置編號在同一個磁碟區標籤下變了 → 這是兩顆不同的碟，不能相減
            if ($x.dev -ne $prev.dev) { $prev = $x; continue }
            $e = ($x.perf - $prev.perf) / [double]$prev.freq
            if ($e -gt 0) {
                $dw = $x.wb - $prev.wb
                $dr = $x.rb - $prev.rb
                if ($dw -gt 0) { $r.Write += $dw }
                if ($dr -gt 0) { $r.Read += $dr }
            }
        }
        $prev = $x
    }
    # 最後兩筆的瞬時速率
    $a = $list[$list.Count - 2]; $b = $list[$list.Count - 1]
    $el = ($b.perf - $a.perf) / [double]$a.freq
    if ($el -gt 0) {
        $r.Rate = [math]::Max(0, $b.wb - $a.wb) / $el
        $r.Elapsed = $el
    }
    $r.LastTs = $b.ts
    return $r
}

# ---------- 讀 attrib 尾巴（只讀最後 250 KB，避免整天檔案拖慢） ----------
function Get-AttribTail([string]$path, [int]$bytes = 262144) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
    $fi = Get-Item -LiteralPath $path
    $rows = @()
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $startAt = [math]::Max(0, $fi.Length - $bytes)
        $null = $fs.Seek($startAt, [IO.SeekOrigin]::Begin)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
    } finally { $fs.Dispose() }
    $lines = $text -split "`r?`n"
    $skipFirst = $true
    if ($startAt -eq 0) { $skipFirst = $false }
    foreach ($ln in $lines) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        if ($skipFirst) { $skipFirst = $false; continue }
        if ($ln.StartsWith('minute,')) { continue }
        $p = $ln.Split(',')
        if ($p.Length -lt 7) { continue }
        # path 可能含逗號 → 最後兩欄一定是數字，前面合併
        $bytesIdx = $p.Length - 2
        $opsIdx = $p.Length - 1
        $b = 0.0; $o = 0.0
        if (-not [double]::TryParse($p[$bytesIdx], [ref]$b)) { continue }
        if (-not [double]::TryParse($p[$opsIdx], [ref]$o)) { continue }
        $vol = $p[3]
        $proc = $p[2]
        $path = ($p[4..($bytesIdx - 1)] -join ',')
        $rows += [pscustomobject]@{ Minute = $p[0]; Pid = $p[1]; Process = $proc; Volume = $vol; Path = $path.Trim('"'); Bytes = $b; Ops = $o }
    }
    return $rows
}

# ---------- 每小時走勢 ----------
function Get-Hourly([int]$count = 24) {
    $f = Join-Path $Root 'logs\hourly-summary.log'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $out = @()
    foreach ($ln in (Get-Content -LiteralPath $f -Encoding UTF8 -Tail $count)) {
        $m = [regex]::Match($ln, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}) \| C: disk ([\d\.]+) (KB|MB|GB)')
        if (-not $m.Success) { continue }
        $v = [double]$m.Groups[2].Value
        switch ($m.Groups[3].Value) {
            'KB' { $v = $v * 1KB }
            'MB' { $v = $v * 1MB }
            'GB' { $v = $v * 1GB }
        }
        $out += [pscustomobject]@{ When = $m.Groups[1].Value; Bytes = $v }
    }
    return $out
}

function Get-Heartbeat {
    $f = Join-Path $Root 'data\state\collector.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

# ---------- 某一小時的 ETW 明細（點長條圖用） ----------
# 這張表是 ETW 的「邏輯寫入」，與長條圖的 PhysicalDisk「實體落盤」是不同量測，不能相加。
# 快取：$script:hourCache[date|hour] = @{ Mtime; Value }；attrib 檔 LastWriteTimeUtc 沒變就重用。
$script:hourCache = @{}
function Get-HourDetail([string]$date, [int]$hour) {
    $label = ('{0:00}:00–{0:00}:59' -f $hour)
    $file = Join-Path $Root ('data\attrib\' + $date + '.csv')
    $empty = [pscustomobject]@{
        date = $date; hour = $hour; label = $label
        totalBytes = [double]0; totalBytesText = (Format-Bytes 0)
        totalOps = [double]0; totalOpsText = '0'
        groups = 0; rows = @()
    }
    if (-not (Test-Path -LiteralPath $file)) { return $empty }

    $mtime = (Get-Item -LiteralPath $file).LastWriteTimeUtc
    $key = $date + '|' + $hour
    if ($script:hourCache.ContainsKey($key)) {
        $hit = $script:hourCache[$key]
        if ($hit.Mtime -eq $mtime) { return $hit.Value }
    }

    $hh = ('{0:00}' -f $hour)
    $agg = @{}
    $totalBytes = [double]0
    $totalOps = [double]0
    # 整天檔（約 8 MB）；欄位：minute,pid,process,volume,path,bytes,ops（path 可能含逗號）
    foreach ($ln in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        if ($ln.Length -lt 20) { continue }
        if ($ln.StartsWith('minute,')) { continue }
        $p = $ln.Split(',')
        if ($p.Length -lt 6) { continue }
        $minute = $p[0]
        if ($minute.Length -lt 16) { continue }
        if ($minute.Substring(11, 2) -ne $hh) { continue }
        $opsIdx = $p.Length - 1
        $bytesIdx = $p.Length - 2
        $b = 0.0; $o = 0.0
        if (-not [double]::TryParse($p[$bytesIdx], [ref]$b)) { continue }
        if (-not [double]::TryParse($p[$opsIdx], [ref]$o)) { continue }
        $proc = $p[2]
        $vol = $p[3]
        $path = ($p[4..($bytesIdx - 1)] -join ',')
        $path = $path.Trim('"')
        $k = $proc + '|' + $vol
        if (-not $agg.ContainsKey($k)) {
            $agg[$k] = [pscustomobject]@{ Process = $proc; Volume = $vol; Bytes = [double]0; Ops = [double]0; Files = @{} }
        }
        $agg[$k].Bytes += $b
        $agg[$k].Ops += $o
        if ($path -ne '(其他)' -and $path -ne '(unknown)') {
            if (-not $agg[$k].Files.ContainsKey($path)) { $agg[$k].Files[$path] = [double]0 }
            $agg[$k].Files[$path] += $b
        }
        $totalBytes += $b
        $totalOps += $o
    }

    $rows = @()
    foreach ($a in @($agg.Values | Sort-Object Bytes -Descending | Select-Object -First 20)) {
        $files = @()
        foreach ($t in @($a.Files.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3)) {
            $files += [pscustomobject]@{ path = [string]$t.Key; bytes = [double]$t.Value; bytesText = (Format-Bytes $t.Value) }
        }
        $rows += [pscustomobject]@{
            process   = [string]$a.Process
            volume    = [string]$a.Volume
            bytes     = [double]$a.Bytes
            bytesText = (Format-Bytes $a.Bytes)
            ops       = [double]$a.Ops
            opsText   = ('{0:N0}' -f $a.Ops)
            files     = $files
        }
    }

    $value = [pscustomobject]@{
        date = $date; hour = $hour; label = $label
        totalBytes = $totalBytes; totalBytesText = (Format-Bytes $totalBytes)
        totalOps = $totalOps; totalOpsText = ('{0:N0}' -f $totalOps)
        groups = $agg.Count; rows = $rows
    }
    $script:hourCache[$key] = [pscustomobject]@{ Mtime = $mtime; Value = $value }
    return $value
}

# ---------- 收集資料：HTML 與 JSON 的唯一來源 ----------
# 回傳一個物件；JSON 直接序列化它，HTML 只是把它排版。兩邊不會各算一份。
function Get-DashboardState([bool]$Live = $true) {
    $now = Get-Date
    $today = $now.Date
    # 讀整天（檔案很小，約 8k 行/日）；先前只讀尾巴 400 行，會讓「今日」只算到最近一小時
    $rows = Get-PhysTail $today 100000
    $c = Get-VolumeStat $rows 'C:'
    $d = Get-VolumeStat $rows 'D:'

    $hb = Get-Heartbeat
    $hbAge = -1
    if ($null -ne $hb -and $hb.updated) {
        try { $hbAge = [int]($now - [datetime]::ParseExact($hb.updated, 'yyyy-MM-dd HH:mm:ss', $inv)).TotalSeconds } catch { }
    }
    $collState = '未啟動'
    $collColor = '#8b949e'
    if ($hbAge -ge 0 -and $hbAge -lt 90) { $collState = '執行中'; $collColor = '#3fb950' }
    elseif ($hbAge -ge 90) { $collState = '停住了（' + $hbAge + ' 秒未更新）'; $collColor = '#d29922' }
    $bytesSeen = 0
    if ($null -ne $hb) { $bytesSeen = [double]$hb.bytes_seen }
    $hbLine = 'collector 尚未啟動'
    if ($null -ne $hb) { $hbLine = 'collector 心跳：' + $hb.updated + '（pid ' + $hb.pid + '）' }

    # 跨日或今日尚無資料時，回退到最近一份有內容的檔案
    $attribDir = Join-Path $Root 'data\attrib'
    $todayFile = Join-Path $attribDir ($today.ToString('yyyy-MM-dd') + '.csv')
    $attrFile = $null
    if ((Test-Path -LiteralPath $todayFile) -and ((Get-Item $todayFile).Length -gt 200)) {
        $attrFile = $todayFile
    } else {
        $latest = Get-ChildItem -LiteralPath $attribDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { $attrFile = $latest.FullName }
    }
    $attrMtime = '（無）'
    if ($attrFile -and (Test-Path -LiteralPath $attrFile)) { $attrMtime = (Get-Item -LiteralPath $attrFile).LastWriteTime.ToString('HH:mm:ss') }
    $physFileNow = Join-Path $Root ('data\phys\' + $today.ToString('yyyy-MM-dd') + '.csv')
    $physMtime = '（無）'
    if (Test-Path -LiteralPath $physFileNow) { $physMtime = (Get-Item -LiteralPath $physFileNow).LastWriteTime.ToString('HH:mm:ss') }

    $attrLabel = '今日'
    if ($attrFile -and ([IO.Path]::GetFileNameWithoutExtension($attrFile) -ne $today.ToString('yyyy-MM-dd'))) {
        $attrLabel = [IO.Path]::GetFileNameWithoutExtension($attrFile) + '（今日尚無資料）'
    }

    # 只採信「歸因邏輯修正後」的資料；更早的列由舊版產生，含已知的假路徑
    $trustedPath = Join-Path $Root 'data\state\attrib-trusted-since.txt'
    $trusted = $null
    if (Test-Path -LiteralPath $trustedPath) {
        try { $trusted = (Get-Content -LiteralPath $trustedPath -Raw -Encoding UTF8).Trim() } catch { }
    }
    $attrAll = @(Get-AttribTail $attrFile)
    $attr = @()
    foreach ($r in $attrAll) {
        if ($trusted -and ($r.Minute -lt $trusted)) { continue }
        $attr += $r
    }
    $droppedRows = $attrAll.Count - $attr.Count
    $agg = @{}
    $suspectBytes = [double]0
    $deviceBytes = [double]0
    foreach ($r in $attr) {
        $trust = Get-PathTrust $r.Path
        if ($trust -ne 'ok') {
            # 裝置層級（volume 本身就是 (device)）= 真的無法歸屬
            # 其他（路徑不存在／是目錄／路徑不明）= 可疑列，可能是 ETW 的幻影歸因
            if ($r.Volume -eq '(device)') { $deviceBytes += $r.Bytes } else { $suspectBytes += $r.Bytes }
            continue
        }
        $vol = $r.Volume
        $k = $r.Process + '|' + $vol
        if (-not $agg.ContainsKey($k)) {
            $agg[$k] = [pscustomobject]@{ Process = $r.Process; Volume = $vol; Bytes = [double]0; Ops = [double]0; Files = @{} }
        }
        $agg[$k].Bytes += $r.Bytes
        $agg[$k].Ops += $r.Ops
        if ($r.Path -ne '(其他)' -and $r.Path -ne '(unknown)') {
            if (-not $agg[$k].Files.ContainsKey($r.Path)) { $agg[$k].Files[$r.Path] = [double]0 }
            $agg[$k].Files[$r.Path] += $r.Bytes
        }
    }
    $topAll = @($agg.Values | Sort-Object Bytes -Descending | Select-Object -First 15)
    $topC = @($agg.Values | Where-Object { $_.Volume -eq 'C:' } | Sort-Object Bytes -Descending | Select-Object -First 12)

    # 具名覆蓋率：ETW 認得的 C: 寫入 ÷ PhysicalDisk 實測的 C: 寫入
    $namedC = [double]0
    foreach ($a in $agg.Values) { if ($a.Volume -eq 'C:') { $namedC += $a.Bytes } }
    $coverageNote = '（尚未有足夠資料計算覆蓋率）'
    if ($trusted) {
        $coverageNote = ('只採信 {0} 之後的資料' -f $trusted.Substring(11))
        if ($droppedRows -gt 0) { $coverageNote += ('（已排除 {0:N0} 列舊版紀錄）' -f $droppedRows) }
        $coverageNote += '。'
    }
    # 分子（ETW）只涵蓋 collector 啟動之後，所以分母也要用同一時間窗，否則會低估
    $firstMin = $null
    foreach ($r in $attr) { if ($null -eq $firstMin -or $r.Minute -lt $firstMin) { $firstMin = $r.Minute } }
    if ($null -ne $firstMin -and $c.Write -gt 0) {
        $windowStart = $null
        try { $windowStart = [datetime]::ParseExact($firstMin + ':00', 'yyyy-MM-dd HH:mm:ss', $inv) } catch { }
        $win = [double]0
        if ($null -ne $windowStart) {
            $prevWb = $null
            $prevDev = $null
            $cRows = @($rows | Where-Object { $_.vols -eq 'C:' } | Sort-Object ts)
            foreach ($x in $cRows) {
                if ($null -ne $prevWb -and $x.dev -eq $prevDev -and $x.ts -ge $windowStart -and $x.wb -ge $prevWb) {
                    $win += ($x.wb - $prevWb)
                }
                $prevWb = $x.wb
                $prevDev = $x.dev
            }
        }
        if ($win -gt 0) {
            # 只在不誇張時才顯示百分比；>105% 代表 ETW 這一層把別的磁碟區也算進來了
            # （實測 2026-11-15：Robocopy 寫 F: 被記成 C:，覆蓋率一度顯示 7,765%）
            $ratio = $namedC / $win * 100
            if ($ratio -le 105) {
                $coverageNote = ('具名覆蓋率 {0:N1}%（{1} 起）：ETW 認得 {2} ／ PhysicalDisk 實測 {3}。' -f $ratio, $firstMin.Substring(11), (Format-Bytes $namedC), (Format-Bytes $win))
                if ($ratio -lt 60) {
                    $coverageNote += ' 這個比例本來就偏低：ETW 只看得到「有檔名的寫入」，其餘是未緩衝 I/O（Robocopy /J、資料庫）與核心內部寫入（登錄檔 hive、NTFS 日誌／MFT、映射回寫）—— 後者原理上沒有行程可歸因。'
                }
            } else {
                $coverageNote = ('具名 {0} ＞ 實測 {1}（{2} 起）：ETW 有列被歸到錯的磁碟區，已從排行榜排除；兩個數字僅供參考。' -f (Format-Bytes $namedC), (Format-Bytes $win), $firstMin.Substring(11))
            }
        }
    }

    $hourly = Get-Hourly 24
    $maxH = 0.0
    foreach ($h in $hourly) { if ($h.Bytes -gt $maxH) { $maxH = $h.Bytes } }

    # sparkline（自家產生、不含任何使用者輸入，前端可以直接 innerHTML）
    # 只有線上模式才加 data-hour／cursor：-Once 的靜態快照不可以留下互動程式碼
    $svg = ''
    if ($hourly.Count -gt 1 -and $maxH -gt 0) {
        $w = 720; $hgt = 90; $bw = [math]::Floor($w / $hourly.Count) - 2
        $bars = ''
        $i = 0
        foreach ($x in $hourly) {
            $bh = [int](($x.Bytes / $maxH) * ($hgt - 10))
            if ($bh -lt 1) { $bh = 1 }
            $xpos = 4 + $i * ($bw + 2)
            $dyn = ''
            if ($Live -and $x.When.Length -ge 13) { $dyn = (' data-hour="{0}" style="cursor:pointer"' -f $x.When.Substring(11, 2)) }
            $bars += ('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#1f6feb" rx="1"{6}><title>{4}  {5}</title></rect>' -f `
                $xpos, ($hgt - $bh), $bw, $bh, $x.When, (Format-Bytes $x.Bytes), $dyn)
            $i++
        }
        $svg = ('<svg width="{0}" height="{1}" viewBox="0 0 {0} {1}">{2}</svg>' -f $w, $hgt, $bars)
    } else {
        $svg = '<div class="muted">還沒有 2 個以上的小時資料</div>'
    }

    $rateTxt = Format-Rate $c.Rate
    $rateColor = '#3fb950'
    if ($c.Rate -gt 5MB) { $rateColor = '#d29922' }
    if ($c.Rate -gt 20MB) { $rateColor = '#f85149' }

    # 排行榜 → 給前端用的形狀（文字欄位先在後端算好，兩邊顯示才會一致）
    function ConvertTo-ProcList($list, [int]$maxFiles) {
        $out = @()
        foreach ($a in $list) {
            $files = @()
            if ($maxFiles -gt 0) {
                foreach ($t in @($a.Files.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $maxFiles)) {
                    $files += [pscustomobject]@{ path = [string]$t.Key; text = (Format-Bytes $t.Value) }
                }
            }
            $out += [pscustomobject]@{
                process   = [string]$a.Process
                volume    = [string]$a.Volume
                bytes     = [double]$a.Bytes
                bytesText = (Format-Bytes $a.Bytes)
                ops       = [double]$a.Ops
                opsText   = ('{0:N0}' -f $a.Ops)
                files     = $files
            }
        }
        return $out
    }

    $hours = @()
    foreach ($x in $hourly) {
        $hours += [pscustomobject]@{ when = [string]$x.When; bytes = [double]$x.Bytes; text = (Format-Bytes $x.Bytes) }
    }

    return [pscustomobject]@{
        generatedAt    = $now.ToString('o')
        generatedLocal = $now.ToString('yyyy-MM-dd HH:mm:ss')
        clock          = $now.ToString('HH:mm:ss')
        rate           = [double]$c.Rate
        rateText       = $rateTxt
        rateColor      = $rateColor
        todayTotal     = [pscustomobject]@{ bytes = [double]$c.Write; text = (Format-Bytes $c.Write) }
        todayD         = [pscustomobject]@{ bytes = [double]$d.Write; text = (Format-Bytes $d.Write) }
        hours          = $hours
        processes      = (ConvertTo-ProcList $topAll 3)
        processesC     = (ConvertTo-ProcList $topC 3)
        collector      = [pscustomobject]@{
            state         = $collState
            color         = $collColor
            pid           = $(if ($null -ne $hb) { $hb.pid } else { $null })
            updated       = $(if ($null -ne $hb) { $hb.updated } else { $null })
            bytesSeen     = $bytesSeen
            bytesSeenText = (Format-Bytes $bytesSeen)
            line          = $hbLine
        }
        attrLabel      = $attrLabel
        attrMtime      = $attrMtime
        physMtime      = $physMtime
        coverageNote   = $coverageNote
        deviceText     = (Format-Bytes $deviceBytes)
        suspectText    = (Format-Bytes $suspectBytes)
        svg            = $svg
    }
}

# ---------- 產生 HTML（只負責排版 state，不再自己算數字） ----------
# $Live = $true（伺服器模式）才產生輪詢腳本；-Once 的靜態快照連 fetch／setInterval 都不寫進去，
# 用 file:// 打開就不會出現「更新失敗」，只顯示「靜態快照（時間）」。
function New-DashboardHtml($s, [bool]$Live = $true) {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    function RowHtml($list, [bool]$showFiles) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($a in $list) {
            $files = ''
            if ($showFiles) {
                $parts = @()
                foreach ($t in @($a.files)) { $parts += ([System.Web.HttpUtility]::HtmlEncode($t.path) + ' <span class="muted">' + $t.text + '</span>') }
                $files = ($parts -join '<br>')
            }
            $procTxt = [System.Web.HttpUtility]::HtmlEncode($a.process)
            if ($a.process -eq 'cwatch') { $procTxt += ' <span class="muted">(本工具，含部署時的自測檔)</span>' }
            $null = $sb.AppendLine(('<tr><td>{0}</td><td class="vol">{1}</td><td class="num">{2}</td><td class="num muted">{3}</td><td class="files">{4}</td></tr>' -f `
                $procTxt, $a.volume, $a.bytesText, $a.opsText, $files))
        }
        if ($sb.Length -eq 0) { $null = $sb.AppendLine('<tr><td colspan="5" class="muted">目前沒有歸因資料（collector 是否在執行？）</td></tr>') }
        return $sb.ToString()
    }

    # 前端腳本由伺服器決定：-Once 的靜態快照不產生 fetch／setInterval（連字串都不留）
    if ($Live) {
        $updHint = '每 15 秒自動更新'
        $updInit = '最後更新 ' + $s.clock
        $hourBox = '<div id="hourDetail"></div>'
        # 圖表標題列＋「即時」按鈕（只有線上模式才有；-Once 不可以留 liveBtn）
        $chartHead = '<div class="chartbar"><h2>最近 24 小時 C: 落盤</h2><button id="liveBtn" class="active" type="button">即時</button></div>'
        $liveCss = @'
.chartbar{display:flex;align-items:center;justify-content:space-between;margin:26px 0 8px}
.chartbar h2{margin:0}
#liveBtn{background:#21262d;border:1px solid #30363d;color:#8b949e;border-radius:6px;padding:3px 12px;font-size:12px;font-family:inherit;cursor:pointer}
#liveBtn.active{background:#1f6feb;border-color:#1f6feb;color:#fff}
#liveBtn:hover{border-color:#8b949e}
'@
        $js = @"
var LIVE = true;
(function () {
  if (!LIVE) { return; }
  var busy = false;
  var lastOkText = "$($s.clock)";
  function el(id) { return document.getElementById(id); }
  function asArray(x) { if (!x) { return []; } if (Object.prototype.toString.call(x) === '[object Array]') { return x; } return [x]; }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function hhmmss(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()); }
  function setText(id, t) { var e = el(id); if (e) { e.textContent = (t === null || t === undefined) ? '' : String(t); } }
  function buildRows(tbody, list, showFiles) {
    if (!tbody) { return; }
    while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
    var arr = asArray(list);
    if (!arr.length) {
      var tr0 = document.createElement('tr');
      var td0 = document.createElement('td');
      td0.colSpan = 5; td0.className = 'muted';
      td0.textContent = '目前沒有歸因資料（collector 是否在執行？）';
      tr0.appendChild(td0); tbody.appendChild(tr0); return;
    }
    for (var i = 0; i < arr.length; i++) {
      var p = arr[i];
      var tr = document.createElement('tr');
      var tdP = document.createElement('td');
      tdP.textContent = p.process;
      if (p.process === 'cwatch') {
        var tag = document.createElement('span'); tag.className = 'muted';
        tag.textContent = ' (本工具，含部署時的自測檔)'; tdP.appendChild(tag);
      }
      tr.appendChild(tdP);
      var tdV = document.createElement('td'); tdV.className = 'vol'; tdV.textContent = p.volume; tr.appendChild(tdV);
      var tdB = document.createElement('td'); tdB.className = 'num'; tdB.textContent = p.bytesText; tr.appendChild(tdB);
      var tdO = document.createElement('td'); tdO.className = 'num muted'; tdO.textContent = p.opsText; tr.appendChild(tdO);
      var tdF = document.createElement('td'); tdF.className = 'files';
      if (showFiles) {
        var fl = asArray(p.files);
        for (var j = 0; j < fl.length; j++) {
          if (j > 0) { tdF.appendChild(document.createElement('br')); }
          tdF.appendChild(document.createTextNode(fl[j].path));
          var sp = document.createElement('span'); sp.className = 'muted';
          sp.textContent = ' ' + fl[j].text; tdF.appendChild(sp);
        }
      }
      tr.appendChild(tdF);
      tbody.appendChild(tr);
    }
  }
  function apply(s) {
    setText('rate', s.rateText);
    var re = el('rate');
    if (re && s.rateColor) { re.style.color = s.rateColor; }
    setText('todayC', s.todayTotal ? s.todayTotal.text : '');
    setText('todayD', s.todayD ? s.todayD.text : '');
    if (s.collector) {
      setText('colltext', s.collector.state);
      var dot = el('colldot');
      if (dot && s.collector.color) { dot.style.background = s.collector.color; }
      setText('bytesseen', s.collector.bytesSeenText);
      setText('srcline', s.collector.line);
    }
    setText('attrts', s.attrMtime);
    setText('physts', s.physMtime);
    setText('attrlabel1', s.attrLabel);
    setText('attrlabel2', s.attrLabel);
    setText('cov', s.coverageNote);
    setText('devbytes', s.deviceText);
    setText('susbytes', s.suspectText);
    var ch = el('chart');
    if (ch && typeof s.svg === 'string' && s.svg.length) { ch.innerHTML = s.svg; }
    highlight();
    buildRows(el('rowsC'), s.processesC, true);
    buildRows(el('rowsAll'), s.processes, false);
  }
  function markOk() {
    lastOkText = hhmmss(new Date());
    var e = el('upd');
    if (e) { e.style.color = ''; e.textContent = '最後更新 ' + lastOkText; }
  }
  function markFail() {
    var e = el('upd');
    if (e) { e.style.color = '#f85149'; e.textContent = '更新失敗（最後成功 ' + lastOkText + '）'; }
  }
  function refresh() {
    if (document.hidden || busy) { return; }
    busy = true;
    fetch('/api/state', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) { throw new Error('HTTP ' + r.status); } return r.json(); })
      .then(function (s) { apply(s); markOk(); })
      .catch(function () { markFail(); })
      .then(function () { busy = false; });
  }
  var selHour = null;
  var chartBox = document.getElementById('chart');
  var hourBox = document.getElementById('hourDetail');
  var liveBtn = document.getElementById('liveBtn');
  function highlight() {
    if (!chartBox) { return; }
    var rects = chartBox.querySelectorAll('rect[data-hour]');
    for (var i = 0; i < rects.length; i++) {
      if (selHour !== null && rects[i].getAttribute('data-hour') === selHour) {
        rects[i].setAttribute('fill', '#f0883e');
      } else {
        rects[i].setAttribute('fill', '#1f6feb');
      }
    }
  }
  function syncLiveBtn() {
    if (!liveBtn) { return; }
    if (selHour === null) { liveBtn.classList.add('active'); }
    else { liveBtn.classList.remove('active'); }
  }
  function backToLive() {
    selHour = null;
    highlight();
    syncLiveBtn();
    if (hourBox) {
      while (hourBox.firstChild) { hourBox.removeChild(hourBox.firstChild); }
      hourBox.style.display = 'none';
    }
  }
  function enterHour(h) {
    selHour = h;
    highlight();
    syncLiveBtn();
    if (hourBox) { hourBox.style.display = ''; }
    fetch('/api/hour?hour=' + encodeURIComponent(h), { cache: 'no-store' })
      .then(function (r) { if (!r.ok) { throw new Error('HTTP ' + r.status); } return r.json(); })
      .then(function (d) { showHourDetail(d); })
      .catch(function () { showHourError(h); });
  }
  function showHourDetail(d) {
    var box = document.getElementById('hourDetail');
    if (!box) { return; }
    while (box.firstChild) { box.removeChild(box.firstChild); }
    var head = document.createElement('div');
    head.className = 'muted';
    head.style.margin = '10px 0 6px';
    head.textContent = d.label + '　合計 ' + d.totalBytesText + '（ETW 歸因：邏輯寫入，非實體落盤；' + d.groups + ' 筆）';
    box.appendChild(head);
    var rows = asArray(d.rows);
    if (!rows.length) {
      var none = document.createElement('div');
      none.className = 'muted';
      none.textContent = '這一小時沒有歸因資料';
      box.appendChild(none);
      return;
    }
    var tbl = document.createElement('table');
    var thead = document.createElement('thead');
    var trh = document.createElement('tr');
    var hs = ['程式', '磁碟區', '寫入', '操作數', '前 3 個檔案'];
    for (var c = 0; c < hs.length; c++) {
      var th = document.createElement('th');
      if (c === 2 || c === 3) { th.className = 'num'; }
      th.textContent = hs[c];
      trh.appendChild(th);
    }
    thead.appendChild(trh);
    tbl.appendChild(thead);
    var tbody = document.createElement('tbody');
    for (var j = 0; j < rows.length; j++) {
      var p = rows[j];
      var tr = document.createElement('tr');
      var tdP = document.createElement('td'); tdP.textContent = p.process; tr.appendChild(tdP);
      var tdV = document.createElement('td'); tdV.className = 'vol'; tdV.textContent = p.volume; tr.appendChild(tdV);
      var tdB = document.createElement('td'); tdB.className = 'num'; tdB.textContent = p.bytesText; tr.appendChild(tdB);
      var tdO = document.createElement('td'); tdO.className = 'num muted'; tdO.textContent = p.opsText; tr.appendChild(tdO);
      var tdF = document.createElement('td'); tdF.className = 'files';
      var fl = asArray(p.files);
      for (var k = 0; k < fl.length; k++) {
        if (k > 0) { tdF.appendChild(document.createElement('br')); }
        tdF.appendChild(document.createTextNode(fl[k].path));
        var sp = document.createElement('span'); sp.className = 'muted';
        sp.textContent = ' ' + fl[k].bytesText; tdF.appendChild(sp);
      }
      tr.appendChild(tdF);
      tbody.appendChild(tr);
    }
    tbl.appendChild(tbody);
    box.appendChild(tbl);
  }
  function showHourError(h) {
    var box = document.getElementById('hourDetail');
    if (!box) { return; }
    while (box.firstChild) { box.removeChild(box.firstChild); }
    var e = document.createElement('div');
    e.className = 'muted';
    e.style.color = '#f85149';
    e.textContent = '讀取 ' + h + ' 時失敗';
    box.appendChild(e);
  }
  if (chartBox) {
    // 事件委派：綁在容器上，圖表每 15 秒被 innerHTML 換掉也不受影響
    // 點同一根 = 取消（回即時）；點別根 = 切到該小時
    chartBox.addEventListener('click', function (ev) {
      var t = ev.target;
      if (!t || t.tagName.toLowerCase() !== 'rect') { return; }
      var h = t.getAttribute('data-hour');
      if (h === null) { return; }
      if (h === selHour) { backToLive(); } else { enterHour(h); }
    });
  }
  if (liveBtn) {
    liveBtn.addEventListener('click', function () { backToLive(); });
  }
  setInterval(refresh, 15000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { refresh(); } });
})();
"@
    } else {
        $updHint = '靜態快照（不會自動更新）'
        $updInit = '靜態快照（' + $s.generatedLocal + '）'
        $hourBox = ''
        $chartHead = '<h2>最近 24 小時 C: 落盤</h2>'
        $liveCss = ''
        $js = @"
var LIVE = false;
(function () {
  var e = document.getElementById('upd');
  if (e) { e.textContent = '靜態快照（$($s.generatedLocal)）'; }
})();
"@
    }
    $html = @"
<!DOCTYPE html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<title>CWatch — C 碟寫入監控</title>
<style>
:root{color-scheme:dark}
body{font-family:"Segoe UI","Microsoft JhengHei",sans-serif;background:#0d1117;color:#c9d1d9;margin:0;padding:24px}
h1{font-size:19px;margin:0 0 4px}
h2{font-size:14px;color:#8b949e;font-weight:600;margin:26px 0 8px;text-transform:uppercase;letter-spacing:.05em}
.cards{display:flex;gap:14px;flex-wrap:wrap;margin-top:16px}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px 18px;min-width:150px}
.card .k{font-size:12px;color:#8b949e}
.card .v{font-size:22px;font-weight:600;margin-top:4px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #21262d;vertical-align:top}
th{color:#8b949e;font-weight:500;font-size:12px}
.num{text-align:right;font-variant-numeric:tabular-nums}
.vol{color:#58a6ff}
.files{color:#8b949e;font-size:12px;max-width:640px;word-break:break-all}
.muted{color:#8b949e}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
$liveCss
</style></head><body>
<h1>CWatch — C 碟寫入監控</h1>
<div class="muted">頁面產生：$($s.generatedLocal) · $updHint · <span id="upd">$updInit</span></div>
<div class="muted" style="margin-top:4px">原始資料：歸因 <span id="attrts">$($s.attrMtime)</span> · 落盤 <span id="physts">$($s.physMtime)</span></div>

<div class="cards">
  <div class="card"><div class="k">C: 目前寫入</div><div class="v" id="rate" style="color:$($s.rateColor)">$($s.rateText)</div></div>
  <div class="card"><div class="k">C: 今日落盤</div><div class="v" id="todayC">$($s.todayTotal.text)</div></div>
  <div class="card"><div class="k">D: 今日落盤</div><div class="v" id="todayD">$($s.todayD.text)</div></div>
  <div class="card"><div class="k">Collector</div><div class="v" style="font-size:15px"><span class="dot" id="colldot" style="background:$($s.collector.color)"></span><span id="colltext">$($s.collector.state)</span></div></div>
  <div class="card"><div class="k">ETW 累計位元組</div><div class="v" style="font-size:15px" id="bytesseen">$($s.collector.bytesSeenText)</div></div>
</div>

$chartHead
<div id="chart">$($s.svg)</div>
$hourBox

<h2>C: 寫入排行（<span id="attrlabel1">$($s.attrLabel)</span>，ETW 歸因）</h2>
<div class="muted" style="margin-bottom:8px" id="cov">$($s.coverageNote)</div>
<table><thead><tr><th>進程</th><th>磁碟區</th><th class="num">寫入</th><th class="num">次數</th><th>主要檔案</th></tr></thead>
<tbody id="rowsC">
$(RowHtml $s.processesC $true)
</tbody></table>

<h2>全機寫入排行（<span id="attrlabel2">$($s.attrLabel)</span>，所有磁碟區）</h2>
<table><thead><tr><th>進程</th><th>磁碟區</th><th class="num">寫入</th><th class="num">次數</th><th>主要檔案</th></tr></thead>
<tbody id="rowsAll">
$(RowHtml $s.processes $false)
</tbody></table>

<p class="muted" style="margin-top:24px;font-size:12px">
資料來源：PhysicalDisk（落盤總量）＋ ETW Kernel-File（進程 × 檔案）。<br>
ETW 只記錄寫入事件；「次數」是寫入 IRP 數，不代表檔案數。<br>
無法歸屬到檔案（裝置／pipe／未緩衝 I/O）：<span id="devbytes">$($s.deviceText)</span><br>
已排除的可疑列（路徑不存在、是目錄、或路徑不明＝磁碟區也可能是猜的）：<span id="susbytes">$($s.suspectText)</span><br>
記憶體映射（mmap）的寫入在系統上記為 <code>System</code>，不會記到原程式。<br>
若某段資料的時間早於目前 collector 的啟動時間，那段可能由舊版程式產生，僅供參考。<br>
<span id="srcline">$($s.collector.line)</span>
</p>
<script>
$js
</script>
</body></html>
"@
    return $html
}

# 相容舊呼叫端（-Once 與外部工具都叫這支）
function New-Dashboard {
    return New-DashboardHtml (Get-DashboardState $false) $false
}

# ---------- 主流程 ----------
if ($Once) {
    $out = $OutFile
    if (-not $out) { $out = Join-Path $Root 'reports\dashboard.html' }
    $dir = Split-Path $out -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($out, (New-Dashboard), (New-Object Text.UTF8Encoding($true)))
    Write-Output ('written: ' + $out)
    exit 0
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Output ("dashboard listening on http://localhost:{0}/" -f $Port)

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 3000
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
        $requestLine = $reader.ReadLine()
        while ($true) {
            $h = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($h)) { break }
        }

        # 只認路徑；查詢字串另外解析（/api/hour 需要 hour/date）
        $reqPath = '/'
        $reqQuery = ''
        if ($requestLine) {
            $bits = $requestLine.Split(' ')
            if ($bits.Length -ge 2) { $reqPath = $bits[1] }
        }
        $q = $reqPath.IndexOf('?')
        if ($q -ge 0) {
            $reqQuery = $reqPath.Substring($q + 1)
            $reqPath = $reqPath.Substring(0, $q)
        }
        $query = @{}
        foreach ($kv in ($reqQuery -split '&')) {
            if (-not $kv) { continue }
            $eq = $kv.IndexOf('=')
            if ($eq -lt 0) { $query[$kv] = '' }
            else { $query[$kv.Substring(0, $eq)] = [System.Uri]::UnescapeDataString($kv.Substring($eq + 1)) }
        }

        $status = 200
        if ($reqPath -eq '/api/state') {
            $body = (Get-DashboardState | ConvertTo-Json -Depth 8 -Compress)
            $ctype = 'application/json; charset=utf-8'
        } elseif ($reqPath -eq '/api/hour') {
            $ctype = 'application/json; charset=utf-8'
            $hourNum = -1
            $hourTxt = [string]$query['hour']
            if (-not [int]::TryParse($hourTxt, [ref]$hourNum) -or $hourNum -lt 0 -or $hourNum -gt 23) {
                $status = 400
                $body = '{"error":"hour must be an integer 0-23"}'
            } else {
                $dateTxt = (Get-Date).ToString('yyyy-MM-dd')
                if ($query.ContainsKey('date') -and $query['date']) { $dateTxt = [string]$query['date'] }
                $dt = [datetime]::MinValue
                $okDate = [datetime]::TryParseExact($dateTxt, 'yyyy-MM-dd', $inv,
                    [System.Globalization.DateTimeStyles]::None, [ref]$dt)
                if (-not $okDate) {
                    $status = 400
                    $body = '{"error":"date must be YYYY-MM-DD"}'
                } else {
                    $body = (Get-HourDetail $dateTxt $hourNum | ConvertTo-Json -Depth 8 -Compress)
                }
            }
        } else {
            $body = New-DashboardHtml (Get-DashboardState)
            $ctype = 'text/html; charset=utf-8'
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $reason = 'OK'
        if ($status -eq 400) { $reason = 'Bad Request' }
        elseif ($status -eq 404) { $reason = 'Not Found' }
        $header = "HTTP/1.1 $status $reason`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store, no-cache, must-revalidate, max-age=0`r`nPragma: no-cache`r`nExpires: 0`r`nConnection: close`r`n`r`n"
        $hb2 = [Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($hb2, 0, $hb2.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        # 單一請求失敗不影響服務
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}
