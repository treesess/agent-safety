# VSS 影子複本會回傳 NULL 區塊（已知缺陷）

> 這份文件記錄一個容易被誤認為「這次事故獨有的怪現象」的 Windows 行為：
> **磁碟區陰影複製（VSS）在讀取時，可能把檔案的整段內容換成 NULL，而且不報任何錯。**
> 檔案大小與原檔完全一致、事件日誌沒有任何 VSS 錯誤、live volume 上的檔案正常。
>
> 2026-11-16 那次資料損失事故裡，救援用的正是 VSS 影子複本。當時的結論是「完整救回」，
> 2026-11-18 的復盤才發現：**檔案清單與大小都對，但有 78 個以上檔案的內容是零。**
> 這份文件是那個發現的外部佐證。

---

## 症狀（可逐項核對）

| 觀察 | 說明 |
|---|---|
| 內容被換成 `0x00` | 整檔全零，或只有部分區段全零 |
| 對齊在 4 KB 叢集邊界 | 零段的起點與長度落在 cluster 邊界上，不是任意位置 |
| 檔案大小不變 | 與原檔位元組數完全一致，所以「比對大小」永遠通過 |
| live volume 正常 | 同樣的檔案在原磁碟上讀出來是好的 |
| 事件日誌沒有 VSS 錯誤 | `vssadmin` 正常、System log 沒有 Volsnap 事件 |
| 與是否已刪除無關 | 檔案還在、或已被刪除／搬移，都可能出現 |
| 與快照新舊無關 | 昨天建的和一個月前建的都可能壞 |
| 與 diff area 容量無關 | 有案例在「上限 9.5 GB、只用了 4.2 GB」時就壞了 |

## 為什麼會這樣（目前的解釋）

VSS 的影子複本是**差分**的：某個區塊自快照之後**沒有被改寫過**，讀取時就直接從 live volume 拿，不進 diff area。所以：

- 自快照以來沒動過的檔案，影子和 live 其實是同一份資料；
- 當這份資料本身在某個環節變成 NULL（或取用路徑上回傳 NULL），那份 NULL 就成為影子的內容；
- 因為沒有「改寫」，也就不會觸發 copy-on-write 把它保留成好的一份。

一位在 63 台機器上做過測試的企業 IT 在同一個討論串裡這樣描述：

> since non-changed files are not being shadowed therefore the shadow copy usually contains only one copy of file, it being the one with null data in it

這也解釋了為什麼**同一個磁碟區的兩份影子會給出完全相同的零**——它們讀的是同一批區塊。

## 外部來源

1. **Microsoft 官方支援文章 KB2748349（2013）— 狀態：已確認的產品問題**
   <https://support.microsoft.com/help/2748349>
   - 症狀：用 VSS 建立快照、再從快照讀檔時，快照裡的檔案是損壞的；而且**只有在還原時才會發現**
   - 原因（原文）：「some regions in the snapshot are not protected when the original volume is changed.
     When the file is read from the snapshot, the file data is not consistent. Therefore, the file data
     becomes corrupted.」
   - 狀態欄：「**Microsoft has confirmed that this is a problem in the Microsoft products** that are
     listed in the 'Applies to' section.」
   - 修正：`volsnap.sys` 更新，已併入 Windows 7 SP1 / Server 2008 R2 SP1
   - **注意**：這是「讀快照會拿到不一致資料」這個**缺陷類別**的官方確認，觸發條件寫的是特定磁碟區大小／擴充模式，
     不是我們看到的 NULL 區塊個案。引用時不要說成「微軟承認了 NULL 區塊這個 bug」。

2. **Microsoft Q&A：Shadow Copy snapshot file contents silently corrupted（2015）**
   <https://learn.microsoft.com/en-au/answers/questions/2672731/shadow-copy-snapshot-file-contents-silently-corrup>
   - 取用方式與本次事故相同：`psexec -s` 提權 → `vssadmin list shadows` → `mklink /d` 到
     `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1` → `robocopy /E`
   - 3 台 Windows 8.1 重現；後續回報 Windows 10 Enterprise LTSB、Windows 10 Pro 1511 也有
   - 提問者回報微軟支援案件 `115060812822144` 被 **closed as confirmed bug**，承諾 hotfix，沒有下文
   - 同頁一位企業 IT 在 Windows 7/8/8.1、14 顆 HDD + 6 顆 SSD、共 **63 台**機器測試，幾乎沒有一台能無損還原
   - 該頁也引用更早的 KB2748349（Windows 7 類似案例）與一個 Super User 問題〈shadow copy recovered files contain lots of null blocks〉

2. **Level1Techs：Volume Shadow Copy returns corrupted files with NULL Bytes（2026-10-31）**
   <https://forum.level1techs.com/t/volume-shadow-copy-returns-corrupted-files-with-null-bytes/259865>
   - Windows 10 22H2 與 **Windows 11 25H2** 都可重現，三台機器
   - ShadowExplorer 與直接走 `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\` 結果相同
   - 描述：「檔案大小與原檔完全一致，內容部分或全部是 NULL」

## 對「靠影子救援」的意義

**影子複本不是備份，是最後手段。** 它可以在「檔案被刪掉、沒有其他副本」時救回結構，但它給你的內容可能已經被靜默替換成零，而且**不會有任何錯誤訊息**。

實務上的三個改變：

1. **不要用「與影子核對一致」當驗收結論**——影子本身可能就是零，比對只證明「複製忠實」。
2. **從影子取回後，逐檔驗內容**：頁級零段掃描、雜湊、Office／zip 用 `testzip()`。
3. **先複製到另一顆磁碟再驗，最後才還原覆蓋。** 直接還原會把 live 上的區塊原位蓋掉，之後想回答「原檔到底壞了沒有」就永遠沒有證據了（261116 就是這樣失去答案的）。

## 怎麼驗一個從影子取回的檔案（可照做）

```powershell
# 1) 頁級零段：整頁 4096 位元組全零的頁數與偏移
python scripts\scan-zero-damage.py "<取回後的目錄>" --exclude recover --exclude "*.damaged-*"

# 2) 有第二份副本就比雜湊，不要靠啟發式
Get-FileHash -Algorithm MD5 "<檔案>" , "<副本>"

# 3) Office / zip 這類容器用 testzip()，它能抓到「中央目錄完好、單一成員毀損」
python -c "import zipfile,sys; print(zipfile.ZipFile(sys.argv[1]).testzip())" "<檔案>.xlsx"
```

判準是「**最大連續零段 ≥ 4 KB**」，不是零位元組比例——mp4、MAT、`.pyc`、UTF-16LE 文字天生就含大量零，用比例會誤判。另外要記得：「小於 4 KB 的檔案不可能出現 4 KB 零段」，所以整檔全零的小檔要用第二層 `suspect` 判準才看得到。

## 還沒被證明的事

這份文件只主張「**存在這樣一個已被重現、且微軟官方確認過相關缺陷類別的資料損壞行為，症狀與 261116 完全吻合**」，不主張 261116 已被證明由它造成：

- KB2748349 描述的觸發條件（磁碟區大小為 8 GB 倍數後又擴充）與 261116 不符，它證明的是「這類缺陷存在且被官方確認」，不是「就是這一個」；
- 外部案例都沒有「先刪除 1.75 GB、再大量寫回」這個脈絡；
- 缺陷的觸發條件（叢集狀態、diff area 內部結構）沒有公開技術說明；
- 要直接證明得建新快照、對同一批檔案重複讀取比對，而原檔已不在。

定位是**最佳解釋**，不是定論。
