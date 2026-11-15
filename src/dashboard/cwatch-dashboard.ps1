<#
    cwatch-dashboard.ps1 —— 本機儀表板（http://localhost:8737）

    資料來源全部是既有檔案，不另存一份：
      data\phys\*.csv            實體裝置落盤量（真正寫到裝置的位元組）
      data\attrib\*.csv          ETW 歸因：minute,pid,process,volume,path,bytes,ops
      logs\hourly-summary.log    每小時摘要（畫走勢）
      data\state\collector.json  collector 心跳

    用法：
      -Once            只輸出 reports\dashboard.html 後結束（測試用）
      -Port 8737       監聽埠
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

# ---------- 產生 HTML ----------
function New-Dashboard {
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

    # sparkline
    $svg = ''
    if ($hourly.Count -gt 1 -and $maxH -gt 0) {
        $w = 720; $hgt = 90; $bw = [math]::Floor($w / $hourly.Count) - 2
        $bars = ''
        $i = 0
        foreach ($x in $hourly) {
            $bh = [int](($x.Bytes / $maxH) * ($hgt - 10))
            if ($bh -lt 1) { $bh = 1 }
            $xpos = 4 + $i * ($bw + 2)
            $bars += ('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#1f6feb" rx="1"><title>{4}  {5}</title></rect>' -f `
                $xpos, ($hgt - $bh), $bw, $bh, $x.When, (Format-Bytes $x.Bytes))
            $i++
        }
        $svg = ('<svg width="{0}" height="{1}" viewBox="0 0 {0} {1}">{2}</svg>' -f $w, $hgt, $bars)
    } else {
        $svg = '<div class="muted">還沒有 2 個以上的小時資料</div>'
    }

    function RowHtml($list, [bool]$showFiles) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($a in $list) {
            $files = ''
            if ($showFiles) {
                $top = @($a.Files.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3)
                $parts = @()
                foreach ($t in $top) { $parts += ([System.Web.HttpUtility]::HtmlEncode($t.Key) + ' <span class="muted">' + (Format-Bytes $t.Value) + '</span>') }
                $files = ($parts -join '<br>')
            }
            $procTxt = [System.Web.HttpUtility]::HtmlEncode($a.Process)
            if ($a.Process -eq 'cwatch') { $procTxt += ' <span class="muted">(本工具，含部署時的自測檔)</span>' }
            $null = $sb.AppendLine(('<tr><td>{0}</td><td class="vol">{1}</td><td class="num">{2}</td><td class="num muted">{3:N0}</td><td class="files">{4}</td></tr>' -f `
                $procTxt, $a.Volume, (Format-Bytes $a.Bytes), $a.Ops, $files))
        }
        if ($sb.Length -eq 0) { $null = $sb.AppendLine('<tr><td colspan="5" class="muted">目前沒有歸因資料（collector 是否在執行？）</td></tr>') }
        return $sb.ToString()
    }

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $rateTxt = Format-Rate $c.Rate
    $rateColor = '#3fb950'
    if ($c.Rate -gt 5MB) { $rateColor = '#d29922' }
    if ($c.Rate -gt 20MB) { $rateColor = '#f85149' }

    $html = @"
<!DOCTYPE html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<title>CWatch — C 碟寫入監控</title>
<script>
// 用帶時間戳的重新載入，避免瀏覽器從快取拿到舊頁面
setTimeout(function () { location.replace('/?t=' + Date.now()); }, 15000);
</script>
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
</style></head><body>
<h1>CWatch — C 碟寫入監控</h1>
<div class="muted">頁面產生：$($now.ToString('yyyy-MM-dd HH:mm:ss')) · 每 15 秒自動更新</div>
<div class="muted" style="margin-top:4px">原始資料：歸因 $attrMtime · 落盤 $physMtime</div>

<div class="cards">
  <div class="card"><div class="k">C: 目前寫入</div><div class="v" style="color:$rateColor">$rateTxt</div></div>
  <div class="card"><div class="k">C: 今日落盤</div><div class="v">$(Format-Bytes $c.Write)</div></div>
  <div class="card"><div class="k">D: 今日落盤</div><div class="v">$(Format-Bytes $d.Write)</div></div>
  <div class="card"><div class="k">Collector</div><div class="v" style="font-size:15px"><span class="dot" style="background:$collColor"></span>$collState</div></div>
  <div class="card"><div class="k">ETW 累計位元組</div><div class="v" style="font-size:15px">$(Format-Bytes $bytesSeen)</div></div>
</div>

<h2>最近 24 小時 C: 落盤</h2>
$svg

<h2>C: 寫入排行（$attrLabel，ETW 歸因）</h2>
<div class="muted" style="margin-bottom:8px">$coverageNote</div>
<table><tr><th>進程</th><th>磁碟區</th><th class="num">寫入</th><th class="num">次數</th><th>主要檔案</th></tr>
$(RowHtml $topC $true)
</table>

<h2>全機寫入排行（$attrLabel，所有磁碟區）</h2>
<table><tr><th>進程</th><th>磁碟區</th><th class="num">寫入</th><th class="num">次數</th><th>主要檔案</th></tr>
$(RowHtml $topAll $false)
</table>

<p class="muted" style="margin-top:24px;font-size:12px">
資料來源：PhysicalDisk（落盤總量）＋ ETW Kernel-File（進程 × 檔案）。<br>
ETW 只記錄寫入事件；「次數」是寫入 IRP 數，不代表檔案數。<br>
無法歸屬到檔案（裝置／pipe／未緩衝 I/O）：$(Format-Bytes $deviceBytes)<br>
已排除的可疑列（路徑不存在、是目錄、或路徑不明＝磁碟區也可能是猜的）：$(Format-Bytes $suspectBytes)<br>
記憶體映射（mmap）的寫入在系統上記為 <code>System</code>，不會記到原程式。<br>
若某段資料的時間早於目前 collector 的啟動時間，那段可能由舊版程式產生，僅供參考。<br>
$(if ($null -ne $hb) { 'collector 心跳：' + $hb.updated + '（pid ' + $hb.pid + '）' } else { 'collector 尚未啟動' })
</p>
</body></html>
"@
    return $html
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
        $body = New-Dashboard
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store, no-cache, must-revalidate, max-age=0`r`nPragma: no-cache`r`nExpires: 0`r`nConnection: close`r`n`r`n"
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
