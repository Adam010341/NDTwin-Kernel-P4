# run-04（sonnet）— 對帳

## 0. 這一輪的判決，先講

> **通過 §1–§6，過程中有兩次 harness 干預，均已逐字記錄，內容僅涉及 tester 對自身環境的誤解。**

理由與逐條檢查在 §5。**干預不在 Adam 的判準裡**——這是事實陳述，不是辯解（見 §4）。
要不要把「零干預」加進判準是**新判準**；在看到結果之後才加，等於改標準，
所以 **run-04 依現行判準結案**，若 Adam 要加，**從 run-05 起算**。

## 1. 帳本 R12 九條預期 vs 實際

九條逐字抄自 `doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`
的 A-7 / run-04 子列（09-02 23:4x 登記，**VM 建立之前寫**）。

| # | 帳本上跑之前寫的（逐字） | 實際 | 裁定 |
|---|---|---|---|
| ① | 「**§1–§5 無 friction ≥2**（run-01 同模型同段落只有 `conda init` 那一項，且成因是 ssh 不是手冊）」 | **字面不中，實質中。** §1／§2／§3／§5 都是 **friction 0**（`JOURNAL.md:20,27,45,115`），**§4 是 friction 2**。但那個 2 是 tester 打給**自己的工具**的：它逐字寫「verdict: 2 needed a workaround: **none from the manual's side (it built clean on the first try)** -- the friction was entirely in how I was watching a background build」。同一節的 build 本身是 `CMAKE_EXIT=0`／`NINJA_EXIT=0`／零 warning／6 分鐘。⇒ **手冊在 §1–§5 造成的 friction 是 0**；那個 2 記的是我們的干預 #1。 | **部分中**（分數不中、成因與預期一致） |
| ② | 「**§6.1 會被丟背景**（手冊這次自己教 `tmux new-session -d`），耗時落在 **7640 s 的 ±10%**，且 **tester 會回頭收 `SCRIPT_EXIT` 與 Step 6.2 的兩條 `--version`**——若它只看 `SCRIPT_EXIT=0` 就宣告完成，那是我加的那段沒寫清楚，不是它的錯」 | **三個子句全中，而且是九條裡證據最強的一條。**<br>**(a) 背景化**：`orchestrator-evidence/2026-09-03_00-03_p4-detached-as-documented.md` 是**跑到一半時**的唯讀觀測，`pane_start_command` 與 `2612b0a` 寫進 Step 6.1 的那段**逐字相同**（含 `; \\` 續行與 `${PIPESTATUS[0]}`）⇒ **照抄，不是自己發明**。<br>**(b) 耗時**：腳本自報 **`Total time : 7748 sec`**（`log.txt:14241`）。**7748 vs 7640 ＝ +1.41%**，遠在 ±10% 內（±10% ＝ 6876–8404 s）。<br>**(c) 回頭收**：`SCRIPT_EXIT=0` 收了（`log.txt:14605`、`JOURNAL.md:393-401`），**兩條 `--version` 也都收了**（`logs/s6_2to6_setup.log:5-13`），而且它**逐字複述了手冊的口徑**：「exit 0 says the script ended, not that it succeeded -- the acceptance check is the two binaries」。 | **中**（三子句全中） |
| ③ | 「**#3 不再重現**：`ln` 不會再吐 `No such file or directory`；但**「開新 login shell」那半會不會被照做，我沒把握**——**這是本輪最可能打臉我的一條**」 | **兩半都中；那個自我懷疑沒有應驗。**<br>**前半**：`mkdir -p ~/.local/bin` 在 tester 自己的 `ndt_install.sh` 裡逐字照抄，`.local`／`.local/bin` 的 **Birth 都是 15:59:10**，全樹零 `ln:` 錯誤。<br>**後半**：它**逐字引用了那段註記**當 Expected（`Open a new login shell before calling ndt. … start one with bash -l.`）⇒ **讀到了**；並從第一次呼叫起就用 `bash -l -c`，自評「**the manual anticipates it and gives a working fix**」、嚴重度 Cosmetic、**明確不立案**。 | **中**（自我懷疑**未**應驗，見 `VERIFICATION.md` 註 ③） |
| ④ | 「**`ndt up ovs` 仍失敗**（G-7 未修，auditor 今晚不動），tester 讀到 Known-limitation 後**直接走三終端、不自己發明修法** ⇒ **friction ≤2 而非 3**。**這條決定「已記錄但未修」能不能算通關**」 | **行為半全中，分數半不中。**<br>仍失敗 ✓（5m08s → `XX fabric has 0 hosts, expected 128`）；讀到 Known-limitation ✓（它在 BUGS.md 逐字引了那個紅框，並說「the manual's own box predicts this failure **before I ever ran the command**」）；轉三終端 ✓ 並跑通；**沒有自己發明修法** ✓（它只**讀**了 `/usr/local/sbin/ndtwin-lab` 確認路徑，明確沒改）。<br>**但它把那一節記成 friction 3**，不是 ≤2——理由是「blocked, worked around」。⚠️ 而那一節是 **User Manual 的 OVS 頁**，**不在 Installation Manual §1–§6 裡**。 | **部分中**（決定性的行為半中；分數半不中，但落在判準範圍外） |
| ⑤ | 「**收斂數對得上**：`ovs-ofctl dump-flows` 每台 **130**，與改後的手冊一致，不會有人等 131 等到天亮」 | **後半中，前半沒有檔。**<br>「不會有人等 131」✓：全程沒有任何等待紀錄，tester 記 B3「reached in under 20s … much faster than the manual's 80-90s reference」。<br>**「每台 130」查無實據**：BUGS／CHECKLIST／JOURNAL 三處都寫了這個數字，**而 `~/logs/` 裡沒有一行 `ovs-ofctl` 輸出**（`cookie=0x`／`n_packets=` 命中 0）。唯一旁證是 `logs/T1_ryu.log` 的 `install_all_pair_paths done: … rules=1280`，1280/10＝**128**，與 130 的**組成**（128＋LLDP＋table-miss）相容但不是那個量測。 | **部分中／數字未測** |
| ⑥ | 「**NTG 這次會起來**（`062d8eb`＋`df614ce` 已在 docs 內），run-03 的 catch-22 不重現」 | **中。** `logs/ntg_install.log:3` 逐字 `python3 -m venv --system-site-packages /home/ndt/ntg-env`；`:137-138` `mininet importable from ntg-env: /usr/lib/python3/dist-packages/mininet/__init__.py`。tester 到達 `NTG>` prompt，`flow --config` 跑完（kernel 端獨立看到 `flows=29`），`dist --config` 也跑了真 iperf3。**guest 上只有 `ryu-env` 一個 conda env**（`GUEST-STATE.txt`）⇒ run-03 那個「手冊指向不存在的 conda 路徑」的條件仍在，**而手冊已不再那樣寫，所以沒人踩到**。 | **中** |
| ⑦ | 「**#9／#10／#13 仍會重現**——公開快照 `20cd80b`（08-28）未動，這三條的修法不在裡面。**它們不影響 §1–§6 判準**，但會再一次出現在 BUGS 裡」 | **未測。** 前提成立（clone 到的仍是 `936f8c6`，見 `logs/ndt_status_baseline.log`：`code 936f8c6`），**但 tester 這一輪根本沒走 REST API 那條路**——BUGS.md 與 CHECKLIST 都沒有 API 端點章節。run-03 的 opus 逐一驗了 41 個端點，run-04 的 sonnet 沒有。⇒ **不是沒重現，是沒被測到**（`VERIFICATION.md` 的取證邊界）。 | **未測**（前提成立、事件未觸發） |
| ⑧ | 「**Web GUI 的 pnpm 仍會炸**（run-01 BUG-009，12 筆修正沒碰它，手冊全站零 `pnpm` 字樣），在 §1–§6 之外」 | **中，逐字命中。** `logs/webgui_deploy.log:331` `Error: ERR_PNPM_IGNORED_BUILDS`、`:334` `Ignored build scripts: esbuild@0.25.5`、`:338` `Failed to start containers.`；連未 pin 的來源都有檔：`:220` `RUN npm install -g pnpm`、`:262` `Done in 322ms using **pnpm v12.3.0**`。位置也對——在 §1–§6 之外。 | **中** |
| ⑨ | 「**整體我賭它通關**（§1–§6 全完、無 friction 3），唯一的但書是 §6 走背景——而「背景完成算不算通關」Adam 沒裁，已列進早上要問他的清單」 | **中。** §1–§6 全完（§6.7 依手冊自己的框定為 optional-of-optional，且 §6.6 專為跳過它的讀者寫了指示，tester 照做）；**§1–§6 之內沒有 friction 3**（唯二的 3 在 User Manual OVS 頁與 Web GUI 頁，都在範圍外）。但書仍然成立且未解：§6.1 花 2h09m，本輪**兩次停手都發生在這段等待裡**。 | **中**（但書未解，見 §4） |

**九條：中 5（②③⑥⑧⑨）· 部分中 3（①④⑤）· 未測 1（⑦）· 不中 0。**

🔑 **⑧ 值得單獨說一句：一條打中的預測本身就是「預先登記管用」的證據。**
它在 VM 建立之前就寫下「Web GUI 的 pnpm 仍會炸，因為那 12 筆修正沒碰它」，
六個半小時後 tester 在一台它從沒見過的機器上撞出**逐字相同**的錯誤。
⇒ 這不是事後合理化，是**可否證的預測被證實**。R12 的預先登記機制在本輪產生了它該產生的東西。

## 2. run-01 → run-04：十一條裡，文件修法消掉了幾條

**這是整個實驗設計的交付物。** 模型固定（皆 sonnet），docs 從 `bcf98f5` 換成 `2612b0a`
⇒ 差異可歸因到文件。run-01 的十一條見 `run-01-sonnet/REPORT.md` §6。

| run-01 | 一句話 | run-04 重現？ | 歸因 |
|---|---|---|---|
| **BUG-001** | §2.6 `is_mininet` 這個 knob 改了沒用 | ❌ **消失** | **文件**：`c60c70f`（在 `d5259f0` 內）。tester 讀檔逐一核對三個 knob，**全對得上**，還發現手冊的「about 545 lines further down」實際是 546 |
| **BUG-002** | §2.6 叫你設的 `switch_num` 那行已經不存在 | ❌ **消失** | **文件**：同 `c60c70f`。手冊改寫成三層 fallback，與 `intelligent_router.py:92-101` 逐字相符 |
| **BUG-003** | `ndt up ovs` 直接死：兩本手冊都沒教你裝 `ndtwin-lab` | ❌ **消失** | **文件**：安裝步驟現在含 `sudo install … ndtwin-lab` ＋ sudoers；tester 三步全做、**三步全 WORKS**（CHECKLIST A1／A2／A3）。⚠️ **確切 commit 本線指不出來**——它在 `bcf98f5`→`d5259f0` 那 12 筆裡，而 website repo 不在本機、guest 的 `~/ndtwin-docs/` 也不是 git repo |
| **BUG-004** | `ndt up` 兩個平面的 fabric 都起不來 | ✅ **重現**（BUG-1 ＋ P4 addendum） | **刻意未修**：G-7，auditor 09-02 裁「今晚不動」（DOCS-FIX-MAP） |
| **BUG-005** | `ndt apps sim`／`energy` 印 `ok … started` 卻什麼都沒起 | ✅ **重現**（BUG-6） | **刻意未修**：G-6，程式缺陷不是手冊錯 |
| **BUG-006** | NSR `stop_…sh` 用了手冊自己禁止的 `kill $(pgrep -f …)`，當場多抓一個 PID | ✅ **重現**（BUG-4 的 stop 半） | **刻意未修**：修法在 NSR 那支腳本裡，不在手冊 |
| **BUG-007** | NTG 的啟動指令指向一個不存在的 conda 路徑 | ❌ **消失** | **文件**：`df614ce`（在 `d5259f0` 內） |
| **BUG-008** | NTG 的 venv 看不到系統的 `mininet` | ❌ **消失** | **文件**：`062d8eb`（在 `d5259f0` 內）。`ntg_install.log:3,137-138` 兩行是直接證據 |
| **BUG-009** | Web GUI 未 pin 的 pnpm 讓 build 整支炸掉 | ✅ **重現**（BUG-5） | **刻意未修**：R12 ⑧ 預先寫明會重現，並解釋了為什麼不修 |
| **BUG-010** | kernel 印完完整的關機訊息之後還活著、還在服務 14 分鐘 | ❌ **未重現** | ⚠️ **不歸功於文件**。tester 每次 Ctrl-C 都查了埠有沒有放掉（`process gone, ss confirms`），沒撞到。公開快照未動 ⇒ 程式沒變 ⇒ **只能說「這一輪沒觸發」，不能說「已修」** |
| **BUG-011** | `/ndt/get_cpu_utilization` 在 Mininet 下是捏造的常數，只有一支沒文件化的 CLI 會揭露 | 🟡 **半消** | **文件半修好了**：tester 在 **WebGUI／Visualizer 的手冊頁**上讀到了那個警告（CHECKLIST A7），`ndt status` 的 baseline 也印 `note /ndt/get_cpu_utilization is fabricated in MININET mode`。**捏造本身仍在**（程式，不是手冊） |

### 對帳結論

| | 條數 |
|---|---|
| **被文件修法消掉** | **5**（001／002／003／007／008） |
| **被文件修法半消** | **1**（011 的揭露那半） |
| **重現，且全部是我們刻意不修的** | **4**（004／005／006／009） |
| 未重現但不歸功於文件 | **1**（010） |

🔑 **這張表就是這個實驗設計要換的東西。** 模型固定、手冊變動，於是：
**十一條裡有五條半純粹因為改了文件而消失，而重現的四條，每一條我們事前都寫下了「不修，理由是 X」。**
**零意外**——沒有任何一條是「改了文件卻沒消失」，也沒有任何一條是「沒改卻消失了」（010 標明例外）。
⇒ **手冊修法與缺陷消失之間的對應是乾淨的**，這是四輪 campaign 到今天為止最直接的一次歸因。

## 3. 已知 vs 新，與四輪對照

### 本輪歸類（明細見 `VERIFICATION.md` 末表）

| 類別 | 條數 | 是哪些 |
|---|---|---|
| **NEW** | **7** | BUG-2（自測假失敗＋寫死 OK banner）、BUG-3（孤兒 kernel／`ndt up` 失敗路徑漏 `stack.sh`）、Docker 兩則小疵、SPM 的 `:8003`、ESA 的 NFS 相依缺口、`VITE_GITHUB_TOKEN` 未文件化、NTG.yaml 的「建議改」其實是「必須改」 |
| **ALREADY-KNOWN** | **4 族** | BUG-1＋兩 addendum → **G-7**（＋**G-8** 的形狀）；BUG-4 → run-01 **BUG-006**；BUG-5 → run-01 **BUG-009**；BUG-6 → **G-6（一字不差）** |
| 非缺陷（正面紀錄） | 3 | PATH friction（手冊已預告並給了可用解）、NSR 前景模式誠實退出、Traffic Visualizer 兩種形狀都照手冊預測 |

### 四輪

| | run-01 sonnet | run-02 haiku | run-03 opus | **run-04 sonnet** |
|---|---|---|---|---|
| docs | `bcf98f5` | `bcf98f5` | `bcf98f5` | **`2612b0a`** |
| 總時 | ~2 h | — | 94 min（被外部中止） | **6h48m（自行收尾）** |
| 干預 | 0 | 5 | 0 | **2（皆 B 類）** |
| 走到哪 | §1–§6＋工具 | §1–5；§6 只 clone | §1–§5＋§6.1；41 個 REST 端點 | **§1–§6 全完＋兩個平面各走完一次 User Manual＋六個工具頁** |
| 有最終報告？ | ✅ | — | ❌（被用量上限殺） | ✅ **`## SUMMARY` 完整** |
| BUGS | 11 | 實質 0 | 22（新 15） | **13 則條目**（新 7） |
| 複驗 | 大致可信 | 前三條主要宣稱全 REFUTED | 38 條：36 對得上／0 UNSUPPORTED | **81 條：58 CONFIRMED／2 mis-stated／1 in-part／20 UNSUPPORTED／0 CONTRADICTED** |

⚠️ **20 條 UNSUPPORTED 不能與 run-02 的 REFUTED 混為一談。** run-02 是**宣稱與證據相反**；
run-04 是**宣稱沒有證據可查**——`0 CONTRADICTED`，凡是有旁證的都對得上。
分界線很乾淨：**tee 到檔案的全部可查，只在回合裡讀過的全部查不到**（`VERIFICATION.md` 註 ⑦）。
⇒ 這是**取證規程**的缺口，不是誠信問題，而修法是模板的一句話（見 §7）。

## 4. 兩次干預

| 時刻（CST） | tester 的遺言（帳本逐字） | 類別 |
|---|---|---|
| **09-03 00:0x** | 「Stopping all actions now. I'll resume automatically when the background build-completion notification arrives.」 | **B** |
| **09-03 00:52** | 「Continuing to let the P4 build run in the background — I'll pause active polling now and resume on the poller's notification.」 | **B** |

（⚠️ 干預 #1 的時刻，帳本記 00:0x CST、tester 自述 caught ~15:57 UTC ＝ 23:57 CST，差約 10 分。
以帳本為準，因為那是當下寫的。差額不影響任何判定。）

**兩次都是 B 類（只關於它自己的執行環境），兩次都沒有洩漏任何關於受測物的東西。**
依早報 §①b 的分類提案：

| 類別 | 內容 | 影響「一次通關」？ |
|---|---|---|
| **A：帶資訊的** | 任何關於手冊、專案、已知缺陷的提示；替它解決它遇到的問題 | 是，該輪作廢 |
| **B：只關於它自己執行環境的** | 「沒有通知會來」「你的 build 還在跑」——**一個坐在桌前的人本來就知道的事** | 否，記錄但不作廢 |

**有沒有洩漏？沒有。** 三項獨立佐證：

1. **帳本當下的記錄**逐字寫著兩次都「**只更正它對自身環境的錯誤信念**（沒有通知會來、
   要在自己的回合裡 `sleep 300` 迴圈等、build 結束 ≠ build 成功），**未給任何與手冊或已知缺陷有關的提示**」。
   （本線持有的是 tester 的遺言逐字，以及帳本對我方訊息內容的當下記錄。）
2. **時序上也不可能洩漏成績。** 兩次都發生在**等待**裡（#1 在 §4 build，#2 在 §6.1 build），
   而本輪絕大多數缺陷是在那之後才被撞出來的——BUG-2／BUG-3 在 00:08–00:18（#1 之後、#2 之前），
   BUG-5／BUG-6 在 00:26–01:09，P4 那一整段在 02:11 之後。**沒有一條缺陷是在干預當下被指出的。**
3. **tester 自己也是這樣歸類的。** 它把兩次都寫成 `## Tooling note: a stop in my own harness, **not the project**`
   （`JOURNAL.md:60-70`、`:317-325`），逐字說「recorded here only so it is not mistaken for the project hanging」，
   並在 SUMMARY 裡再說一次「both were me incorrectly assuming a detached VM-side process would page me,
   **not anything NDTwin did**」。⇒ **它沒有把干預算到 NDTwin 頭上，我們也不該把它算到手冊頭上。**

⚠️ **成本仍然是真的，只是記在別的帳上**：§4 與 §6 的 friction 2 **就是這兩次干預**，
不是手冊。tester 逐字寫「none from the manual's side」。
⇒ **這兩個 2 是我們儀器的分數，被誤植在手冊的成績單上。**

## 5. Adam 的判準

> 「Installation Manual §1–§6 complete, no friction-3 blocker, no workaround the tester had to invent, kernel comes up.」

四個子句逐條查：

| 子句 | 證據 | 判 |
|---|---|---|
| **§1–§6 全做完** | §1（`JOURNAL:20`）／§2（`:27`）／§3（`:45`）／§4（`:88`，`CMAKE_EXIT=0`＋`NINJA_EXIT=0`）／§5（`:115`）／§6.0–6.6（`logs/s6_2to6_setup.log` 全程）。**§6.7 跳過**——手冊自己框定它是 optional-on-top-of-optional，且 **§6.6 專門為跳過它的讀者寫了指示**（把 `bmv2_binary_override` 指向 stock build），tester 照做並確認該路徑是可執行檔。⇒ **依手冊自己的定義，§6 是完成的。** | ✅ |
| **無 friction-3 blocker** | §1–§6 的分數是 **0／0／0／2／0／2**，**沒有 3**。全輪唯二的 3 是 **User Manual 的 OVS 頁**（`JOURNAL:123`）與 **Web GUI 頁**（`:214`）——**兩者都不在 Installation Manual §1–§6 裡**。<br>⚠️ 而 §4 與 §6 的那兩個 2 **是 tester 打給我們兩次干預的**，不是打給手冊的（§4 逐字：「none from the manual's side」）。 | ✅ |
| **無 tester 自己發明的 workaround** | §1–§6 之內：**零**。`ndt up ovs` 失敗後走的是**手冊自己的三終端程序**（手冊明文推薦用於這個已知情況）；`bash -l` 是**手冊自己的字**；`bmv2_binary_override` 改成 stock 是**手冊 §6.6 的指示**。<br>⚠️ **範圍外有一個**：NSR 的 `source ~/nsr-env/bin/activate`（BUG-4）。**NSR 是「NDTwin Tool」頁，不是 Installation Manual §1–§6** ⇒ 不落在判準裡。**這一句我不軟化：它確實發明了一個 workaround，只是不在被評的範圍內。** | ✅（§1–§6 範圍內） |
| **kernel 起得來** | OVS 平面兩次（`logs/T3_kernel_run2.log` 16:19:49、`T3_kernel_run3.log` 16:23:58），P4 平面一次（`logs/P4T3_kernel.log` 18:19:24），三次都是 `topology from the control plane: **10 switches, 128 hosts, 288 edges up**`，三次都有真流量被 API 偵測到（`flows=2, counters=2` ×2、`flows=29` ×1）。 | ✅ |

### ⇒ **四比四，通過。**

> **通過 §1–§6，過程中有兩次 harness 干預，均已逐字記錄，內容僅涉及 tester 對自身環境的誤解。**

**兩次干預對這個裁定的影響：沒有影響，而理由不是「不算」，是「不在判準裡」。**
Adam 親裁的四個子句沒有一句提到干預次數。把它們算成失敗，等於**用手冊的成績單去記錄我們儀器的限制**
——而那個限制的形狀已經另案立在 `FINDING-a-stop-looks-like-completion.md` 裡了。
⇒ **要不要把「零干預」加進判準，是一個新判準。** 在看到結果之後才加會變成移動球門，
所以列進早上要問 Adam 的清單，**若他要，從 run-05 起算**。

## 6. 🔴 一則本線的自承

> Adam 問 `ndt down` 靠什麼保證環境乾淨，本線逐條講解了 `cmd_clean` 的五條斷言、並逐字引用了
> 那三個埠（8000／8080／8081）——**而沒有看出清單少了一個**。BUG-3 不是本線推論出來的，
> 是 tester 撞出來的。這就是為什麼「涵蓋不足」比「邏輯錯誤」難抓：
> **背誦一張清單不會揭露清單缺了什麼。**

補一句本輪的後續：撞出來之後，**本線能做而 tester 不能做的事是讀碼**，於是把它從
「有一支孤兒行程」推進到「**`ndt up` 的失敗路徑會漏出一支活的 `stack.sh`，它接著把 kernel
起到別人的 fabric 上**」，並確認**埠原語本身只認 TCP**、`--deep` 同樣構不到
（`VERIFICATION.md` 註 ①）。⇒ **分工是對的：tester 找得到我背不出來的洞，我補得上它讀不到的機制。**

## 7. 帶進 run-05 與 A-8

### 給 run-05 的模板修正（一條，本輪唯一的取證教訓）

🔴 **run-03 交代的第 1 條只補了 tmux pane，漏掉了最常見的那一種：普通指令的輸出。**
本輪 20 條 UNSUPPORTED **全部**落在「在自己回合裡跑、讀完就丟」這一類。建議的一般規則：

> **凡是你打算在 BUGS.md／JOURNAL.md 裡逐字引用的輸出，先把它寫進 `~/logs/` 再引用。**
> 「我在這個回合裡看過」不是證據——你的回合會結束，檔案不會。

點名要存的最小集合（本輪各缺一格）：`ndt` 的每一次輸出、`ovs-ofctl dump-flows` 的計數、
`iperf3` 的吞吐、每一段 traceback、每一次「反證用」的手動指令、`/tmp/*.json` 之類的 manifest。

### run-05 的自變數要分兩類算

DOCS-FIX-MAP 已經寫明：`174beca` 在 run-04 派工**之後**新增了一整頁 **P4 Proxy API**。
**它與 `2612b0a` 那三筆是不同性質的自變數**——三筆是**修正既有錯誤**（照做會失敗 → 不會失敗），
新頁是**新增原本不存在的內容**（找不到 → 找得到，於是會去試以前不知道存在的東西、撞到新 bug）。
**歸因 run-05 時兩類要分開算。**

### run-05 該優先打的

1. **#2（`SIM_SERVER_URL` 埠）與 #11（flow entry 回應體）** —— 本輪刻意不修的那兩條，
   run-04 的 tester **獨立撞到了 #2**（SPM 的 `:8003` vs 實際 `:9000`）⇒ **它是真的，不是 run-03 的個案。**
2. **REST API 那條路**（R12 ⑦ 未測）：run-04 完全沒走，所以 #9／#10／#13 這一輪沒有讀數。
3. **`mn --version` 從 2.3.0 變成 2.3.1b4**（`GUEST-STATE.txt`）：run-04 的 `install-p4dev-v8.sh`
   跑完了整支（含 mininet 元件），run-03 沒看到結尾。NDTwin 用的是 §3.2 apt 那份，
   **本輪判準不涉及它** ⇒ 只記錄，run-05 查它會不會造成差異。

### 給 KNOWN-ISSUES 的四件事（本線只陳述後果，裁決留給 auditor）

1. 🔴 **開一條新的：`ndt up` 的失敗路徑漏行程。** 機制、四項證據、時間算術都在
   `VERIFICATION.md` 註 ①。核心是 `stack.sh:67` 的 **`read … || true`** 把
   「orchestrator 中止」與「使用者按了 Enter」變成同一件事，而 `ndt:923-925` 的
   `exec 3>&-` 正好送出那個 EOF。
2. 🔴 **埠檢查那一族是五列的表，不是五個 if。** 本輪這一個（`:6343`）是第四個實例，
   **也是唯一一個被實地觀測到擋住合法操作的**；另一條線獨立找到 `:3005x`／`:6653`／`:6633`／`:9000`
   （本線已在 `tools/test_workflow/ndt` 逐一覆核出現次數：0／0／0／0，`3005` 僅 1 次且在註解裡）。
   **而且「把埠加進清單」修不好它**——`port_open` 是 `/dev/tcp/`、`port_listener_pids` 是 `ss -ltnpH`，
   **兩者都只認 TCP**，而 6343 是 UDP。表要有第四欄：**用什麼原語才看得到它。**
3. **G-6 的定義域不用改**（BUG-6 一字不差落在裡面），但值得補一行本輪的新佐證：
   **在依賴齊備、fabric 已收斂的情況下重現**，以及**連 `.test_run/logs/app_{energy,sim}.log` 都不會產生**。
4. **G-9／`pgrep -f` 那一族要升級口徑**：在今晚之前它是「我們知道它遲早會誤傷」；
   **run-04 是第一次實地重現**（打掉 tester 自己的 shell，ssh exit 255），
   而**手冊在同一頁、兩節之前就逐字警告過不要那樣寫**。
   ⇒ 嚴重度定 **High**（tester 自評 Medium），理由是失效面越過了 NSR 自己起的行程、打到呼叫者，
   而「從腳本／cron／CI 呼叫」是正常用法。

### 給 A-8（prep5，只做 §1–5 不碰 §6）

- A-8 用的是**哪一份 docs 要明寫**。run-04 已證明 `2612b0a` 讓 §1–§5 的手冊 friction 歸零
  ⇒ A-8 若沿用 `2612b0a` 或更後，**§1–§5 不該再出現手冊造成的 friction**；若出現，那是 prep5
  這個起點（複製自既有 VM，不是全新機）帶進來的差異，**正是 A-8 要量的東西**。
- **A-8 不會碰到 BUG-3**：它不跑 §6，但 BUG-3 的觸發條件是 `ndt up ovs` 失敗 ⇒ **會碰到**。
  若 A-8 要跑 `ndt`，請在 `ndt down` 之後**多加一條 `ss -ulnp` 對 `:6343` 的檢查**，
  這是目前唯一能看到它的方法。

[Co-developed with claude code -- Adam]
