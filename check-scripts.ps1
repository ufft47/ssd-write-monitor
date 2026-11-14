# check-scripts.ps1 —— 檢查所有 .ps1 的 BOM 與語法
# 用途：改完腳本後跑一次。含中文卻沒有 BOM 的檔案，PowerShell 5.1 會用 CP950 解讀，
#       全形括號／引號可能吃掉下一個引號，產生「看起來莫名其妙的 ParserError」。
param([string]$Root = 'D:\dev\disk-monitor')

$ErrorActionPreference = 'Stop'
$bad = 0
Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.ps1 | Sort-Object FullName | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $text = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    $hasChinese = $text -match '[\u4e00-\u9fff]'
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)

    $issues = New-Object System.Collections.Generic.List[string]
    if ($hasChinese -and -not $hasBom) { $issues.Add('缺 BOM') }
    if ($errs -and $errs.Count -gt 0) { $issues.Add(('語法錯誤 {0} 個：{1}' -f $errs.Count, $errs[0].Message)) }

    $rel = $_.FullName.Substring($Root.Length + 1)
    if ($issues.Count -gt 0) {
        $bad++
        '{0,-44} ✗ {1}' -f $rel, ($issues -join ' / ')
    } else {
        '{0,-44} ✓' -f $rel
    }
}
''
if ($bad -eq 0) { '全部通過' } else { ('有 {0} 個檔案要修' -f $bad) }
exit $(if ($bad -eq 0) { 0 } else { 1 })
