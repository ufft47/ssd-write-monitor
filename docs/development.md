# development.md — 開發紀錄

> 不是進度（那是 `TODO.md`），也不是歷史（那是 `HISTORY.md`），而是**做這件事時學到什麼**。
> 這裡的內容應該讓下一個人少走一趟冤枉路。
> 最後更新：2026-11-15 10:05

---

## 1. 這個專案的量測現實（先讀這段，再改任何數字）

### 1.1 兩層資料，不要混用

| 層 | 來源 | 意義 | 可信度 |
|---|---|---|---|
| 物理層 | `PhysicalDisk` 效能計數器（累計值） | 真正寫到裝置的位元組 | 總量可信 |
| 邏輯層 | ETW Kernel-File（pid × FileObject） | 「哪個程式寫了哪個檔案」 | 單筆可能誤歸因 |

對帳只能用**長區間總量**。單一分鐘會失真：`phys` 取樣在每分鐘 `:29`–`:32`，ETW 分鐘是 `:00–:59`。

### 1.2 三個「會把數字變成垃圾」的陷阱（今天全部踩過）

**① 累計值會歸零，排序不能用 `perf`**

`phys` CSV 的 `write_bytes` 是累計值，`ts_perf` 是「開機後經過的 100ns」，**每次重開機歸零**。
按 `perf` 排序會把不同開機期串在一起，跨期的位元組差看起來像巨量寫入。

> 症狀：C: 今日落盤 333 GB（實際 22 GB）、07:00 與 08:00 各一根 310 GB 的假柱。
> 修法：一律按 `ts` 排序，並跳過「位元組倒退」的配對。

**② 裝置編號會在重開機後對調**

實測：`dev 2` 從 `I: F:` 變成 `D:`、`dev 3` 從 `D:` 變成 `I: F:`。
用裝置編號查某個磁碟區，會把兩個不同的實體碟加在一起。

> 症狀：D: 今日落盤 122.9 GB（實際約 85 GB，其中一部分還是別的碟）。
> 修法：用**磁碟區標籤**查，並在「同標籤但裝置編號變了」處斷開基線。

**③ 歸因列有幻影，要用路徑可信度過濾**

三種列會憑空生出巨量寫入：

| 路徑型態 | 問題 | 實例 |
|---|---|---|
| `X:\Device\HarddiskVolumeN\...` | 磁碟區相對路徑被冠上磁碟機代號 | Robocopy 寫 F: 被記成 `C:\Device\...` |
| 是**目錄** | 目錄不是寫入目標 | `%USERPROFILE%\.claude\ide`（9,470 MB） |
| **不存在**且不在暫存區 | ETW 幻影 | `endpoints.json`（7,576 MB）、`ApplicationInsightsDiagnostics.json`（4,621 MB） |

> 症狀：排行榜第一名是 Robocopy 59.35 GB、具名覆蓋率 7,765%。
> 修法：同一套規則（`clean-attrib.ps1` / 儀表板的 `Get-PathTrust`）：
> 目錄＝可疑；不存在且不在 `Temp`/`Cache`/`Sessions`/`.tmp`/`.log` 下＝可疑；
> 路徑不明（`(其他)`）＝磁碟區也是猜的，不算給任何碟。

### 1.3 覆蓋率低是常態，不是壞掉

ETW 只看得到「有檔名的寫入」。其餘是：

- 未緩衝 I/O（Robocopy `/J`、資料庫）
- 核心內部寫入：登錄檔 hive、NTFS 日誌／MFT、mapped page 回寫

後者**原理上沒有行程可歸因**。實測安靜時段覆蓋率 11–14%，一整天約 33%。
儀表板現在會直接寫明這件事，避免被誤認為監控壞了。

---

## 2. 量測方法論：先確認「你在數什麼」

今天犯了兩次同一類錯誤，都值得記住。

### 2.1 `attrib` CSV 的 `minute` 是**完整時間戳**

```
2026-11-15 05:45,26616,pwsh,C:,C:\...,74557,14777
```

用 `'05:14'` 去比字串，`'2026-...' < '05:14'` 永遠為假 → **篩選等於沒做，算出來是全天數字**。
我因此把「05:14 之後 taskhostw 寫了 24.5 MB」報成 254.7 MB（那是全天）。

**對帳規則**：臨時分析的結果必須跟 `clean-attrib.ps1` 比對，
差異只應該來自「診斷探針列」與「暫存路徑分類」。兩者差太多就是自己算錯。

### 2.2 「拒絕存取」有兩個完全不同的原因

刪 AVG 殘留時，我把四項失敗全歸因於自我保護（`avgSP`）。
實際上：

| 原因 | 判別方式 | 例子 |
|---|---|---|
| **ACL 權限** | 提權後就成功 | `C:\ProgramData\AVG.bak-*`（`BUILTIN\Users` 沒有 Delete 權） |
| **驅動攔截** | 提權後仍被拒，連改名也拒絕 | `AppData\Local\AVG\Browser`（自己的目錄也刪不掉） |

**先用「提權重試」把兩者分開**，再決定要不要進安全模式。

### 2.3 錯誤訊息描述的層級 ≠ 故障的層級

- 刪目錄失敗 → 報 `拒絕存取路徑 'api-ms-win-core-console-l1-1-0.dll'`
  → 看起來像 DLL 問題，實際是**整個目錄被自我保護**。
- 刪目錄失敗 → 報 `拒絕存取路徑 'vault.db'`
  → 看起來像單檔問題，實際是**父目錄 ACL**。
- WSL 拒絕被壓縮的 `ext4.vhdx` → 報「檔名語法不正確」（那是另一件舊事，同一個通則）。

### 2.4 驗證要驗「結果」，而且要**在對的時機驗**

`ProgramData\AVG` 的 junction 在安全模式建好、落地測試也通過。
**AVG 一啟動就把它拆了**，重建實體目錄並改寫 C:。

> 教訓：安全模式裡的「成功」不算數，因為服務是停的。
> 現在 `avg-clean-and-move.ps1 -Verify` 要在**正常開機、AVG 跑起來之後**再驗一次。

### 2.5 早退分支只印「無需處理」＝把驗證丟回給人

`move-asus-ime-log.ps1` 遇到「已經是 junction」時只印一句「無需搬移」就結束。
我因此誤判「重開機後 ASUS 又開始寫 C:」——實際上寫入一直都在 D:。

> 修法：早退前要驗證並印出**證據**（目標路徑、15 秒成長量、C:/D: 是否同一個檔案）。

---

## 3. AVG / ASUS 的實測事實（避免重查）

### 3.1 AVG 的自我保護

| 事實 | 證據 |
|---|---|
| `avgSP.sys` 是自我保護驅動，`StartMode=System` | `Win32_SystemDriver` |
| 另外 15 個 AVG 驅動同時執行 | 名單在 README |
| **安全模式下全部不載入** | `SafeBoot\Minimal`（85 項）與 `Network`（143 項）都沒有真正的 AVG 服務名（只有一個對不上的 `avgSP.sys` 殘留項） |
| 但 `avgArDisk`（StartMode=Boot）**仍會被核心載入** | 07:35 安全模式實測 |
| 它沒有握住 AVG 的檔案 | 獨佔開檔測試回「沒被鎖」，改名探針成功 |
| 保護認的是**檔案本身**，不是路徑字串 | 把 `.bak` 改名成 `_del_...` 也 `Access denied` |
| 會**拆掉** `ProgramData\AVG` 與 `AppData\Local\AVG\Browser` 的 junction | 08:00–08:02 重建，D: 副本從此無人引用 |
| **不會拆** `Program Files\AVG` 的 junction | 08:02:28 定義檔仍寫到 D: |

### 3.2 ASUS 輸入法的 ETW 追蹤

| 事實 | 證據 |
|---|---|
| `AsusIMEService` 是**執行中的 ETW 追蹤工作階段**（不是 autologger，Autologger 鍵 0 筆） | `logman query -ets` |
| 寫 `C:\ProgramData\ASUS\AsusIME\log\asus_ime_service.etl` | 檔案成長 |
| 速率 0.9–1.5 GB/日（隨輸入量變動） | 120 秒精量 63.7 MB/h；當日累積回推 0.89 GB/日；30 秒粗採 97 MB/h |
| 在歸因表裡落在 `System`（當日只記到 49.6 MB） | ETW 由核心寫入，不經過應用程式手柄 |
| 停掉之後**輸入法功能不受影響** | 業主實測打字正常 |
| 但**不持久**：重開機後服務重建追蹤 | 08:19 `.etl` 又開始長 |
| 目錄可以 junction 到 D:，不需安全模式 | ASUS 沒有自我保護 |

### 3.3 卸載器的坑（夸克网盘）

官方登錄的 `UninstallString` 是 `unins000.exe /SILENT --brand-clouddrive /LOG`。
照它跑 → **結束碼 1、完全沒卸載**（程式目錄 2,539 MB 原封不動）。
改用 Inno Setup 標準參數 `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` 才成功。

而且**成功卸載後仍留下 5 處懸空引用**（Run 值 ×2、排程工作 ×1、`HKCU\Classes` ×2）。

---

## 4. 工具與環境

### 4.1 這台機器的特殊之處

| 項目 | 狀態 | 影響 |
|---|---|---|
| C: 所在碟 | Disk 0，**MBR**，`IsBoot/IsSystem = True` | 真正的 BCD 在 `C:\Boot\BCD` |
| 磁碟 3 上的 100 MB ESP | **殘留**，不參與開機 | 別被它誤導 |
| **WinRE 映像缺失** | `Winre.wim` 兩個位置都沒有 | 「進階啟動」選單永遠不會出現 → 只能用 `msconfig` 或 `bcdedit` |
| `bcdedit` 拒絕 `{current}` / `{default}` | `/enum {current}` 回「命令列選項無效」，但 `{bootmgr}` 正常 | 要用 `/enum ACTIVE` 讀真實 GUID |
| 瀏覽器 profile | Brave / Chrome 在 D:（junction） | AVG Browser 的已被 AVG 拆掉 |
| 分頁檔 | C: 固定 24,576 MB | 搬 D: 可省 22 GB（業主擱置） |

### 4.2 腳本撰寫守則（本專案強制）

1. **含中文的 `.ps1` 一律 UTF-8 **有 BOM**。** 沒 BOM 時 PS 5.1 用 CP950 解讀，行尾中文可能吃掉換行
   （實際踩到：`param()` 被併進註解，參數全變 `$null`）。
2. **`Get-ChildItem -LiteralPath` 搭配 `-Include` 在 PS 5.1 會被靜默忽略**
   → 用 `-Path (Join-Path $dir '*') -Include`，或改用 `Where-Object`。
3. **寫日誌失敗不可以中斷主流程**：`Add-Content` 包 try/catch
   （安全模式下曾出現「資料流是不可讀取的」非終止錯誤）。
4. **刪 junction 只用 `cmd /c rmdir`，不加 `/s`**（會跟進刪掉目標資料）。
5. **複製目錄一律 `robocopy /E`，不用 `/MOVE`**；驗證 missing / size-diff 皆為 0 才動來源。
6. **能用改名就不要用搬移**（改名是瞬間且可逆）。
7. **每個提權腳本都要有 `-DryRun` 與 `-Revert`**，並在 DryRun 裡印出「會做什麼」。
8. **刪除前先掃 `ReparsePoint`**，避免 `Remove-Item -Recurse` 跟進別人的目標。

### 4.3 驗證指令速查

```powershell
# 監控是否活著
Get-Content D:\dev\disk-monitor\data\state\collector.json -Raw | ConvertFrom-Json
Get-ScheduledTask DiskMonitor,CWatchCollector,CWatchTray | Get-ScheduledTaskInfo

# 歸因對帳（扣掉可疑列）
powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\clean-attrib.ps1 -Top 12

# AVG 搬移是否還健康
powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\check-avg-migration.ps1

# 儀表板（單次輸出、不啟服務）
powershell -ExecutionPolicy Bypass -File D:\dev\disk-monitor\src\dashboard\cwatch-dashboard.ps1 `
  -Root D:\dev\disk-monitor -Once -OutFile D:\TEMP\dash.html
```

---

## 5. 待補的文件債

- `disk-report.ps1` 的 `cover` 欄位仍含可疑列（與儀表板算法不一致）。
- `README.md` 的「三個校正」寫的是儀表板修正前的觀察，部分數字已被後續修正取代，
  需要在下次改動時一併對齊。
- `check-scripts.ps1` 的覆蓋範圍不足（BOM / 語法 / DryRun 冒煙）。
