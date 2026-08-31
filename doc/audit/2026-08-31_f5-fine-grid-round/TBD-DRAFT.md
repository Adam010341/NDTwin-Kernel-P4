# F-5 輪 TBD 草案＋預註冊缺陷清單（**草案，未蓋章**）

[Co-developed with claude code -- Adam]

**狀態**：**草案**。作者＝腳本作者，**不自蓋章**（設計者不自審，利益迴避照舊）。交 auditor 送複驗。
**時點**：2026-08-31，**接觸任何量測資料之前**（`raw/` 只有偵測器的合成 force test 產物，
無任何 fabric 讀數）。照 `prereg-amendment-before-data` 三條件逐條寫明
**改了什麼／為什麼／誰在什麼時候**。

---

## 第一部分：預註冊的缺陷

### 🔴 F-D1. §3 的負載寫「chaos `traffic.sh` 模式」，但**那支只跑一對寫死的 PID**

- `doc/audit/2026-08-28_chaos-harness/harness/traffic.sh:22-23` 把 `H1_PID`／`H2_PID`
  **寫死**（`3434673`／`3434675`），任何一次 fabric 重啟後就過期；它是 h2→h1 的**單一對**。
- §3 同時要求「背景 mesh＋30 s 一條新 pair churn」——那是它的後繼
  `doc/audit/2026-08-30_live-traffic-round/harness/traffic_mesh.sh` 才有的能力
  （其檔頭列出原版**沒有**做到的三件事：≥8 條跨交換機 pair、每 ~30 s 一條沒用過的新 pair、
  offered rate 從 namespace 內的 netdev counter 讀）。
- 🔑 更關鍵的先例，就寫在那支的註解裡：`traffic_mesh.sh:63-70` 記著第一版的 `grep -qx`
  **永遠自我匹配**，於是**靜靜地跑了零流量**，讓一支 600 s 的取樣器錄了一整段閒置 fabric。
  照 §3 的字面用 `traffic.sh`，本輪會拿到「一對流量」而不是「mesh＋churn」，
  而且那個差別在讀數上長得像「負載下也沒事」。
- **建議修法**：§3 的負載改指名 `traffic_mesh.sh`，並註明 offered rate 走 datapath counter。
  🔒 腳本已用 `traffic_mesh.sh` 並在缺檔時中止。

### 🔴 F-D2. pre-T-11 binary 只能靠**符號**認，不能靠檔名

- §4 說兩顆 binary 各記身分，Q2 指名 `a40e04ce`。但
  `.test_run/binaries/ndtwin_kernel.a40e04ce.provenance` 自己寫著
  `commit=UNKNOWN`、`dirty_worktree=UNKNOWN`，而且明文警告 **mtime 是反的**
  （該 binary 比描述它的 commit 早 26 秒）。
- **建議**：把「pre/post-T-11」的判準寫成**符號**：`91e7743`（T-11-A）引入
  `setProgrammedPredicate`，對**執行中行程的** `/proc/<pid>/exe` 取 `nm -C | grep -c`，
  post 必須 >0、pre 必須 =0。檔名只是標籤。
  🔒 已實作為 `run_f5.sh:assert_arm_binary`，且是對**執行中**的 exe 而非磁碟檔。
- **這個選擇會讓哪一種結論失效**：靠檔名的話，一次裝錯就會把 Q1 量在 pre-T-11 上
  （報成「修復回歸」）或把 Q2 量在 post-T-11 上（報成「舊世界本來就沒事」）。
  兩個方向都會產生一個**看起來完全正常**的結果。

### 🟡 F-D3. 【TBD-3】的節奏與 §3 凍結的 60 個位址**可能對不上**

- §3 凍結「N＝60 次 install、序列先凍、交錯 dst、**不重複**」。Q3 是「交錯緊打」，
  若其操作數超過 60，就得重用位址——而**重用的 dst 會讓第二次 install 變成 modify**，
  modify 不產生本輪要找的那一列快取行 ⇒ 該臂會因為一個與 T-11 無關的理由讀出「比較少幽靈」。
- **建議**：TBD-3 除了節奏，**同時要凍 Q3 自己的位址預算**（另一段不重疊的區間），
  或把 Q3 的操作數壓在 60 以內。
  🔒 `f5_sampler.py` 已對重複位址直接拒絕，所以這件事不會靜靜發生——但它會**中止 Q3**，
  所以要先裁。

### 🟡 F-D4. 150 ms 偏斜上限的可達性綁在「4-host 工作點」上

記憶裡已有一次「兩個要求互斥」的先例（128 host 取樣 735 ms 對上需要 ≤500 ms 的要求，
最後是換工作點而不是加取樣）。本輪已在 4-host，方向是對的；但這個上限的成立與否
**是一個要被量的東西**，不是假設。🔒 sampler 逐點記 `kernel_dur_s`／`southbound_dur_s`，
第一臂跑完就能回答「150 ms 是不是可達的」。若不可達，照 §2 是**標不可判定、不丟棄**，
而不是放寬上限。

---

## 第二部分：三處 TBD 的草案

### 【TBD-1】install 序列逐字（dst 清單）

- **建議值**：`f5_dst_sequence.py`（已交付）。60 個位址取自 **10.0.0.180–10.0.0.239**，
  以 **stride 7** 走訪（7 與 60 互質 ⇒ 每個恰好一次），dpid 固定 1。
  前六個＝`10.0.0.180, .187, .194, .201, .208, .215`，末筆＝`.233`。
  `--print` 是純函數輸出（無 RNG、無時鐘），**每次都一樣**，那 60 行就是註冊正本。
- **為什麼這個區間**：兩臂的 fabric 都是 4-host（10.0.0.1–4），連 128-host 拓樸也只到 .128。
  ⇒ 這 60 個位址**不對應任何真實 host**，規則裝上去不會跟本輪刻意跑的 mesh 流量搶路徑，
  而「有沒有被快取、看不看得見」不需要對端存在。
- **為什麼 stride 而不是連號**：§3 的字是「交錯」。連續兩次 install 相距 7，
  任何依賴位址鄰近性的效應（LPM 鄰域、表區段、快取行）會被攤開而不是與 run 的開頭對齊；
  也保證第一筆與最後一筆不是鄰居，於是整臂的漂移不會偽裝成位址效應。
- **不重複是被斷言的**：生成器與 sampler 各檢查一次。
- **這個選擇會讓哪一種結論失效**：若改用連號，`R2` 的窗分布若出現趨勢，就**無法分辨**
  那是時間漂移還是位址鄰近性——兩者在連號設計下完全共線。
- 🔒 **序列先落盤再讀回**：`run_f5.sh:freeze_sequence` 在第一次 install 前把 60 行寫進
  `raw/<arm>/dst_sequence.txt` 並記 sha256，之後 sampler 從**那個檔**讀。
  跑過的序列因此是一份**存檔**，不是「生成器當時應該會產生什麼」的宣稱。

### 【TBD-2】sampler 實作

- **建議值**：`f5_sampler.py`（已交付）。要點：
  1. **t=0 ≡ POST 回應返回的時刻**；POST 自身耗時 `post.duration_s` **逐次另記，不併入 t**。
     每個格點另記 `t_actual`（實際落點），所以排程誤差是資料不是假設。
  2. **雙儀器、順序每點交替**（`kernel-first`／`southbound-first`，parity 走
     `(install_index + grid_index)`，所以同一格點在不同 install 之間也會交替——
     否則所有 t=0 的讀數會共用同一個順序）。
  3. **偏斜＝兩次讀取「中點」之差**（讀取有耗時，它的時刻不是它的起點）；
     `> SKEW_LIMIT_MS` 標 `indeterminate=true` 並**保留**。
  4. **幽靈的判準是三個條件同時成立**：視圖有、**同刻**南向沒有、且帶結構指紋
     （`classify()` 自 TR-3 harness **import**，不重寫）。
  5. **結構指紋只記不濾**——T-11-A 的 commit message 自己說修法刻意不以指紋為 key，
     「keying the fix on it would make the filter the same shape as the thing it measures」；
     同一個理由對儀器也成立。
  6. **南向從未拿到規則的 install 記 `BLIND`，不進分母**，也**不算「沒有幽靈」**。
  7. sampler 自身 CPU 逐 install 記錄（登記共變量）。
  8. **零命中只印一種句子**：「N 次 install 零命中，95% 上界 ≤X%」，
     並明文列出**不得寫**的三句。
- **為什麼要 import 而不是重寫**：`entries_of()` 的第一版回傳頂層的十個 wrapper，於是
  「0 phantom / 10 entries」——而 0 phantom **正是健康系統的樣子**，
  只有控制組那句「而且 real 也是 0」才讓它現形。重寫等於把那個更正分叉掉。
- **偵測器自己的雙向 force（已真跑，非 dry-run 宣稱）**：
  `--dry-scenario` 換掉傳輸層，三個情境全部照預期出來——
  `phantom`→ 2/2 HIT；`clean`→ 0 HIT、8 NO-HIT 並印出上界句；
  `blind`→ 2 CONTROL-FAILED（**不是**「零幽靈」）。
  🔑 一個只在活 fabric 上跑過、而那次 fabric 剛好乾淨的偵測器，**從未被證明它會叫**。
- **這個選擇會讓哪一種結論失效**：若把 `BLIND` 併進「沒有幽靈」的分母，
  §3-零 的上界就是**偏低**的——分母混進了沒有鑑別力的試驗，
  而那正是 08-18「30 分鐘 0 次自然發作」誤導兩週的同一個形狀。

### 【TBD-3】Q3 交錯操作的精確節奏

- **建議值**：`Q3_BURST=10`、`Q3_GAP_MS=0`、`Q3_ROUNDS=6`（＝60 次操作，**剛好用完凍結的
  60 個位址**，見 F-D3），格點壓成 `0 0.05 0.1 0.25 0.5` s。
  上界以「每百次交錯操作的命中數」報（§3 R4）。
- **為什麼 gap=0**：Q3 問的是**刻意觸發的上界**。窗約 2–3 s，任何非零 gap 都只是把
  上界往下拉，而「意外的案例會低估故意的案例」那一課的正面執行要求**打到最緊**。
- **為什麼 6 輪 ×10 而不是 10×10**：位址預算。100 次操作需要 100 個不重複位址，
  而 §3 凍了 60；重用會把 install 變成 modify（F-D3）。
  **要 100 次就必須先註冊第二段位址區間**——那是修訂，要複驗者裁。
- **為什麼格點要壓縮**：Q3 打的是緊耦合的 install/list 交錯，12 s 的尾巴對「刻意觸發」
  沒有資訊，卻讓每次操作多花十幾秒。壓縮**只縮短觀察窗**，不改判準。
- **這個選擇會讓哪一種結論失效**：若不凍位址預算就跑 100 次，Q3 的上界會是
  **對一半是 modify 的操作序列**算出來的 ⇒ 那個數字不能叫「install 的幽靈上界」，
  §3 R4 的「每百次交錯操作」也就沒有一個叫得出名字的母體。
- 🔒 腳本已把這條卡死：`run_f5.sh q3` 在 `Q3_CADENCE_RULED` 未設時**拒絕執行**，
  理由是「在看到 fabric 之後才選節奏＝事後選工作點」。

---

## 第三部分：交付的腳本與驗收方式（未跑任何量測）

| 檔案 | 作用 | 驗收（已做） |
|---|---|---|
| `round.env` | 臂／端點／凍結值；未凍結值集中並標 TBD | — |
| `f5_dst_sequence.py` | 【TBD-1】序列生成＋不重複斷言 | **真跑**：60 distinct、stride 互質檢查會拒 |
| `f5_sampler.py` | 【TBD-2】雙儀器取樣器 | **真跑三向 force**：phantom→HIT／clean→零＋上界句／blind→CONTROL-FAILED |
| `run_f5.sh` | 臂驅動、括號身分、R1 範圍化中止、Q3 閘 | `plan`／`selftest`／dry `arm`／五種拒絕路徑 |

**R1 的停跑範圍是程式碼**：post-T-11 臂出現任一命中 ⇒ 落 `raw/R1-TRIGGERED`，
`q3` 讀到它就拒跑，而 **Q2 不受影響**（§3 F3：停 Q3、續 Q2）。已驗。

**符號判準已對真 binary 驗過（含負控制）**，2026-08-31：

| binary | `nm -C \| grep -c setProgrammedPredicate` | `strings` | `nm` 總符號數 |
|---|---|---|---|
| `build/bin/ndtwin_kernel`（tip，post-T-11） | **1** | 3 | 41848 |
| `.test_run/binaries/ndtwin_kernel.a40e04ce`（pre-T-11） | **0** | 0 | 41548 |

第三欄是負控制的負控制：兩顆的 `nm` 都讀得出四萬多個符號 ⇒ pre 那顆的 **0 是真的沒有**，
不是 `nm` 讀不到。（`.provenance` 記著同一種手法曾經只分辨出三顆中的兩顆，所以這一欄不是多餘的。）

🔴 **未驗的部分**：所有需要 fabric 的路徑（真 POST、真南向、`traffic_mesh.sh`、括號身分對真行程）
都只走過 dry-run。建議窗一開先跑 `run_f5.sh selftest`，再跑一臂的前兩次 install 當煙霧測試，
確認 `southbound_has` 會在 ~20 ms 翻成 true——那是整個判準的前提，也是 TR-3 已量過的形狀。
