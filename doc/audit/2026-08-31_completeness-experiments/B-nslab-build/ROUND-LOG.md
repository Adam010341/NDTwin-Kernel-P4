# B 輪・遠端動作紀錄（本輪自己的帳；不是機器的使用規則）

🔑 **範圍界定**：nslab 的**使用規定與佔用表**正本歸「遠端機器測試」那條線
（Adam 08-31：規定尚未成型、由該線撰寫）。**本檔只記本輪自己做了什麼**——
避免兩條線各寫一份同機器規則而產生兩個真實來源。

## 狀態

🔴 **2026-08-31 Adam「等等，先不要用遠端機器」＝暫緩（非停用）。**
解封＝使用規定落地＋Adam 開口。PREREG-B **v1.0 凍結不受影響**（凍結是紙上的事實）。

## 本輪在 nslab 上實際做過的事（時序；host 時區）

| 時間 | 動作 | 結果 |
|---|---|---|
| ~13:5x | 只讀探測（規格／kvm 群組／VM 狀態） | 28 核 31 G、841 G 可用；guest 16 vCPU、106 G 可用 |
| ~13:59 | `ndtwin-vm.sh stop`→`snap`→`start` | 🔴 資源無聲變 12/8192，**已以顯式參數復原 16/16384**；建了**同名快照** `fresh`(ID2)，另建 `p4-bootstrapped-nodocker`(ID3)。全文＝PREREG-B §4a |
| ~14:2x | guest 內 `apt install docker.io`＋啟用 daemon＋使用者入 docker 群組 | **docker 仍在**（C4 用） |
| ~14:5x | guest 內 clone p4benchmark（`~/c4`）；clone behavioral-model 並 checkout `f0b7d201`（`~/b-round/bmv2-src`） | tree sha `f0b7d201570d088a056b7fe660802ca1a8bcb912` |
| ~15:0x | **sender-gate 校準**（netns+veth、3×10 s iperf3 UDP） | ✅ **G = 8331.3 Mbit/s**，見 `GATE-RESULT.md` |
| ~15:0x | 啟動四顆並行 bmv2 編譯 | 🔴 **因 Adam 暫緩令中途 KILL**（session group 2775，TERM→KILL，驗到 `remaining=0`） |

**八臂一步都沒開始 ⇒ 本輪零量測資料，無髒資料問題。**

## 留在那台上的東西（未清除；依裁示「不為了收乾淨再動那台」）

`~/b-round/`：`sgc.sh`、`b4.sh`、`gate/`（3×JSON＋meta＋ping）、`bmv2-src`（f0b7d201）、
四份 `tree_*`（**部分編譯**）、`builds/`（部分 log、`tree.txt`、`march_native.txt`）；
`~/c4/p4benchmark`；**guest 內 docker 已裝並啟用**；三個快照；VM 以 16 vCPU/16384 執行中。
⚠️ **未查證**：校準腳本結尾的 netns/veth 清除行是否確實執行（校準本身跑完了，
清除行在輸出之後）；磁碟用量未量。

## 重疊事件（外部）

~15:0x–約 15:5x，手冊線（Adam 直接授權）向 `/home/nslab` 傳 2.6 GB `.ova`（~1 MB/s）。
**與我的四核滿載編譯時間重疊。** ⇒ 即使解封，**B 的第一臂必須排在該傳輸結束之後**：
那筆傳輸正是 PREREG-B v0.5 宿主負載閘要抓的東西，**一個正確運作的閘門會把這段期間的臂
全部判成 suspect**——而它是被**外部事件**觸發，不是被我們的實驗觸發，正好證明那道閘
不能只靠自律。

## 解封後的第一步

1. 確認外部傳輸已結束、宿主 idle。
2. 自 `p4-bootstrapped-nodocker` 還原（洗掉 docker）。
3. VM 以**顯式** `VM_CPUS=16 VM_MEM=16384` 起。
4. 四顆 build 重編（`b4.sh`；被 KILL 的部分編譯樹先刪）。
5. 八臂（PREREG-B §2 交錯序）。G 已有、校準不必重跑，**除非 VM 或 host 組態改變**。

[Co-developed with claude code -- Adam]
