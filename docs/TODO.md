# TODO — 現在與接下來

> **這是業主監控進度的地方。任何狀態變動都要即時更新本檔。**
> 完成的項目移到 [`HISTORY.md`](HISTORY.md)；還沒成形的構想放 [`BACKLOG.md`](BACKLOG.md)。
> 最後更新：2026-11-18 18:10

---

## 進行中（In progress）

| 項目 | 為什麼要做 | 下一步 | 卡在哪 |
|---|---|---|---|
| **`disk-report.ps1` 的 `cover` 欄位仍含可疑列** | 儀表板已修，但每小時報告的覆蓋率分子仍含幻影列（Robocopy 之類） | 把 `Get-PathTrust` 那套可信度規則套進報告 | 無阻塞，只是還沒做 |
| **Edge `User Data` 備份觀察期**（第 0 / 3 天） | Edge 已 junction 到 D:（18,663 檔 / 1.89 GB，比對缺 0、大小不同 0、落地測試 是）；C: 上的 `User Data.bak-20261116-013507`（1.89 GB）要確認正常才敢刪 —— **刪除前 C: 的實際釋放是 0** | 每天開一次 Edge 確認書籤／登入正常；必要時跑 `move-edge-ud.ps1 -Verify`（結論要 `OK`）；期滿再刪備份 | 等時間到（比照 AVG 的 3 天，最快 **2026-11-19**） |

---

## 已排程（Scheduled）

| 項目 | 內容 | 需要什麼 |
|---|---|---|
| **刪 AVG 備份 1,967.6 MB** | `C:\Program Files\AVG.bak-20261115-075637`。**觀察期滿且五項全過**（2026-11-18 18:05 手動驗證：junction 正確、服務 Running、定義 26111704 於 0.6 天前更新、定義寫在 D:、安全性中心路徑在 D:；已過 3.4 天） | **安全模式**（`avgSP` 會擋），一行 `Remove-Item` |
| 刪 AVG 殘留 1,417 MB | `D:\MX500\avg\ProgramData`（1,056.8 MB）＋ `AppData\Local\AVG\Browser`（360.8 MB）。已提權試過，兩項都被 `avgSP` 拒絕存取 | **安全模式**，一行 `Remove-Item` |

> 兩件可以排在同一次安全模式開機做，省一次重開機。
> `check-avg-migration.ps1` 已不在專案內（一次性工具已移除）；要再驗證就用上面那五項手動查。

---

## 候選任務（Candidate，尚未承諾）

| 項目 | 預估收益 | 風險／成本 | 需要誰決定 |
|---|---|---|---|
| **使用者層快取搬 D:**（uv 8.0 GB、NuGet 4.0 GB、pip 1.0 GB、npm 0.13 GB） | C: 約 +13 GB | 只改使用者環境變數（`UV_CACHE_DIR`、`NUGET_PACKAGES`、`PIP_CACHE_DIR`），**不需提權、不需重開機** | 業主（涉及環境變數） |
| **分頁檔搬到 D:** | C: +22 GB、分頁移到 NVMe | 改 `PagingFiles` 登錄值 + 重開機 | **業主已明確表示擱置** |
| **修復 WinRE** | 恢復「進階啟動／重設此電腦／自動修復」 | `reagentc /enable`，會動復原分割 | 業主（本機 WinRE 映像缺失，屬獨立風險） |
| **Chrome 6 個高風險擴充審查** | 降低隱私風險 | 需逐一確認用途 | 業主（`browse` 最可疑：11/14 安裝、有 `debugger` + `tabCapture` + `<all_urls>`） |
| **`EXPERIENCE.md` 第 24 條的剩餘疑問** | 文件正確性 | 需多版本實測 | 隨緣 |

---

## 已完成（僅摘要；細節見 HISTORY）

- 磁碟歸因工具鏈（`clean-attrib.ps1`）＋ 儀表板三個量測 bug 修正
- Autodesk 更新器關閉（1.87 GB/日 → 0）
- AVG 垃圾清理 3,600 MB、`Program Files\AVG` 搬到 D:（生效中）
- 夸克网盘移除（C: +3.01 GB）
- ASUS IME 的 ETW 追蹤停止 + 日誌搬 D:
- **C: 可用空間 124.30 GB → 132.46 GB（+8.16 GB）**
- **AVG 托盤圖示／UI 卡住** —— CPU 迴圈已修好：不是 AVG 的問題，是工作列圖示快取 `TrayNotify`
  膨脹（`PastIconsStream` 929,606 bytes），explorer 對每個圖示反覆重算簽章。
  用 `reset-traynotify.ps1` 重置後 **41–43% → 1–3%**（快取重建為 47,392 bytes），已 `-Verify` = OK。
  **托盤圖示已確認恢復**（業主目視：右下角看得到 AVG 圖示）。
