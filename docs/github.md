# GitHub 更新紀錄

> 這份檔案記錄**本專案在 GitHub 上的每一次更新**，以及公開 issue 的處理結果。
> 使用者說明在 [`../README.md`](../README.md)（English）與 [`../README.zh-TW.md`](../README.zh-TW.md)（中文）。

## 基本資料

| 項目 | 值 |
|---|---|
| Repo | <https://github.com/ufft47/ssd-write-monitor>（公開） |
| 授權 | **MIT**（[`../LICENSE`](../LICENSE)） |
| 第三方元件 | 見 [`../NOTICE.md`](../NOTICE.md)（`src/cwatch/lib/` 的微軟 DLL 不在本專案 MIT 範圍） |
| 語言／平台 | PowerShell 5.1（相容 7.x）＋ C# (ETW)｜Windows 10 / 11 x64 |

---

## 更新紀錄

| 日期 | 類型 | 內容 | Commit |
|---|---|---|---|
| 2026-11-16 | chore | 從公開版移除 11 支腳本（8 支作者本機環境清理：網盤/AVG/Autodesk/殘留；另 reset-traynotify、safemode、dump-events 與量測無關或依賴缺失），避免與量測主題混淆；同時新增 `tools/github-watch.ps1`（自動監看 issue） | `61fd5a8` |
| 2026-11-16 | **首次發佈** | public repo 建立（MIT）：中英雙語說明（`README.md` / `README.zh-TW.md`）、英文版 README、`LICENSE`、`NOTICE.md`（微軟 DLL 授權）、去識別（`<host>\<user>` → `<user>`、`C:\Users\<user>` → `%USERPROFILE%`）、`.gitignore` 排除執行期資料（`data/ reports/ logs/`）與編譯產物、新增本檔。推送 50 個檔案。 | `3a9ef7b` |
| 2026-11-16 | fix | `remove-quark.ps1` / `remove-avg-browser.ps1` / `purge-leftovers.ps1` 移除寫死的 `C:\Users\<user>`，改用 `$env:LOCALAPPDATA` / `$env:APPDATA`（同機展開值不變，其他使用者才找得到自己的目錄；DryRun 已核對） | `fa95894` |

> 「Commit」欄留 `—` 表示那是發佈動作本身或僅文件調整；有對應 commit 時填短 hash。

> **本文件（以及 `docs/HISTORY.md`、`docs/TODO.md`、`docs/development.md`）提到的一些腳本
> —— `avg-*`、`remove-*`、`purge-leftovers`、`disable-autodesk`、`safemode`、`reset-traynotify`、
> `dump-events` 等 —— 是作者本機的工具，未包含在公開版。** 那些紀錄保留原樣（歷史事實），
> 但相關檔案不在這個 repo 裡。

## Issue 處理紀錄

一筆一行，**最新在最上面**；欄位固定。

| 日期 | Issue | 類型 | 處理摘要 | Commit | 已回覆 |
|---|---|---|---|---|---|
| — | — | — | （尚無公開 issue） | — | — |

- **類型**：`bug` / `feat` / `question` / `wontfix`
- **處理摘要**：一句話說「改了什麼」，不要貼整段 diff
- **已回覆**：`✅` / `❌`（❌ 代表只改了程式、還沒在 issue 上說明 → 不算處理完）

---

## 分流原則

| 類型 | 判斷 | 處理 |
|---|---|---|
| **Bug**（數字錯、腳本壞、資料缺） | 能重現，或指出的行為與文件矛盾 | **直接修**，優先於任何 feature。修完在 issue 貼 commit 與驗證輸出，再關閉 |
| **Feature** | 不偏離主題即可做 | 主題＝「量測真實寫入量／找出誰在寫／延緩 SSD 磨損」。符合就排進 `docs/TODO.md`，不合則關閉並說明原因 |
| **問題／用法詢問** | 文件已回答 | 貼文件段落連結後關閉（`question`） |
| **環境不相容**（Linux/macOS、非 Windows 10/11） | 架構上不做 | 關閉並說明：本專案依賴 `PhysicalDisk` 計數器、ETW Kernel-File 與 `mklink /J` |

**偏離主題的典型例子**（會關閉）：「順便幫我清 C: 暫存檔」（那是搬移／清理，不是量測）、
「預測 SSD 什麼時候壞」（那是 SMART 趨勢）、「加雲端儀表板」（見下節）。

## 不接受的變更

1. **任何把資料上傳到雲端／第三方的設計。** 資料全留在本機，唯一監聽是 `localhost:8737`。
   加遙測、遠端 API、「同步到雲端」一律拒絕。
2. **要求關閉防毒／Windows 安全性功能才能運作。** 需要提權的地方只有 ETW 收集，且只用官方 API。
3. **內建破解、序號、繞過授權**，或協助規避他人軟體授權的功能。
4. 需要修改系統核心設定才能量測的做法（本專案刻意只用效能計數器與 ETW）。

## 自動監看

已實作：**`tools/github-watch.ps1`** ＋ Windows 排程工作 `SSDWriteMonitor-GitHubWatch`（每 30 分鐘）。

```
powershell -NoProfile -ExecutionPolicy Bypass -File D:\dev\disk-monitor\tools\github-watch.ps1 -Once
```

行為：

1. `gh issue list` 抓 open issues（最多 50 個）
2. 與 `logs\github-state.json` 比對 → 只處理「新出現」或「updatedAt 變了」的
3. 有就派一個 agent：`opencode run --auto --archived`
   （任務內容寫在 `logs\github-issue-<N>-<時間>.md`，agent 輸出存 `logs\github-agent-<N>-<時間>.log`）
4. agent 依上面的分流原則處理：bug 直接修 → 跑 `check-scripts.ps1` → commit + push →
   在 issue 回覆 → 回填本檔「Issue 處理紀錄」
5. **沒有新 issue 就什麼都不做**（一次檢查約 1–2 秒）

保險：

- **鎖檔** `logs\github-watch.lock`（60 分鐘過期）→ 不會兩個 agent 同時改同一個 repo
- **每輪最多 3 個 issue**（`-MaxPerRun`），其餘留到下一輪
- **agent 逾時 45 分鐘**強制結束（`-AgentTimeoutMinutes`）
- `-DryRun` 只看會處理哪些；`-NoDispatch` 只更新狀態不派工；`-Loop` 前景常駐（測試用）
- 日誌：`logs\github-watch-<日期>.log`

移除排程：

```powershell
Unregister-ScheduledTask -TaskName 'SSDWriteMonitor-GitHubWatch' -Confirm:$false
```

手動流程（沒有排程或想自己處理時）：開 [Issues](https://github.com/ufft47/ssd-write-monitor/issues)
→ 依上表分流 → 處理後回填「Issue 處理紀錄」。
