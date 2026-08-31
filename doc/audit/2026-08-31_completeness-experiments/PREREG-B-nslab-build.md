# PREREG B — nslab 四臂 build 實驗（B2 第二機複製＋B1 flags 消融合一；**v1.0 凍結**）

**狀態**：v0.2-stamped＝**auditor 章已蓋（2026-08-31：結構 PASS＋R1–R3 落點逐一驗訖）**；
四處【TBD】皆機械核對類——**落定即自升 v1.0**（修訂記錄記明何時何人落定）；
【TBD】全屬機械核對——**落定即自升 v1.0、修訂記錄記明**（auditor 裁，毋須 C4 式
primary 快核閘）；**凍結前不得接觸任何量測資料**（偵察＝裝環境、
驗 kvm、smoke 拓樸可起，不產生任何效能數字）。
**裁決鏈**：完整性波 64_ §2-B1/B2 → Adam 08-31 表單「B 級全開、用遠端 VM 不搶實驗室」。

## 1. 問題（兩問合一 fabric）

在第二台機器（nslab qemu VM）上，沿 study ① 的單跳設計：

- **Q-B2（複製）**：stock→full-fast 的 build 混淆是否再現（**只問方向與 rung 級距，
  不轉移機器 1 的比值**——懷疑派 #2 規格）。
- **Q-B1（消融）**：documented-config 與 full-fast 之間、以及 -g -O2（專案預設）與兩端
  之間，在 rung 解析度下是否可分辨——解 study 現文的 hedge（"provided the three flags
  we added do not slow the build"）在機器 2 的版本。

## 2. 臂定義（四 build × 各 2 臂＝8 臂）

同一 behavioral-model tree（**釘 `f0b7d201`，與 study ① 同**）：

| 臂 | configure |
|---|---|
| A stock | p4-guide installer 逐字（`./configure --with-pi --with-thrift --with-python_prefix=<VM venv> 'CXXFLAGS=-O0 -g'`、logging macros＋elogger 開；正本＝`doc/audit/bmv2-binary-provenance.md:36`，`--with-python_prefix` 係 host 綁定路徑、於 VM 適配為其 venv 並揭露——效能無關項） |
| B default | 專案預設 `./configure`（＝`-g -O2`，study 已在乾淨樹驗過） |
| C documented | `-O3 --disable-logging-macros --disable-elogger`（官方文件建議、無自加 flags） |
| D full-fast | C ＋ `-DNDEBUG -march=native -fno-semantic-interposition`（study 的 fast） |

- 交錯序（先凍）：A1 B1 C1 D1 A2 B2 C2 D2；**每臂 fabric 全重啟**（builds swap——
  study ① 慣例；auditor C5 的 fabric 版新鮮度）。
- Binary identity（auditor C3）：每臂 sha256＋bidirectional symbol signature（沿 study，
  含 negative control）＋ `ldd`＋`readelf -d` RUNPATH 快照；`-march=native` 在 VM 內的
  實際展開一併存。

## 3. 量測與判定規則（規則先凍、值後算——auditor C1）

- 拓樸＝單跳、控制面活著（與 study ① 同構）；工作點＝1400 B payload（1442 B frame）UDP。
- 梯階＝① 的**註冊 ladder 逐字**：`1 2 3 5 8 12 20 30 45 70 110 160 240 360` Mbit/s，
  向上爬到 **saturation stop 發火＝連續兩 rung loss >25%**（540/810 等延伸 rung 由規則
  產生，非人選；`RUNAWAY_MAX=40` 純 bug backstop、發火則該臂讀值不作 saturation 解）。
  ✅ TBD-verify 已落定（08-31，reviewer）：rungs＋stop rule＝`2026-08-28_single-switch-
  build-ratio/PREREG-1b.md:39-47` 逐字；Arm A configure 行＝`bmv2-binary-provenance.md:36`
  逐字（差異一處：`--with-python_prefix` host 路徑，已列適配條款——R3 抓到的真差異）。
- Clean＝loss ≤0.5% on 3-rep medians（同 study）；每臂讀出＝最高 clean rung。
- **判定規則（全部先凍）**：
  - R-B2：兩 D 臂讀值皆嚴格高於兩 A 臂 ⇒「混淆在機器 2 存在」成立；報 rung 級距
    （quantisation interval 照 study 規則），**不換算、不與機器 1 比值比較**。
  - R-B1a（C vs D）：兩 D 臂皆嚴格高於兩 C 臂 ⇒「三支自加 flags 在機器 2 買到 ≥1 rung」；
    兩 C 臂皆嚴格高於兩 D 臂 ⇒「自加 flags 在機器 2 反而變慢」（**兩向都登記、都可發表**）；
    其餘 ⇒「rung 解析度內不可分辨」＝以保守方向解 study hedge（自加 flags 效應 ≤1 rung）。
  - R-B1b（B vs A、C vs B）：同構規則（兩臂嚴格序＝可分辨，否則不可分辨）。
  - 🔴 凍結後**不加 rep、不加臂、不加梯階救任何結果**（auditor C5／「不准為救比值加梯階」）；
    n 與臂數只能凍結前修訂。
- 陽性對照：per-process CPU gate 沿 study（**先讓它發火一次才信**）。
- **Sender gate（公式先凍、校準只填常數——auditor R1）**：
  - 判定式（v1.0 即存在）：令 G＝VM 內 sender→sink **直測天花板**；凡 rung X 滿足
    **G < 5×X ⇒ 該 rung 及以上的讀值標 sender-limited、不入 clean 判定**。
    ✅ 錨點已落定（08-31，reviewer）：5× 要求＋loopback 不經 bmv2＝
    `23_FINDINGS_packet-size.md:68-77`（②註冊原文＋770.7 kpps 實測樣例）；loopback
    直測先例＝`2026-08-28_single-switch-build-ratio/PREREG-1b.md:76-82`（①b 於臂後跑；
    **本實驗改於臂前跑＝刻意更嚴**，防火牆理由見上）。
  - 校準時序與防火牆：凍結後、正式臂之前跑；**校準路徑 sender→sink 直連、不經過任何
    受測 build 的 binary**（不洩漏臂的性能包絡）；校準產出只有常數 G、只餵判定式、
    不入 primary。

## 4. 環境（auditor C4）

- **nslab qemu VM 專屬**（⚠️ `/dev/kvm` 靠**群組**成員資格、已驗 `nslab` 在 `kvm` 群組內）；
  🔴 **起點快照＝`p4-bootstrapped-nodocker`（ID 3，2026-08-31 14:01）**，**不是 `fresh`**
  ——見 §4a 的事故紀錄：磁碟上有**兩個同名 `fresh`**、內容完全不同（ID 1＝bootstrap 前的
  裸雲端映像；ID 2＝bootstrap 後），`restore fresh` 因此是不確定的。**本實驗不設本機 fallback**（本機的 documented-only 補臂
  ＝另一張小 prereg，見 §6）。
- 完整層疊揭露：bare nslab → qemu/KVM VM → Mininet veth。
  ✅ **VM manifest 已落定（08-31 14:5x，reviewer，於 guest 內實測；最後一個 TBD）**：

  | 欄 | 值 |
  |---|---|
  | guest OS | Ubuntu 24.04.4 LTS |
  | kernel | `6.8.0-138-generic` |
  | CPU model（宿主直通） | Intel Core i7-14700 |
  | vCPU／RAM | 16 ／ 15 GiB（＝顯式 `VM_CPUS=16 VM_MEM=16384`） |
  | iperf3 | **3.16（cJSON 1.7.15）** ——🔑 **與機器 1 逐字相同**（`35_MACHINE-ENV`）⇒ 量測工具不是跨機差異的來源 |
  | Mininet | 2.3.0 |
  | p4c | `p4c-bm2-ss`（版本字串於編譯 .p4 當下記入 raw） |
  | guest 既有 behavioral-model | `583e76e`（**bootstrap 遺留、不是本輪受測對象**——四臂各自從 `f0b7d201` 重建） |

  🔴 此為 **bootstrap 參考版**；**權威版仍是跑臂當下由 runner dump 的那份**，兩者逐欄對帳
  （見上條時效條款）。⚠️ 記錄當下 guest 內已裝 docker（C4 用）——docker 不在 manifest
  欄位內，但**臂必須自 `p4-bootstrapped-nodocker` 還原後才跑**。
- **Manifest 的時效條款（auditor 08-31）**：manifest 的權威版本＝**跑臂當下實測**，
  不是 bootstrap 當下的（中間一次重開機或 VPN 斷線重連就可能換掉 CPU model／kernel／
  governor——「一次正確的量測會無聲過期」的同型）。實作：**臂 runner 開頭自動 dump
  一份 manifest 進 raw，與 bootstrap 那份逐欄對帳；任一欄不一致 ⇒ 停止並報告，
  不得默默採用新值**（不一致本身即發現，處置照 abandon 條款的精神：如實報、不硬修）。
- **Pinning／governor＝凍結決策、非記錄（auditor R2）**：裁定＝**不 pin vCPU、governor
  照 VM 預設不動**——與 study ①（機器 1 無 pinning、無定頻）同 protocol，複製忠實度
  優先；pinning 敏感度屬 B3（本機、另立 prereg）。
- 🔴 **qemu 資源＝顯式凍結值，必須每次明傳**：`VM_CPUS=16 VM_MEM=16384`。
  **更正 v0.3 的事實錯誤**：這**不是**腳本預設——腳本預設是 `VM_CPUS=12`／`VM_MEM=8192`
  （`ndtwin-vm.sh:33-34`，其註解「host has 32／15Gi」是為**另一台**機器寫的；nslab 實為
  28 核／31 GB）。⇒ **不明傳就會拿到 12/8192**，見 §4a。

### 4a. 事故紀錄（08-31，reviewer 造成；manifest 條款的第一個實例）

我為了補一個 `fresh` 快照而 `stop`→`snap`→`start`，結果**兩件事同時出錯**：

1. **VM 資源被無聲換掉**：原本以 16 vCPU／16384 MiB 啟動，重啟時**環境變數沒帶**⇒
   吃到腳本預設 **12 vCPU／8192 MiB**。guest 實測從 `nproc 16` 變成 `12`。
   🔑 **這正是 v0.3a 那條 manifest 條款要防的東西，而它在條款寫下數十分鐘後就發生了**
   ——證明「跑臂當下重量、與 bootstrap 版逐欄對帳、不符即停」是必要的，不是形式。
   已用顯式參數復原（現況：16 vCPU／15 Gi、106 G 可用）。
2. **製造了同名快照**：磁碟上原本已有 `fresh`（ID 1，11:47，**bootstrap 前**），我又建了
   一個 `fresh`（ID 2，13:59，**bootstrap 後**）⇒ **同 tag 兩種狀態**。
   🔑 **成因＝我把工具的讀取失敗當成了「不存在」**：`ndtwin-vm.sh snaps` 因 qemu 持有
   磁碟寫鎖而讀不到，回報「(no disk or no snapshots)」，我照字面採信。正確做法＝
   `qemu-img snapshot -l -U`（force-share）繞過鎖再讀。
   **處置**：不刪（`qemu-img snapshot -d` 只認 tag，同名情況下可能刪錯那一個），改建
   **不歧義名稱** `p4-bootstrapped-nodocker`（ID 3）並由本 prereg 指名使用。
   🔴 **`fresh` 這個名字自此在本輪作廢，任何腳本不得用它 restore。**
- **nslab 獨占條款**：跑臂期間 nslab 上不開任何其他重活——nslab 無 claim 工具，
  **本句即其 claim**。
- 🔴 **宿主外來負載閘（v0.5 新增；收緊）**：上句只約束**我們自己**，但 nslab 是實驗室
  機器、**不保證獨佔**（08-31 遠端線通報；本輪查核當下 `who` 即顯示多個登入）。
  而 VM **看不到宿主的負載** ⇒ 光在 guest 內量 CPU 不夠。
  **實作**：每臂**在 nslab 宿主上**（VM 外）取樣 `/proc/stat` busy fraction 與 `uptime`，
  隨該臂 raw 落盤；**判定規則先凍**——若某臂的宿主 busy 中位數超出**該輪所有臂宿主
  busy 中位數**的 +0.15，**該臂標 foreign-load-suspect、不入嚴格序判定**（沿 ③ 輪的
  相對形式）。🔑 **已知限制照實寫**：此閘與「臂自己的負載」無法完全分離（②/③ 兩輪的
  老問題），但**臂自己的負載在 guest 內、宿主看到的是它經過 VM 的投影**，兩者不同源
  ⇒ 比 guest 內自量有鑑別力；**仍不得**用它反推臂的效能。
- P4 程式 ✅ 已落定（08-31，reviewer）：`p4_proxy/p4_src/ndtwin_switch.p4`、
  sha256 `5786a63e9b31402ce40bc6401319a6408a1cf71f6dddaca0c023d450f3ae23d5`，
  自 `f64897b`（08-25 19:30）未再變動＝**早於 ① 的 08-28 量測 ⇒ 與 ① 同顆**（時序驗過，
  benchmark-must-name 的坑已排）。p4c＝**於 nslab VM bootstrap 時現編現記**（本機 PATH
  今日印 1.2.5.15/5b948b037a，僅供參考、不假設為任何既有 JSON 的編譯器）；JSON hash
  於編譯當下記。此格順手補了 AEC 抓的論文缺口（35_ 的 camera-ready 待辦一併解）。
- 每臂 fabric 重啟＝新鮮度；VM 不 snapshot-rollback 中途（8 臂一氣跑完、中斷則整輪作廢
  重跑並記錄）。

## 5. 措辭紅線

- **跨機器可比性免責（auditor C2 同構）**：本註冊只裁「機器 2 上各 build 對是否可分辨
  ＋方向」；**不登記**與機器 1 的 8.0×/12× 的倍率可比性；跨機器倍率並列一律標事後探索。
  方向相符＝什麼都還沒得到。
- 結果無論方向如實報（含「VM 環境撐不起 clean baseline」的 abandon 路徑：報不可行＋
  失敗點）。
- VM 層＝正式限制條款：所有結論措辭綁「on this VM」，不寫裸的「on a second machine」。
- ✅ **與 08-31 遠端線「自足性」界線的相符聲明**：該線裁定＝「一個效能宣稱必須自足——
  所有臂同機器、同 binary、同工作點，並指名量了什麼；新機器違反的只是**併**不是**量**」。
  本註冊逐條相符：八臂全在同一顆 VM、同一 tree（`f0b7d201`）、同一工作點（1442 B UDP
  單跳）；C2 條款已禁止與機器 1 的任何倍率併比。
  ⇒ Q-B2 屬該線列為**加分項**的「第二平台重現定性結論」（＝新的一格，不是多一個 rep）。
- 🔴 **不轉移清單**（該線點名）：收端類結論（`jitter-is-the-receiver-not-the-network`）
  **不適用**於本 VM——virtio 收包路徑是另一回事；本輪任何讀值不得用來支持或反駁該結論。
  絕對容量若量得出來＝**另一個工作點的新一組數字**，不併入舊表。

## 6. 與其他軌的關係

- R-B1a 的「不可分辨」結果＝以機器 2 證據**收窄** study hedge，不改機器 1 條文。
- 本機 documented-only 補臂（嚴格解機器 1 hedge 用）＝另一張 mini-prereg，等本機空檔
  ＋不疊 9/03 窗；與本實驗互引。
- C4（Whippersnapper）的 Arm F＝本實驗 Arm C 的 2017 代碼庫遠親——三處數據點
  （機器 1 上界、機器 2 消融、2017 管線）合讀時一律標事後探索。
- 產出落 `doc/audit/2026-08-31_completeness-experiments/B-nslab-build/`（raw＋log＋
  env manifest 全存）。

## 7. 修訂記錄

- v0.1（08-31）：初稿（reviewer 線起草；auditor 五條件 C1–C5 預套——C1 判定規則全數
  先凍、C2 跨機器免責、C3 ldd/RUNPATH、C4 環境條款、C5 新鮮度＋凍結後不加）。
  【TBD】×4：rungs 對 21_/22_ 核對、VM manifest、P4 程式/p4c 逐字記名、sender gate
  的 VM 校準程序。
- **v1.0（08-31，資料接觸前）＝凍結**：最後一個【TBD】（VM 環境 manifest）已於 guest 內
  實測落定（見 §4 表）。依 auditor 裁定「TBD 全屬機械核對、落定即自升 v1.0」⇒ 本註冊
  **自此凍結**：判定規則、臂、梯階、n 一律不得再改；後續只能追加「資料接觸前」的收緊
  修訂，且須逐項標明。**下一步＝sender-gate 校準（凍結後、正式臂前）**。
- v0.5（08-31，**資料接觸前**；只收緊）：①新增**宿主外來負載閘**——nslab 非獨佔、
  VM 看不到宿主負載 ⇒ 每臂在宿主側取樣 `/proc/stat`，相對門檻 +0.15 標 suspect
  （鑑別力限制照實寫）；②新增與遠端線「自足性」界線的**相符聲明**與**不轉移清單**
  （收端類結論不適用於 virtio 路徑；絕對容量屬另一工作點）。
- v0.4（08-31，**資料接觸前**）：①起點快照改指名 `p4-bootstrapped-nodocker`（`fresh`
  同名兩份、作廢）；②qemu 資源改列**顯式凍結值**並更正 v0.3 的「這是腳本預設」事實錯誤
  （真預設＝12/8192）；③新增 §4a 事故紀錄（manifest 條款的第一個實例，肇因者＝我）。
- v0.2（08-31，**資料接觸前**）：auditor 覆核（結構 PASS）三騎士條款落地——
  R1＝sender gate 公式先凍（G<5×X ⇒ sender-limited；校準 sender→sink 直連繞開受測物、
  只填常數 G、不入 primary；②錨點行號列入 TBD-verify）；R2＝pinning/governor 凍結裁定
  ＝不 pin、不動 governor（與 study ① 同 protocol；敏感度歸 B3）；R3＝Arm A stock
  configure 行併入 TBD-verify 同批。另補 nslab 獨占條款（無 claim 工具、條款即 claim）。
  流程（auditor 裁）：TBD 全屬機械核對，落定即自升 v1.0。
- v0.3（08-31，reviewer 落定、**資料接觸前**）：四 TBD 落定三——①rungs/stop rule＝
  PREREG-1b:39-47 逐字（saturation stop＝連續兩 rung >25%）；②Arm A configure＝
  bmv2-binary-provenance.md:36 逐字（R3 抓到 `--with-python_prefix` host 路徑差異
  →列適配條款）；③sender-gate 錨點＝23_:68-77＋PREREG-1b:76-82（本實驗校準改臂前＝
  刻意更嚴）；④P4 程式＝ndtwin_switch.p4 sha256 5786a63e…、f64897b（08-25）後未動
  ＝與 ① 同顆（時序驗訖）。**僅剩 VM 環境 manifest 一格（nslab bootstrap 時落）——
  落定即自升 v1.0。**
- v0.3a（08-31，auditor 提醒→reviewer 落，資料接觸前）：§4 加 **manifest 時效條款**
  ——權威版＝跑臂當下實測、runner 開頭自動 dump 進 raw 與 bootstrap 版逐欄對帳、
  不一致即停機報告不得默默採用。（理由同 [[cited-line-numbers-are-not-evidence]] 的
  「一次正確的量測會無聲過期」。）

[Co-developed with claude code -- Adam]
