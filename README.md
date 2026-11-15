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
  clean-attrib.ps1          歸因 CSV 的清理與對帳（扣掉不可能成立的列）
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

## 扣掉「不可能成立」的歸因列（`clean-attrib.ps1`）

ETW 的 `(pid, FileObject)` 對照表有個先天的洞：`FileObject` 指標會被核心回收、再配給別的檔案。
若新的 `FileIOCreate` 沒送達，舊對照就會把**後來的寫入算到前者頭上**。

2026-11-15 實測的代價很大 —— Robocopy 在 F: 寫了 22.3 GB，卻被記到 C: 底下**五個根本不存在的路徑**：

```
9,470.8 MB  Robocopy  C:\Users\ufft4\.claude\ide
7,576.8 MB  Robocopy  C:\Users\ufft4\AppData\Local\herdr\client\endpoints.json
4,621.4 MB  Robocopy  C:\Users\ufft4\ApplicationInsightsDiagnostics.json
  689.1 MB  Robocopy  C:\Users\ufft4\AppData\Roaming\BaiduNetdisk\...
  493.5 MB  Robocopy  C:\Program Files\Git\cmd\git.EXE.Config
```

這讓 C: 的歸因總量變成物理量的 **1.9 倍**。根因（用 `FileKey` 交叉驗證）之後再修；
現在先用**路徑可信度**把這種列扣掉，並且**明確列出扣了什麼**，不偷偷丟資料。

### 分類規則

| 判定 | 條件 | 算不算 |
|---|---|---|
| `ok` | 路徑存在且是檔案 | ✅ 可信 |
| `ok` | 路徑不存在，但在 `Temp`/`Cache`/`Sessions`/`.tmp`/`.log` 下 | ✅ 可信（本來就會被刪） |
| `probe` | 檔名含 `cwatch-probe` / `cwatch-mmf` / `cwatch-selftest` | ❌ 排除，單獨列出 |
| `dir` | 路徑是目錄（目錄不是寫入目標） | ❌ 可疑 |
| `missing` | 不存在且不是暫存路徑 | ❌ 可疑 |

`probe` 那一類是**這支工具自己**寫的測試檔。不排除的話，診斷期間的名單第一名永遠是 `pwsh`。

### 用法

```powershell
& 'D:\dev\disk-monitor\clean-attrib.ps1'                    # 今天
& 'D:\dev\disk-monitor\clean-attrib.ps1' -Since '04:31'     # 只看 04:31 之後
& 'D:\dev\disk-monitor\clean-attrib.ps1' -Date 2026-11-14 -Top 25
```

輸出有五段：各實體碟對帳、被排除的探針、C: 可信名單、C: 可疑列、**C: 熱分鐘明細**。

### 對帳結果（2026-11-15 00:00–05:12 實測）

| 實體碟 | 物理寫入 | 可信歸因 | 覆蓋率 | 判讀 |
|---|---|---|---|---|
| **F:（dev 2）** | 351.6 GB | 348.8 GB | **99%** | 大檔順序寫入，歸因可信 |
| C:（dev 0） | 15.87 GB | 5.02 GB | 33% | 扣掉探針 815 MB 後 **33%** |
| D:（dev 3） | 19.43 GB | 23.43 GB | 121% | **不可用**，見下 |

**只有 04:31 之後的資料可信。** 用 `-Since 04:31` 限定的話：F: **98–99%**、C: **12–14%**、D: **6%**。
腳本會在覆蓋率 >105% 時直接印出警告，因為那在物理上不可能。

### 三個必須知道的限制

1. **C: 只覆蓋 12–14%，但這不是 bug。** 安靜量測（05:06–05:10，我不動手）：
   C: 物理 25.4 MB / 歸因 3.6 MB。剩下的是**不經過使用者模式手柄**的寫入 ——
   登錄檔 hive（registry manager 不是 FileIO）、NTFS 日誌與 MFT、記憶體映射的髒頁回寫。
   原理上無法歸因到程式，只能當成基線。
2. **D: 不能對帳，因為 Docker 在跑。** 容器的 I/O 全部發生在
   `D:\docker\wsl\DockerDesktopWSL\data\ext4.vhdx`（38.5 GB）**裡面**；
   主機端只看到 VM 對那個 vhdx 的寫入，而 `attrib` CSV 裡 **`vhdx` 一筆都沒有**。
   D: 的常態缺口約 15 MB/min，就是這個。
3. **`(device)` 是舊版的桶。** 舊版 collector 會另外寫 `volume=(device)` 的列（本日 240.77 GB），
   它不屬於任何磁碟區，新版已不再產生。

### 真正的結論：C: 是被「幾次尖峰」撐大的，不是被常態寫入

用物理量（不依賴任何歸因）拆解的形狀：

```
合計             15.87 GB
中位數/分        11.5 MB   ← 常態基線（≈16 GB/日）
P90/分           115.8 MB
平均/分          52.1 MB
熱分鐘(>=200MB)  13 個，合計 7.23 GB（佔 46%）
```

**一半的 C: 寫入集中在 13 分鐘裡。** 而這些尖峰幾乎都能指名：

| 分鐘 | 物理寫入 | 主要來源 |
|---|---|---|
| 01:31 | 1,578 MB | `icarus` 1,533 MB（AVG 掃描引擎） |
| 01:35 | 1,341 MB | `AdODIS-installer` 1,038 MB（Autodesk 更新器） |
| 03:52 | 1,301 MB | `AdODIS-installer`（+ `ADPSDK\JSON\Upload`） |
| 00:38 | 420 MB | `System`（`C:\ProgramData`） |
| 02:36 / 02:37 | 385 / 374 MB | `AVGSvc`（`ipwl.cache`） |
| 01:41 | 337 MB | `System`（`Autodesk\ADPSDK\JSON\Upload`） |

以全天可信歸因排名，前兩名各佔 36%：**`AdODIS-installer` 1.87 GB、`icarus` 1.86 GB**。
換句話說，**想砍 C: 的寫入，先處理 AVG 與 Autodesk 更新器**，投報率遠高於逐一追查常態寫入。

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
5. **`attrib` CSV 的 `minute` 欄位是完整時間戳**（`2026-11-15 05:45`），不是 `HH:mm`。
   拿 `'05:14'` 去比會得到 `'2026-...' < '05:14'` 永遠為假 —— **篩選等於沒做，算出來是全天數字**。
   實際踩到：用臨時腳本算「05:14 之後 taskhostw 寫了多少」，得到 254.7 MB；
   正確值是 24.5 MB（`clean-attrib.ps1` 的 32.9 MB 含同目錄其他檔案）。
   臨時分析要跟 `clean-attrib.ps1` 對帳，兩者差在「探針列」與「暫存路徑」才算合理差異。

---

## 把 AVG 的目錄搬到 D:（含為什麼選安全模式）

`C:\Program Files\AVG` 是 AVG **寫入最兇的目錄**（2026-11-15 實測：可信寫入 523 MB，
其中定義更新 `defs\*.tmp` 300.6 MB、`AvVps\*.ipending` 222.0 MB），
但它同時是**最難搬的**。原因與對策如下。

### 障礙：自我保護驅動

| 項目 | 實測 |
|---|---|
| `avgSP.sys` | `State=Running`、`StartMode=System`，在 `C:\WINDOWS\system32\drivers\` |
| 其他 AVG 驅動 | 共 **16 個**（`avgArDisk`／`avgArPot`／`avgbidsdriver`／`avgbidsh`／`avgbuniv`／`avgDrvBrg`／`avgElam`／`avgKbd`／`avgMonFlt`／`avgNetHub`／`avgRdr`／`avgRvrt`／`avgSnx`／`avgStm`／`avgVmm`）全部 Running |
| `C:\Program Files\AVG` 的 ACL | Administrators 有 FullControl —— **不是 ACL 擋的** |

所以正常開機狀態下「改名這個目錄」一定失敗：`avgSP` 會拒絕，而且 16 個驅動握著裡面的檔案。

### 為什麼不是「把 16 個驅動設停用 → 重開機」

那條路要改 `HKLM\SYSTEM\CurrentControlSet\Services\avg*` 的 `Start` 值，但這些鍵本身受 AVG 保護，
且改壞會讓防毒停在半殘狀態（驅動不載入、服務照跑），比搬目錄本身危險。

### 實測：安全模式就能解鎖

| 查證 | 結果 |
|---|---|
| `Control\SafeBoot\Minimal`（85 項）的 AVG 相關項目 | 只有一個叫 **`avgSP.sys`** 的殘留項目 |
| `Control\SafeBoot\Network`（143 項） | 同上 |
| 真正的服務名 `avgSP` 是否在清單內 | **不在**（`avgSP.sys` 對不上 `avgSP`，那個項目沒有任何作用） |
| 16 個 AVG 驅動在安全模式 | **全部不載入** |
| `Winmgmt`（互鎖要用的 WMI）是否在 Minimal | **在**，所以安全模式下 `Get-CimInstance` 可用 |

結論：**安全模式 = 一個 AVG 完全不存在的環境**，而那正是搬目錄需要的狀態。
一次重開機即可，不必碰任何驅動登錄鍵。

### 執行方式（`avg-move-programfiles.ps1`）

> **2026-11-15 更正：本機的 WinRE 映像不存在，所以「Shift + 重新啟動 → 疑難排解 → 啟動設定」
> 這條路走不通。** 實測 `C:\Windows\System32\Recovery\Winre.wim` 與
> `C:\Recovery\WindowsRE\Winre.wim` 都不存在，`ReAgent.xml` 卻在 06:49 被改過；
> 三次重開機（06:44 / 06:58 / 07:10）都是 `RuntimeBroker` 發起的**正常重新啟動**，
> 沒有出現任何選單。「進階啟動」選單是 WinRE 提供的，映像不在就只剩正常開機。
>
> 改用下列任一方式，兩者都不需要 WinRE：
>
> - **msconfig（首選，最不容易出錯）**：Win+R → `msconfig` → 「開機」頁 → 勾「安全開機」→
>   套用 → 確定 → 重新啟動。做完事後**回去取消勾選**再重新啟動。
> - **`safemode.ps1 -Enter`**：用 `bcdedit` 指定下一次開機進安全模式；
>   做完用 `-Exit` 清除。注意本機 bcdedit 對 `{current}`／`{default}` 會回
>   「指定的命令列選項無效」，所以腳本改用 `/enum ACTIVE` 讀出的真實 GUID。

```powershell
# 0) 讓下一次開機直接進安全模式（不需 WinRE）
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\safemode.ps1','-Enter'
#    或用 msconfig 勾「安全開機」，效果相同

# 2) 安全模式中提權執行搬移
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Move'

# 3) 正常重新開機後驗證
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Verify'

# 4) 出事時（安全模式）還原
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Revert'
```

### 安全網

- **三重前置檢查**：AVG 行程數、AVG 服務狀態、`sc.exe` 驅動狀態、以及「獨佔開檔測試是否仍被鎖」。
  任一項成立就中止，且**不改動任何東西**。開機狀態判定失敗（WMI 無回應）時不阻擋，改由這四項把關。- **複製先行**：`robocopy /E /COPY:DAT /XJ`（不用 `/MOVE`），逐檔比對 missing 與 size-diff 皆為 0 才動來源。
- **原件只改名**（`AVG.bak-<時間>`），**不刪除**；改名失敗或落地測試失敗都會自動回滾。
- **刪 junction 只用 `cmd /c rmdir`**，不加 `/s`（會跟進刪掉 D: 上的目標）。

### 三個必須知道的代價

1. **搬完不會立刻省空間。** 原件留在 `C:\Program Files\AVG.bak-<時間>`（2.5 GB），
   確認 AVG 穩定運作幾天才刪 —— 那時 C: 才會真正釋放。
2. **AVG 更新器可能把目錄重建回 C:**。這正是「設定會被改回去」的同一個問題，
   只是層級換成檔案系統。用 `-Verify` 隨時看 junction 還在不在。
3. **安全模式期間防毒不存在**。搬移那十幾分鐘機器沒有即時防護，請不要在這段時間上網或插隨身碟。

### 實測結果（2026-11-15，安全模式那趟）

| 項目 | 結果 |
|---|---|
| `C:\Program Files\AVG` → `D:\MX500\avg\ProgramFiles` | **成功，junction 撐住了**。D: 上的定義檔 08:02:28 仍被更新 → AVG 確實透過 junction 寫入 |
| `C:\ProgramData\AVG` → `D:\MX500\avg\ProgramData` | **失敗**。搬完驗證通過，但 AVG 在正常開機啟動時**拆掉 junction、重建全新實體目錄**（08:00–08:02） |
| `C:\Users\ufft4\AppData\Local\AVG\Browser\User Data` | **junction 也被 AVG 那次重建拆掉**，改在 C: 重建 |
| AVG Secure Browser | **AVG 自己把它整個移除了**（程式目錄、卸載登錄、排程工作全消失） |

**結論：AVG 只接受 `Program Files\AVG` 是 junction，不接受 `ProgramData` 與 Browser 的 `AppData`。**

兩個操作教訓：

1. **安全模式裡的成功驗證不算數。** 當時服務是停的，驗證通過是真的；
   AVG 一啟動就把 junction 換掉。`-MoveProgramData` 的驗證必須在**正常開機、AVG 跑起來之後**再做一次
   —— 已加 `avg-clean-and-move.ps1 -Verify`（會判斷「被 AVG 接手」並列出備份與孤兒位置）。
2. **`avgSP` 保護的是檔案本身，不是路徑字串。** 事後要刪 `.bak` 副本時：
   - `Remove-Item` → `拒絕存取路徑 'vault.db'`
   - 改名成不含「AVG」的名字 → `Access to the path ... is denied`
   - 也就是說**連 `.bak` 都只能在安全模式刪**。

### 搬完之後的殘留清理（08:29 實測）

| 路徑 | 大小 | 結果 |
|---|---|---|
| `C:\ProgramData\ASUS\AsusIME\log.bak-20261115-061446` | 259.8 MB | ✅ 提權刪除 |
| `C:\ProgramData\AVG.bak-20261115-075503` | 1,057.1 MB | ✅ 提權刪除 |
| `D:\MX500\avg\ProgramData` | 1,056.5 MB | ❌ 拒絕存取 `'vault.db'` |
| `C:\Users\ufft4\AppData\Local\AVG\Browser` | 360.8 MB | ❌ 拒絕存取 `'CrashReports'` |

這裡有一個**判斷錯誤的實例**：一開始把四項的失敗全歸因於 `avgSP` 自我保護，實際上
`ProgramData` 底下那兩項只是**權限**（`BUILTIN\Users` 沒有 `Delete` 權，助手又不是管理員），
一提權就刪掉了。**只有最後兩項才是真的被 `avgSP` 擋。**

→ 通則：`拒絕存取` 有兩個完全不同的原因（ACL vs 驅動攔截），先用「提權重試」把它們分開。

### 還沒搬的部分

| 路徑 | 大小 | 說明 |
|---|---|---|
| `C:\Program Files\Common Files\AVG` | 77.3 MB | `Icarus\avg-av-vps\temp\` 的更新暫存（當日 14.6 MB + 11.3 MB + 3.9 MB）。量小，暫不處理 |
| `C:\ProgramData\AVG` | 4.67 GB | 由 `avg-clean-and-move.ps1 -MoveProgramData` 處理（含常態快取，當日 198 MB） |

---

## 提權腳本一覽與建議執行順序

所有腳本都在這個目錄，都需要使用者自行提權執行（助手不是管理員），
且全部支援 `-DryRun`（不需提權即可預覽）。

| 腳本 | 做什麼 | 需要安全模式 | 可逆 |
|---|---|---|---|
| `disable-autodesk.ps1` | 停 `Autodesk Access Service Host`、啟動類型改 `Disabled` | 否 | 是（`-Revert`） |
| `avg-clean-and-move.ps1 -CleanJunk` | 刪 AVG 垃圾 302 項 / 4,653 MB | 否 | **否**（刪除） |
| `avg-clean-and-move.ps1 -MoveProgramData` | `C:\ProgramData\AVG` → D: + junction | 建議 | 是（`-Revert`） |
| `avg-move-programfiles.ps1` | `C:\Program Files\AVG` → D: + junction | **是**（互鎖） | 是（`-Revert`） |
| `avg-try-stop.ps1` | 診斷「只關服務能不能解鎖」 | 否 | 是（自動復原） |
| `remove-avg-browser.ps1` | 移除 AVG Secure Browser + 清孤兒 junction | 否 | 否（需重裝） |
| `remove-quark.ps1` | 移除夸克网盘 + 清懸空引用 | 否 | 否（需重裝） |
| `move-asus-ime-log.ps1` | 停 ASUS IME 的 ETW 追蹤（`-StopTrace`）或把 log 搬 D: | 否 | 是（`-Revert`） |
| `move-pagefile.ps1` | 主分頁檔搬到 D:（C: 省 22 GB） | 否 | 是（`-Revert`） |
| `safemode.ps1` | 指定／取消「下一次開機進安全模式」（`bcdedit`） | — | 是（`-Exit`） |

### 建議順序

```powershell
# 0) 隨時可做
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\disable-autodesk.ps1'

# 1) 進安全模式，一次做完三件（重開機最麻煩，只做一次）
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-clean-and-move.ps1','-CleanJunk'
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-clean-and-move.ps1','-MoveProgramData'
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Move'

# 2) 正常開機後驗證
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\avg-move-programfiles.ps1','-Verify'

# 3) 移除 AVG Secure Browser（獨立，任何時候）
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\remove-avg-browser.ps1'
```

先清垃圾再搬，是因為 `defs\26111106`（575 MB）會被刪掉，複製量從 2.54 GB 降到約 1.97 GB。

### AVG Secure Browser 為什麼值得移除

它不是「閒置的程式」：排程工作 `AVGBrowserProtectS-1-5-21-...-1001`
（`...\Application\AVGBrowserProtect.exe --runonce`）以使用者身分**每 10 分鐘**執行一次
（實測上次 05:40:40、下次 05:50:50），持續碰觸 profile。當日仍有 12.7 MB 寫入 C:。

它的 User Data 是 junction → `D:\MX500\avg-browser\User Data`（2,049 MB / 9,647 檔），
卸載程式**不會**清它，所以 `remove-avg-browser.ps1` 會處理孤兒 junction。
刪 junction 只能用 `cmd /c rmdir`，**不能加 `/s`**（會跟進刪掉 D: 上的目標）。

profile 裡有 `Default\Bookmarks`（2024-05）與 `Default\Login Data`（2025-12，48 KB 已存密碼）。
要連 profile 一起刪時必須加 `-RemoveProfile`，腳本會**先**把書籤與密碼等小檔案
複製到 `D:\MX500\avg-browser\_backup-<時間>\`（約 0.5 MB）再刪。

---

## 誰在寫 C: —— 名單、處置與三個校正

2026-11-15 的實測結果與處置狀態。分段的物理量（`phys` CSV，dev 0 = C:）：

| 區段 | 分鐘數 | 合計 | 平均 |
|---|---|---|---|
| 00:00–05:13（高峰） | 312 | 16,247.6 MB | **52.08 MB/min** |
| 05:14–05:45（安靜） | 31 | 525.7 MB | 16.96 MB/min |
| 05:46–06:09（含 06:00 突發） | 23 | 922.2 MB | 40.09 MB/min |
| 06:10–06:16（停止 ASUS 追蹤後） | 7 | 119.2 MB | 17.03 MB/min |

### 已指名並處置

| 來源 | 每日寫入 | 佔 C: 空間 | 處置 | 狀態 |
|---|---|---|---|---|
| `AdODIS-installer`（Autodesk Access 更新器） | 1.87 GB | 2.0 GB | 停服務 + `Disabled` | 腳本備妥 |
| `icarus` / `AVGSvc`（AVG 定義與快取） | 1.86 GB | 8.5 GB | 清垃圾 4.65 GB + 兩目錄搬 D: | 腳本備妥（需安全模式） |
| **ASUS IME ETW 追蹤**（躲在 `System` 裡） | **0.9–1.5 GB** | 258 MB | `logman stop`（已執行，寫入 0） | **已生效，但不持久** |
| `taskhostw` → `WebCacheV01.dat` | 0.5 GB | — | 不動（Windows 管理） | — |
| `brave`、Docker、OneDrive、Dropbox | 各 0.1–0.3 GB | — | 不動 | — |
| **夸克网盘（Quark 4.6.5.580）** | 0.002 GB | **3.09 GB** | **已移除** | **完成，C: +3.01 GB** |

### 三個校正（都是實測，不是推論）

**1. 「停止 ASUS 追蹤」省下的量，在分鐘解析度上看不出來。**

停掉之後 06:10–06:16 是 17.03 MB/min，跟停之前的安靜段 16.96 MB/min 幾乎一樣。
原因是 ASUS 只佔 1.49 GB/日 ≈ **1.04 MB/min**，而 C: 的底噪本身就有 17 MB/min。
**省是真的（檔案 60 秒 +0.00 MB），只是被更大的背景量蓋住。**
→ 教訓：用「每分鐘」看小額改善會得到錯誤結論，要拉長區間或直接看目標檔案。

**2. `logman stop` 不持久，`mklink /J` 才是確定性的。**

`logman stop AsusIMEService -ets` 之後 `logman query` 回 `Data Collector Set was not found`、
`.etl` 凍結在 231.88 MB。但服務是追蹤的建立者，**下次服務啟動（含重開機）會重建它（推論，未驗證）**。
重驗：`logman query AsusIMEService -ets`。
要持久只能把目錄 junction 到 D:（寫入換地方，但確定）。

**3. 我自己的掃描不會污染 C: 的寫入量測。**

對照實驗（各 20 秒，掃 7.8 GB / 19,970 檔）：

| | 寫入 | 讀取 | 分頁輸出 |
|---|---|---|---|
| 閒置 | 0.3 MB | 0.0 MB | 0 |
| 掃描後 | 2.1 MB | **455.0 MB** | 0 |

→ 掃描產生大量**讀取**，寫入只多 1.8 MB。所以「分析動作本身」不會偽造寫入尖峰。

### 仍未解釋的：06:00–06:01 的 625 MB 突發

物理量 06:00 = 363.84 MB、06:01 = 261.15 MB，但同期歸因表只有 **6.2 MB**（可信列）。
檢查過、都排除了的候選：

- 我自己的目錄掃描 → 已用對照實驗排除（見校正 3）
- 分頁輸出 → 同時間採樣為 0
- 排程工作 → 05:50–06:05 只有 `QuarkUpdaterTaskUser`（06:02:02），但 `QuarkUpdater` 目錄裡
  沒有對應的大檔（最大 0.27 MB 的 `updater.log`），且 Quark 全天歸因只有 2.2 MB
- `hiberfil.sys` / 快速啟動 → 不存在、`HiberbootEnabled = 0`

也就是說它落在「核心內部寫入」（NTFS 日誌／MFT／mapped page 回寫）這一類，
**原理上不會有行程歸因** —— 與整天 10 GB 殘差同源。

### 校正 4：官方卸載字串可能是壞的，要驗證「結果」不是「結束碼」

夸克网盘的登錄檔寫的卸載指令是：

```
unins000.exe /SILENT --brand-clouddrive /LOG
```

照它跑 → **結束碼 1、程式目錄 2,539 MB 原封不動、登錄項目與 Run 值全都還在**。
改用 Inno Setup 標準參數才成功（結束碼 0）：

```
unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART --brand-clouddrive /LOG=<檔案>
```

而且**成功卸載後仍留下三處懸空引用**（指向已刪除的檔案）：

| 類型 | 內容 |
|---|---|
| `HKCU\...\Run` | `quark`、`QuarkUpdaterTaskUser1.0.0.18` |
| 排程工作 | `\QuarkUpdaterUser\QuarkUpdater\QuarkUpdaterTaskUser...` |
| `HKCU\SOFTWARE\Classes` | `QuarkHTM`、`QuarkUpdaterUpdate.Update3WebUser` |

→ `remove-quark.ps1` 已把「驗證目錄是否真的消失」當成前置條件：
**卸載失敗時不會刪殘留資料**（否則會留下「裝著但沒有快取」的半殘狀態），要覆寫得加 `-Force`。

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
