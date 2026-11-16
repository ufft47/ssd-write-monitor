<#
    github-watch.ps1 —— 定時看 GitHub repo 的 open issues，有新 issue 就派 agent 處理。

    設計原則（與 docs/github.md 一致）：
      - 只讀不亂寫：沒有新 issue 時什麼都不做（零成本）
      - 一次一個：用鎖檔避免兩個 agent 同時改同一個 repo
      - 全部留痕：每次執行寫 logs\github-watch-<date>.log；agent 的處理結果寫 docs\github.md
      - 不越權：只處理「量測真實寫入量 / 找出誰在寫 / 延緩 SSD 磨損」這個主題的請求

    典型用法：
      # 單次檢查（排程用這個）
      powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\github-watch.ps1 -Once

      # 自己手動看會做什麼（不派工）
      powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\github-watch.ps1 -DryRun

      # 前景常駐（每 30 分鐘一次，測試用）
      powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\github-watch.ps1 -Loop
#>
[CmdletBinding()]
param(
    [string]$Repo = 'ufft47/ssd-write-monitor',
    [string]$Root = 'D:\dev\disk-monitor',
    [switch]$Once,
    [switch]$Loop,
    [switch]$DryRun,
    [int]$IntervalMinutes = 30,
    [int]$MaxPerRun = 3,
    [int]$AgentTimeoutMinutes = 45,
    [switch]$NoDispatch
)

$ErrorActionPreference = 'Continue'

# ---------- 路徑與基本檢查 ----------
$logDir   = Join-Path $Root 'logs'
$stateDir = Join-Path $Root 'logs'
$lockFile = Join-Path $logDir 'github-watch.lock'
$stateFile = Join-Path $stateDir 'github-state.json'
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile  = Join-Path $logDir ("github-watch-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Say([string]$m, [string]$color = 'Gray') {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $color
    try { [IO.File]::AppendAllText($logFile, $line + "`r`n", $utf8NoBom) } catch { }
}

function Get-GhPath {
    $c = Get-Command gh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @('C:\Program Files\GitHub CLI\gh.exe', "$env:LOCALAPPDATA\GitHubCLI\gh.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

$gh = Get-GhPath
if (-not $gh) { Say '找不到 gh.exe（GitHub CLI），結束' 'Red'; exit 2 }

# ---------- 鎖檔：避免兩個 agent 同時跑 ----------
$lockOk = $true
if (Test-Path -LiteralPath $lockFile) {
    $lockAge = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalMinutes
    if ($lockAge -lt 60) {
        Say ("另一個 github-watch 還在跑（鎖檔 {0:N0} 分鐘前建立），本次跳過" -f $lockAge) 'Yellow'
        $lockOk = $false
    } else {
        Say ("鎖檔已過期（{0:N0} 分鐘），清除" -f $lockAge) 'Yellow'
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
}
if (-not $lockOk) { exit 0 }
try { [IO.File]::WriteAllText($lockFile, ("pid={0}`r`nstart={1}" -f $PID, (Get-Date -Format 'o')), $utf8NoBom) } catch { }

function Release-Lock {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

# ---------- 狀態檔 ----------
function Read-State {
    $s = [pscustomobject]@{ seen = @{} }
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $j = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.seen) {
                $h = @{}
                foreach ($p in $j.seen.PSObject.Properties) {
                    $k = [string]$p.Name
                    if ($k -and $k -match '^\d+$') { $h[$k] = [string]$p.Value }
                }
                $s.seen = $h
            }
        } catch { Say ("狀態檔解析失敗（忽略）：{0}" -f $_.Exception.Message) 'Yellow' }
    }
    return $s
}
function Save-State($s) {
    $obj = [pscustomobject]@{ updatedAt = (Get-Date -Format 'o'); seen = $s.seen }
    try { [IO.File]::WriteAllText($stateFile, ($obj | ConvertTo-Json -Depth 4), $utf8NoBom) } catch { Say ("寫狀態檔失敗：{0}" -f $_.Exception.Message) 'Red' }
}

# ---------- 抓 issues ----------
function Get-OpenIssues {
    # 只收 stdout 當 JSON；stderr 另外收，避免混進 JSON 造成解析失敗
    $raw = & $gh issue list --repo $Repo --state open --limit 50 --json number,title,author,updatedAt,createdAt,labels,url 2>$null
    if ($LASTEXITCODE -ne 0) { Say ("gh issue list 失敗：exit={0}" -f $LASTEXITCODE) 'Red'; return [pscustomobject]@{ Ok = $false; Items = @() } }
    try {
        # 注意（PowerShell 5.1）：把 ConvertFrom-Json 接在管線尾端，整個 JSON 陣列會變成
        # 「包著陣列的單一物件」，之後 @() 就變成巢狀（Count 永遠是 1），issue 的欄位全部讀不到
        # → 會派工給一個「沒有編號」的假 issue。一律用 -InputObject 取字串、先指定給變數再展開。
        $text = (@($raw) -join "`n").Trim()
        if ($text.Length -eq 0) { return [pscustomobject]@{ Ok = $true; Items = @() } }
        $obj = ConvertFrom-Json -InputObject $text
        # 再擋一層：只留真的帶 number 的項目，其餘一律當成解析異常
        $parsed = @($obj | Where-Object { $null -ne $_ -and $null -ne $_.number -and [string]$_.number -ne '' })
        return [pscustomobject]@{ Ok = $true; Items = $parsed }
    } catch {
        Say ("issue JSON 解析失敗：{0}" -f $_.Exception.Message) 'Red'
        return [pscustomobject]@{ Ok = $false; Items = @() }
    }
}

# ---------- 派工 ----------
function New-IssuePrompt($issue) {
    $labels = @($issue.labels | ForEach-Object { $_.name }) -join ', '
    @"
你正在自動處理 GitHub issue（專案：ssd-write-monitor，repo：$Repo，工作目錄：$Root）。

issue #$($issue.number)：$($issue.title)
作者：$($issue.author.login)　labels：$labels　URL：$($issue.url)

請這樣做：
1. 用 `gh issue view $($issue.number) --repo $Repo --json title,body,comments` 讀完整內容與留言。
2. 判斷類型並照 docs/github.md 的分流原則處理：
   - **bug**（數字錯、腳本壞、資料缺）：直接修，優先於任何 feature。
   - **feature**：只有在不偏離主題時才做。主題＝「量測真實寫入量／找出誰在寫／延緩 SSD 磨損」。
     偏離的（清暫存、預測 SSD 何時壞、雲端儀表板、關防毒、破解）→ 不要改程式，在 issue 說明原因並關閉。
   - **問題／用法**：用 README 的內容回答後關閉。
3. 改完一定要跑 `powershell -NoProfile -ExecutionPolicy Bypass -File .\check-scripts.ps1`；
   **沒通過就不要 commit、不要 push**，改成在 issue 回報卡在哪。
4. 通過就 commit（訊息說明修了什麼）並 `git push`。
5. 用 `gh issue comment $($issue.number) --repo $Repo --body "..."` 回覆：
   說明改了什麼、commit hash、以及怎麼驗證。**用 issue 本身的語言回**（中文 issue 用中文）。
   若已完全解決，再 `gh issue close $($issue.number) --repo $Repo`。
6. 在 `docs/github.md` 的「Issue 處理紀錄」表**最上面**加一列：
   | 日期 | #$($issue.number) | bug/feat/question/wontfix | 一句話摘要 | `短hash` | ✅ |
7. 若這個 issue 顯示的是「專案本身的 bug」，請順手檢查有沒有同類問題（同一個函式/同一支腳本）。

限制：不要上傳任何資料到雲端、不要關閉防毒或 Windows 安全性功能、不要新增遙測或遠端 API。
若你判斷這個 issue 需要人類決定（例如要改架構、要動別人的機器），**不要改程式**，
在 issue 留言說明你的判斷與建議，然後結束。
"@
}

function Invoke-AgentForIssue($issue) {
    # 防呆：沒有編號就代表解析異常，寧可跳過也不要派工給一個不存在的 issue
    if ($null -eq $issue -or [string]::IsNullOrWhiteSpace([string]$issue.number)) {
        Say '收到沒有編號的 issue 物件，跳過（不派工）' 'Red'
        return $false
    }
    $prompt = New-IssuePrompt $issue
    $promptFile = Join-Path $logDir ("github-issue-{0}-{1}.md" -f $issue.number, $stamp)
    try { [IO.File]::WriteAllText($promptFile, $prompt, $utf8NoBom) } catch {
        Say ("寫入任務檔失敗：{0}" -f $_.Exception.Message) 'Red'
        return $false
    }
    $safeTitle = ("issue-{0}" -f $issue.number)
    $out = Join-Path $logDir ("github-agent-{0}-{1}.log" -f $issue.number, $stamp)
    $msg = ('讀取 "{0}" 並完全照裡面的指示處理 GitHub issue #{1}。' -f $promptFile, $issue.number)
    Say ("派工：issue #{0} 「{1}」→ opencode run --auto（輸出：{2}）" -f $issue.number, $issue.title, (Split-Path $out -Leaf)) 'Cyan'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'opencode.cmd'
    $psi.Arguments = ('run --auto --archived --title "{0}" "{1}"' -f $safeTitle, $msg)
    $psi.WorkingDirectory = $Root
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Say ("啟動 opencode 失敗：{0}" -f $_.Exception.Message) 'Red'
        return $false
    }
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $timeoutMs = [int]($AgentTimeoutMinutes * 60 * 1000)
    if (-not $proc.WaitForExit($timeoutMs)) {
        Say ("agent 逾時（{0} 分鐘），強制結束" -f $AgentTimeoutMinutes) 'Red'
        try { $proc.Kill() } catch { }
    }
    $text = $stdout.Result + "`r`n--- stderr ---`r`n" + $stderr.Result
    try { [IO.File]::WriteAllText($out, ("issue #{0} {1}`r`n`r`n{2}" -f $issue.number, $issue.title, $text), $utf8NoBom) } catch { }
    Say ("agent 結束（exit={0}），輸出 {1:N0} bytes" -f $proc.ExitCode, $text.Length) $(if ($proc.ExitCode -eq 0) { 'Green' } else { 'Yellow' })
    return ($proc.ExitCode -eq 0)
}

# ---------- 主流程 ----------
function Invoke-Check {
    $state = Read-State
    $res = Get-OpenIssues
    if (-not $res.Ok) { return $false }
    $issues = @($res.Items)
    # 防呆：只接受欄位完整的 issue（gh 輸出若夾雜警告字串，ConvertFrom-Json 會吐出沒有欄位的空物件）
    $valid = @($issues | Where-Object { $_.number -and [int]$_.number -gt 0 -and $_.title })
    if ($valid.Count -ne $issues.Count) {
        Say ("警告：{0} 筆資料缺少 number/title，已忽略" -f ($issues.Count - $valid.Count)) 'Yellow'
    }
    $issues = $valid

    $todo = New-Object System.Collections.Generic.List[object]
    foreach ($i in $issues) {
        $key = [string]$i.number
        $prev = $null
        if ($state.seen.ContainsKey($key)) { $prev = [string]$state.seen[$key] }
        if ($null -eq $prev -or $prev -ne [string]$i.updatedAt) { $todo.Add($i) }
    }

    Say ("open issues: {0}　待處理（新或已更新）: {1}" -f $issues.Count, $todo.Count)
    if ($todo.Count -eq 0) {
        Save-State $state
        return $true
    }

    $n = 0
    foreach ($i in $todo) {
        if ($n -ge $MaxPerRun) { Say ("本次上限 {0} 個，其餘留到下一輪" -f $MaxPerRun) 'Yellow'; break }
        Say ("  → #{0} {1}（updated {2}）" -f $i.number, $i.title, $i.updatedAt)
        if ($DryRun -or $NoDispatch) {
            Say '    （DryRun／NoDispatch：不派工）' 'Yellow'
            continue
        }
        $ok = Invoke-AgentForIssue $i
        $state.seen[[string]$i.number] = [string]$i.updatedAt
        Save-State $state
        $n++
    }
    Save-State $state
    return $true
}

Say ("=== github-watch 開始（repo={0}, dryRun={1}, max={2}） ===" -f $Repo, $DryRun, $MaxPerRun) 'Cyan'
$ok = Invoke-Check
Release-Lock

if (-not $ok) { exit 1 }
Say '完成' 'Green'

if ($Loop) {
    while ($true) {
        Say ("等待 {0} 分鐘…" -f $IntervalMinutes)
        Start-Sleep -Seconds ($IntervalMinutes * 60)
        try { [IO.File]::WriteAllText($lockFile, ("pid={0}`r`nstart={1}" -f $PID, (Get-Date -Format 'o')), $utf8NoBom) } catch { }
        $ok2 = Invoke-Check
        Release-Lock
        if (-not $ok2) { Say '本輪失敗，下一輪再試' 'Yellow' }
    }
}
exit 0
