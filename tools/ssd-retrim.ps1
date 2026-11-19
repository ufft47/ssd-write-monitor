<#
    ssd-retrim.ps1 —— 只送 TRIM（不搬資料），用來取代 Windows 排程磁碟重組。

    為什麼：
      2026-11-19 的排程重組（ScheduledDefrag，defrag.exe -c -h -o）對 C: 寫了 44.2 GB、
      對 D: 寫了 54.2 GB（讀取量幾乎相同），佔當天 SSD 寫入的 7–8 成。
      SSD 做完整重組對效能幾乎沒幫助，但對壽命很傷；真正需要的是 TRIM。

    用法：
      Optimize-Volume -DriveLetter C -ReTrim  （需要管理員）

    排程：SSDWriteMonitor-ReTrim（每週日 04:00，SYSTEM、最高權限）
#>
param(
    [string[]]$Letters = @('C', 'D'),
    [string]$Root = 'D:\dev\disk-monitor'
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('ssd-retrim-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
$enc = New-Object System.Text.UTF8Encoding($false)

function Say([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Output $line
    try { [IO.File]::AppendAllText($log, $line + "`r`n", $enc) } catch { }
}

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say ("start  letters={0}  elevated={1}" -f ($Letters -join ','), $isAdmin)

$fail = 0
foreach ($d in $Letters) {
    try {
        $out = Optimize-Volume -DriveLetter $d -ReTrim -ErrorAction Stop 2>&1 | Out-String
        Say ("{0}: retrim OK  {1}" -f $d, ($out -replace "`r?`n", ' ').Trim())
    } catch {
        $fail++
        Say ("{0}: retrim FAILED - {1}" -f $d, $_.Exception.Message)
    }
}
Say ("done  failed={0}" -f $fail)
exit $(if ($fail -eq 0) { 0 } else { 1 })
