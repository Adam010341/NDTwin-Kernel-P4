# SUMMARY：R-N1、R-N2、Q2、R-N3（round 3）

- **分支**：`fix/hb-followups-r3-0927`，從 trunk `b2eeb71d` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-hb-followups-r3-0927`。
- **Head**：`c22d130041f0416293e333fbcd13956d5e4bbbd7`，共 5 個 commit。
- 沒 push、沒 merge、沒 sudo、沒碰 lab 也沒碰主 checkout，每一次執行都走 guard 並帶 nolab shim。driver 一律從唯讀的凍結副本執行。

[Co-developed with claude code -- Adam]

## 1. R-N1：08 的 mutant tree 不再帶著 checkout 的 lab 狀態

**缺陷（OBSERVED）**

- `mutate_p4_heartbeat_w.sh` 的 lmutant／lbase 把整個 `p4_proxy` symlink 進每一棵 mutant tree。
- `_common.sh` 以那棵 tree 為基準決定三個 lab-state knob 的路徑：
  - `$REPO/p4_proxy/mininet/host_count_override`；
  - `app_package_override`；
  - `telemetry_override`。
- 結果：tree 裡的 knob 就是 checkout 自己的 knob，一個會寫 knob 的 mutant 就會寫到真的那一份。

**red first：`c0cef392`**

- 所有 tree 改由同一個 builder `ltree` 建立。
- `ltree_leaks` 列出兩種「出口」：
  - 除了兩條唯讀連結（`p4_proxy/proxy_agent` 給 consts 用、`p4_proxy/venv` 給直譯器用）之外，每一條通往 tree 外的連結；
  - tree 裡出現的每一個 knob。
- 進入任何 mutation 之前先做 preflight：
  - probe tree 有出口 → refuse；
  - 對照組（一棵連結整個 `p4_proxy` 的 tree）看不到出口 → 也 refuse，因為那表示這個檢查沒有鑑別力。
- 閘門 `redfirst_r3` 的實測（OBSERVED）：
  - 在 `c0cef392` 上跑整支 gate：rc 2，在任何 mutation 之前 refuse，沒有任何 mutation 被執行。
  - refuse 的訊息寫明兩個出口：
    - `p4_proxy/mininet/host_count_override resolves to <worktree>/p4_proxy/mininet/host_count_override`
    - `p4_proxy is a link to <worktree>/p4_proxy`
  - 在 worktree 裡，這個「checkout」就是 worktree 本身。在主 checkout 上跑這支 gate 時，它就是 lab 真正在用的那一份 knob（INFERRED；那份檔案在主 checkout 的 git status 裡是 M）。

**修正：`3eb42ba5`**

- `ltree` 把 `p4_proxy` 建成真的目錄，裡面只放 `proxy_agent` 和 `venv` 兩條連結。tree 裡根本沒有 `p4_proxy/mininet`。
- HEAD 的 preflight 印出：`08's mutant tree: only p4_proxy/proxy_agent and p4_proxy/venv lead out of it, and no lab-state knob is in it`。
- 08 自測在這樣的 tree 裡是 PASS（guard 內試跑；gate 的 lbase 也會跑）。
- `redfirst_r3` 在同一份原始碼上分別用 `c0cef392` 和 HEAD 的 `ltree` 各建一棵 tree：前者列出出口；HEAD 一個都沒有，而且沒有 `p4_proxy/mininet`，`proxy_agent` 與 venv 的 python 都在。

## 2. R-N2：07 live path 的 L1 poll 不再從環境繼承

**缺陷**

- `l6_switch_state` 用 `${L1_POLL_S:-30}` 決定 poll 時間，而 `L1_POLL_S` 正是 st_l6 用來縮短 poll 的旋鈕。
- 所以呼叫端只要剛好 export 了它，live path 等 watchdog 第一次 pass 的時間就會被砍短。

**red first：`a435d24e`**

- 新增一格自測：照 live path 的呼叫方式（`l6_roles`，不帶參數）去跑，環境裡放 `L1_POLL_S=2` 和 `SELFTEST_L1_POLL_S=2`，對一份永遠 heard 不到的 switch_state。
- 要求：6.5 s 時它還在 poll，也就是還沒有任何判定，而且讀了不只一次。
- 在 `a435d24e` 上**正好只紅這一格**：`judged 3 polls 2`。繼承來的 2 s 讓它在 6.5 s 前就判了三次。

**修正：`f90722f3`**

- poll 改成 `l6_switch_state` 的第 7 個參數。
- `l6_roles`／`l6_plain` 把自己的參數傳下去；沒有參數時用 30 s。live path 正是不帶參數呼叫（07:827、07:918）。
- st_l6 改成用參數傳它的短 poll，不再設 `L1_POLL_S`。
- 07 裡已經沒有任何地方讀 `L1_POLL_S`，所以 export 了它或 `SELFTEST_L1_POLL_S` 都沒有作用。
- 我選「參數」而不是「改名成 `SELFTEST_L1_POLL_S`」：改名後它仍然是一個環境變數，仍然可以被繼承；參數不行。
- 在 HEAD 上，新格是 `still polling at 6.5 s (judged 0 polls 4)`。

**閘門 `c22d1300`：`mutate_roles_binding` 加兩個 mutant**

- L7-28：讀 `${L1_POLL_S:-$poll}`。
- L7-29：live path 自己的預設改成 2 s。
- 兩個的 killer 都是新格。結果見 §6。

## 3. Q2：red-first 的 green() 會保留輸出，而且分得出 PASS 後面多一行

新增 `redfirst_lib.sh`，以後每一輪的 redfirst 腳本都 source 它（本輪的 `redfirst_r3.sh` 已經在用）。

- `green`：只有同時滿足兩個條件才算乾淨的 PASS：
  - `SELF-TEST PASS` 是**最後一行**；
  - 它上面沒有任何紅行。
- 不乾淨時，會用下面四種說法之一講出原因，並**保留輸出**（`$KEEP`）：
  - 沒有 PASS 行；
  - PASS 不是最後一行（附上後面有幾行、第一行是什麼）；
  - PASS 上面有紅行；
  - （`exactly_red` 專用）紅的集合不對。
- `--self-check` 用 fixture 驗證上面每一種情況，包括：
  - PASS 後面接一行 `… Killed …`，必須判為不乾淨；
  - 必須寫出「not the last line: 1 line(s) after it」；
  - 必須保留輸出。
- 閘門 `redfirst_lib_gate`：
  - self-check 是 PASS；
  - mutant Q2-1（拿掉 `pl < total` 分支）讓指名的那條「a line AFTER SELF-TEST PASS is told apart」變紅。
- INFERRED：r2 那一次 08-at-HEAD 沒重現的紅，如果是「PASS 後面多一行」這一型，就是 r2 的 green() 給不出原因的那種情況；現在這一型會被點名。但它是不是這一型，沒有證據。

## 4. R-N3：措辭更正（只改字）

在 `P4-HB-FOLLOWUPS-R2-SUMMARY.md` 的 §5 與 §8 閘門表，把「0 段編譯不過」改成「**掃描器集合裡的** 98 段，0 段編譯不過」。另外註明兩段不在集合內的程式：

- 08:1381：`st_h5_dies` 在 `SAMPLER_PY` 前面補一行 stderr 的雙引號組合字串；
- 08:1717：刻意寫壞、讓 sampler 起不來的單行 `SAMPLER_PY`。

兩段都是縮排的單行賦值，掃描器的 `*_PY=` 樣式認不出來。

## 5. Commits（`b2eeb71d..c22d1300`）

- `c0cef392` HB W gate (red first): refuse a 08 mutant tree that reaches the checkout's lab state
- `3eb42ba5` HB W gate: 08's mutant trees link only p4_proxy/proxy_agent and p4_proxy/venv
- `a435d24e` 07 tests (red first): an inherited L1_POLL_S must not shorten the live L1 poll
- `f90722f3` 07: the L1-on-switch_state poll is an argument, never the environment
- `c22d1300` roles gate: L7-28/L7-29 -- the live L1 poll is 30 s, never the caller's

## 6. 閘門

全部經 `env JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh`，PATH 最前面是 nolab shim。

- log 在 `logs/gates-0910/<gate>.p4hbr3-c22d1300.log`。
- 腳本副本在 `scripts-p4hbr3-c22d1300{,-b,-c}/`，附 SHA256SUMS。
- driver 都從唯讀的凍結副本執行。

| 閘門 | rc | 結果（OBSERVED） |
|---|---|---|
| `live07_selftest` | 0 | SELF-TEST PASS（含新的一格） |
| `live08_selftest` | 0 | SELF-TEST PASS |
| `redfirst_lib_gate` | 0 | self-check PASS；mutant Q2-1 被它指名的那條抓到 |
| `redfirst_r3` | 0 | R-N1、R-N2 在各自的 red-first 樹上紅，HEAD 乾淨（§1、§2） |
| `check_gate_anchors` | 0 | 120/120 |
| `nolab_tripwire` | 0 | 0 次 lab 呼叫（shim log 42 行，全是 `file://` 的 curl） |
| `mutate_p4_heartbeat_w` | 2 | **不算**：proxy baseline 紅，因為這個新 worktree 少了 `p4_proxy/p4_src/build` 的連結（gitignored；之前幾個 worktree 都連到主 checkout 的，唯讀）。補上連結後重跑，沒有任何 tracked 檔案變動 |
| `mutate_roles_binding` | 2 | **不算**：同上 |
| `mutate_p4_heartbeat_w_b` | — | **無效**：跑到約第 83 格時，因你的 PAUSE（live 07）被我停掉。log 沒有 rc 行，不計 |
| `mutate_p4_heartbeat_w_c` | 0 | 195 個 mutation，0 存活。preflight 印出「only p4_proxy/proxy_agent and p4_proxy/venv lead out of it, and no lab-state knob is in it」；L55–L60 全部抓到 |
| `mutate_roles_binding_c` | 0 | 174 個 mutation，0 存活（172＋L7-28、L7-29，都抓到） |
| `nolab_tripwire_c` | 0 | 0 次 lab 呼叫。shim log 512 行，全是 `file://` 的 curl。只涵蓋 driver 自己的 `NOLAB_LOG` |

**red-first 證據一覽**（全部在 `redfirst_r3.p4hbr3-c22d1300.log` 與 `redfirst_lib_gate.p4hbr3-c22d1300.log`）

- **R-N1**：
  - `c0cef392` 的 gate：rc 2，在任何 mutation 之前 refuse，mutation 行數 0。
  - refuse 訊息原文：`p4_proxy/mininet/host_count_override resolves to <worktree>/p4_proxy/mininet/host_count_override` 與 `p4_proxy is a link to <worktree>/p4_proxy`。
  - 用兩版 `ltree` 各建一棵 tree：`c0cef392` 版列出同樣兩個出口；HEAD 版 0 個出口，而且沒有 `p4_proxy/mininet`。
- **R-N2**：
  - 07 在 `a435d24e`：只紅一格，`an inherited L1_POLL_S does not shorten the live poll -- judged 3 polls 2`，最後一行 SELF-TEST FAIL。
  - HEAD：57 個 ok、0 紅，SELF-TEST PASS 是最後一行；新格是 `judged 0 polls 4`。
  - mutant L7-28、L7-29 都抓到。
- **Q2**：
  - self-check 裡「PASS 後面多一行 `… Killed …`」被判為不乾淨、講出原因、並保留輸出。
  - mutant Q2-1（拿掉 `pl < total` 分支）讓「a line AFTER SELF-TEST PASS is told apart」、「and says what it is」、「and keeps the output」三條都紅。

DELIVERED c22d130041f0416293e333fbcd13956d5e4bbbd7
