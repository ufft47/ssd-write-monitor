<#
    disk-monitor-run.ps1 —— 排程工作唯一的進入點。

    每次執行：取一次樣本（寫入 raw CSV）；若該小時還沒產出報告，就產出報告。
    報告腳本本身會判斷「有沒有待產出的小時」，沒有就立刻結束，成本很低。
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\dev\disk-monitor'
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath   = Join-Path $logDir 'monitor.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$msg) {
    $line = ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg)
    [IO.File]::AppendAllText($logPath, $line + "`r`n", $utf8NoBom)
}

# 日誌 > 8 MB 就輪替為 monitor.log.1
if (Test-Path -LiteralPath $logPath) {
    $fi = Get-Item -LiteralPath $logPath
    if ($fi.Length -gt 8MB) {
        $bak = $logPath + '.1'
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
        Move-Item -LiteralPath $logPath -Destination $bak -Force
    }
}

$exitCode = 0

try {
    $sampleOut = & (Join-Path $Root 'src\disk-sample.ps1') -Root $Root
    if (-not $sampleOut) { Write-Log 'sample produced no output' }
} catch {
    $exitCode = 1
    Write-Log ('SAMPLE FAILED: ' + $_.Exception.Message)
}

try {
    $reportOut = & (Join-Path $Root 'src\disk-report.ps1') -Root $Root
    foreach ($l in @($reportOut)) {
        if ($null -eq $l) { continue }
        if ($l -eq 'no pending hours') { continue }
        Write-Log ('report: ' + $l)
    }
} catch {
    $exitCode = 1
    Write-Log ('REPORT FAILED: ' + $_.Exception.Message)
}

# 每日對照表：只在整點嘗試，避免失敗時每分鐘重跑（它要解析數萬行的 SMART 歷史）
if ((Get-Date).Minute -eq 0) {
    try {
        $lastDailyPath = Join-Path $Root 'data\state\last-daily.json'
        $needDaily = $true
        if (Test-Path -LiteralPath $lastDailyPath) {
            try {
                $ld = Get-Content -LiteralPath $lastDailyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($ld.lastDate -eq (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')) { $needDaily = $false }
            } catch { $needDaily = $true }
        }
        if ($needDaily) {
            $dailyOut = & (Join-Path $Root 'src\disk-daily.ps1') -Root $Root
            foreach ($l in @($dailyOut)) {
                if ($null -ne $l) { Write-Log ('daily: ' + $l) }
            }
        }
    } catch {
        $exitCode = 1
        Write-Log ('DAILY FAILED: ' + $_.Exception.Message)
    }
}

exit $exitCode
