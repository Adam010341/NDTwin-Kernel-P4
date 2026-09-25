# NDTwin-Kernel 測試說明書（權威入口，2026-08-17）

**這一份是入口。** 想知道「我現在該跑什麼」，讀這份就夠；其餘七份測試文件是背景、歷史
或深入細節，各自的地位列在最後一節。

**要開機／收機，直接跳 §2**，那是完整的開機手冊。其餘各節刻意保持短——長文件會腐爛得比
它被讀的速度快。§2 之所以是例外，是因為開機的失敗模式沒有一個長得像失敗，短寫等於不寫。
**§2 裡「為什麼」一律收在摺疊區**，跳過摺疊區就能一路照著打完。

**適用範圍**：本 repo（kernel + P4 proxy）。跨元件串接看
`doc/2026-08-14_cross-component-integration-matrix.md`。

[Co-developed with claude code -- Adam]

---

## 1. 依意圖分派

| 我剛做了什麼 | 就跑這個 | 要多久／要什麼 |
|---|---|---|
| **要開機／收機／換拓樸／開 app** | **見 §2（開機手冊）** | `ndt up` 25–40 秒 |
| 改了任何程式碼，還沒 commit | `bash tools/test_workflow/run_layers.sh selftest` | 秒級，完全離線 |
| 改完想確認沒弄壞既有行為 | `bash tools/test_workflow/run_layers.sh quick` | 約 2 分鐘，不需要 Mininet |
| 準備 commit／想跑「CI」 | `bash tools/test_workflow/local_ci.sh` | 實測 234–272 秒，6 個 job（GCC 建置+直跑+ctest、Python L1、ASan+UBSan、TSan、clang、p4 覆蓋閘門）。**不 fail-fast**——一次看完所有壞掉的東西 |
| 只想跑單元測試 | `bash tools/test_workflow/l1_unit_tests.sh` | **ctest 與直跑兩種都跑**——ctest 每個 TEST_F 各自一個 process，跨測試污染只有直跑抓得到 |
| 改了 `.p4` | `tools/test_workflow/p4_coverage_gate.sh` | hash 沒變時 14ms；`--force` 強制實測 |
| 動了資料面／要驗一輪 live | 見 §2、§3 | 要起 fabric |
| 想確認 twin 沒說謊 | 見 §4 | 要起 fabric＋有流量 |

**Python 一律用 `p4_proxy/venv/bin/python`。** conda 的 `python3` 缺 grpc/networkx，壞掉的
套件在它底下看起來是綠的。且本 repo 走 `unittest` 不是 pytest——**看 `Ran N` 不要只看 `OK`**，
`__main__` guard 底下的測試根本不會被收集。

**目前基準線（2026-08-18 重跑，`b62bafe`）**：C++ **588 tests / 80 suites**、`p4_proxy/tests` **453 ran**（另 1 skipped＝`test_p4_client.py` 自己宣告要 live
switch，所以收集到的是 454）、`tests/python` **238**、`tests/shell/test_faults.sh`
**Ran 60 checks**、p4 覆蓋未覆蓋集 `[414..421]` 不變。數字對不上就是有人動了碼或收集壞了。

⚠️ **加測試的 commit 要回來更新這一行。** 本行第一版寫的是 579/78 與 Ran 454，當天稍後就被
`1b1f941`／`13e53df` 追過——於是「數字對不上＝有人動了碼」這句話把讀者指向不存在的問題，
說明書自己變成假警報的來源。

⚠️ **2026-08-18 更新**：`b62bafe`（`setupNFSForApp` 分辨「目錄已存在」與「建不出來」）
加了 3 條測試、1 個 suite，所以是 585/79 → **588/80**。前一版數字量於 `13e53df`。

📌 **通則：實測數字寫進文件時，一律把當時的 commit 標在旁邊**（像上一段的 `13e53df`）。
量測只對產生它的那版程式成立，而程式會動；沒有 commit，讀的人分不出「現況」和「歷史」，
於是過期的數字會被一直當成系統的性質引用。2026-08-17 同一天抓到兩個實例：上面那行活了
幾小時，而「OVS 斷鏈黑洞 291 秒零自癒」在修好它的 `034da18` 落地之後**又被引用了四天、
散進 11 個檔案**（重量結果與完整脈絡見 `doc/audit/2026-08-17_p4-vs-ovs-matched-topology/`）。
兩者寫下的當時都是正確的——標 commit 防不了數字過期，它防的是**下一個人看不出它過期了**。

📌 **同一個道理的第二條：但書要自己帶到期日。** 分支併進 trunk 之後，規格裡「這個還沒好」的
那一段沒有人回來撤（KNOWN-ISSUES **G-52**）。文件不會被編譯，而「修法在某某單」這句話
永遠合文法。2026-09-12 的 sweep 在本檔 §2.1／§2.6 找到四處，其中一處早就被證實是錯的、
卻因為不在當時那張單的範圍裡而又留了兩天——照著那一段讀的人，會把真的紅當成預期中的紅。
慣例有兩種寫法，**用途不同**：

**① `NDT-MERGED-CAVEAT` 標記（本檔專用，給已經被 sweep 過的那一段）**

```
<!-- NDT-MERGED-CAVEAT:BEGIN <id> <merge sha> -->
   …撤回後的文字：🏁 已修／已併入，指名是哪一顆 merge，並把當時量到的東西留在原地…
<!-- NDT-MERGED-CAVEAT:END <id> -->
```

- **什麼時候用**：你把一段「還沒好」的但書改寫成「已經好了」的時候。`<id>` 是這段但書在講
  什麼的短名，`<merge sha>` 是**讓它不再成立的那一顆 merge**。
- **BEGIN 與 END 兩個都要有。** 少了 END，讀標記的程式會一路吃到檔尾，底下每一條斷言
  都對著「大半份文件」通過——變異閘門的 M9 就是這樣活下來過一次。
- **撤回不是刪除**：但書底下的量測（pid、逐字輸出、當時的 rc）要留著。
  「已修」是對今天的宣稱，log 是當時真的發生過的事，兩者不互相取代。

**② 就地撤回（`doc/` 底下每一份 `.md` 都適用，不需要標記）**

一句話說「某某還沒修」或「某個分支還沒併」的時候，**同一個 markdown 段落裡要寫出那顆 merge**：
`已修`／`已併` 加上一顆 sha。段落是單位而不是行——散文會折行，把限定詞折到上一行去。

**誰驗祖先：閘門，每一次跑都重驗。** 不是寫的人記得驗就算數。
`tests/shell/test_manual_no_stale_in_progress.sh` 每次都重問 git：
case 5a–5d 驗標記裡的 sha、case 6／6b 掃本檔、case 11／11b 掃 `doc/` 底下每一份文件
（不含 `doc/audit/`——那裡是證據不是規格，改它讓 lint 過等於篡改證據），
case 11c 確保它真的有東西可掃。sha 要過三關：解得開、是 merge commit（兩個以上的父）、
是 HEAD 的祖先。變異閘門是 `tests/shell/mutate_manual_no_stale_in_progress.sh`。

⚠️ **閘門查「那張單併了沒」靠的是分支名前綴，而分支命名並不一致**（有的帶單號與日期，
有的完全不帶單號）⇒ 它可能**配到別張單的 merge**，也可能**查不到而靜靜放行**。
失敗訊息會把它配到的分支名一起印出來，就是為了讓人看得出配錯。
**寫進文件的那顆 sha 要是人親自查過的那顆，不是閘門猜的那顆。**

---

## 2. 開機手冊

> ✅ **2026-08-21 從乾淨環境實跑驗證過**（`52cba51`）：P4 128 台與 OVS 128 台各一輪，
> 含清空、三個承諾的拒絕、跨象限連通性、收尾與 `clean` 斷言。**實跑推翻了本節初稿的三條**，
> 都已改正並標在原地（§2.1 的 veth、§2.2 的秒數、§2.3 的 `--check`）。
> 逐字輸出：`doc/audit/2026-08-21_bringup-manual-verification/TRANSCRIPT.md`。

**一切都走 `ndt`。** 它是 `tools/test_workflow/ndt`，`~/.local/bin/ndt` 有 symlink，
所以任何目錄下都能打。底層的 `ndtwin-lab` + `stack.sh` 仍然可用（見 §2.9 的摺疊區），
但**不要混用**——`ndt` 記帳、裸指令不記帳，混用就是 §2.10 的第一條。

⚠️ **`ndt help` 把完整 usage 印出來之後 `exit 2`。** 它不是失敗，是「你沒給我一個動詞」的
rc（沒有動詞的 `ndt` 也一樣）。**放進 `set -e` 腳本的那一行會讓整支腳本停在那裡**，
要印用法請自己接 `|| true`。手冊其餘各節的指令都回它們自己的 rc，只有這一個是這樣。
<!-- 來源：ROLE-11 F11，log hunt-0911/logs/ROLE-11/01-ndt-help.log（末行 RC=2）；
     本單在主 checkout 自己再跑過一次，同樣 RC=2
     （logs/gates-0910/ndt-help-spelling.doc1-0912-r1.log）＝🟢 親自跑過。 -->

### 2.0 三十秒版

```bash
ndt status          # 有人在用嗎？現在是什麼狀態？
ndt down            # 清空
ndt up              # 開 OVS 128 台（預設平面是 OVS，等同 ndt up ovs）／ P4 要指名 ndt up p4 …
ndt down            # 收
```

🔴 **裸 `ndt up`、`ndt up 4`、`ndt up 128` 三個都是 OVS。** 預設平面 2026-09-03 由 P4 改成
OVS（Adam），本節先前寫「`ndt up` 開 P4（預設）」是改之前的話。要 P4 一律指名 `ndt up p4 …`，
見 §2.2。
<!-- 來源：F1（ROLE-11 F1 的同一形狀，本單自查擴大）。① 親自讀過：tools/test_workflow/ndt
     的 resolve_up_target（`${1:-ovs}`／`4) up_ovs 4`）與其上方註解「THE DEFAULT PLANE IS OVS
     (Adam, 2026-09-03) ... It was p4 until then」；② 親自跑過：`ndt help` 逐字
     `ndt up  Ryu + OVS, 128 hosts  (the default plane is OVS)`，log
     scratch/overnight-2026-09-05/logs/gates-0910/ndt-help-spelling.doc1-0912-r1.log。
     裸 `ndt up` 本輪沒有人 live 跑過——這一句的證據是 help 與碼，不是 live。 -->

**多人共用的機器，第一步永遠是 `ndt status`。** 擁有者在 `lab` 區塊的 **`claim` 那一行**
（輸出的第二行；第一行是區塊標題 `lab`），長這樣：

```
lab
  claim          yours -- 68m left (until 03:27:18)
```

不必去問別的 session。
<!-- 來源：ROLE-11 F12，log hunt-0911/logs/ROLE-11/02-ndt-status.log（🟠 轉述）。
     先前這裡寫「它第一行就告訴你實驗室現在屬於誰」，而第一行是區塊標題。 -->

---

### 2.1 先清空環境

```bash
ndt down            # 正常收：apps -> kernel/proxy/Ryu -> topo session -> 掃除
ndt clean           # 只驗不動手；怎麼讀它的 exit code 見下面那張表
```

#### `ndt up`／`ndt down`／`ndt clean` 的 exit code

2026-09-12 起這三個動詞**共用一套 rc**：同一個碼在三個動詞裡是同一個意思。
**正本是 `ndt help`**（`up`／`down`／`clean` 三段各印一次），下表是它的中文對照；
**整份手冊只有這一張表**，別處提到 rc 一律指回這裡。

<!-- NDT-RC-TABLE:BEGIN
     正本＝tools/test_workflow/ndt help 的 up／down／clean 三段（FIX-NDT-8 把表放進 help）。
     右欄是從那份輸出抄下來的原句，tests/shell/test_manual_rc_table.sh 會拿它去對真的 help。
     要加行、改字、或在手冊別處再寫一次 rc 之前，先讀那支測試：第二張表就是這次要修的缺陷。 -->

| rc | 意思 | `ndt help` 的原句 |
|---|---|---|
| 0 | 量到了，而且乾淨 | `the teardown finished and the machine verified clean` |
| 1 | 量到了，而且髒 | `something was MEASURED and is still there` |
| 3 | **沒有東西可量**——閒置的機器、已經收掉的 lab | `THERE WAS NOTHING TO JUDGE` |
| 5 | **守衛拒絕，機器一個 byte 都沒動** | `A GUARD REFUSED and nothing was torn down` |
| 2 | 用法錯誤 | `is a usage error` |

<!-- NDT-RC-TABLE:END -->

🔴 **3 不是「乾淨」。** 閒置機器上 `ndt clean` 回 3 並印 `nothing to judge`；已經收掉的 lab
再 `ndt down` 也回 3。09-12 之前這兩種狀態都回 0，於是對腳本而言「拆掉十台 bmv2 並驗證它們
都不在了」與「這台機器上從來沒起過 lab」是同一個 byte。

🔴 **5 是「它沒看」。** lab 被別人 claim、claim 裡宣告了 `measuring=`、有量測在跑、
這個 checkout 的另一個 `ndt down` 還在跑、`NDT_TOPO` 指著另一個網路的 model ⇒ 一律 5，
而且**什麼都沒做**。以前這些混在 1 裡，所以分不出「去看那台機器」與「等那個 teardown」。
兩個條件同時成立時（有 teardown 在跑、又有 port 被佔）答案是 **5**，兩件事都會印出來。

⚠️ **這套 rc 只管 `up`／`down`／`clean` 三個動詞。** `ndt status --check`、`ndt check`、
`ndt apps orphans` 各有自己的表（§2.3、§2.5），**別把碼跨動詞讀**——
`ndt apps orphans` 的 5 是「行程乾淨、但 **rules-in-window** 查不到」，不是「被拒絕」；
判孤兒看 `orphans_verdict.sh` 印的 `VERDICT:`，不看它的 rc。
<!-- 來源：本單親自跑 `bash tools/test_workflow/ndt help` 讀 up／down／clean 三段（親自讀過）。
     契約本身＝FIX-NDT-8（merge `af5efa4f`，2026-09-12），登記在 KNOWN-ISSUES G-53。
     釘在 tests/shell/test_manual_rc_table.sh，變異閘門 tests/shell/mutate_manual_rc_table.sh。
     上一行的 rules-in-window：09-12 改名前這裡寫 residue（G-54b），而 `ndt` 今天對這個 5
     逐字印的是 `NOT CHECKED: the rules-in-window question could not be answered -- rc 5.`
     （tools/test_workflow/ndt:8040，FIX-DOC-5 親自讀檔）。`ndt clean` 輸出裡的 residue
     是另一個意思（行程佔 port），那些沒有改。 -->

`ndt down` 分四步印出來（`[0/3] apps` 只在真的有 app 在跑時出現）：

| 步驟 | 它做什麼 |
|---|---|
| `[0/3] apps` | 停掉 energy / sim / nsr / viz / te |
| `[1/3] kernel + proxy/Ryu` | 停 `.test_run/pids/` 裡登記的行程 |
| `[2/3] topology session` | `ndtwin-lab topo-stop`，關 Mininet |
| `[3/3] sweep` | `mn -c`，收殘留的 veth／namespace |

`ndt clean` 檢查五件事：bmv2 行程數、host/switch 行程數、topo tmux session、
switch manifest、以及 **9 條 port 規則、展開共 27 個 port**。全部過才印綠色 `clean`，
那一行逐字長這樣：

```
ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000
```

**不是只有 :8000／:8080／:8081 三個**（本節先前只寫那三個）：另外六條規則是 Ryu 的 OpenFlow
listener `:6653`／`:6633`、kernel 的 sFlow collector `:6343`（UDP）、bmv2 每台一個的 gRPC
`:30051-30060` 與 Thrift `:9091-9100`（各 10 個）、以及 sim app 的 `:9000`。
正本是 `tools/test_workflow/ports.sh` 的 `NDT_PORT_TABLE`，`clean` 與 `--deep` 讀同一張表。
⇒ **不乾淨的時候輸出不是五行**：每個被佔的 port 各三行（residue／owner／後果），
09-12 那次活著的 fabric 上共 **74 行 `XX`**。
<!-- 來源：ROLE-11 F7，log hunt-0911/logs/ROLE-11/92-clean.log（ok 那行逐字）與 18-clean-live.log
     （74 行 XX）＝🟠 轉述；9 條規則／27 個 port 的展開＝本單親自讀 tools/test_workflow/ports.sh
     的 NDT_PORT_TABLE 數出來的（6 個單埠＋10＋10＋1）。 -->

<!-- NDT-MERGED-CAVEAT:BEGIN clean-calls-your-fabric-residue 1656bdba -->
🏁 **已修（工具的措辭，2026-09-12 merge `1656bdba`，FIX-NDT-6 ④）：在你自己**活著的** fabric 上跑
`ndt clean`，它曾經把你這一輪的行程列成 residue，並在清單末尾一律建議 `ndt down --deep`。**
現在它走一次 port 表，對每個被佔的 port 先問兩個紀錄——`.test_run/pids/` 與 switch manifest——
答得出來的印在 `the fabric this stack started is still up. Take it down with:  ndt down` 底下、
逐個標明是哪一個紀錄認的；**只有兩個紀錄都不認的 port** 才會拿到 `--deep` 那一句。
登記在 KNOWN-ISSUES G-44／G-45。
fabric 活著時 `ndt clean` 回 rc 1 是正常的（就是上面那張表的 **1＝量到了，而且髒**），
要收請用 `ndt down`；`--deep` 是會殺別人行程的動詞。細節與逐字輸出見下面的摺疊區。
<!-- 來源：merge `1656bdba` 是不是 HEAD 的祖先＝本單 `git merge-base --is-ancestor` 親驗；
     `the fabric this stack started is still up` 那句與兩個紀錄的問法＝本單親自讀
     tools/test_workflow/ndt 的 cmd_clean（mine／strangers 兩個陣列）。
     🟠 轉述 KNOWN-ISSUES G-45 與 fix/FIX-NDT-6-SUMMARY.md §1.4：本單沒有開 lab 重跑 `ndt clean`。 -->
<!-- NDT-MERGED-CAVEAT:END clean-calls-your-fabric-residue -->

<details><summary>什麼時候需要 <code>ndt down --deep</code></summary>

`ndt down` **預設不碰不是它起的東西**。所以如果有人手動跑了一顆 kernel、或上一個
session 的殘骸還佔著 :8000，`down` 會**報告它、然後放著不動**：

```
XX  :8000 still listening -- this stack did not start it
```

這是刻意的：`--deep` 會殺掉佔住**那 27 個 port**（＝上面 `clean` 檢查的同一張表）的任何行程，
而那可能是別人正在用的東西。確定機器是你的，才加 `--deep`。

<!-- NDT-MERGED-CAVEAT:BEGIN help-deep-names-three-ports 1656bdba -->
🏁 **已修（2026-09-12 merge `1656bdba`，FIX-NDT-6 ⑤）：`ndt help` 的 `down` 段落曾經寫
「`--deep` also kills whatever still holds :8000/:8080/:8081」，那是三個 port 時代的話。**
它現在印的是 `--deep also kills whatever still holds ANY port in ports.sh's table -- 9 rule(s), 27 port(s) --`，
下一行把整張表展開成 `8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000`。
**那兩個數字是 `ndt` 自己從 `ports.sh` 算出來的，不是打進散文裡的**，所以它們不會再各自過期；
手冊與 `ndt help` 現在講同一件事，要對數字看 `ndt help`。登記在 KNOWN-ISSUES G-46。
<!-- 來源：`ndt help` 現在那兩行逐字＝本單自己跑 `ndt help` 讀到的
     （logs/gates-0910/ndt-help-verbatim.doc4-0912-r1.log，rc 2）；deep_sweep 與 cmd_clean 讀
     ports.sh 同一張表＝FIX-DOC-1 親讀、本單只對帳；merge 是不是 HEAD 的祖先＝本單親驗。 -->
<!-- NDT-MERGED-CAVEAT:END help-deep-names-three-ports -->

<!-- NDT-MERGED-CAVEAT:BEGIN clean-advises-deep-on-your-own 1656bdba -->
🏁 **已修（2026-09-12 merge `1656bdba`，FIX-NDT-6 ④）：那句「this stack did not start it」
曾經蓋到這個 stack 自己登記的行程。**
**修之前**的 09-12 實測：`ndt up p4 4` 起完約 30 秒跑 `ndt clean`，輸出 **74 行 `XX`**，頭兩筆是

```
XX  residue: ndtwin_kernel pid 2511227 holding :8000 (tcp)
XX  residue: python pid 2510886 holding :8081 (tcp)
```

而同一分鐘的 `ndt status --check` 逐字印
`kernel.child.pid=2511227 alive,kernel.pid=2511223 alive,p4_proxy.child.pid=2510886 alive,…`
——這兩個 pid 正是 `.test_run/pids/` 登記在案的。清單**末尾**那一行總結
`XX     this stack did not start it; to kill it too:  ndt down --deep`
因此涵蓋了自己人。**第一次用的人照著加 `--deep`，殺掉的是自己剛起的 fabric。**
修法（`1656bdba` 起）：`cmd_clean` 走一次 port 表，對每個被佔的 port 問 `.test_run/pids/` 與
switch manifest 兩個紀錄；答得出來的印在 `the fabric this stack started is still up` 底下，
**只有兩個紀錄都不認的**才留給 `this stack did not start it; to kill it too:  ndt down --deep`。
那一句刻意留著：一顆別人起的 kernel 佔著 :8000，正是一個 P4 session 量到 OVS kernel 的來源，
把它拿掉會是同一個缺陷把號誌反過來。判「這是不是我的」現在看 `ndt clean` 自己印的那兩塊，
`ndt status` 的 `pidfiles` 欄仍然可以對帳。
<!-- 來源：ROLE-11 F5，log hunt-0911/logs/ROLE-11/18-clean-live.log（74 行 XX、末行的 --deep 建議）
     與 16-check-p4.log（pidfiles 欄）。🟠 轉述（ROLE-11 log）。修法的兩塊輸出與「刻意留著」
     的理由＝本單親自讀 tools/test_workflow/ndt 的 cmd_clean；merge 是不是 HEAD 的祖先＝本單親驗。 -->
<!-- NDT-MERGED-CAVEAT:END clean-advises-deep-on-your-own -->

`--deep` 自己也有兩道保險：不對 pid < 2 動手、不殺 `ndt` 自己；而如果 port 的持有者
查不出 pid（例如在別的 netns 裡），它會明說 `--deep cannot address it` 而不是假裝成功。
</details>

⚠️ **`ndt clean` 不看 veth / OVS bridge / netns / `tc netem` / `.test_run/`。**
正常路徑上 `[3/3] sweep` 的 `mn -c` 會清掉它們，但 `clean` **不斷言**它們。
做完故障注入（`faults.sh`）之後，要自己確認 `tc qdisc show` 是乾淨的——
`ndt status` 的 `tc netem` 那行會告訴你。

⚠️ **這台機器上永遠有 4 條 veth，它們不是殘留。**（2026-08-21 實測更正：本節初稿寫
「實測 0/0/0/0」，那是錯的。）三條掛在 `br-634fc31085ec`、一條掛在 `docker0`，
屬於 Docker 容器（Web-GUI 那組 `ndt-frontend` :3000 / `ndt-node-positions-api` :3001 /
`ndt-postgres` :5433，加一個 hugo 容器）。**數 veth 判斷乾不乾淨要扣掉這 4 條**，
或者只數名字像 `s1-eth1` 的那些。netem 和 OVS bridge 收乾淨後確實是 0/0。

---

### 2.2 開 bmv2 / OVS

**兩種 fabric 不能同時開**（`s1..s10` 介面名會撞）。`ndt up` 會自己擋下來，
但先 `ndt down` 比較快。

⚠️ **`ndt up` 只能在 helper 的那棵樹裡跑；從 worktree 跑會被拒絕。**
`sudo ndtwin-lab` 的 `KERNEL_DIR` 是**寫死的常數**（＝主 checkout，而且刻意不吃環境變數：
root 執行那支 `.py`），`ndt` 的 `$REPO` 卻是它自己所在的樹 ⇒ 從 worktree 跑一次 `up`
就是**fabric 用主 checkout、kernel 與 proxy 用 worktree**，兩棵樹、兩個 `host_count_override`。
09-10 實測：`ndt up p4 128` 從 worktree 起了一個 **4 台**的 fabric（主 checkout 的旋鈕）配
**128 台**的 kernel／proxy，fabric、proxy、16256 條路徑全部走完、結構檢查全綠，
只有 `[3/3]` 一行 `model/fabric mismatch` ——而那行講的是數字，一個字都沒提到第二棵樹。
現在 `preflight` **在動任何東西之前**比 `$REPO` 與 helper 的 `KERNEL_DIR`：不同就 **rc 1、
什麼都不起**，訊息裡有兩個路徑、兩棵樹各自的 `host_count_override`，和兩條出路——
去那棵樹跑，或由 root 用 `/etc/ndtwin-lab.conf` 把 lab 指過來（**它只認一棵樹**，
所以兩個 worktree 不可能同時 live）。
同時 `ndt up` 不再把 `topo-start` 印的 `topo session started from <KERNEL_DIR>` 丟進
`/dev/null`：**兩棵樹相同時，那一行就是「這次用了哪棵樹」的唯一證據**。

#### P4／bmv2　（實測 33.6 秒 @128 hosts，`52cba51`）

```bash
ndt up p4           # 用現在的 host 數（見 ndt status 的 `p4 host knob` 欄）
ndt up p4 4         # 4 hosts（會把 host_count_override 改寫成 4）
ndt up p4 128       # 128 hosts
```

📌 **4 台 P4 的唯一寫法就是 `ndt up p4 4`。** 09-12 之前本手冊沒有任何一行給得出它
（`ndt up 4` 是 OVS），照手冊做的人做不出 4 台的 P4 twin。實跑 14 秒、rc 0，
`[3/3]` 印 `model matches fabric: 4 hosts`。
<!-- 來源：ROLE-11 F2（缺步驟）與其繞法，log hunt-0911/logs/ROLE-11/15-up-p4-4.log
     （🟠 轉述：ROLE-11 的實跑輸出）。拼法出自 `ndt help` 的
     `ndt up p4 4       p4 at 4 hosts   (rewrites host_count_override)`，本單親自核對
     （logs/gates-0910/ndt-help-spelling.doc1-0912-r1.log）。 -->

🔴 **P4 一定要指名 `p4`。** 本節先前把 `ndt up`／`ndt up 4` 列在這個標題底下，**那兩個都是 OVS**
（預設平面 2026-09-03 改成 OVS）：09-12 實跑 `ndt up 4`，工具第一行就回 `ndt up ovs4`、載
`StaticNetworkTopologyOVS_10Switches_4Hosts.json`、走 OVS 的 `[1/4] control plane (Ryu)`。
兩個平面的驗收判準是相反的（§2.3），所以拿錯平面的人下一步連紅綠都讀反。
<!-- 來源：ROLE-11 F1，log hunt-0911/logs/ROLE-11/04-ndt-up-4.log（🟠 轉述：ROLE-11 的實跑輸出）。
     指令拼法另由本單在主 checkout 以 `ndt help` 親自核對，log
     scratch/overnight-2026-09-05/logs/gates-0910/ndt-help-spelling.doc1-0912-r1.log。 -->

三步：`[1/3] bmv2 fabric` → `[2/3] proxy + kernel` → `[3/3] verify`。

#### OVS／Ryu　（實測 24.1 秒 @128 hosts，`52cba51`）

```bash
ndt up ovs          # 128 hosts（NTG 自帶的 testbed_topo.py）
ndt up ovs4         # 4 hosts（P4 測試床的佈局搬到 OVS 上）
ndt up              # ＝ ndt up ovs（128）
ndt up 128          # ＝ ndt up ovs
ndt up 4            # ＝ ndt up ovs4　🔴 它不是 P4
```

四步：`[1/4] control plane (Ryu)` → `[2/4] data plane (OVS fabric)` →
`[3/4] proxy-less convergence + kernel` → `[4/4] verify`。

⚠️ **OVS 只有 4 和 128 兩個尺寸，而且不是參數。** `ndt up ovs 16` 會被直接拒絕
（rc=2）。原因是尺寸由「跑哪個動詞」決定：`ovs-topo-start` 是別的 repo 寫死的 128、
`ovs-topo-4host` 是我們的 4，兩支都不吃 host 數。2026-08-21 之前 `ndt up ovs 16`
會**蓋一個 128 台的 fabric、載一份 16 台的模型，然後回報「model matches fabric」**。
要 16 台就用 `ndt up p4 16`。

<details><summary>為什麼兩種 fabric 的啟動順序是相反的</summary>

**南向連線的方向相反：**

- **OVS**：Ryu 是 server，switch 撥出去找它 ⇒ **Ryu 必須先聽好**，Mininet 才能起。
- **P4**：bmv2 是 server（`simple_switch_grpc` 聽 `0.0.0.0:30051-30060`），proxy 是
  gRPC **client** ⇒ **Mininet 必須先起**，否則 proxy 第一個 RPC 就 ECONNREFUSED，
  uvicorn 在開 :8081 之前就退出。

把兩者都當成「控制平面先起」就是以前 P4 模式壞掉的原因。`ndt up` 已經把順序寫死了，
這段是給要看底層或除錯的人。
</details>

<details><summary>關於 6653 / 6633：一條流傳很久的假警告（2026-08-21 更正）</summary>

**舊說法**：「Ryu 一定要聽 6653；照官方文件加 `--ofp-tcp-listen-port 6633`，
switch 仍去敲 6653，永遠連不上。」

**這是錯的。** `mininet/node.py` 的 `RemoteController.checkListening`：

```python
for port in 6653, 6633:
    if self.isListening( self.ip, port ):
        self.port = port; break
```

**兩個都探，誰應答就連誰**；只有兩個都沒人應才 fallback 成 6653。所以帶了
`--ofp-tcp-listen-port 6633` 的 Ryu，switch 探 6653 沒人、探 6633 有人 ⇒ **連 6633，通**。
三臂 live 實測（08-21，128-host）：帶旗標 10/10 connected、不帶旗標 10/10 connected、
照官方文件逐字 10 switches / 32 links。

**真正的失敗模式是順序，不是埠號**：Ryu 兩個埠都還沒聽的時候起 Mininet，
探測全滅 → fallback 6653 → switch 對著死埠撥，**而且任何 log 都不會提到 port**，
你只會看到拓撲永不收斂。

🔴 同一條假警告還躺在另外兩個地方，都還沒改：`tools/test_workflow/stack.sh:660-669`
的註解、以及 `doc/2026-08-16_delivery-package/docs-errata.md` 的第 1 條。
**那份勘誤在轉交給 patty 之前必須把第 1 條刪掉**，否則會去「修」一份本來就對的官方文件。
</details>

⚠️ **官方手冊（ndtwin.org/docs）仍有一處與本機不符**：`sudo ./testbed_topo.py` 會走到
`/usr/bin/python3`（缺 `nornir`/`loguru`，立刻 ImportError）。要用 ntg-env 的直譯器，
或直接讓 `ndt up ovs` 去起。

**Port 佈局**：kernel API **:8000**、P4 proxy **:8081**、Ryu **:8080**。
任何寫「kernel :8080」的舊筆記都是錯的。

---

### 2.3 確認真的開起來了

```bash
ndt status --check      # exit 非零 = 有東西會讓量測不可信
```

`ndt up` 的最後一步（`verify`）**已經送過真的封包**了——`mnexec -a <host-pid> ping`。
這一步存在的理由：**拓樸畫面十台全綠、網路完全不通，發生過兩次**，只有送封包抓得到。

🔴 **在 OVS 上 `--check` 永遠回 rc=1，而且那是假警報。**（2026-08-21 實測更正，
本節初稿把 `--check` 當成 OVS 的驗收關卡，那是錯的。）它會說：

```
network health
  links          288 total, 256 down, 0 admin-disabled
check: 1 problem(s)
  - 256 link(s) are down
```

**網路是好的**——同一輪的 h1→h64、h64→h128、h128→h1 全部 0% 掉包。
把 kernel 的圖逐條分類之後（不是靠 288−32=256 這種算術湊出來的）：

| 邊 | 數量 | `is_up` | `is_enabled` |
|---|---:|---|---|
| switch ↔ **host**（`dst_dpid=0`，例如 `dpid 1:3 → 10.0.0.1`） | **256** | `False` | `False` |
| switch ↔ switch（例如 `dpid 1:1 → dpid 5`） | 32 | `True` | `True` |

128 hosts × 2 = 256。**OVS 平面在 128 台上從來不把 host 邊標成 up**，而 P4 平面會
（同一天的 P4 輪：`288 total, 0 down`）。實測到 4 分鐘都沒動（`32 up / 256 down / 0 hosts up`
每 15 秒取樣一次），所以不是「還沒收斂」。

🔴 **上面那個「從來不」只在 128 台成立。** 09-12 的 `ndt up ovs4` 實測
`links 40 total, 0 down`，而那份模型裡有 **8 條** host 邊 ⇒ 4 台的 OVS 輪裡 host 邊是 up 的。
**兩個量測的尺寸不同，機制（Ryu 的 `ipv4` 空不空）在 4 台上沒有重新量過**，
所以不要拿下面那段解釋去推 4 台會怎樣，也不要拿 4 台的結果去推翻 128 台的紀錄。
<!-- 來源：ROLE-11 F4，log hunt-0911/logs/ROLE-11/05-check-after-up.log（🟠 轉述）；
     8 條 host 邊＝本單親自讀 setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json 數出來的。
     為什麼 4 台會 up、128 台不會，尚未查 ⇒ 已列進 FIX-DOC-1 SUMMARY §7。 -->

<details><summary>為什麼——不是設計決定，是資料對不上</summary>

邊的狀態不在模型檔裡。模型檔只有接線（`src_dpid`／`src_interface`／…），
`loadStaticTopologyFromFile` 把**每一條邊都設成 `isUp=false, isEnabled=false`**
（`TopologyAndFlowMonitor.cpp:318`），之後只有控制平面回報得到的才會被標 up。

host 邊是靠 `/v1.0/topology/hosts` 標的——一台 host 一條邊，**用 IP 去找**
（`findEdgeByHostIp`）。而在那之前有一道門：

```cpp
// TopologyAndFlowMonitor.cpp:618
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "Skipping host with no IPv4 address");
    continue;                      // ← 跳過，下面標 up 的兩行不會執行
}
```

**Ryu 回報了 128 台，但每一台的 `ipv4` 都是空陣列**（實測，剛開機時與 60 秒後都一樣）：

```json
{ "mac": "00:00:00:00:00:72", "ipv4": [], "ipv6": ["::", "fe80::200:ff:fe00:72"],
  "port": { "dpid": "0000000000000004", "name": "s4-eth20" } }
```

有 IPv6 沒有 IPv4。**而且灌真流量也不會變**——h1 對 10.0.0.2 與 10.0.0.64 各 ping 三次
全通之後再問，仍然是 128 台、0 台有 ipv4。所以不是「還沒學到」。

P4 那邊沒有這個問題，因為 **proxy 不用學、它直接從自己的模型 render**
（`ryu_topology.render_hosts`），128 台全部帶著 IP 出場 ⇒ 256 條邊全部標 up。

⇒ **兩個平面的差別不是「有人決定不標 host 邊」，是 Ryu 用學的、proxy 用宣告的。**

🔴 **Ryu 為什麼學不到 IPv4，還沒有結論。** 合理的懷疑是測試床設了 static ARP、
於是 host 從不送 ARP，而 Ryu 的 host tracker 正是從 ARP 取 IPv4 的（IPv6 走 NDP，
所以那一欄有值）。**但這個說法在 2026-08-11 被查過並否決**，而且當時的紀錄是
「128/128 都有 IP」——**跟今天的 0/128 直接矛盾**。兩個量測不可能都對，
中間有東西變了或條件不同，沒查清楚之前不要引用任何一邊當機制。
</details>

所以（**判準跟尺寸走，不是只跟平面走**）：

- **P4**：`ndt status --check` 回 rc=0 才算過。（09-12 `ndt up p4 4` 實測 rc **0**、`check: ok`。）
- **OVS 128 台**：`--check` 一定 rc=1。**看它列出來的問題是不是只有「256 link(s) are down」**——
  只有這一條就是正常的；多出任何別的才要查。
- 🆕 **OVS 4 台（`ndt up ovs4`／`ndt up 4`）：一條 link 都不該 down。** 09-12 實測
  `links          40 total, 0 down, 0 admin-disabled`（模型宣告 40 條邊，其中 8 條是 host 邊）
  ⇒ 上一行那句「只有 256 link(s) are down 才正常」在這個尺寸上**一條都不適用**。
  那一輪 rc 確實是 1，唯一的 problem 是
  `the network carries app residue: 60 rule(s) installed inside an app's window`
  （**那是 09-12 改名前的字**，現在同一件事印 `rules-in-window: N rule(s) …`）——
  🔴 **而那 60 條就是這一輪 ovs4 自己剛裝好的轉送規則**，被一個 **stale 的 `app_viz.pid`**
  框了進去：viz 於 09-11 14:05:43 自己跑完退出、沒有人跑過 `ndt apps stop viz`，pidfile 就留在
  `.test_run/pids/`；pid 死掉之後 `ndt` 改拿**那個 pidfile 的 mtime** 當開窗時刻，而且**右端開口到
  `now`** ⇒ 一個 12.3 小時的窗，把之後任何人裝的規則整碗算進去。工具自己的話逐字：
  `anything installed in that window is listed, whoever installed it`。
  🆕 **09-12 修掉了（FIX-NDT-9 ①，Adam 12:3x 裁）**：pid 已死的 pidfile 開的窗，**右端封在該 app
  自己 log 的 mtime**（viz 這例＝`14:05:43`）⇒ 那 60 條落在窗外。沒有可用的 log（`energy` 在任何
  機器上都沒有 log 管道；log 比 pidfile 還舊也算）⇒ **零長視窗**，報告會明說
  `the window has NO extent … NOT 'this app left nothing'`——**那是「沒有東西可以歸屬」，不是「乾淨」**。
  pid 活著的窗照舊開到 `now`。
  🆕 **09-25 起 `ndt down` 會清掉那個 pidfile**（Adam 09-25 裁，TICKET-ndt-ovs-claim）：pid 不在
  （或活著但不是那個 app、或那個行程比 pidfile 晚啟動＝號碼被回收），**而且**記錄的 process group
  也沒有程序 ⇒ **stale**。`down` 先把那個窗（起點＝pidfile 的 mtime、右端＝上面封住的那一端）寫進
  `.test_run/apps/<app>.window` 再刪檔——**窗寫不進去就不刪、`down` 回 1**；之後的報告從那份紀錄讀
  同一個窗，零長的窗照樣印上面那句 `NO extent`。lab 已經 down、只剩 stale 檔時 `down` 回 **3**。
  `ndt status` 在 apps 區塊把它標成 `app pidfile  STALE -- …`（**只是標記，不讓 `--check` 變紅**）。
  ⇒ **在下一次 `ndt down` 之前**，OVS 上 `--check` 會不會因為 rules-in-window 變紅，取決於
  `.test_run/pids/` 裡那個 stale `app_*.pid` 的 app 在窗內有沒有真的裝東西，跟 ovs4 這個尺寸無關。
  看到這條 problem，先去問 `.test_run/pids/app_*.pid` 指的行程還活不活（`ndt status` 的
  `app pidfile` 列、`ndt apps orphans` 會把窗的起迄印出來），不要先去找誰在網路上留了東西。
  本輪沒有在乾淨機器上觀測過 ovs4 的 `--check`，所以**不宣稱**它會回 rc 0：
  ovs4 的 `--check` 要自己看 problems 那幾行，不要拿 128 台那條規則套。
<!-- 來源：links 那組數字＝ROLE-11 F4，log hunt-0911/logs/ROLE-11/05-check-after-up.log（ovs4，
     🟠 轉述）、16-check-p4.log（p4 4，rc 0）；40 條邊裡 8 條是 host 邊＝親自讀
     setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json 數出來的（dpid 0 兩端共 8 筆）。
     🔴 那 60 條的來源＝RESIDUE-1 唯讀調查（hunt-0911/RESIDUE-1-REPORT.md §1 時間線、§2 機制）。
     本段先前寫「那 60 條在該輪第一個 ndt up 之前就在了、來源未追 ⇒ 不是 ovs4 的性質」，那是錯的：
     它把基線那一列的 `residue NOT CHECKED -- :8000 is closed` 讀成了「查過沒事」。反證＝R7 的
     3 秒取樣器（第三方）量到 `list-br` 在 02:20:28 才 0→10，而 60 在 02:20:45 第一次被量到；
     同型 ovs4 在 09-11 的三輪都是 0 條 dated。窗來自 app_viz.pid（mtime 09-11 14:04:25，
     pid 463161 已死）。修法三選項與「要不要清掉那個 pidfile」在 RESIDUE-1 §7，待 Adam。 -->

🆕 **2026-09-07 起 `--check` 多一列 `rules-in-window`**（G-12／W16-2；**09-12 之前這一列叫
`residue`**，Adam 12:3x 改名——`residue` 這個字在 `ndt` 裡同時是 `ndt clean` 的
`XX residue: <proc> holding :<port>`，那是**行程佔 port**、`ndt down` 收得掉的，跟這一列的
**流表規則**不是同一件事，而這裡什麼都不刪）：它會去問「有沒有 app
留在網路上的東西」——某個 app 的時間窗內裝的流表規則、還握著的鎖。判準因此多了一條：

| `rules-in-window` 那一列說 | 意思 | 對 rc 的影響 |
|---|---|---|
| `none` | 問過了，沒有 | 無 |
| `N rule(s) inside an app window, M lock(s) HELD` | **有殘留** | **算一個 problem ⇒ rc 1** |
| `NOT CHECKED: ...` | **沒問到**（kernel 沒起來／讀不到流表／這個平面分不了窗） | 不算 problem |

🔴 `NOT CHECKED` **不等於乾淨**。**P4 平面上只要有 app 在「這個 checkout」留下窗，
就是 `NOT CHECKED`**：它的流表統計是 proxy 合成的，`duration_sec`／`duration_nsec` 恆 0
（2026-09-07 實測），沒有時間軸就分不出窗。
它不算 problem 的唯一理由就是上面那一行「P4 rc=0 才算過」——一個永遠過不了的閘門
沒有人會看。**鎖在 P4 上還是查得到的**，所以 P4 上握著的鎖照樣讓 `--check` 變紅。
細節用 `ndt apps orphans` 看（它會把每一條列出來，一條都不刪）。

⚠️ **09-07 更正（先前這裡寫「P4 平面永遠是 `NOT CHECKED`」，實跑推翻）**：**沒有任何窗的時候
它印 `none`，`ndt apps orphans` 回 0**——`0 dated rule(s) in a window, 0 lock(s) held,
0 could not be dated, 0 not answerable`＋`(no app had a datable window in this run)`。
🔴 **那個 `none`／0 是「沒東西可定年」，不是「網路乾淨」：一條規則都沒被問過。**
窗來自**這個 checkout** 的 app pidfile／log，所以別的 checkout（例如主 checkout）跑過的 app
留下的規則，在這裡永遠沒有窗、永遠不會被查。
〔實跑：`rounds/08-round2.md:157-172` 乾淨 P4 ⇒ 0；`:174-193` 在同一個 checkout 起過一次 app ⇒ 5。〕
🆕 **09-07 修好了（3-51／G-14）：`energy` 與 `sim` 現在跟其他三個 app 一樣有窗。**
先前它們是 helper（`sudo ndtwin-lab <name>-start`）起的、`ndt` 不寫 pidfile ⇒ 永遠沒窗。
現在 `ndt apps start energy|sim` 起完、**確認活行程之後**把那個 pid 寫進
`.test_run/pids/app_<name>.pid`；沒有 pidfile 時 `app_started_at` 還會退一步問活行程的
`ps -o etimes=`。所以：

- **在這個 checkout 用 `ndt apps start` 起的 sim／energy，`orphans`／`--check` 看得到它的窗**；
- `ndt apps stop` 驗證停掉之後**會把 pidfile 刪掉**（窗才會關；否則每次 `--check` 都會把
  之後裝的每一條規則算成殘留）。**同一個指令自己印的殘留報告仍然有窗**——窗是在停之前讀的。
- **「跑過沒」現在看 helper 那棵樹的 log**：`sim` 是
  `<helper 的 KERNEL_DIR>/.test_run/logs/app_sim.log`（預設主 checkout；
  `/etc/ndtwin-lab.conf` 可改，`ndt` 唯讀地照 helper 同一套信任規則解析），**不是這個 worktree 的**。
- 🔴 **`energy` 例外：helper 不給它留任何 disk log**（沒有 `script -f`），所以
  「它在這裡跑過沒」**沒有任何管道可以問**。報告會明說 `CANNOT BE ASKED`，
  `--check` 的 `rules-in-window` 列會多印一行「N app(s) could not be asked whether they ran here」。
  **這一條不算 problem、不會讓 rc 變 1**（沒有人能對它做任何事，永遠紅的閘門沒人看），
  但也**不會被寫成「沒跑過」**——「查不了」跟「查了沒事」在這份輸出裡長得不一樣。
- 🔴 **上面那句「別的 checkout 跑過的 app 在這裡永遠沒有窗」對 `sim` 要改口**：窗確實還是只來自
  這個 checkout，**但「它跑過沒」現在是全機器的問題**——helper 的 `KERNEL_DIR` 裡
  `app_sim.log` 非空、而這裡沒有 sim 的 pidfile ⇒ 判定是「**window is LOST**」⇒ `orphans`／
  `--check` 的 rules-in-window 是 **rc 5（NOT CHECKED）**，不是 0。報告會印 `(log read: <路徑>)`，
  **看到 5 先看那一行是哪個檔**。要讓它回到 0 只能清掉那個 log，而**那個檔是 root 的**。
  🆕 **09-08（3-51c）起 `ndt` 自己會講，但它清不掉**：在**主 checkout** 上
  `ndt apps trim sim` 印 `cannot truncate <path>: owned by root (helper wrote it); ask the
  operator to 'sudo truncate -s0 <path>'`、rc 1（也不再留一個沒用的 `<log>.tail`），
  `ndt apps status` 多一句 `log is root's (<path>); trim needs sudo`。
  **在 worktree 裡 `apps trim` 連那條路徑都碰不到**（它走這個 checkout 的 `app_logfile`），
  所以那裡什麼都不會說——要清就自己下那道 `sudo truncate -s0`。
- 🆕 **09-08（3-51c）：`ndt apps orphans` 多一個回 2 的情形，而 2 不是「有孤兒」也不是「乾淨」。**
  helper 起的 sim 是 root 行程，它的 `/proc/<pid>/fd` 這個使用者讀不到 ⇒ 找「誰持有 app log 的
  可寫 fd」那條通道對它是**盲的**（以前盲的時候輸出跟「找了、沒有」一模一樣）。現在會印
  `no untracked app processes found, but a channel was blind: … fd channel: CANNOT READ
  /proc/<pid>/fd (root process) -- not checked`，rc 2。**照抄那一行進報告。**
  〔這一格只有單元測試，還沒 live 驗過。〕

#### Known count under a helper-started sim（helper 起著 sim 時的已知計數）

🆕 **09-08 Adam 裁：接受、登記。** 零改碼——**判準沒有變，變的是情形**。這一段是給
「看到 2 想知道自己是不是踩到新東西」的人看的。

- **什麼情境回 2**：在**主 checkout** 上、**`sim` 由 helper 起著還沒停**的時候跑
  `ndt apps orphans`（`ndt status --check` 的同一條路也一樣）⇒ **rc 2**，以前是 rc 0。
  worktree 裡不會（那裡沒有這個 sim 的 pidfile，走的是另一格）；sim 沒在跑時也不會。
- **為什麼**：helper 起的 sim 是**兩層 root 行程**（`script -qfa <log> -c …` ＋它 exec 的程式）。
  行程組通道找得到那個 root wrapper，但它會被 `APP_LIVE_PIDS` 相減成「有人在追蹤」
  ⇒ `found == 0`；而第三條通道（誰持有 app log 的可寫 fd）要讀 `/proc/<pid>/fd`，
  root 行程的那個目錄是 0500 ⇒ 這個使用者**讀不到、也就不能宣稱看過**
  （`tools/test_workflow/ndt:3790` 的 `app_fd_blindness`，`:3914-3918` 併進 `APP_SURVIVOR_BLIND`）。
  `found == 0` ＋有一條通道是盲的 ⇒ **依既有判準**回 2（`ndt:5482-5489`；
  `found > 0` ⇒ 1、乾淨且每條通道都看得成 ⇒ 0）。合 E-7 的口徑：**查不了不准長得像查過了**。
- 🔑 **那個 2 不是新的孤兒**：機器上**沒有多出任何一個沒人追蹤的行程**。2 的意思是
  「**這一輪有一條通道沒能回答**」，不是「有殘留」。那個 root wrapper 正是 pidfile 記著的
  那個 pid——3-51 的 lw351 補丁已經把它從孤兒名單裡減掉了（見 G-14）。
- ⚠️ **把 `orphans` 的 rc 當閘門的呼叫者**：09-05 夜巡的 `arm_down.sh` 是已知的一個
  （restore check 2/3，`c2` 要 0 才印 `RESTORE-OK`，非 0 ⇒ `RESTORE-FAIL`）。
  **它碰不到這一格**：它在 `ndt down` 之後才跑，那時沒有 sim 在跑。
  🔴 那支腳本在 `scratch/`，**不在版控**。**新寫的閘門一律要看得懂 0／1／2／4／5**——
  尤其**不要把「非 0」讀成「有殘留」**：2 是「沒問完」、5 是「窗掉了、沒問」。
  🆕 **09-10 Adam 裁：讀 tally 行，不要讀 rc。** rc 在一個合併視窗裡對同一個狀態位移了兩次
  （乾淨 OVS4 `0 → 5`、P4 起著 sim `5 → 2`，R4-LIVE §4-A7／§4-A9）。**閘門不要自己 parse**：
  `bash tools/test_workflow/orphans_verdict.sh <orphans 的完整輸出> [rc]`
  給你 `processes=` ／ `network=<窗內規則>/<鎖>/<定不了年的>` ／ `not_answerable=`，
  乾淨＝`processes=clean` 且前兩個數字是 0；**`not_answerable`＞0 與「定不了年」＞0 是 NOTE 不是 FAIL**。
  沒有 tally 行 ⇒ 它回 rc 2 `UNUSABLE`，**不准當成過**。規格：`tests/shell/test_orphans_verdict.sh`。
  🆕 **09-11 例外只有一個：`ndt down` 之後。** `ndt down` 關掉 `:8000`，`residue_report`
  （`ndt:5415`）就會印 `the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked.`
  然後**在印 tally 之前 return**——所以收工那一道問到的報告本來就沒有 tally 行。
  報告裡有那句 ⇒ helper 進 **kernel-down 模式**：印 `network=n/a`、`not_answerable=n/a`、
  `NOTE: network half not checkable: kernel down`（底下引 `ndt` 自己那兩句），
  **VERDICT 由行程那半決定**（它讀 pidfile／`/proc`／argv，不讀 `:8000`，down 之後仍然是答案；
  有 untracked 行程照樣 NOT CLEAN）。**沒有那句 ⇒ 照舊 UNUSABLE**：沒有 tally 還有另外兩個成因
  （殘留那半中途死掉、舊版 `ndt` 的 `orphans` 根本沒有網路那半），而**舊版那個一行形報告
  kernel 開著關著長得一模一樣**（`logs/*-04-orphans.log` 8 份是開著的）⇒ 光看「沒有 tally」
  分不出來，所以判準是**那句話**不是那個缺口。**網路那半要有答案就在 `ndt down` 之前問。**
  🆕 **09-11 另加一個 rc：3 `NOT CHECKED`。** 上面那句「前兩個數字是 0 就算乾淨」有一個地板，
  09-11 才補上（F-OFFLINE-1 §1.11 離線實測）：**kernel 開著、tally 有印、而三個 lock probe
  全部回 `NOT CHECKED (http 500)`** 的報告，helper 原本印 `VERDICT: CLEAN` rc 0，
  而 `ndt` 自己對同一份觀測回 5（`residue_verdict`，`ndt:5349`）。那三個 0 **不是量到 0**，
  是計數器（`ndt:5405-5409`）從來沒被加過——`0 lock(s) held` 在三個 probe 都失敗之後不是測量值。
  ⇒ 現在的判準是：**網路那半至少要有一個正面答覆**（`lock <t> free`／`lock <t> HELD`／
  `no flow entry arrived during that window`／`rule(s) listed:` 之一）才可能 CLEAN；
  **kernel 開著而一個都沒有 ⇒ rc 3、印 `VERDICT: NOT CHECKED`**（不是 CLEAN 也不是 NOT CLEAN：
  什麼都沒找到是因為什麼都沒問到，補救是把 probe 修好再問一次）。
  **部分問到照舊是 CLEAN＋NOTE**——這個 lab 平常就是部分盲（一個 app 的窗掉了那種）。
  🔴 **kernel-down 那格不受影響**：`ndt down` 之後照舊 `VERDICT: CLEAN -- the process half only`
  （Adam 09-10 裁）。差別是「操作者自己關的 :8000」與「kernel 在、但回 http 500」——
  後者是故障、而且現在就還能再問一次。⇒ **`grep -F 'VERDICT: CLEAN'` 的閘門在 all-blind 那格
  現在不會 match**（這正是修法的目的）；rc 也從 0 變 3，把 rc 當 0/非 0 讀的呼叫者會直接 FAIL。
- **要退掉這個行為**（如果哪天不要了）：把 `ndt:3914-3918` 那兩行從
  「併進 `APP_SURVIVOR_BLIND`」改成只印不記，閘門
  `tests/shell/mutate_ndt_helper_apps_window.sh` 的 M24 會立刻紅。
- **證據等級**：🔵 **讀碼＋單元測試／閘門，沒有 live 驗過這一格**（3-51c 全單皆然）。

Adam 對「P4 的規則定不了年」的處置是**從根本修**：G-13——讓 proxy 在裝規則時記時間戳。

⚠️ 這代表 **OVS 沒有一鍵驗收**。OVS 的驗收就看 `ndt up` 最後那行 `data plane: ... forwards`，
外加下面那張表。

要自己再驗一次，看 `ndt status` 的這三塊：

| 看哪裡 | 什麼叫對 |
|---|---|
| `running` | bmv2 10（P4）或 `:8080 ryu open`（OVS）、三個 port 該開的開 |
| `network health` | `switches 10 up, 10 enabled`、`links` 的 down 數是你預期的 |
| `kernel graph` | switch／host／edge 數要跟 `configuration` 的 topology 檔一致 |

⚠️ **`/ndt/get_cpu_utilization` 在 MININET 模式下是假的**——它回 `10 + hash(ip) % 50`，
恆定不動，而 Web-GUI 直接顯示它。要量 CPU 只能用
`tools/test_workflow/cpu_probe.py` 讀 `/proc`。

---

### 2.4 切換拓樸檔

**這裡有三層拓樸，來源各自不同**，這是最容易搞錯的一節：

| 哪一層 | 由什麼決定 | 誰在讀 |
|---|---|---|
| **fabric 真的接了幾台** | P4：`p4_proxy/mininet/host_count_override`<br>OVS：跑哪個動詞（`ovs-topo-start`=128 / `ovs-topo-4host`=4） | Mininet |
| **kernel 的模型** | `ndt up` 自動依 host 數挑；`NDT_TOPO=<檔>` 可強制 | kernel |
| **Ryu 的模型**（只有 OVS） | `NDTWIN_RYU_TOPO_FILE`，`ndt up ovs` 自動設成和 kernel 同一個檔 | `intelligent_router.py` |

日常用法就是**不要自己碰**——講 host 數就好，其餘 `ndt` 自己對齊：

```bash
ndt up p4 4         # 改 host_count_override -> 4，並挑 4 台的模型
ndt up p4 128       # 改回 128
```

⚠️ **只有 `ndt up p4 <n>` 會寫那個旋鈕。** `ndt up 4`／`ndt up ovs4` 是 OVS，
`ndt help` 逐字：`OVS has no such knob -- there the size is the verb`；09-12 實跑 `ndt up 4`
之後 `ndt status --check` 仍印 `knob baseline  4 == the value this round started with`，
一個字都沒寫進去。
<!-- 來源：ROLE-11 F1，log hunt-0911/logs/ROLE-11/04-ndt-up-4.log、05-check-after-up.log:14
     （🟠 轉述：ROLE-11 的實跑輸出）；`ndt help` 那句由本單親自核對（ndt-help-spelling.doc1-0912-r1.log）。 -->

`host_count` 必須是 4 的倍數且 ≥ 4（hosts 分散在 s1–s4）。改動會印黃字警告，因為
`host_count_override` 是**持久狀態**——下一輪繼承別人設的數字，就是量測描述錯網路的起點。

現有的模型檔：

| host 數 | P4 | OVS／Mininet |
|---:|---|---|
| 4 | `StaticNetworkTopologyP4_10Switches_4Hosts.json` | `StaticNetworkTopologyOVS_10Switches_4Hosts.json` |
| 8 / 16 / 32 / 64 | — | `StaticNetworkTopologyOVS_10Switches_{8,16,32,64}Hosts.json` |
| 128 | `StaticNetworkTopologyP4_10Switches_128Hosts.json` | `StaticNetworkTopologyMininet_10Switches.json` |

要用不照命名規則的模型：`NDT_TOPO=/path/to/model.json ndt up`。

<details><summary>為什麼不要自己 export <code>NDTWIN_RYU_TOPO_FILE</code></summary>

它**預設是 128 台的 Mininet 模型，不管 fabric 實際幾台**。2026-08-21 之前 `ndt` 只設
kernel 的模型、沒設這個，於是 `ndt up ovs4` 蓋了 4 台的 fabric、給 kernel 4 台的模型，
而 **Ryu 為 128 台裝路由**：每一對之間 100% 掉包，**而 kernel 的圖、Ryu 的
`/v1.0/topology/hosts`、`ndt` 自己的「model matches fabric」三個視圖全都顯示正確**。

這個變數有一個 reader、零個自動 setter——repo 裡唯一的 `export` 是某份報告裡手打的一行。
所以那一輪的數字是好的，之後每一次無人值守的跑都不是。現在由 `ndt up ovs` 設定，
自己 export 只會蓋掉它。
</details>

---

### 2.5 改實驗參數：bmv2 快慢版／host 數／取樣率

三個旋鈕，**代價差很多**：

| 改什麼 | 怎麼改 | 什麼時候生效 |
|---|---|---|
| host 數 | `ndt up p4 4` / `ndt up p4 128`（**只有指名 `p4` 的形式會寫旋鈕**，見 §2.4） | 下次開機 |
| bmv2 stock ↔ fast | 註解／取消註解 `p4_proxy/mininet/bmv2_binary_override` 那一行 | 下次開機 |
| **取樣率** | 改 `.p4` 裡的 const **＋重編 pipeline** | **要重編＋重起 fabric** |

`ndt status` 的 `configuration` 區塊會把三個當下的值一起印出來，開始量之前看那三行就好。

<details><summary>bmv2 的 stock 與 fast 差在哪、為什麼預設指向 fast</summary>

程式碼的**預設**是裸名 `simple_switch_grpc`（走 PATH → `/usr/local/bin/`，
**-O0、debug log 全開**）。實際在跑的是 `/usr/local/bmv2-fast/bin/simple_switch_grpc`，
因為 `p4_proxy/mininet/bmv2_binary_override` 這個**有進 git 的檔案**指過去。

**為什麼指過去（2026-08-17）**：stock 版大約 **22 Mbps** 封頂，而鏈路宣稱 1 Gbps
⇒ 利用率永遠在 ~2%，於是 energy app 的合併決策**對流量完全不敏感**（實測：有流量、
沒流量，同樣三台、同樣順序），TE 也永遠碰不到它的 70% 門檻。

它是**檔案不是環境變數**，因為 lab wrapper 用固定的 root 環境起拓樸，env var 到不了那裡。
`../lib` 會自動被當成 `LD_LIBRARY_PATH` 帶上——fast 版的函式庫必須跟著它的執行檔，
否則就是把 stock 的函式庫混進一份自稱 fast 的量測裡。

檔案在但內容壞掉（路徑不存在／不是絕對路徑）時**直接拒絕開機**，不會 fallback。
理由：fallback 等於用一個宣稱相反的檔名去 benchmark stock 版，而壞掉的比較比拒絕還糟。
</details>

<details><summary>取樣率為什麼沒有開機旋鈕</summary>

它是編譯期常數：

```
p4_proxy/p4_src/ndtwin_switch.p4:52:  const bit<16> SAMPLE_RATE = 256;
```

要改就得改 source → `p4c-bm2-ss` 重編 → **重起 fabric**（bmv2 在 exec 時載入 JSON，
之後永不重載）。零個環境變數、零個旗標。唯一自動化的是
`doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh`，那是實驗 driver 不是支援介面
（但它 `sed` 完會 `grep -q` 自證改成功，值得抄）。

`ndt status` 的 `sample rate` 是**讀回來對帳的**，不是設定值。存在的理由就是 2026-08-20
抓到 source 註解寫 256、實際跑的 fabric 是 1024。

🆕 **2026-09-07 起它看平面**（D-2／X-2），而且旁邊多一列 `rate source` 寫它從哪裡讀的：

| 平面 | 讀哪裡 |
|---|---|
| **P4** | 編出來的 `p4_proxy/p4_src/build/ndtwin_switch.json` 裡 `random(0, N-1)` 的上下界 |
| **OVS** | `ovs-vsctl --columns=sampling list sflow`（OVSDB，`testbed_topo.py:160` 設的那個） |
| 沒有 fabric | 上面那個 JSON，而且那一列會明講「這不是任何在跑的東西的讀數」 |

🔴 **為什麼要分**：2026-09-06 實測（`logs/x1-22-status-blind-to-ovs-rate.log`），把十筆
OVS sflow record 全設成 64 之後 `ndt status` 照樣印 `sample rate 1/256`——它讀的是 bmv2
的編譯產物，跟 OVS fabric 一點關係都沒有。**兩邊只是碰巧都是 256**，所以幾個月沒人發現。
OVS 側另外三種答案都不會被印成分數：十筆不一致（`DISAGREE`）、一筆都沒有（**什麼都沒在取樣**）、
`ovs-vsctl` 被拒（`UNREADABLE`，**不是預設值**）——三種都會讓 `--check` 變紅。

⚠️ **在 fabric 活著的時候重編，`status` 會說謊**——JSON 換了、switch 沒換。
`ndt status` 有 `stale_pipeline` 偵測（比對 build JSON 與 manifest 的 mtime）會提醒你，
但正解是：**重編完一定重起 fabric**。
</details>

---

### 2.6 跟 fabric 互動：Mininet CLI 還是 NTG prompt

**這兩個是二選一，開機時就決定，開起來之後不能切。**

```bash
ndt ntg             # 現在是哪個
ndt ntg cli         # 下次開機掉進 Mininet 的 CLI
ndt ntg prompt      # 下次開機交給 NTG 自己的 prompt
```

⚠️ `ndt ntg` 改的是**別的 repo** 的設定檔（`~/Network-Traffic-Generator/setting/Mininet.yaml`
的 `mode:`），所以它會印黃字警告。改完要下一次 `ndt up` 才生效，正在跑的拓樸維持原樣。

**Mininet CLI 常用**（在 `topo` 這個 tmux session 裡）：

```
nodes                 列出所有節點
net                   列出所有鏈路
h1 ping -c 3 h2       在 h1 裡 ping h2
h1 ifconfig           看 h1 的介面
pingall               全對 ping（128 台會很久，別隨手打）
iperf h1 h2           兩台之間量頻寬
sh <任何 shell 指令>   在 root namespace 裡跑
exit                  結束拓樸（＝關掉整個 fabric）
```

**NTG prompt**：`flow --config <檔>` 灌流量。
⚠️ **NTG 不支援中斷實驗**——中斷等於整個 NTG 關掉；要等所有非無限的 flow 自然結束。
kernel 還沒起來時 NTG 會卡在 `Failed to get hosts, retrying`，那是**預期的中間態**。

從外面不進 tmux 也能對 host 下指令：

```bash
sudo -n mnexec -a <host-pid> ping -c 2 10.0.0.2
```

---

### 2.7 開外部工具

```bash
ndt apps                    # 在終端機上不帶參數 = 互動選單
ndt apps nsr te             # 指名開
ndt apps stop all           # 全部停
```

| 名字 | 是什麼 | 會不會改變網路 |
|---|---|---|
| `energy` | Energy-Saving-App | 🔴 **會**——它會把 switch 關掉 |
| `te` | Traffic-Engineering-App | 🔴 **會**——它會裝流量規則 |
| `nsr` | Network-State-Recorder | 否，只讀 kernel API |
| `sim` | Simulation-Platform-Manager | 否 |
| `viz` | Network-Traffic-Visualizer | 否（JavaFX GUI，**要有顯示器**） |

**apps 刻意不算在 `ndt up` 裡面**：其中兩個會改變網路，所以「開了哪幾個」是每個實驗
setup 的一部分，不能是預設值。

<details><summary>不歸 <code>ndt</code> 管的兩個</summary>

- **Web-GUI**：`localhost:3000` 的 Docker 容器，生命週期比這裡的任何東西都長，
  用 docker 指令自己起停。這台機器**沒有 Node**，只能走 Docker，而且我們對它只有讀權限。
- **NTG**：它根本不是獨立行程，是拓樸腳本把控制權交出去的那個 prompt（見 §2.6）。

其餘七個兄弟 repo 的路徑都在 `tools/test_workflow/components.env`，那是路徑的唯一真實來源。
**別人的 repo 只測不改。**
</details>

---

### 2.8 收尾

```bash
ndt down            # 收
ndt clean           # 驗收；怎麼讀它的 exit code 見 §2.1 那張表
```

`ndt down` 約 13 秒。細節見 §2.1（清空和收尾是同一件事）。

🏁 **已修（兩半都修了，2026-09-12）：收一個活著的 P4 fabric 時，同一份輸出曾經同時說兩件相反的話。**
09-12 02:2x 實測（`ndt up p4 4` 之後）：`verify clean` 底下五行全 `ok`（含
`ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000`）、印綠色 `clean`，
**緊接著一行** `claim note now says the teardown did not verify clean`，`RC=1`。
那句話還會**活過這次指令**——之後 `ndt status` 的 `note` 欄逐字：
`down at 2026-09-12 02:26:12 did NOT verify clean; claim kept -- read 'running' below, not this note`，
接班的人第一眼看到的就是它。

**rc 那半**由 FIX-NDT-6 ② 修掉（merge `1656bdba`）：`[1/3]` 點名的 bmv2 port 在 `verify clean`
之後**按號重讀**，rc 跟第二次讀數走 ⇒ 收乾淨的活 P4 fabric 現在回 **0**。
**已經落到磁碟上那半**由 FIX-NDT-7 ③ 修掉（merge `aab7581e`）：note 描述機器，不再是 rc 的別名。
⇒ **今天再看到「印了 `clean` 卻 `RC=1`」，那是新缺陷，不是這一條。**
<!-- 來源：兩個 merge sha 是不是 trunk 的祖先＝本單親自 `git merge-base --is-ancestor` 驗過（都是）；
     「修好了、現在回 0」本身＝🟠 轉述 KNOWN-ISSUES G-43／G-49 與 00-COMMON-0911-DAY 05:58 那節，
     本單沒有開 lab 重驗。原本這裡寫「FIX-NDT-6 在修」，是 09-12 05:56 兩顆 merge 之前的話。 -->

**還原判準——三件套。**

<!-- NDT-RESTORE-CRITERION:BEGIN
     這是整份手冊唯一一段教人怎麼判「還原了沒」的文字。rc 的意思看 §2.1 那張表，
     這裡只寫怎麼用；tests/shell/test_manual_rc_table.sh 對著 `ndt help` 守它。 -->

1. **`ndt clean` 回 0 或 3。** 兩個都是還原成功——剛收完的 lab 沒有東西可判，那就是 **3**
   （09-12 之前它回 0，所以舊版手冊寫「要 rc 0」；照舊版做會把一個收乾淨的 lab 判成沒收乾淨）。
2. **`orphans_verdict.sh` 印 `VERDICT: CLEAN`**（不是讀 `ndt apps orphans` 的 rc——
   那支的碼是另一套，見 §2.5）。
3. **`ndt status --check` 與你開工時的基線一致。**

三件都過就是**已還原**。`ndt down` 自己的 rc 用 §2.1 的同一張表讀：**0 或 3** 都算過
（3 ＝這次 down 開工時機器上就沒有東西可拆），**1** ＝量到髒。
`ndt clean` 回 **1** ＝量到還有東西在，**還沒還原**。
`ndt clean` 回 **5** ＝有守衛擋著、**它什麼都沒驗**——先讀它印的是誰擋的（另一個 teardown、
別人的 claim），等它結束再判；**5 既不是「乾淨」也不是「髒」，不准當成三件套的任何一件通過。**

夜巡的 `live_cells/run_cells.sh` 就是照這個判的（`down` ∈ {0,3}、`clean` ∈ {0,3}、
`VERDICT: CLEAN`；任何一項不過就 `RESTORE-FAIL`，5 還會印是誰擋的，然後停掉整輪）。

<!-- NDT-RESTORE-CRITERION:END -->
<!-- 來源：三件套的形狀出自 ROLE-11 F6，log hunt-0911/logs/ROLE-11/91-down.log（末六行）、
     99-final-check.log（note 欄）、92-clean.log、93-orphans-after.log（VERDICT: CLEAN）＝🟠 轉述。
     rc 值改口＝FIX-NDT-8（merge `af5efa4f`，2026-09-12，KNOWN-ISSUES G-53）：`ndt clean` 的
     0→{0,3}、1＝髒、5＝拒絕，與 `live_cells/run_cells.sh` 的 restore 硬判同一套（本單親自讀）。 -->

<details><summary>收到一半被 Ctrl-C 會怎樣（2026-08-21 實測）</summary>

SIGINT 打在 `[2/3]` 的結果**比預期好**：`ndt` 被 signal 2 殺掉、kernel 與 proxy 已經停了、
**fabric 完整留著**（不是半毀）、`ndt clean` **正確回報 not clean 且 rc=1**、
再跑一次 `ndt down` 完全復原。

也就是說：中斷之後**再跑一次 `ndt down` 就好**，不需要手動收拾。
但一定要跑 `ndt clean` 確認，不要假設。
</details>

---

### 2.9 開不起來怎麼辦

**已知的失敗全都不長得像失敗**——這張表就是為此存在的。

| 症狀 | 真正的原因 | 解法 |
|---|---|---|
| `kernel did not open :8000`，但環境看起來好好的 | kernel 用 `popen(curl)` 打 HTTP，而 `localhost` 在這台機器上走 IPv6 黑洞，SYN 被丟掉不是被拒絕 ⇒ 卡 **131 秒** | 已於 `b539be7` 修掉（加 `--connect-timeout 2 --max-time 10`、刪掉 `start()` 裡的同步呼叫）。**先確認你跑的 binary 真的重建過**，見下方 |
| `no lab sessions`，但 fabric 明明活著 | tmux 有控制終端時需要環境裡有 `TERM`（**沒 export 等於沒有**）；它的 stderr 被丟進 `/dev/null`，`\|\| echo` 把失敗寫成跟「真的沒有」一模一樣的字 | `ndt` 檔頭已 `export TERM="${TERM:-dumb}"`。裸跑 `ndtwin-lab status` 時自己帶 `TERM=dumb` |
| 拓樸永不收斂，log 完全沒提到 port | 起 Mininet 的時候 Ryu 還沒聽 ⇒ 探測 6653/6633 全滅 ⇒ fallback 到死埠 | **先確認 Ryu 在聽**再起拓樸。`ndt up ovs` 已經處理了（它等 `[2/3]` banner）。**不是埠號問題**，見 §2.2 的摺疊區 |
| 關機後送 `action=on` 回 **200 Success，但什麼都沒發生** | 電源開機在關機後約 10 秒內是 no-op，卻回報成功 | **關機後等 15 秒**再開機。示範前務必知道這條 |
| `ndt up` 說看到 orphan、把健康的 fabric 掃掉 | 上一條 `TERM` 的下游效應（session 被判成不存在） | 同上；已修 |
| 一切都對，但 host 之間 100% 不通 | Ryu 的模型和 fabric 尺寸不一致（見 §2.4） | 用 `ndt up ovs4` 而不是自己拼；不要自己 export `NDTWIN_RYU_TOPO_FILE` |
| `all_destination_paths` 抓到的路徑數比預期少 | 路徑集合**不是單調的**——會先漲到 16256 再掉回 13184，而 **kernel 只抓一次不重試** | 等它沉澱，不要單次取樣就下結論 |
| `pgrep -c simple_switch_grpc` 回 0，但 switch 在跑 | `/proc/<pid>/comm` 上限 15 字元，而這個名字有 18 個 | `ps -eo comm= \| grep -c '^simple_switch'`，或 `pgrep -cx simple_switch_g` |

**沒有頭緒的時候**：`ndt status --check` 會把所有「會讓量測不可信」的狀態一次列出來，
並且 exit 非零。日誌在 `.test_run/logs/`。

🔴 **`ndt status` 的 `code` 欄不能拿來判斷 binary 有沒有重建。** 它是 git HEAD ＋
未提交檔案數，講的是 **source**；binary 是不是那份 source 編出來的，它一個字都沒說。
改完 C++ 忘記重建，然後對著舊 binary 量一整輪——這個 repo 已經連續兩次栽在這上面，
而且兩次的數字看起來都很合理。真的要問 binary，比對時間：

```bash
ls -la build/bin/ndtwin_kernel
find src include -name '*.cpp' -o -name '*.hpp' | xargs ls -t | head -1
```

binary 比最新的 source **新**才算重建過（注意是 `build/bin/`，不是 `bin/`）。

<details><summary>底層路徑（<code>ndt</code> 本身壞掉時）</summary>

```bash
# P4
sudo -n /usr/local/sbin/ndtwin-lab topo-start
bash tools/test_workflow/stack.sh up p4
bash tools/test_workflow/stack.sh wait
bash tools/test_workflow/stack.sh down
sudo -n /usr/local/sbin/ndtwin-lab topo-stop

# OVS（要兩個終端機：stack.sh 會停在 Mininet 提示等你）
bash tools/test_workflow/stack.sh up ovs
sudo -n /usr/local/sbin/ndtwin-lab ovs-topo-start    # 另一個終端
# 回去按 Enter
```

**這條路徑不記帳**（`.test_run/pids/` 不會有登記），所以之後 `ndt down` 收不乾淨。
只在 `ndt` 自己壞掉的時候用，用完自己收。
</details>

---

### 2.10 絕對不要做，以及每一步該花多久

**黑名單：**

| 不要做 | 會發生什麼 |
|---|---|
| `pkill -f <任何字串>` | 🔴 **會殺掉你自己的 shell**——`-f` 比對整條 argv，而你的命令列裡就有那個字串 |
| 把量測指令直接打在命令列 | 同上的偵測版：`pgrep -f` 會匹配到自己。**寫進 script 檔**，script 的 argv 天然免疫 |
| `ifconfig <iface> down` 在 bmv2 上 | 🔴 **整台 switch 停止轉送**，不是斷一條鏈路。斷單鏈路一律 `tc netem loss 100%`，**兩端都要下** |
| 在 h2 裡面 `pkill` | Mininet 只隔離網路 namespace，**PID 空間跟 host 共用** ⇒ 殺全場 |
| 裸的 `sudo -n kill` 做訊號注入 | 本機 sudoers 沒授權 ⇒ **無聲失敗**，下游一切「正常」。用 `sudo -n mnexec -a 1 kill` |
| 開著 fabric 重編 P4 pipeline | `status` 的取樣率會說謊（JSON 換了、switch 沒換） |
| 混用 `ndt` 和裸 `ndtwin-lab` / `stack.sh` | `ndt` 記帳、裸指令不記帳 ⇒ `ndt down` 收不乾淨 |
| 沒設 `NDT_OWNER` 就跑 `ndt claim` 之外的指令 | 🔴 **任何 claim 都會被當成別人的**（安全預設），包括你自己剛剛下的 |

**時間預期表——超過就是卡住了，不是慢**（除註明外皆為 2026-08-21 `52cba51` 實測）：

| 動作 | 正常 | 其中 |
|---|---:|---|
| `ndt status` | 0.3–0.7 秒 | |
| `ndt up p4 128` | **33.6 秒** | bmv2 10 台 18 秒、路徑收斂 4 秒 |
| `ndt up ovs`（128） | **24.1 秒** | Ryu settle 10 秒、收斂 20 秒 |
| `ndt up ovs4`（＝`ndt up 4`） | 10–15 秒 | 09-12 單次實測 **8 秒**（`d7aa176e`） |
| `ndt up p4 4` | **14 秒** | 09-12 單次實測（`d7aa176e`）；bmv2 10 台 4 秒、路徑收斂 5 秒 |
| `ndt down` | **13.3–13.8 秒** | 空的實驗室只要 1.6 秒 |
| `ndt clean` | 0.1 秒 | |
| kernel 開 :8000 | 第一次 poll 就開 | 修好之前是 167 秒＋回報失敗 |

<!-- 來源：`ndt up p4 4` 與 `ndt up 4`(ovs4) 兩列的 09-12 數字＝ROLE-11 F2／F1，
     log hunt-0911/logs/ROLE-11/15-up-p4-4.log（ELAPSED=14s）與 04-ndt-up-4.log（ELAPSED=8s），
     🟠 轉述（ROLE-11 log）、各一次取樣不是分布。 -->

<details><summary>OVS 開機為什麼從 73 秒降到 25 秒（2026-08-21）</summary>

兩個原因，都在 `intelligent_router.py`：

1. **一行沒有任何記錄理由的 `hub.sleep(60)`**，支配了整個 OVS 開機。降到 10 秒後
   128-host 三次全通（h1→h64、h64→h128、h128→h1，跨核心跨象限）。
   `NDTWIN_RYU_SETTLE_S=60` 可以完全還原舊行為。
   **預設留 10 秒不是 3 秒**，因為原本的 60 秒沒有理由記錄，不知道它當初為何而設。
2. **`find_host_by_ip` 線性掃 `net.nodes`，被最內層迴圈呼叫**（128 台時 13.7×），
   已改成索引。順帶推翻一個數字：all-pairs walk 在 128 台是 **2.166 秒不是 ~60 秒**，
   而且 95% 不是裝規則。

⚠️ 這些都是**開機路徑**的量測。failover 的 walk 是不同的呼叫點，那個數字**還沒量過**。
</details>

---

### 2.11 補充：`ndt status` 逐欄解讀

```
lab
  claim          maindev-0821 -- 80m left (until 18:39:09)
  note           experiment: LLDP detection time at 4 vs 128 hosts
  measuring      nothing
  code           07ae07c  +4 file(s) with uncommitted changes
```

| 欄位 | 怎麼讀 |
|---|---|
| `claim` | 四種狀態措辭**刻意不同**：自己的／別人的名字／`EXPIRED`／`none`。過期的不會讀起來像活的。相對時間在前、絕對時間在括號 |
| `note` | 別人留的一句話，說他在做什麼 |
| `measuring` | 有沒有 `iperf3 -c` 在跑。**不是 nothing 就不要拆** |
| `code` | 現在這份 checkout 的 commit＋有沒有未提交的改動。**量測數字要跟這個 commit 一起記** |
| `knob baseline` 🆕 | `p4_proxy/mininet/host_count_override` **現在的值**跟你 `ndt claim` 那一刻的值比。**不看 git 髒不髒**——2026-09-05 那次它被寫成 128（＝HEAD），git 因此說它乾淨，警告整段消失，而 `porcelain` 行數還從 22 掉到 21（I-3）。還原＝**寫回**那個值，不是 `git checkout --`。🔴 **三種答案，看下一列** |
| `knob baseline` 的三種答案 🆕 | ① **`<n> == the value this round started with`**＝沒動過，綠。<br>② **`<n>, written by 'ndt up p4 <n>' at HH:MM:SS this round`**＝**你自己用 `ndt` 改的**，黃字警告、**不進 problems、`--check` 仍然 rc 0**。因為 `ndt up p4 4` 會把 4 寫穿這個旋鈕（`set_host_count`），所以「claim 在 128 → `up p4 4`」的標準 P4 輪，從第二個指令起整輪都會是紅的——**一個整輪都紅的閘門沒有人讀**。它還是要寫回去，只是那個期限改由 `ndt release` 收（見下面 `ndt release`）。<br>③ **`NOT RESTORED`**＝現值既不是開工值、也不是 `ndt up` 寫的值 ⇒ **有人手改過**，紅字＋problem ⇒ **`--check` rc 1**（2026-09-07，E-9；先前它印紅字卻回 rc 0——`rounds/08-round2.md:146` 04:36 實測）。<br>🔴 **只有 ③ 進 problems**：`4 (the default)` 與 `!= 4, and no round baseline exists` 兩句只印不紅（後者分不出「忘了還原」與「本來就要 128 但沒 claim」）；**沒有 `up_wrote` 欄位時 ② 不存在**，`≠` 開工值一律走 ③ |
| `tree vs round` 🆕 | 從開工到現在，未提交清單**多了誰、少了誰**（列檔名，不是數量）。**少了誰**才是危險的方向：它代表那個檔現在跟 HEAD 一樣了，而那不等於還原。🔴 **這一列不進 `--check` 的 problems**：一輪中 commit 會合理地改變這個集合，每次 commit 都紅的閘門沒有人讀 |
| `knob baseline`／`tree vs round` 的來源 | `.test_run/round.baseline`，由 `ndt claim` 寫，欄位是 `at=`／`by=`／`head=`／`host_count=`（開工時旋鈕的值）／每個未提交路徑一行 `dirty=`。🆕 **另有 `up_wrote=<n>`＋`up_wrote_at=<epoch>` 兩欄，由 `ndt up p4 <n>` 事後補寫**（2026-09-07，E-9b）——它是上面第 ② 種答案的唯一依據，**只保留最後一次**（不累積），**沒 claim 就不寫**（沒有 round 可以被赦免）。**`ndt release` 會把整個檔改名成 `.prev`**（2026-09-07，E-11，照 `lab.handoff` 的前例）⇒ release 之後兩列都會說「沒有 baseline」，**那是正確語意（round 結束了），不是資料掉了**；事後要查開工狀態看 `.test_run/round.baseline.prev`（沒有任何程式讀它，它是留給人的） |

```
configuration
  hosts / topology / bmv2 / sample rate / rate source
```
**這五行決定你量到的每一個數字。** 開始之前看一眼；寫報告的時候一起抄下來。
（`rate source` 是 2026-09-07 加的，見 §2.5 的 sampling rate 那段。）

```
running / network health / kernel graph
```
見 §2.3。

**要保留實驗室**：

```bash
NDT_OWNER=<你的名字> ndt claim 60 "在量 X"
NDT_OWNER=<你的名字> ndt release
```

🔴 **`NDT_OWNER` 每一個指令都要帶，不只 `claim`。** 沒設的時候，**任何 claim 都算別人的**
（安全預設）——mainDev 08-21 就這樣被自己的 claim 擋在門外。被擋下來時訊息會先給你
`NDT_OWNER=<誰> ndt down`，`--force` 放在最後：照著 `--force` 打會拆掉真的有人在用的實驗室。

🔴 **`ndt up` 在兩個平面都擋別人的 claim 與進行中的量測**（rc **5**，什麼都不建、什麼都不寫）。
P4 從 09-12 起就這樣；**OVS 是 09-25 才開始**——在那之前 `ndt up ovs`／`ndt up 4` 會在別人的
claim 底下照建、回 0（ndt serve 那一輪 09-24 22:49 實測）。被擋下來時一樣先給你
`NDT_OWNER=<誰> ndt up …`，最後才給覆寫：

```bash
NDT_OWNER=<你的名字> ndt up 4 --force      # 兩個平面同一個旗標；放在 argv 任何位置都可以
```

- **每一次真的越過了什麼的 `--force`，都會在 `.test_run/lab.claim.overrides` 追加一行**（tab 分隔：
  `at`／`by`＝你的 `NDT_OWNER`／`user`／`pid`／`command`／`over`＝被蓋過的 claim 的 owner、只因量測在跑
  則是 `none`／`claim_expires`／`claim_note`／`measuring`／`running`）。沒東西要越過時不寫；
  **那一行寫不進去就不建（rc 5）**。只 export `NDT_UP_FORCE=1` 沒有用，旗標必須打在指令上。
- **那一行的意思是「用了 `--force`」，不是「建起來了」**：它在守衛那一步就寫下，後面的檢查
  （另一個 `ndt down` 還在跑、port 被佔、Mininet 已在跑、H4）照樣可以拒絕；建沒建起來看那一次的 rc。
- `ndt status` 在 `prev claim` 下面多一列 `override`，印最後一次 `--force`（何時、誰、蓋過誰、
  指令、總筆數）——**被蓋過的那一方下一次看 `status` 就看得到**。它是歷史，不讓 `--check` 變紅。
- 那個檔是獨立的，不寫進 `lab.claim`：被蓋的 claim 是別人的（不准非持有者改寫），`ndt claim`／
  `ndt release` 會重寫或改名掉 claim，而只因量測在跑而覆寫時根本沒有 claim。只追加、不輪替。

🔴 **claim 只擋 `ndt` 的動詞，擋不住裸指令。** 直接跑 `./bin/ndtwin_kernel` 或
`ndtwin-lab topo-start` 一樣會撞進去。**它是約定不是鎖。**

🔴 **也擋不住北向 API，而且過期／被搶不會有任何訊號**（2026-09-11 實測，ROLE-4 T4）。
一個每 2 秒打 `/ndt/install_flow_entry`＋`/ndt/delete_flow_entry` 的迴圈：**自己的 claim 過期那一秒
是 http 200，別人搶到 claim 之後還是 200**，一直到搶到的人跑 `ndt down` 把 kernel SIGTERM 掉才變 `000`
（`kernel.exit` 的 `at=` 與那一格同秒）。⇒ **寫入端唯一看得到的訊號是「連不上」**，
而且**沒有任何一端會被通知 claim 換手了**——包括原本的持有者。要知道就自己重讀 `ndt status`。
（要不要讓 API 讀 claim 是設計題，尚未裁；現況先寫在這裡。）

🔴 **`measuring=` 現在會擋 `ndt down`**（2026-09-11，T2d）。claim 裡 `measuring=` 非空時
`ndt down` 拒絕並把那行唸出來；**`--force` 是唯一的覆寫，`--deep` 不是**。
真的過完了就 `ndt down --force`（它會把 `measuring=` 清掉並寫進 `note`）或重新 `ndt claim` 改宣告。
在這之前：那個宣告**保護不了任何東西**——01:57 實測 owner 自己 `ndt down` 照拆、rc 0、一個字都沒提。

🔴 **`ndt claim` 現在有鎖**（`.test_run/lab.claim.lock`）。同秒兩個人搶，輸的那個會收到
`beaten to it: ...` 與 **rc 1**；在這之前**兩個都會收到 rc 0 與「ok lab claimed by 你」**，
而檔案只留最後寫的那個（01:53–01:54 實測 2/16）。**被覆寫掉的那份留在 `.test_run/lab.claim.prev`**。
⚠️ 鎖只管走 `ndt claim` 的人；直接寫檔的腳本不吃鎖，所以 `ndt claim` 寫完會**回讀**確認 owner 是自己。

### 🔴 要獨佔 CPU 的量測：`NDT_EXCLUSIVE_CPU=1`（2026-08-28 新增）

```bash
NDT_OWNER=<你的名字> NDT_EXCLUSIVE_CPU=1 ndt claim 60 "六臂量測，不要開 VM"
```

**為什麼有這個欄位**：claim 保護 fabric 與 build，**從來不保護 CPU**。
08-28 一個 session 在另一個 session 的六臂量測窗內跑 4 vCPU 編譯，
**沒有碰 build、沒有碰 binary、沒有碰 fabric**——claim 涵蓋的東西一項都沒動——
而污染在六個臂之間**不對稱**，正好是那個實驗設計唯一無法吸收的形狀。

⚠️ **這件事當時記憶裡已經寫著了**（VM 不撞網路但搶 CPU/RAM/I-O，而沒有機制會通知別人）。
**知道不等於有機制**，所以這個欄位**同時**做了兩件事：

| | |
|---|---|
| **宣告** | `ndt claim` 寫 `exclusive_cpu=yes` |
| **讀取** | `ndt status` **無條件**印出來（不是加旗標才印），並且**把宣告與實際並排** |

`ndt status` 在有 claim 時一律顯示這一行，例如：

```
  exclusive cpu  yes (load1 3.2 on 14 cores -- holding)
                 🔴 do not start a VM, a compile, or any heavy local job
```

實際負載超過 `1.5 × 核心數` 時改印 **`yes -- but load1 is N ... so it is NOT holding`**，
並讓 **`ndt status --check` 失敗**。

🔑 **只加欄位不加讀取端等於沒做**——那只是把同一個失效換一個位置重演。
**門檻用 `load1` 不用 CPU%**：CPU 佔用率會在 1.0 飽和，機器滿了之後它就無法再表達有多滿；
`load1` 沒有上界。08-28 那次正是因為主判準選了有上界的量而漏掉的
（六臂 `busy_max` 全部 = 1.000，`Δbusy` 只有 0.005）。

📌 **門檻是拿當初那次事故校準的**：block 1 的 `load1` 是 27–31，門檻 `1.5 × 14 = 21`
⇒ **當時會被擋下來。**

---

## 3. 對跑著的 stack 驗契約（L2–L4）

```bash
bash tools/test_workflow/run_layers.sh api p4 --traffic     # 或 api ovs
bash tools/test_workflow/run_layers.sh baseline ovs --traffic   # 建 L4 基準（健康的 OVS 輪）
bash tools/test_workflow/run_layers.sh compare                  # P4 對 OVS 基準
```

`api` = L2 契約 + L3 元件依賴 + log 檢查。`--traffic` 額外要求真的有 flow/path/rate，
`--mutations` 才會去打寫入端點。工具本身在 `tools/contract_test/`，那裡的 README 解釋
為什麼「7 個元件與 kernel 之間唯一的介面就是 `/ndt/*`」使得在一處驗契約等於驗了全部地基。

<a id="run-layers-asks-the-kernel"></a>
### 3a. `run_layers.sh` 拿哪一份模型來驗（2026-09-07 起改成**問 kernel**）

**先問 kernel，問不到才推導。** 順序是固定的三層：

1. `NDT_TOPO=<path>` — 手動指定，蓋過下面兩層（不變，仍是逃生門）。
2. **kernel 說的**：`GET /ndt/get_graph_data` 的 `topology_file`。腳本會拿本機那個檔的
   `sha256sum` 跟 kernel 回的 `topology_sha256` 對，**一致才用**。
3. kernel 沒回這個欄位（不通、或是 E-2 之前的 kernel）⇒ 退回原本的推導
   （由活著的 host 數在 `setting/` 找同基數的模型），並**印一行說它在猜（`guessing`）**。

🔴 **為什麼要改**：第 3 層是猜。`setting/` 裡不只一份模型是「10 switch／4 host／40 edge／
同十個 dpid」，所以拿 A 的 fabric 對 B 的模型驗**本來就會全綠**——每一條 per-node 身分
檢查都通過，因為數字本來就一樣。儀器不知道自己在測什麼（`fix/R2-PY-SUMMARY.md` §7-3、
`doc/KNOWN-ISSUES.md` **G-15**）。

**兩種 rc 3（拒絕，不是失敗）**，兩種都會印該怎麼辦：

| 情況 | 訊息 |
|---|---|
| kernel 說的檔**載入後被改過**（sha 不合） | `... has been edited since the kernel loaded it`，並列出兩個 digest。twin 在服務舊內容、下面的層會讀新內容，差異會被當成產品缺陷 |
| kernel 說的檔**本機讀不到** | `... cannot read that file`。這一輪無法確認 twin 在描述哪個網路 |

⚠️ **舊 kernel 不是壞掉。** `28b8b13` 與所有 E-2 之前的 kernel 都不送這三個欄位；
**缺欄位＝「kernel 沒說」**，不是「沒有東西要檢查」。腳本照樣跑（退回推導），
契約套件則回 `TOOL-PRECONDITION-FAILED` 而不是綠也不是紅
（`tools/contract_test/spec.py` 的 `inv_kernel_serves_the_model_under_test`）。
**把「沒說」當成拒絕跑，是這個閘門的 M6 對照格在擋的加寬。**

⚠️ **`NDT_TOPO` 指到一個 kernel 沒載入的檔 ⇒ L2 契約會紅**，訊息是
「the kernel loaded X, and this run is validating it against Y」。**這是它該做的**：
把 twin 拿去跟另一份模型比，每一條計數與 dpid 檢查都會通過（數字一樣），
唯一會說話的就是這一條。要對比另一份模型，請自己讀那條訊息，不要把它當成雜訊關掉。

自動化測試：`tests/shell/test_run_layers_asks_kernel.sh`（10 格）、
`tests/test_TopologyLoadedModelReported.cpp`（kernel 那半）、
`tests/python/test_contract_spec.py` 的 `ModelUnderTestTest`、
閘門 `tests/shell/mutate_kernel_reports_loaded_model.sh`。

**規格對照**：`doc/2026-01-02_ndt_api.md` 記載全部 **41** 個端點（§1–§41，與 dispatcher
逐條相符）；其中 **32** 個有機器檢查（2026-08-17 補上 `historical_logging` 三條與
`intent_translator/text` 的錯誤路徑一條）。剩下九條沒有：group／meter 各三（Tier 2，
裁決不動）、`link_failure_detected`／`link_recovery_detected`／`inform_all_destination_paths`
（proxy 每輪 live 都在打，只是沒契約測試）。

⚠️ **上面那三個數字（41／32／九）在 2026-09-06 已經過期，不要沿用**——用
`tools/contract_test/README.md` 的〈重算涵蓋率〉那段自己算。當天實測是 **45 個註冊端點、33 個有
contract、12 個沒有**；其中兩筆是 B-6 修法在分支 `fix/w8-declared-link-failure-sticky` 加的
`inject_link_failure`／`inject_link_recovery`，寫在 API 手冊的 **§2b／§2c**——**刻意用字母後綴而不是
§42／§43**，因為插進編號會把整份手冊往後推，每一份引用 §N 的文件同時失效。
剩下的差額在那次改動之前就在了（trunk `1536ff17` 上算出來是 43／33／10）。
[Co-developed with claude code -- Adam]

<!-- NDT-MERGED-CAVEAT:BEGIN e21-contract-branch-only bb9301a0 -->
⚠️ **2026-09-07 又動了一次**：Adam 裁 **E-21**，四個 link 端點
（`link_failure_detected`／`link_recovery_detected`／`inject_link_failure`／`inject_link_recovery`）
進契約 ⇒ 🟢 實測 **45／37／8**，剩下的八個是 group／meter 六個 ＋ `get_sflow_stats` ＋
`inform_all_destination_paths`。
🏁 **那個分支 `fix/e21-link-endpoints-in-contract` 已併入 trunk**（merge `bb9301a0`，2026-09-10）。
原本寫「未併入 trunk」，是 09-10 14:22 那顆 merge 之前的話。
🔴 **但那十七筆檢查在併入之後沒有人重跑過。** 它們當初寫的是分支的行為
（`inject_*` 兩條路在**當時的** trunk 上回 404、`link_failure_detected` 只回
`{"status": "link failure processed"}`），所以**「對 trunk 跑會紅」這句話現在沒有證據支撐，
也還沒有人證偽**——要用它們之前先自己對一顆 trunk 建出來的 kernel 跑一次，並把結果寫回這裡。
其中六筆是 `MUTATE`：它們會**宣告並真的切斷**
一條 switch↔switch link（MININET 下 `netem loss 100%`，兩端），序列的最後兩步再把它接回來
⇒ **不帶 `--allow-mutations` 不會跑到**。
<!-- 來源：merge `bb9301a0` 是不是 HEAD 的祖先＝FIX-DOC-4 `git merge-base --is-ancestor` 與
     `git log --merges` 親驗（日期取自該 commit 的 %ad）。🔴 FIX-DOC-4 **沒有建 kernel、沒有跑
     契約測試**，所以「併入之後那十七筆會不會過」在本檔裡仍然是未量的。 -->
<!-- NDT-MERGED-CAVEAT:END e21-contract-branch-only -->
[Co-developed with claude code -- Adam]

⚠️ **MUTATE 類檢查要 `--allow-mutations` 才會跑**，所以它們很久沒被執行過——2026-08-17
第一次跑就抓到兩條**自己壞掉的檢查**（`modify_nickname` 送 `nickname`、`modify_device_name`
送 `device_name`，文件規定的是 `new_nickname` 與 `new_name`，kernel 一直正確地回 400）。
**定期跑一次帶 `--mutations` 的輪次**，否則這一半的套件會靜靜爛掉。

⚠️ **跑完 `--mutations` 之後 `git status` 會髒**：`modify_device_name` 會讓 kernel 重寫
`setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`。即使寫回的是同一個名字，
kernel 的序列化器會把 `edges` 排到 `nodes` 前面、鍵序也不同，於是產生 ~1300 行的 diff
——**內容經解析比對完全等價**（2026-08-17 驗過），直接 `git checkout --` 還原即可。

---

## 4. 專用工具

| 工具 | 一句話 | 指令 |
|---|---|---|
| twin 測謊器 | 對帳 twin 宣稱的活流量與實際封包，說謊就 exit 1 | `p4_proxy/venv/bin/python tools/twin_audit/twin_audit.py audit` |
| 故障注入（L5） | 照 `faults.txt` 注入一個具名故障、證明它生效、還原 | `tools/test_workflow/faults.sh list` / `run L-2 --pair 10.0.0.1,10.0.0.2 --iface s1-eth1` / `run-all` |
| qdisc 前後快照 | 每輪注入的前後置，diff 不為空就作廢該輪 | `tools/test_workflow/qdisc_snapshot.sh`（`faults.sh` 自動呼叫） |
| sFlow fuzzer | libFuzzer harness（`-DFUZZING=ON`，clang-only） | `./build-fuzz/bin/fuzz_sflow <corpus> -max_total_time=5400 -timeout=5` |

**跑 `faults.sh` 前要知道的兩件事**（兩件都是它首役當場學到的）：

- **P4 stack 要 `export PATHS_URL=http://localhost:8081`**，否則 `criteria.py` 預設打 Ryu 的
  :8080，paths 通道整輪回 unknown，三通道法定人數**靜默**降成兩通道。
- **訊號注入不要用裸 `sudo -n kill`**：本機 sudoers 沒有 bare `kill` 的 NOPASSWD，注入會
  無聲失敗成 not-injected，而下游 capture 與 verdict 一切「正常」。用
  `FAULTS_KILL="sudo -n mnexec -a 1 kill"`。注入後一律斷言它宣稱的狀態改變
  （訊號驗 `/proc/<pid>/status` 的 `State`，qdisc 驗 `tc qdisc show`）。

**tc 的部分已經好了**：2026-08-15 Adam 補上兩條 `parent` 規則，`sudo -n -l`（08-17 複查）
四條全在，所以 `faults.sh` 預設的安全形式現在直接可用，不必再繞 mnexec。

---

## 5. 環境陷阱（只列最常咬人的，完整清單見 `doc/2026-07-29_environment_gotchas.md`）

**動到 fabric 的那些陷阱在 §2.10**（`ifconfig down`、`pkill -f`、Mininet 共用 PID 空間、
裸 `sudo -n kill`……）——那份表是唯一版本，這裡不重複，兩邊各寫一份就是它們開始分歧的起點。

以下是**建置與測試**這一側的，跟開機無關：

- TSan 一定要 `setarch "$(uname -m)" -R`，否則在 main 之前就 FATAL（`local_ci.sh` 已寫死）。
- 對未 commit 的檔案做 mutation 之前先 commit——`git checkout --` 洗掉過未提交的修復。
- 🔴 **測試裡的暫存路徑一定要帶「每個行程都不一樣」的東西**：`::getpid()`／`os.getpid()`／
  `$$`，或者乾脆讓 `mkdtemp`／`mkstemp`／`mktemp -d` 去挑名字。`ctest` 每一支測試各一個行程，
  所以**常數路徑**與**行程內計數器**（每個行程都從 0 重來）都會撞——兩個行程同時建、同時
  `remove_all`，其中一個的 fixture 建構子就會在對方 chdir 在裡面的時候把樹刪掉。
  症狀是 **`-j1` 全綠、`-j2` 偶爾紅、而且每次紅的不是同一支**，最後都會被當成「重跑一次就好」。
  2026-09-06（W11 那一輪）真的發生過，`c3d99d00` 一次修掉六個 fixture。
  閘門：`python3 tests/shell/check_test_tmpdirs.py`（rc 0 乾淨／1 有固定路徑／**2 有檔案讀不到、
  那不算乾淨**），自己的測試是 `tests/python/test_check_test_tmpdirs.py`、變異閘門是
  `tests/shell/mutate_check_test_tmpdirs.sh`。掃描器只抓**真的會去建立／刪除**的路徑：
  只拿去給 parser 的 argv、斷言用的字串、注入 payload 一律不報（規則與逐條例外寫在腳本開頭）。
  `l1_unit_tests.sh` 的第 0b 步（緊接在 gate anchors 之後、**建置之前**）會自動跑它，
  rc 1 與 rc 2 都算紅、但印不同的話——rc 2 是「這支閘門瞎了」，不是「樹是乾淨的」。
- **Python 一律用 `p4_proxy/venv/bin/python`**（見 §1）。conda 的 `python3` 缺 grpc/networkx。
- 監看用的 shell 迴圈要用 `pgrep -f "poll_al[l].sh"` 這種 bracket 寫法，否則會匹配到自己、
  永遠不結束（真的掛過 8 小時）。⚠️ bracket **只保護 pattern**——同一行指令裡任何地方
  （`echo` 標籤、變數預設值）出現同一個裸字串，一樣會匹配到自己。最穩的是把量測指令
  **寫進 script 檔**，script 的 argv 天然免疫。

### 5.1 引 `doc/KNOWN-ISSUES.md` 用條目代號，不要用行號

[Co-developed with claude code -- Adam]

**寫 `KNOWN-ISSUES B-11`，不要寫 `KNOWN-ISSUES.md:<行號>`。** 那份清單天天被插新條目，
插一條就把它下面每一行都推走；2026-09-07 全 repo 62 個行號引用裡有 **58 個指到別的條目**，
其中四個**在寫下的當天就已經指錯**。代號在條目被重新編號之前都是對的。

- 閘門＝`tests/python/test_known_issues_references.py`（L1 用 glob 自動收，不必登記 ctest）。
  它掃 `doc/ tests/ tools/ src/ include/ p4_proxy/` 與根目錄 `*.md`，
  對每一個 `KNOWN-ISSUES.md:<n>` 形式的引用，查同一行（找不到再查同一段）最近的代號，
  並斷言第 n 行真的落在該代號的區段裡。沒有代號可對就紅，訊息寫「改成條目代號」。
- **它不禁止行號**——留行號當附註可以，但**代號要在同一行**，而且行號會被驗。
  最省事的是不留行號。
- `*.log`／`*.diff`／`*.patch` **不掃也不改**：那是逐字紀錄，改了就是竄改。
- 跑法：`p4_proxy/venv/bin/python -m unittest discover -s tests/python -p test_known_issues_references.py`；
  變異閘門 `bash tests/shell/mutate_known_issues_references.sh`（9 變異全紅＋1 對照格存活）。
- 沒有代號可引的條目（`### 縮短 LLDP beacon 間隔…` 那十七個標題）先用
  `KNOWN-ISSUES §G` 這種「章＋標題引號」的寫法；**不要自己替它們補代號**。

---

## 6. 其餘七份測試文件現在的地位

| 文件 | 地位 | 什麼時候才需要它 |
|---|---|---|
| `2026-08-07_testing_tools_overview.md` | **參照**：每個工具的完整說明 | 要深入某個工具的設計與取捨時 |
| `2026-07-27_testing_workflow.md` | **參照**：L0–L5 五層架構的定義與理由 | 要新增一層或搬動層界時 |
| `2026-07-28_test_coverage_gaps.md` | **參照**：涵蓋範圍與已知缺口 | 要判斷某個東西有沒有被測到時 |
| `2026-08-10_p4_manual_test_runbook.md` | **手動 runbook**：P4 逐步一步一確認。⚠️ **其中的起停步驟已由 §2 取代** | 要人工走一輪 P4 的**驗證**部分時 |
| `2026-08-10_ovs_manual_test_runbook.md` | 同上，OVS | 同上 |
| `2026-07-30_full_test_runbook.md` | **歷史**：OVS+P4 各一輪的早期執行腳本 | 追溯當初怎麼建立基準時 |
| `2026-07-29_p4_status_and_test_guide.md` | **歷史**：2026-07-30 當時的 P4 進度與測法 | 追溯 P4 支援的演進時 |

**唯一的權威是這一份加上它指到的工具本身。** 上表任何一份與這裡衝突，以這裡為準；
與**程式碼**衝突，以程式碼為準，並回來修這一份。
