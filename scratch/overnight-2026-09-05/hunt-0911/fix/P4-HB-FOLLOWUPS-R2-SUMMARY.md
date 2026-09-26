# SUMMARY：三條後續的 judge NOTE（N2-1、N3-1／N3-2、N1-1／N1-2、N2-2）——round 2b

- **分支**：`fix/hb-followups-r2-0927`，從 trunk＝main `3f8c2abf` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-hb-followups-r2-0927`。
- **Head**：`4f661e31baf999b729691b27b27391b5d59bfd4f`，共 10 個 commit（清單在 §7）。
- 沒 push、沒 merge、沒 sudo、沒跑任何 `ndt` 動詞、沒動主 checkout 的 working tree、root helper 沒動。
- **但這一輪我碰到了 lab 一次（非預期，已查清楚）——先讀 §0。**

[Co-developed with claude code -- Adam]

## 0. 🔴 事故：我的覆蓋率量測，把一條真的 iperf 打進了你 live 06 的 p4runtime/solution 臂

**發生了什麼（OBSERVED）**

- 01:55:05–01:55:17 +0800（17:55:05–17:55:17Z），我在 worktree 裡跑覆蓋率量測（`cover_run2.sh`，未經 guard 的試跑）。它會執行 `tests/shell/test_live_p1_common.sh`。
- 那支測試的 5e 段有兩格（`to-h2`、`default`，`test_live_p1_common.sh:539,541`）用 `$PKG3`。這個假套件的主機名是 h1..h3，**和真 fabric 的主機名一樣**。`drive()` 只 stub 了 `curl` 和 `sleep`，**沒有 stub `sudo` 和 `iperf`**。
- `link_usage_round`（`_common.sh:1078-`）用 `host_pid` 掃 `ps` 找 `mininet:h1`／`mininet:h2`。當時你的 06 正在跑 p4runtime/solution，找得到。於是往下走：
  - `netdev_tx`；
  - `sudo -n mnexec -a <h2> iperf -s -u &`；
  - `sudo -n mnexec -a <h1> iperf -c 10.0.2.2 -u -b 2M -l 1200 …`。
  - `mnexec` 在這台是 NOPASSWD。
- 證據一：覆蓋標記。
  - `_common.sh-701`（netdev_tx）在 01:55:08.172 被建立，時間落在 `test_live_p1_common` 跑的區間內。
  - `host_pid` 對兩端都回數字之後，才會走到這一行，接著就是那兩條 `sudo -n mnexec … iperf`。
  - 01:55:16.72 再走到 1160／1168／1169。
- 證據二：你那一臂的 G1 raw。
  - 位置：`doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T175425Z_p4runtime_solution_ndtwin/link_usage/`（未提交的觀測）。
  - 它的 iperf 窗是 16 s：client 在 01:55:08.71 結束，`netdev.after` 在 01:55:09.56 讀。
  - 我的 flow 大約從 01:55:08.2 開始，**和它的量測窗尾重疊約 1.3 s**。
  - `onpath.txt` 是 `s1-eth2 P 4735073`、`s2-eth1 P 4719873`。
  - 這一臂之前 6 次（09-19、09-24 兩次、09-26 三次）都是 4,359,824–4,360,027 與 4,346,031。
  - **多出 ≈375 kB ≈ 301 個 1242 B 的 frame ≈ 2.1 Mbit/s 的 1.38 s**，和重疊時間吻合。
- 影響範圍（OBSERVED）：
  - 那一臂仍是 PASS (5/5)，G1 的判定不受影響：我的 flow 和它同一條 h1→h2 路徑，只加在 on-path 上。
  - H5 的 `v_same_06`（08:508）只比每臂的 rc 和 verdict。**H5 的 06 對照不受影響。**
  - 受影響的是那一臂 G1 的**數字**（on-path bytes 約 +8.6%；twin integral 在 01:55:09.54 讀，推測也吃到一部分）。
- 其他時間點（OBSERVED）：
  - 這個 session 裡其餘幾次跑這支測試，`host_pid` 都是空的，沒有碰到 lab：
    - 00:11 xtrace；
    - 00:25／00:28 覆蓋率；
    - 00:59 的 f4f43a32 閘門；
    - 01:57 cover4。
  - 我把 09-26 06:00Z 以來每個 `*_ndtwin` run 的 `onpath.txt` 都掃過一遍：只有這一臂有 +375 kB 等級的跳動，同一場 06（17:29Z 起）的其他臂，和它們前一場（15:3x–15:5xZ）相比，on-path 位元組的差異都在 ~5 kB 以內（ecn +5,035、mri +3,636，其餘幾十到幾百 B）；只有 p4runtime/solution 多出 +375,249。
- 目前狀態：`ps` 裡沒有殘留的 iperf，也沒有 mininet 主機。

**我已經做的（OBSERVED）**

- 這一輪之後的每個閘門，PATH 最前面都放了兩個 shim：
  - `sudo`：記錄後拒絕；
  - `curl`：記錄一切，拒絕 `:8000`／`:8081`。
  - shim 在 `logs/gates-0910/scripts-p4hbr2b-4f661e31*/nolab/`。
- tripwire log 本身就是最後一個閘門。
- `cover_run2.sh` 在有任何 `mininet:` 主機時**不跑** `test_live_p1_common`，記成 NOT RUN。

**建議（INFERRED，要你決定）**

- p4runtime/solution 在 17:54:25Z 那次的 G1 數字不要當乾淨數據引用。要重跑的話只需要這一臂。
- `test_live_p1_common.sh` 5e 的 `to-h2`／`default` 是既有的測試缺陷。同一段的註解已經對 `no-ns` 那格指出過這個危險，但只修了那一格。
  - 修法二選一：改用不可能存在的主機名（像 `no-ns` 那格一樣用 zz1..zz3）；或在 `drive()` 裡 stub `sudo`／`iperf`。
  - 這支檔案不在這張票的範圍內，這個分支沒改；你已指示另開 `fix/live-p1-common-5e-nolab-0927` 來修。

## 1. N2-1：08 的 sampler 在「起來之後」才死，現在會讓整個 run 以 FAIL 結束

**red first：`7403eb79`**（只有測試）

- 在該 commit 的 archive 上 SELF-TEST FAIL，**正好 5 紅**。閘門逐條比對，每條恰好紅一次，沒有其他紅：
  - `H5 sampler killed after a good start`（run 的最後一行是 `PASS 08_heartbeat`）；
  - `H5 sampler with a warning on its stderr`（同上）；
  - `H5 01 with no sample in its window`（`v_no_session` 在零樣本時回 OK）；
  - `H5 a sampler that stopped reading for 500 s mid-06`；
  - `H5 01 where the sampler stopped half-way`。

**修正：`73bd47b0`**（行號為 HEAD 的 `08_heartbeat.sh`）

- (a) stderr 非空時，`sampler_stop` 從 `bad` 改成 `fail`（:791）。`bad` 只印，不改 `VERDICT_RC`。
- (b) 寫 stop 檔**之前**先 `sampler_alive`（:772-782）。
  - 判斷條件是 pid 活著，**而且** `/proc/<pid>/cmdline` 裡有這個 sampler 的 stop 檔路徑。這是為了防 pid 被回收後重用。
  - 不在 → `fail`，附上它的 stderr 開頭。
  - 被 signal 殺掉的 sampler 沒有 stderr，所以只能靠這一步抓到。
- (c) 樣本覆蓋規則：`MAX_SAMPLE_GAP_S = 10.0`（:541）；`sample_gaps`（:543）找出區間內（含兩端）超過 10 s 沒有讀取的段落。
  - `v_h5_heartbeat`：從第一臂開始到結束，不能有缺口（:571）。
  - `v_no_session`：01 的窗內零樣本＝整窗都是缺口 → BAD（:586）。
- 為什麼用「缺口」而不是「每臂至少一個樣本」（INFERRED）：被拒絕的臂只有約 1 s，讀取間隔是 1 s；逐臂要求會在健康的 run 上假紅。

**後加的測試與 mutant**

- `ace06dd6`：`sampler_alive` 不把重用的 pid 當成 sampler（在修正之後才寫，它的鑑別力由 L59 證明）。
- `consts`（08:139-142）現在由自測執行。原本只有 live H1-H4 會跑（judge 的 N2-2）。
  - 它在 red-first 上本來就會綠：程式碼早就在，只是沒人跑。它的鑑別力由 L60 證明。
- `4fe7ed2b`：`mutate_p4_heartbeat_w` 加 L55–L60，每個都有指名的 killer：
  - L55：stderr 改回 `bad` → `H5 sampler with a warning on its stderr`；
  - L56：`if ! sampler_alive` → `if false` → `H5 sampler killed after a good start`；
  - L57：`v_no_session` 的 gaps → `[]` → `H5 01 with no sample in its window`；
  - L58：`v_h5_heartbeat` 的 gaps → `[]` → `H5 a sampler that stopped reading for 500 s mid-06`；
  - L59：`sampler_alive` 不看 argv → `sampler_alive with a reused pid`；
  - L60：`consts` 印的順序錯 → `consts gave`。
- lmutant／lbase 另外補了 p4_proxy 的 symlink，讓 mutant 樹裡的 `consts` 跑得起來。

## 2. N3-1：07 的 `links_heard` 在 startup grace 內的 false green

- **缺陷**：從沒聽到的方向在 30 s grace 內輸出 `source heartbeat / down false / last_beacon_age_s null`，舊的 `links_heard` 會判 OK。
- **修正：`7748943b`**
  - HEARD 的定義改成「有 age」：`last_beacon_age_s` 必須是數字，不接受 bool（07:205-206）。
  - 否則回 BAD，理由是 `not heard yet (no last_beacon_age_s: the proxy's startup grace) [...]`（:218）。
- **fixture**（red first `691d46da`）：
  - `links_one_grace.json`：一個方向在 grace 內；
  - `state_grace.json`：八個方向都在 grace 內。
  - 兩條在 691d46da 上都紅，舊規則回 `OK 8/8 … every one source: heartbeat, down: false`。這兩條才是真正的 red first。
- **真實資料**（judge 建議的第 2 項，OBSERVED）：
  - 來源：你 15:26Z 那次 08 run 的四份 switch_state，路徑 `live-p1/runs/2026-09-26T152605Z_08_heartbeat/`（未提交的觀測）。我複製了一份唯讀快照，sha256 和原檔相同（22 `bbc815c2…`、35 `3af7e640…`、61 `c6bbc2c4…`、67 `1b2b2df6…`、topology `d9dc6f1e…`）。
  - 結果：**22、61 → BAD**（剛 up，全是 declared）；**35、67 → OK**（還原後八條都 heartbeat，有 age）。與 judge 的預期一致。
  - 07 自測有一段只在這些檔案存在時才跑（`SELFTEST_HB_RUN`／`SELFTEST_HB_PKGS`），閘門每次都有跑，並驗了 4 條 ok。
- **mutant**：L7-23（`unheard = []`）→ killer `L1 a direction never heard yet (the startup grace)`。

## 3. N3-2：`state_until` 和 live 的兩個呼叫點，現在由自測透過 file:// 執行

**修正：`7748943b`**

- `state_until` 和兩個呼叫點原本定義在 07 的 `--self-test` 分派**下面**，自測根本呼叫不到。
- 現在移到分派**上面**，並把兩個呼叫點抽成函數：
  - `l6_switch_state`：參數化的共同體；
  - `l6_roles`／`l6_plain`：live 的兩個呼叫點，參數原樣照搬。
  - 位置：07:354-392。
  - live 流程改成呼叫 `l6_roles`（:801）與 `l6_plain`（:892）。
- `st_l6`：
  - 用 08 的 file:// 先例，`PROXY_URL=file://`，並用背景寫入器在 2.5 s 時換掉 switch_state。
  - 5 格：
    - roles 一次就全 heard → 三個 OK、1 次讀；
    - 先 grace、2.5 s 後 heard → 在後面的讀取得到 OK（≥2 次讀）；
    - poll 內一直沒 heard → BAD（≥2 次讀）；
    - 完全沒有 switch_state → `fail`；
    - unbound 呼叫點用它自己的 capabilities、skipped 和標籤。
- **red first `691d46da`**：共 7 紅，其中 5 紅是「`l6_roles: command not found`」（函數當時還不存在）。這 5 條的鑑別力靠 mutant 證明：
  - L7-24：`state_until` 讀一次就停 → `state_until through the startup grace`；
  - L7-25：unbound 呼叫點用 owned 的 caps → `L6/L1 on switch_state (unbound)`；
  - L7-26：L1 永遠 `judge "OK stub"` → `never heard within the poll`；
  - L7-27：`if true` → `no switch_state at all`。
- `024b3219` 是測試格式的修正：
  - red 行改成 `<case> -- …`，因為 `l7_report` 要比對 case 名後面跟空格；
  - ok()／red() 的 printf 格式裡原本誤放了真的換行字元，改回 `\n`。
- **仍未做（照實說）**：07 從沒在 lab 上跑過，`state_until` 的第一次 live 執行還在後面。

## 4. N1-1／N1-2：ndt serve 的文字

- `8a9876f8`：`tools/ndt_serve/README.md:60` 改成 `ndt:9416-9431`。
- `verbs.py`：原本說 124 行都在「above」，改成說清楚位置——122 行在 `cmd_status` 之前，2 行在它裡面（`heartbeat` 那一列，位於判定之前）。
  - 已核對：`cmd_status` 從 6548 移到 6670，正好 +122。
- `4f661e31`（新增，讓 N1-1 也有 red first）：
  - 新測試 `RcProvenance.test_lock_probe_citations_are_lock_probe`。它讀 README、serve.py、test_ndt_serve.py 裡所有在 lock probe 旁邊引用的 `(ndt:A-B)`，要求每一個都：
    - 從 `lock_probe` 的註解區塊開始；
    - 涵蓋它對 `/ndt/acquire_lock` 的 POST；
    - 落在 `lock_probe` 函數內。
  - 如果某個地方一條引用都沒有，也算失敗。
  - 對 `3f8c2abf` 的 `tools/ndt_serve` 跑是紅的（`README.md:60 cites ndt:9292-9307`），在 HEAD 是綠的。
  - `mutate_ndt_serve` 現在會把 README 放進每棵 mutant 樹，並監看它有沒有被改。新增兩個 mutant：
    - M64：README 改回 9292-9307；
    - M65：serve.py 的範圍停在 POST 之前。
  - killer 都是這個新測試。
- 其他 ndt 行號引用我逐條用 `sed` 看過，都指對了。這些是 OBSERVED，但沒有自動化測試：
  - `verbs.py:207` 的 7070-7072 與 6698；
  - `serve.py:513` 的 4362、`:526` 的 5786、`:753` 的 5799；
  - `test_ndt_serve_cells.py:101,293`。
- N1-2 只是註解文字，沒有測試。

## 5. N2-2：內嵌程式盤點重做——這次也修正了 judge 沒提到的漏法

`embedded_sweep2.py` 改在**邏輯行**上比對：接起反斜線續行，偏移量可以映射回原本的實體行。

**judge 點名的兩段：抓到了**

- 08:140 的 `consts`；
- `_common.sh:748` 的 `link_usage_window`。

**重新計數時，我另外發現舊盤點還漏了這些（OBSERVED）**

1. `awk -v c="$(cat "$X/clock")"`：舊版把裡面的 `"$HB_WATCH_SIM/clock"` 誤讀成一段 double-quoted 的 awk 程式，真正的 awk 程式（`S_heartbeat_spike.sh:1175`，`BEGIN { printf "%.6f", c + d }`）反而沒算到。
   - 舊的 79 裡有一列是幻影，卻少了一段真的。
2. 直譯器清單少了 spike 的 `$PY_SELFTEST`，因此漏掉 5 段：916、924（`PYAGREE` heredoc）、1078、1081、1096。
3. 先寫進檔案、再從檔案執行的程式沒被找：`cat > x.py <<'PYFAKE'`（1128）、`<<'PYCHECK'`（1663）。
4. 10 段 shell heredoc（`DRIVER`×7、`FAKETC`、`FAKEQDISC`、`FAKENDT`）從沒被 `bash -n` 過。
   - 1175 那段 awk 就在 `FAKETC` 裡面，所以 shell heredoc 的內容現在也會被掃描。

**新的數字（OBSERVED，`embedded_compile` 在 HEAD 上）**

- 共 **98 列**：88 段 Python／awk，加 10 段 shell。
  - 88 裡的 08:753 是 08:716 `SAMPLER_PY` 的**呼叫點**，所以不同的 Python／awk 程式文字是 **87 段**。
  - 用舊的單位（每列一段）比：舊宣稱 79，judge 說 ≥81，實際是 88。
- 分檔：08 32、07 15、`_common.sh` 23、spike 27（其中 10 段是 shell）、oldcode 1。
- **掃描器找到的這 98 列裡，0 段編譯不過**。檢查方式：Python 3.13 與 venv Python 各編一次；awk 用 `mawk -W dump`；shell 用 `bash -n`。
  - （R-N3 措辭更正，09-27 r3）這句只對掃描器的集合成立。08 自測裡還有兩段程式不在集合內：
    - 08:1381：`st_h5_dies` 在 `SAMPLER_PY` 前面補一行 stderr 的雙引號組合字串；
    - 08:1717：`SAMPLER_PY='print(f"{d.get(\"status\")}")'`，刻意寫壞、讓 sampler 起不來。
  - 兩段都是縮排的單行變數賦值，掃描器的 `*_PY=` 樣式認不出來。
- 獨立對帳：每個檔用 grep 數 awk、`python -c`、jqp、heredoc 開頭，數字與掃描出來的列數一一相等。
  - awk 14／0／10／7／0；`-c` 12／1／11／7／0；jqp 0／3／1／0／0；heredoc 開頭 6／11／1／13／1。

**覆蓋（OBSERVED，`embedded_cover` 在 HEAD 上；每個 run 寫進自己的標記目錄，所以能說出是誰執行了哪一段）**

- 97 段做了標記，**88 段被自測執行**，9 段沒有。沒做標記的只有 08:753：它是 716 那段 `SAMPLER_PY` 的呼叫點，716 本身有被執行。
- 分檔（標記／執行）：08 31／31；07 15／12；`_common.sh` 23／19；spike 27／26；oldcode 1／0。
- 本輪新加進自測的：
  - 08:140 的 `consts`（由 08 自測執行）；
  - 07 的 `state_until` 與兩個呼叫點；
  - `_common.sh:315` 的 `get_json`（07 的 `st_l6` 透過 file:// 呼叫它）；
  - spike 那 5 段 `$PY_SELFTEST`、2 段寫檔的 Python、10 段 shell heredoc，全部由 spike 自測執行。
  - 另外，judge 點名的 `_common.sh:748` `link_usage_window` 是由 `test_live_p1_common` 執行的。
- 沒被自測執行的 9 段：
  - 07 的 698、708（jqp）與 751（ENTRY_TABLES）；
  - `_common.sh` 的 701（netdev_tx）與 1160／1168／1169（awk）；
  - spike 的 200（consts）；
  - `oldcode_selftest.sh:67`。
  - 這 9 段 `runtime_check` 都跑過真實的文字，而且都答對。`runtime_covers_not` 閘門核對了「NOT 集合 ⊆ runtime_check 跑過的集合」。
- 覆蓋率量測時沒有 mininet 主機（`live_p1_common` 前後都是 0）。`_common.sh` 的 701／1160-1169 是否被執行，取決於有沒有 fabric 在跑（§0），所以量測前會先檢查，有主機就不跑。

## 6. 更正我先前的宣稱

| 先前的宣稱 | 更正 |
|---|---|
| `P4-HB-H5SAMPLER-SUMMARY.md:79`「五個檔共 79 段」 | 錯：98 列（88 段 Python／awk＋10 段 shell）；judge 說的 ≥81 是對的，而且仍然偏低（見 §5 的四種漏法） |
| 同檔「08 未執行 0 段」 | 當時錯（`consts` 只有 live 才跑）；現在在 HEAD 上是 31／31，`consts` 由自測執行 |
| 同檔 :85、:111「沒被執行的 10 段都經 runtime_check」 | 錯：是 9／10，缺 `oldcode_selftest.sh:67`。現在 `runtime_check2` 用 `--list` 跑這一段，另有閘門 `runtime_covers_not` 核對：每一列 NOT 都要在 runtime_check 的 COVERED 集合裡 |
| 同檔 :42「刻意做成確定性的測試」 | 措辭過頭：停止路徑那個測試只有 ~0.5 s 的時序餘裕，不是確定性的 |
| `P4-HB07-SUMMARY.md:15`「07 live 的 `declared_links_marked` 一定會紅」 | 錯：如果單次讀取剛好落在第一個 watchdog pass 之前（真實的 22／61 正是這種情形，全部還是 declared），就會碰巧綠。修正仍然必要 |
| 本輪以前每份 SUMMARY 的「沒碰 lab」 | 前幾輪的 `test_live_p1_common` 在本 session 可查的 run 都沒碰到（§0）；本輪碰到一次 |

兩份舊 SUMMARY 的檔尾各加了一段「更正（09-27）」，指向這裡；原文沒有改。

## 7. Commits（`3f8c2abf..4f661e31`，舊→新）

- `7403eb79` 08 (red first): a sampler that dies after a good start, or complains, must end the run FAIL
- `73bd47b0` 08: a sampler that dies after a good start, or writes to its stderr, fails the run; the verdicts need reads throughout
- `691d46da` 07 (red first): the startup grace passes L1 on switch_state, and L6/L1's live code has never run
- `7748943b` 07: HEARD means an age; L6/L1 on switch_state is two functions the self-test runs, above its dispatch
- `8a9876f8` ndt serve: README cites lock_probe at ndt:9416-9431; verbs.py says where segment W's 124 lines are
- `ace06dd6` 08 tests: sampler_alive does not take a reused pid for the sampler
- `4fe7ed2b` HB W gate: L55-L60 -- a sampler that dies late or complains, reads throughout, sampler_alive's argv, consts
- `024b3219` 07 tests: st_l6's red lines read "<case> -- <what it saw>"; ok/red print a real \n
- `463b2691` roles gate: L7-23..L7-27 -- the startup grace, state_until, and the live path's L6/L1 calls
- `4f661e31` ndt serve tests: hold every lock-probe citation to ndt's lock_probe; M64/M65

## 8. 閘門

全部透過 `env JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh` 執行。

- log 在 `logs/gates-0910/<gate>.p4hbr2b-4f661e31.log`：第一行是完整 sha，最後一行是 `# rc=`。
- 執行的腳本是 `scripts-p4hbr2b-4f661e31{,-extra,-repeat}/` 裡的副本，附 SHA256SUMS。
- PATH 最前面都是 nolab shim：sudo 一律拒絕，打 :8000／:8081 的 curl 也拒絕，全部寫進 tripwire。

| 閘門 | rc | 結果（OBSERVED） |
|---|---|---|
| `live08_selftest` | 0 | SELF-TEST PASS |
| `live07_selftest` | 0 | SELF-TEST PASS（56 ok，含四份真實 capture） |
| `redfirst_r2b` | **1** | 三棵 red-first 樹都照預期紅（08 恰好 5 紅、07 恰好 7 紅、ndt serve 在 README:60 紅），07 和 ndt serve 在 HEAD 是綠的；**只有這一次，08 at HEAD 不是乾淨的 PASS，輸出沒留下來**，見下面的說明 |
| `mutate_p4_heartbeat_w` | 0 | 195 個 mutation，0 存活（L55–L60 各自被指名的 killer 抓到） |
| `mutate_roles_binding` | 0 | 172 個 mutation，0 存活（L7-23..27） |
| `check_gate_anchors` | 0 | 120/120 |
| `test_ndt_serve` | 0 | 74 個測試 OK，含 `test_lock_probe_citations_are_lock_probe` |
| `test_ndt_serve_cells` | 0 | 35 個測試 OK |
| `mutate_ndt_serve` | 0 | 93 個 mutation，0 存活（M64、M65 抓到） |
| `embedded_compile` | 0 | 掃描器集合裡的 98 段（88 段 Python／awk、10 段 shell），0 段編譯不過；08:1381、08:1717 不在集合內（R-N3，見 §5） |
| `embedded_cover` | 0 | 97 段標記、88 段被執行；每個 run 都 rc 0；量測時沒有 mininet 主機 |
| `runtime_check` | 0 | 9 段 NOT 加上 315，全部答對 |
| `runtime_covers_not` | 0 | 每一段 NOT 都在 runtime_check 裡跑過 |
| `nolab_tripwire` | 0 | 0 次 sudo、0 次打 lab 端點 |
| `flake08_guard` | 0 | guard 下 08 自測 20/20 乾淨 |
| `redfirst_r2b_keep` | 0 | red-first 全部照預期；08 at HEAD 125 ok、0 紅 |
| `nolab_tripwire_extra` | 0 | 0／0 |
| `redfirst_r2b_repeat` | 0 | 同一個設定再跑 10 次，10/10 都照預期（保留了失敗輸出，但沒有失敗） |
| `nolab_tripwire_repeat` | 0 | 0／0 |

**那一次沒重現的紅（照實說）**
- OBSERVED：
  - `redfirst_r2b`（18:11:15–18:12:01Z，46 s，時長正常）裡，08 at HEAD 那次不是乾淨的 PASS。
  - 同一次 run 裡，新加的三格 sampler 測試和 consts 都有 ok 行，所以不是它們。
  - 之後 08 at HEAD 再跑了 54 次，全部乾淨：guard 內 31 次（20＋1＋10），guard 外 23 次。
  - 那次的輸出沒保留，因為當時的 green() 不會留輸出；`redfirst_r2b.sh` 現在會留。
  - N2-3 的 flake 率：08 at HEAD 共 56 次，1 次不乾淨。
- INFERRED：
  - 最可能是 08 裡既有、會受時序影響的某一格：st_sampler 的 0.5 s 停留、restore_watch 的 0.3 s 改寫、graph_until 的 1.5–3.5 s 窗。
  - 抓不到它，我就沒有依據去改任何一格。沒有加重試，也沒有放寬任何一格。
  - 這個 gate 的紅記錄保持原樣。

## 9. 沒做的

- N2-3：量了，沒有修。08 at HEAD 共 56 次、1 次不乾淨，那一次沒被重現、也沒有輸出（§8）。
- N3-3（拿 062604Z 的真實模型比對）這台沒跑。我用的是 §2 那四份真實 switch_state。
- 07 仍未在 lab 上跑過。
- `test_live_p1_common.sh` 5e 的缺陷不在這個分支修，改由另一個分支 `fix/live-p1-common-5e-nolab-0927` 處理（§0，照你的指示）。

DELIVERED 4f661e31baf999b729691b27b27391b5d59bfd4f
