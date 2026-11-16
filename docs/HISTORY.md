# HISTORY — 已完成項目的完整紀錄

> 每項都記「估時 / 實際 / 倍率 / 驗收證據」。完成的任務從 `TODO.md` 移到這裡。
> **估時＝人類工程師的估計工時（推估）；實際＝本次工作階段的牆上時間。**
> 倍率＝實際 ÷ 估時。依 `EXPERIENCE.md` 第 38 條：純邏輯類通常 0.2×、UI 類 0.5×、驗證整合類 0.8×。
> 最後更新：2026-11-16 12:01

---

## 2026-11-15（單日 31 個 commit）

### A. 監控系統：歸因工具鏈與儀表板

| # | 項目 | 估時 | 實際 | 倍率 | 驗收證據 |
|---|---|---|---|---|---|
| A1 | `clean-attrib.ps1`：用「路徑可信度」扣掉不可能成立的歸因列 | 90 分 | 34 分（04:40–05:14） | **0.38×** | F: 對帳 99%（351.6 / 348.8 GB）；C: 33%（15.90 / 5.03 GB）；D: 121% 被標為不可用 |
| A2 | 指名 C: 的熱分鐘（13 個 ≥200 MB 佔 46%） | 30 分 | 含在 A1 | — | `01:31 icarus 1,533 MB`、`01:35 AdODIS-installer 1,038 MB`、`02:36/02:37 AVGSvc` |
| A3 | 修 `disk-report.ps1` 排序（`perf` → `ts`） | 20 分 | 8 分 | 0.4× | 07:00 / 08:00 的 310 GB 假柱消失 |
| A4 | 修儀表板三個量測 bug | 120 分 | 50 分（09:00–09:50） | **0.42×** | C: 今日 333.38 → **22.25 GB**；D: 320.18 → **85.74 GB**；Robocopy 59.35 GB 從排行消失；覆蓋率 7,765% → 3.2%（並附解釋） |
| A5 | 修 `hourly-summary.log` 的兩根假柱 | 30 分 | 22 分 | 0.73× | 07:00 310.31 → **1.66 GB**、08:00 310.25 → **0.95 GB**；`today` 327.28 → 18.63、328.82 → 19.58。**改寫前先驗算**：01:00–06:00 合計 = 原檔 06:00 的 `today` 16.97 GB ✓ |

### B. 清理與搬移（C: 空間與寫入）

| # | 項目 | 估時 | 實際 | 倍率 | 驗收證據 |
|---|---|---|---|---|---|
| B1 | 關閉 Autodesk Access 更新器（1.87 GB/日） | 25 分 | 12 分 | 0.48× | 服務 `Autodesk Access Service Host` = `Stopped` / `Disabled`，無 `AdODIS` 進程 |
| B2 | AVG 垃圾清理（崩潰傾印 300 檔） | 40 分 | 15 分 | 0.38× | 實刪 **3,600 MB**；`Antivirus\log` 3,988 → 388.7 MB；AVG 四服務仍 Running |
| B3 | 移除夸克网盘 | 40 分 | 6 分 | 0.15× | C: **+3.01 GB**（124.30 → 127.31 GB）；4 個目錄消失、懸空引用 5 處全清 |
| B4 | `Program Files\AVG` → D:（安全模式） | 150 分 | 47 分（07:23–08:10，含兩次失敗） | **0.31×** | junction 存活；D: 上 `defs\26111412_stream\*.bin` 08:02:28 仍被寫入；安全性中心登記路徑 = `D:\MX500\avg\ProgramFiles\Antivirus\wsc_proxy.exe` |
| B5 | ASUS IME ETW 追蹤停止 | 30 分 | 12 分 | 0.4× | `.etl` 凍結在 231.88 MB、60 秒 +0.00 MB；`logman query` 回 `Data Collector Set was not found`；打字正常 |
| B6 | ASUS 日誌搬 D: | 30 分 | 12 分 | 0.4× | C:/D: 兩條路徑指向同一檔（286.250 MB / 同一 `LastWriteTime`）；D: 上 `.etl` 30 秒 +0.375 MB |
| B7 | 殘留清理（兩批） | 40 分 | 15 分 | 0.38× | 第一批刪 D: 孤兒 **2,062.5 MB**；第二批提權刪 **1,317 MB**（ASUS `log.bak` 260 + `ProgramData\AVG.bak` 1,057） |

### C. 診斷工具與文件

| # | 項目 | 估時 | 實際 | 倍率 | 驗收證據 |
|---|---|---|---|---|---|
| C1 | `safemode.ps1`（WinRE 缺失時的替代方案） | 45 分 | 18 分 | 0.4× | 發現本機 `{current}` / `{default}` 被 bcdedit 拒絕，改用 `/enum ACTIVE` 讀真實 GUID |
| C2 | `check-avg-migration.ps1`（五項健康檢查 + 每日排程） | 60 分 | 22 分 | 0.37× | 五項全 OK、verdict=WAIT（0.04/3 天）、最快可刪日 2026-11-18 07:56、exit=1 |
| C3 | 系統變更台帳 5 筆（`SYSTEM-CHANGES.md`） | 40 分 | 25 分 | 0.63× | 178,846 → 194,497 bytes；六欄位齊全、最新在最上面（順序與欄位標題都校正過） |
| C4 | README 增補 8 節（含三個量測 bug 的根因） | 60 分 | 30 分 | 0.5× | 37.2 KB；含「拒絕存取有兩種原因」「attrib CSV 的 minute 是完整時間戳」等地雷 |

**當日合計：估時 955 分（15.9 小時）／實際 394 分（6.6 小時）→ 0.41×**

---

## 2026-11-16

### D. 瀏覽器 profile

| # | 項目 | 估時 | 實際 | 倍率 | 驗收證據 |
|---|---|---|---|---|---|
| D1 | Edge `User Data` 搬 D:（junction，工具 `move-edge-ud.ps1`） | 未預估 | 約 11 分 | — | Junction → `D:\MX500\edge\User Data`；18,663 檔 / 1.89 GB，逐檔比對缺 **0**、大小不同 **0**、落地測試 **是**；備份 `User Data.bak-20261116-013507`（1.89 GB）留觀察期 |

### E. 診斷：explorer.exe 吃 41–43% CPU

| # | 項目 | 估時 | 實際 | 倍率 | 驗收證據 |
|---|---|---|---|---|---|
| E1 | 工作列圖示快取（`TrayNotify`）膨脹 → `reset-traynotify.ps1` | 未預估 | 約 2 小時（含 xperf 診斷） | — | xperf 堆疊：`CTrayNotify::_InsertNotify` → `CTrayItemRegistry::DoesGUIDIconMatchPathOrIdentity` → `TNIdentity::GetIdentity` → `WINTRUST!WTGetSignatureInfo` → SHA-256（75%）；刪 `IconStreams`/`PastIconsStream` 並重啟 explorer 後 **41–43% → 1–3%**，`PastIconsStream` 929,606 → 47,392 bytes |

> 2026-11-16 的兩項都估時未預估，所以不算倍率、也不列當日合計。

---

## 被放棄 / 判定不可行的任務

| 項目 | 為什麼放棄 | 什麼情況下該重新評估 | 留下的資產 |
|---|---|---|---|
| **`C:\ProgramData\AVG` 搬到 D:** | AVG 啟動時**把 junction 拆掉、重建實體目錄**（08:00–08:02，並開始往 C: 寫） | AVG 改版若不再重建 ProgramData；或改用 AVG 官方支援的資料目錄設定 | `avg-clean-and-move.ps1 -MoveProgramData`（含 `-Verify` 可判定「被 AVG 接手」）；完整記錄在 README |
| **只停 AVG 服務就搬（不進安全模式）** | 服務停得掉，但 16 個驅動仍在；`avgSP` 是 System 級自我保護 | 不再需要處置（已改用安全模式成功） | `avg-try-stop.ps1`（會實測並自動復原，可重複使用） |
| **`logman stop` 當成永久解法** | 不持久：重開機後服務會重建 ETW 追蹤（實測 08:19 已恢復） | 若 ASUS 提供關閉記錄的設定 | 改成 junction（B6）後就不再依賴它 |
| **分頁檔搬到 D:（22 GB）** | **業主明確表示擱置** | 業主主動提起 | `move-pagefile.ps1`（含 `-Verify` / `-Revert`，可直接用） |
| **追查 06:00–06:01 的 625 MB 突發** | 已排除目錄掃描（對照實驗：掃 7.8 GB 只 +1.8 MB 寫入）、分頁（0 p/s）、排程工作、休眠。屬核心內部寫入，**原理上無行程可歸因** | 若出現規律性尖峰且伴隨效能問題 | 對照實驗方法（見 `development.md`） |
| **用 `FileIOName` / `FileIOFileRundown` 拿檔名** | 實測完全不送（`name_events=0`、`rundown_entries=0`） | Windows 版本行為改變 | 已知限制，避免後人重試 |
| **`GetProcessIoCounters` 對帳** | 含管道／IPC，與實體落差 2.7 倍 | 只看單一行程的相對趨勢時仍可用 | 記錄在 README |

---

## 更早（2026-11-14 及之前，摘要）

| 項目 | 證據 |
|---|---|
| 監控三本柱（`DiskMonitor` / `CWatchCollector` / `CWatchTray`）＋ 網頁儀表板 8737 | 三個排程工作皆 Ready；`collector.json` 心跳正常 |
| cwatch collector 五次修正（IRP 配對、FileKey 只做診斷、Other 桶重複計數…） | commit `3cc9eae`→`1800fa3`；100 MB 探針驗收記成 111 MB（物理 100.2 MB） |
| 三個瀏覽器 profile 搬到 D: | `系統目錄連結清單.md` 記載 3 個 junction（Brave 3.23 GB / Chrome 2.37 GB / opencode 1,007.6 MB） |
