<#
    deploy-collector.ps1 —— 換上新的 collector 執行檔並重新啟動（必須以系統管理員身分執行）

    為什麼需要提權：CWatchCollector 是以最高權限執行，正在跑的 cwatch.exe 會鎖住檔案，
    而且停／啟排程需要管理員。

    做的事：
      1. 確認提權
      2. 停止排程、等待 cwatch.exe 結束（最多 20 秒，逾時用 PID 強制結束）
      3. 備份舊 cwatch.exe → cwatch.exe.bak-<時間>
      4. cwatch.new.exe → cwatch.exe
      5. 跑 selftest（回歸驗證）
      6. 重新啟動排程並驗證心跳（含「無法歸屬」比例）
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor',
    [string]$TaskName = 'CWatchCollector'
)

$ErrorActionPreference = 'Stop'
$dir = Join-Path $Root 'src\cwatch'
$exe = Join-Path $dir 'cwatch.exe'
$newExe = Join-Path $dir 'cwatch.new.exe'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"admin = $isAdmin  (user $($id.Name))"
if (-not $isAdmin) {
    "尚未提權。請用： Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath'"
    exit 2
}
if (-not (Test-Path -LiteralPath $newExe)) { "找不到 $newExe（先編譯）"; exit 3 }

# ---------- 停 ----------
"--- 停止 collector ---"
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop; '  已下達停止' } catch { "  停止失敗：$($_.Exception.Message)" }
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $procs = @(Get-Process -Name 'cwatch' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
}
$procs = @(Get-Process -Name 'cwatch' -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    foreach ($p in $procs) {
        $path = ''
        try { $path = $p.MainModule.FileName } catch { }
        if ($path -and $path -ieq $exe) {
            "  強制結束 pid=$($p.Id)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        } else {
            "  略過 pid=$($p.Id)（不是我們的執行檔：$path）"
        }
    }
    Start-Sleep -Seconds 2
}
if (@(Get-Process -Name 'cwatch' -ErrorAction SilentlyContinue).Count -gt 0) { "  仍有 cwatch 在執行，中止"; exit 4 }
'  cwatch.exe 已結束'

# ---------- 換檔 ----------
"--- 換檔 ---"
$bak = $exe + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $exe -Destination $bak -Force
Move-Item -LiteralPath $newExe -Destination $exe -Force
"  舊檔備份：$bak"
"  新檔大小：{0:N0} KB" -f ((Get-Item $exe).Length / 1KB)

# ---------- selftest ----------
"--- selftest ---"
$out = & $exe selftest $Root 2>&1
foreach ($l in $out) { '  ' + $l }
if ($LASTEXITCODE -ne 0) {
    "  [中止] selftest 失敗，把舊檔換回來"
    Copy-Item -LiteralPath $bak -Destination $exe -Force
    Start-ScheduledTask -TaskName $TaskName
    exit 5
}

# ---------- 啟動 ----------
"--- 啟動 ---"
$stopFile = Join-Path $Root 'data\state\collector.stop'
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force; '  已清除 collector.stop' }
Start-ScheduledTask -TaskName $TaskName

$hb = Join-Path $Root 'data\state\collector.json'
$deadline = (Get-Date).AddSeconds(60)
$ok = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-Path -LiteralPath $hb) {
        try {
            $j = Get-Content -LiteralPath $hb -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.state -eq 'running' -and $j.bytes_seen -gt 0) { $ok = $true; break }
        } catch { }
    }
}

if ($ok) {
    $unres = 0.0
    if ($null -ne $j.bytes_unresolved) { $unres = [double]$j.bytes_unresolved }
    $rk = 0
    if ($null -ne $j.resolved_filekey) { $rk = [int64]$j.resolved_filekey }
    $nd = 0
    if ($null -ne $j.rundown_entries) { $nd = [int64]$j.rundown_entries }
    $nn = 0
    if ($null -ne $j.name_events) { $nn = [int64]$j.name_events }
    "  心跳 OK  已歸因={0:N2} GB  落地層(未計入)={1:N2} GB  events_write={2:N0}" -f ([double]$j.bytes_seen/1GB), ($unres/1GB), [double]$j.events_write
    "  FileKey: rundown={0:N0} name={1:N0} 用 FileKey 解出={2:N0}" -f $nd, $nn, $rk
    if ($rk -eq 0 -and $nd -eq 0 -and $nn -eq 0) { "  [注意] 完全沒有 FileKey 事件（FileIOName / FileIOFileRundown），此版只靠 FileIOCreate" }
} else {
    "  [警告] 60 秒內沒看到心跳"
    $cl = Join-Path $Root 'logs\collector.log'
    if (Test-Path -LiteralPath $cl) { Get-Content -LiteralPath $cl -Encoding UTF8 -Tail 8 | ForEach-Object { '    ' + $_ } }
}
Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime, LastTaskResult | Format-List
if (-not $ok) { exit 6 }
