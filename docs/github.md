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
| 2026-11-16 | **首次發佈** | public repo 建立（MIT）：中英雙語說明（`README.md` / `README.zh-TW.md`）、英文版 README、`LICENSE`、`NOTICE.md`（微軟 DLL 授權）、去識別（`WIN10-MX5000\<user>` → `<user>`、`C:\Users\<user>` → `%USERPROFILE%`）、`.gitignore` 排除執行期資料（`data/ reports/ logs/`）與編譯產物、新增本檔。推送 50 個檔案。 | `3a9ef7b` |

> 「Commit」欄留 `—` 表示那是發佈動作本身或僅文件調整；有對應 commit 時填短 hash。

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

**規劃中**：`tools/github-watch.ps1`（每 30 分鐘）→ 有新 issue 時派 agent 讀取、依上表分流、
修 bug、跑 `check-scripts.ps1`、commit + push、在 issue 回覆、並回填本檔。

在完成之前，手動流程：開 [Issues](https://github.com/ufft47/ssd-write-monitor/issues)
→ 依上表分流 → 處理後回填「Issue 處理紀錄」。
