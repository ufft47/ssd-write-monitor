# 磁碟 IO 長期監控（disk-monitor）

長時間記錄磁碟讀寫，每小時產出一份報告。主要目的是追蹤 **C: 的實際寫入量**
（SSD 磨損與空間壓力），並找出是誰在寫。

所有東西都在 `D:\dev\disk-monitor`，不佔 C: 空間，也不寫進任何 git repo。

---

## 資料實際在哪裡

這套工具用到的檔案分兩類：

- **工具自己的資料**：`data\`、`reports\`、`logs\`，就在本目錄底下。
- **別的東西**：瀏覽器 profile、快取、OpenCode 資料等 —— 這些實際位於 `D:\MX500`，
  C: 上只是 junction。

完整的「哪個 C: 路徑 → D: 的哪裡」對照記在另一份文件：

**`D:\MX500\系統目錄連結清單.md`**（產生器：`D:\MX500\tools\list-links.ps1`，環境變了重跑一次即可）

這裡**不重複**那張表 —— 兩份清單各自維護一定會不同步。

## 最關鍵的一件事：量哪一個計數器

| 計數器 | 代表什麼 | 能不能當「落盤量」 |
|---|---|---|
| **`PhysicalDisk`** | 真正寫到裝置的位元組 | ✅ **唯一可信** |
| `LogicalDisk` | 檔案系統層：哪個磁碟區被寫 | ⚠️ 含快取命中與延遲回寫，與落盤不同步 |
| `Process … IO Write Bytes` | 進程發出的**邏輯** I/O | ❌ 含 pipe／socket／快取命中，會虛高一個量級 |

**實測對照（2026-11-10 14:50，同一小時窗口）**

| 來源 | 數字 |
|---|---|
| 進程邏輯 I/O 合計 | OpenCode 5.83 GB + brave 2.45 GB + … |
| `PhysicalDisk 0`（C: 所在） | **191.8 MB** |
| `LogicalDisk C:` | 947.3 MB |

差距不是誤差，是定義不同。**要回答「這顆 SSD 被寫了多少」，只能看 PhysicalDisk。**

這個結論來自 `D:\MX500\tools\measure-writes.ps1`（README §4）的實測：

> C: 中位數 0 / P90 353 KB/s / max 2,425 KB/s → 9.5 GB/日；180 個樣本中 98 個零寫入。
> 若改用 `Process IO Write Bytes/sec`，會得到 545 KB/s，而實際落盤只有約 40 KB/s。

因此本監控**以 PhysicalDisk 為主表**，LogicalDisk 只作為「哪個磁碟區」與「剩餘空間」的輔助。

---

## 資料來源與檔案

全部取自「開機以來累計值」（`Win32_PerfRawData_*`），由報告腳本用前後差值換算。
累計值的優點是**總量精確**，不受取樣間隔影響；間隔只影響分布統計的解析度。

```
disk-monitor\
  setup-task.ps1            建立／更新排程工作
  README.md                 本檔
  src\
    disk-monitor-run.ps1    排程唯一進入點（取樣 → 必要時補報告／日報）
    disk-sample.ps1         取一次樣本
    disk-report.ps1         每小時報告（-NowView 即時檢視、-Force 重算上小時）
    disk-daily.ps1          每日 C:/D: 對照（搬遷前後基線比較）
    run-hidden.vbs          由 setup-task.ps1 產生，讓排程執行時完全不閃視窗
  data\
    phys\YYYY-MM-DD.csv     實體裝置累計值（**主要來源**）
    raw\YYYY-MM-DD.csv      磁碟區累計值 + 剩餘空間
    smart\YYYY-MM-DD.csv    SMART 快照：終身寫入、健康度、溫度、通電時數
    proc\YYYY-MM-DD.csv     每分鐘寫入量 ≥1 MiB 的進程（邏輯 I/O）
    state\proc-prev.json    上一輪進程計數（算差值用）
    state\last-report.json  已產出到哪個小時（避免重複、支援補寫）
  reports\
    YYYY-MM-DD.md           當日每小時報告
    latest.md               最新一小時 + 今日累計 + SMART 長期
    daily.md                C:/D: 每日寫入對照（搬遷前後基線）
  logs\
    hourly-summary.log      單行摘要（長期趨勢，最適合貼進 Excel）
    daily-summary.log       每日一行（C:/D: 的 SMART 與實測落盤量）
    monitor.log             執行記錄與錯誤
```

裝置與磁碟區的對應（本機實測）：`0 C:`、`1 E:`、`2 I: F: G:`、`3 D:`。

---

## 報告長什麼樣

每個小時一塊，含三段：

1. **實體落盤**：寫入總量、中位數、P90、最大、零寫入樣本數、忙碌率、推估 GB/日
2. **檔案系統層**：每個磁碟區的寫入、中位數、峰值、剩餘空間變化
3. **C: 寫入焦點**：落盤量、與前一小時比較、今日累計、開機以來累計、以及進程（標明是邏輯 I/O）

單行摘要（`logs\hourly-summary.log`）：

```
2026-11-10 15:00 | C: disk 850.2 MB | med 12.1 KB/s | p90 353.0 KB/s | max 12.40 MB/s | fs 900.0 MB | today 4.21 GB | free 125.6 GB (-120.0 MB) | cover 98.3%
```

`disk` = 實體落盤、`fs` = 檔案系統層、`med`/`p90`/`max` = 每分鐘樣本速率分布。

### 隨時看目前這一小時（不寫檔）

```powershell
& 'D:\dev\disk-monitor\src\disk-report.ps1' -NowView
```

---

## 終身寫入量與健康度（SMART，不需要管理員）

效能計數器重開機就歸零，所以「這顆 SSD 一輩子被寫了多少」只能從 SMART 拿。
本機的做法是**借道已經在跑的 CrystalDiskInfo**：

```
C:\soft\disk\CrystalDiskInfo8_1_0\Smart\<機型+序號>\Smart.ini
C:\soft\disk\CrystalDiskInfo8_1_0\Smart\<機型+序號>\HostWrites.csv
```

- CrystalDiskInfo 是以管理員權限常駐的（`DiskInfo64.exe` 的 `ExecutablePath` 對一般使用者不可見就是證據），
  所以它讀得到 SMART；
- 它把結果寫進 `Smart.ini`（現值）與 `HostWrites.csv`（每 10 分鐘一筆的歷史）；
- 我們**只讀檔案**，因此不需要提權。直接呼叫 `Get-StorageReliabilityCounter` 在非管理員下會 `CimException`。

### 目前的實測值（2026-11-10）

| 磁碟 | 機型 | 終身寫入 | 健康度 | 通電 | 溫度 |
|---|---|---|---|---|---|
| **C:** | CT500MX500SSD1 | **64,064 GB** | 正常（壽命剩 43%） | 10,721 h | 39 °C |
| D: | GIGABYTE GP-GSM2NE3512GNTD | 5,897 GB | 正常（100%） | 25,516 h | 41 °C |
| E: | WDC WD40PURZ | — | **注意** | 20,868 h | 33 °C |
| I:/F:/G: | ST8000AS0002 | — | **注意** | 17,589 h | 33 °C |

C: 的歷史：2019-05-23 上線、2,728 天、平均 23.5 GB/日。近 7 日 50.9 GB/日、近 30 日 40.0 GB/日
—— 比終身平均高出一倍，值得注意。

### 三個限制

1. **CrystalDiskInfo 必須在跑**。它關掉或移除後，`HostWrites.csv` 就停止更新，數值會凍結在最後一次。
2. **解析度 1 GB、每 10 分鐘才更新**。所以「本小時增量」很粗略；要看趨勢請用日統計。
3. **單位是 CrystalDiskInfo 顯示的 GB**，不是位元組原文。要換算 TBW 時以它的數字為準，
   不要自行乘 512（那會得到完全不同的量級）。

### 日統計從哪來

`reports\latest.md` 的「SMART 長期寫入」直接讀 CrystalDiskInfo 的 `HostWrites.csv`
（46,000 筆、2019 至今），算出：終身累計、昨天、近 7 日、近 30 日平均。
`data\smart\*.csv` 則是本監控自己的快照，用於每小時報告的表格與交叉檢查。

CrystalDiskInfo 若被移到別的位置，用 `-CdiSmartDir` 指定：

```powershell
& 'D:\dev\disk-monitor\src\disk-report.ps1' -NowView -CdiSmartDir 'D:\path\to\Smart'
```

---

## 每日對照：搬遷前後（`reports\daily.md`）

`src\disk-daily.ps1` 每天整點自動產出一次，把 **C: 與 D: 的每日寫入量**放在同一張表，
並依 `data\state\cutover.json` 的日期切成「搬遷前 / 搬遷後」：

```json
{"date":"2026-11-10","note":"C: 的寫入密集目錄已搬到 D:（瀏覽器快取、OpenCode data、WSL/Docker、TEMP 等）"}
```

要改基準日就改這個檔（只影響報表的切分，不會動任何資料）。

兩種數字並列，因為它們回答不同問題：

| 欄位 | 來源 | 能回答 |
|---|---|---|
| `SMART` | CrystalDiskInfo `HostWrites.csv` | 幾年前到今天的長期趨勢（1 GB 解析度） |
| `落盤` | 本監控 `data\phys` | 2026-11-10 之後的位元組級精確量 |

手動產生（含今天這個還沒結束的一天）：

```powershell
& 'D:\dev\disk-monitor\src\disk-daily.ps1' -IncludeToday
```

看之前先確認「有效天數」。CrystalDiskInfo 沒在跑的日子沒有資料（表上是 `—`），
有效天數少於 7 天時，單日尖峰就能主導平均。

---

## 為什麼是「中位數 / P90 / 最大」而不是平均值

平均值會被單一尖峰綁架。實測：一個 62 MB/s 的尖峰可以把「9.5 GB/日」算成「63 GB/日」。

- **中位數**：這顆碟「平常」的寫入速率（很多時候是 0）
- **P90**：有一成時間高於這個值
- **最大**：偶發尖峰（Windows Update、瀏覽器下載、 antivirus 掃描）
- **推估 GB/日**：以本小時實際速率外推，**只適合看量級**，短窗口容易失真

所以判斷「長期寫入量」請看 `hourly-summary.log` 的每日總和，不要看單一小時的推估值。

---

## 判讀上的三個陷阱

1. **延遲回寫**：某分鐘 C: 落盤 918 KB/s，但同期所有進程邏輯寫入只有 700 KB/s ——
   因為那是先前累積的髒頁被刷出。所以**只談趨勢，不要對到毫秒**，也不要用
   「進程加總 = 落盤量」去對帳。
2. **邏輯 I/O ≠ 落盤**：寫進快取、寫到 pipe／socket 都算進程 I/O，但沒有碰碟。
   本機實測差距可達 40 倍。
3. **重開機**：累計值歸零。偵測到數值下降的區間會整段略過，並在報告註記。

### 想看「終身累計寫入量」

**不需要管理員**：走 CrystalDiskInfo 的 `Smart\*\Smart.ini`，見上面「終身寫入量與健康度」。
直接呼叫 `Get-StorageReliabilityCounter` 在非管理員下會 `CimException`，那是另一條路。

---

## 排程工作

名稱 `DiskMonitor`，每 1 分鐘執行一次，使用者帳號、`InteractiveToken`，
透過 `wscript` + `run-hidden.vbs` 以完全隱藏視窗啟動（不會閃主控台）。
已設定為電池供電也執行、單次執行上限 10 分鐘。

```powershell
Get-ScheduledTask -TaskName DiskMonitor | Format-List TaskName,State
Get-ScheduledTaskInfo -TaskName DiskMonitor | Select LastRunTime,LastTaskResult,NextRunTime

# 立即手動跑一輪
& 'D:\dev\disk-monitor\src\disk-monitor-run.ps1'

Disable-ScheduledTask -TaskName DiskMonitor          # 暫停
Unregister-ScheduledTask -TaskName DiskMonitor -Confirm:$false   # 移除
```

重建或改間隔：

```powershell
& 'D:\dev\disk-monitor\setup-task.ps1' -IntervalMinutes 2
```

> 註：本機標準使用者無法使用 S4U（會「存取被拒」），所以退回 InteractiveToken。
> 「不閃視窗」是靠 wscript 的 `Run(..., 0, ...)`，與登入類型無關。

### 補寫漏掉的小時

報告腳本每次執行都會檢查「有沒有還沒產出的小時」，休眠或關機造成的空窗會在下次
執行時自動補上（最多回溯 48 小時），空窗小時只留一行說明。

要重算上一個小時（會**再追加**一塊，不覆蓋舊的）：

```powershell
& 'D:\dev\disk-monitor\src\disk-report.ps1' -Force
```

---

## 保留期限

- `data\phys`、`data\raw`、`data\proc`：120 天（`disk-sample.ps1` 的 `-RetentionDays`）
- `reports`：365 天
- `logs\monitor.log`：超過 8 MB 自動輪替為 `monitor.log.1`

---

## CWatch：逐進程 × 逐磁碟區歸因（需要管理員）

前面所有表格都只能回答「C: 被寫了多少」。要回答**「哪個程式寫的」**，唯一可靠的方法是
ETW 的 kernel FileIO 事件（每筆都帶 ProcessId 與檔案路徑）。

```
src\cwatch\cwatch.exe     collector（需管理員）：ETW → data\attrib\*.csv
src\dashboard\            http://localhost:8737 儀表板
src\tray\                 系統匣（顯示即時 C: 速率）
```

### 為什麼需要管理員

建立 kernel ETW session 需要 `SeSystemProfilePrivilege`。非管理員執行會直接得到
`NEED_ADMIN`（實測：`UnauthorizedAccessException - Access Denied (Administrator rights required to start ETW)`）。
所以 collector 由排程工作 `CWatchCollector` 以**最高權限**執行；儀表板與托盤都是一般權限。

### 安裝 / 驗證 / 移除

```powershell
# 一次（會跳 UAC 同意視窗）：跑 selftest → 註冊 CWatchCollector → 啟動 → 驗證心跳
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\install-collector.ps1'

# 托盤 + 儀表板（一般權限）
& 'D:\dev\disk-monitor\install-tray.ps1'

# 移除
Unregister-ScheduledTask -TaskName CWatchCollector -Confirm:$false
Unregister-ScheduledTask -TaskName CWatchTray -Confirm:$false
```

### 資料格式

`data\attrib\YYYY-MM-DD.csv`

```
minute,pid,process,volume,path,bytes,ops
2026-11-14 22:50,39804,brave.exe,C:,"C:\...\Default\History",125829120,812
2026-11-14 22:50,39804,brave.exe,C:,"C:\...\Default\Cache\data_1,data_2",5242880,40
```

- 每個（進程 × 磁碟區）保留**前 5 大檔案**，其餘合成 `(其他)` 一列，所以總量不會失真
- `bytes` 來自 ETW 的 `IoSize`；若某次寫入拿不到大小，`ops` 仍會計數，
  可用 `bytes/ops` 判斷資料是否完整
- `data\state\collector.json` 是心跳（15 秒更新），托盤與儀表板靠它判斷 collector 是否活著

### 已知限制

1. **只記錄寫入**，不記讀取（DiskGenius 那种大量讀取不會出現在這裡）。
2. **全機同時只能有一個 kernel logger**。你若同時跑 WPA／`wpr` 錄影，collector 會啟動失敗
   並在 `logs\collector.log` 留下原因 —— 這是明確失敗，不是靜默。
3. 檔案路徑含使用者資訊，資料只留在本機。

---

## 修改時的地雷（實測）

1. **`.ps1` 只要含中文，就必須是 UTF-8 **有 BOM**。**
   沒有 BOM 時 PowerShell 5.1 用 CP950 解讀，**行尾的中文可能把換行吃掉** ——
   症狀是下一行被併進上一行。實際踩到：`param()` 被併進註解，預設值完全失效，
   腳本拿到的參數全是 `$null`，錯誤卻指向十幾行之後。
   ```powershell
   $p = '...\disk-sample.ps1'
   [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))
   ```
2. **`ConvertFrom-Json` 不要接在管線尾端再 `@()`**：它把整個陣列當一個物件輸出，
   `@()` 之後變巢狀陣列（`Count` 永遠是 1）。用 `ConvertFrom-Json -InputObject $raw`。
3. **`ConvertTo-Json -InputObject` 不要直接吃 `List[object]`**（丟 ArgumentException），先 `.ToArray()`。
4. **PowerShell 變數不分大小寫**：`$now`（時間）與 `$Now`（開關）是同一個變數。
   所以「即時檢視」的開關叫 `-NowView`。

---

## 版本控制

這個目錄是 git repo（分支 `main`）。

- **納入版控**：腳本、文件、`src\cwatch\lib\` 的第三方 DLL（重建用，約 5 MB）
- **不納入**：`data\`（每天成長的原始資料與歸因表）、`reports\`、`logs\`、
  `*.exe`（`build.ps1` 重建）、`*-hidden.vbs`（安裝腳本產生、含機器專屬路徑）

```powershell
git -C D:\dev\disk-monitor status
git -C D:\dev\disk-monitor log --oneline -10
```

改完腳本要留紀錄：

```powershell
cd D:\dev\disk-monitor
git add -A
git commit -m "說明改了什麼"
```

> `.gitattributes` 設了 `* -text`：**不做行尾轉換**。這些 `.ps1` 含 BOM 且直接在本機執行，
> 讓 git 轉 CRLF/LF 只會製造無意義 diff。
