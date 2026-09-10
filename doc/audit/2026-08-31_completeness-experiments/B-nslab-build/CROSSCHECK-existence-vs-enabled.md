# 交叉檢查：PREREG-B 有沒有把「存在」讀成「啟用」

**觸發**＝auditor 08-31：E 輪的腳本 agent 推翻了他 prereg 的一條前提——
`NDTWIN_SFLOW_BATCH` **從來沒被設過**（`main.py:82` 預設關閉、全 repo 無設定處、
KNOWN-ISSUES E-2 早有記載）⇒ **碼進了版控 ≠ 那條路徑在跑**。
他要我對已凍結的 PREREG-B 做同族掃描。
🔴 **本檔只回報，不修改凍結後的 prereg**（處置由 auditor 裁）。

## 🔴 F1（最嚴重）：四顆 build 裝好了 ≠ 四臂真的各跑一顆

PREREG-B §2 定義四臂＝四條 configure 行，§2 要求「每臂記 sha256＋symbol signature＋
`ldd`＋RUNPATH」。**但整份註冊沒有任何一句說明：fabric 要怎麼被指到某一臂的 binary。**

在機器 1 上，這件事有專門的機制——`p4_proxy/mininet/bmv2_binary_override`，
其第一行非註解行是**要啟動的 `simple_switch_grpc` 絕對路徑**。該檔與
`p4_testbed_topo.py:39` 的註解逐字寫著這個坑**已經發生過一次**：

> It used to be `"simple_switch_grpc"` — a bare name, **PATH lookup, which resolves to the
> stock** [build]

⇒ **若 VM 的 fabric 沿用 PATH 查找（或用另一支沒有 override 的拓樸腳本），八臂會全部跑
同一顆 binary，而實驗會量到「四種 build 沒有差別」——一個乾淨、可複製、完全錯誤的結果。**
🔑 **而所有身分紀錄仍會看起來正確**，因為我們記的是**編出來那顆**的 sha256，
不是**跑起來那顆**的。這正是 08-30「patch 打到另一個 repo 的同名檔案」的同族
（[[benchmark-must-name-the-binary-it-measured]] 第三擊）。

**缺的兩句**：①arm 選擇機制要指名（VM 上是哪一支拓樸腳本、它從哪裡讀 binary 路徑）；
②切換後要有**斷言**（換了臂之後，跑起來的真的是這一臂）。

## 🔴 F2：身分紀錄沒有指定「從跑著的行程取」

§2 只寫「每臂記 sha256」，未寫**取自何處**。取自 `$OUT/<arm>/…`（編譯產物）
與取自 `/proc/<執行中 pid>/exe` 是**兩個不同的事實**，而只有後者能否證 F1。
（C4 的 prereg 已經有括號式 `/proc/<pid>/exe` 首尾對帳——**B 反而沒有**，
兩張同一天寫的註冊在這點上不一致。）

## 🟡 F3：「控制面活著」是存在陳述，不是功能陳述

§3「拓樸＝單跳、**控制面活著**（與 study ① 同構）」——未定義如何斷言「活著」。
若只驗行程存在，這就是 [[existence-is-not-wiring]]（EventBus 零 production subscriber）
與 [[committed-setter-uncommitted-reader]] 的同族。**建議的斷言**：換臂後至少一條規則
被實際編程（南向直讀可見），而不是「proxy 行程在」。

## ✅ 掃過但**不成立**的三處（記下來，免得下次重掃）

1. **四條 configure 行本身**＝編譯期，`--disable-logging-macros`／`--disable-elogger`／
   `-march=native` 都會改變產出的碼，且 §2 的 symbol signature 正是為此設計 ⇒ 無存在／啟用落差。
2. **logging 在執行期有沒有開**：stock 臂的成本主張是「巨集在熱點做 null-sink 格式化」，
   **不依賴執行期有沒有 log sink** ⇒ 不是 enablement 前提。（且本輪量的是差值，不是機制。）
3. **宿主負載閘**：實作風險（取樣有沒有真的跑），不是前提誤讀；且已有「不一致即停」條款。

## 我的建議（**裁決權在 auditor**）

F1＋F2 我讀成**同一個缺口的兩半**，且是**資料接觸前**（八臂零開始）。
若判為「資料接觸前的收緊更正」：加兩句——arm 選擇機制指名＋每臂自
`/proc/<pid>/exe` 取 sha256 並與編譯產物比對，不符即停輪。
若判為「必須解凍重來」：我照辦，**不預設走比較省事的那條**。
F3 我建議一併收緊（成本一行、風險不對稱）。

[Co-developed with claude code -- Adam]

## 🆕 由本次發現升成規矩（auditor 08-31 裁）

> **同一批寫出來的多張預註冊，儀器節要彼此對 diff。**

理由：這種漏法**在單張檔案內看不出來**。PREREG-B 自己讀起來完整無缺——臂、梯階、判定
規則、binary 身分四項齊備；**只有跟同一天寫的 PREREG-C4 並排，才顯出 C4 有括號式
`/proc/<pid>/exe` 首尾對帳而 B 沒有**。單張自審永遠抓不到「我在另一張想到、這一張忘了」。

⇒ 這是 [[verify-against-known-good-output]] 的預註冊版：**已知正確的輸出，是同一批的另一張**。
（auditor 同時把它套在自己身上：E 輪那張要去比對 F-5 那張的儀器節。）
