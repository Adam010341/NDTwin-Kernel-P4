# ndt serve 第二張單：live_cells 入口＋逐步引導模式 — 報告

[Co-developed with claude code -- Adam]

- 裁定：Adam 在 09-24 21:4x 用表單決定（`REPORT.md` §4.6）。內容是「包 live_cells 格子」加「逐步引導模式」，排在第一刀交件之後，接著在同一條分支上做。
- 目的（Adam 原話）：讓他能快速親眼看到、驗證 AI 的工作成果，「這樣我才不會心虛」。
- 分支：`feat/ndt-serve-0924`。第一刀的審查停在 `f023b388`；本單的 commit 從 `727d4b00` 開始。**沒有併進 trunk，也沒有推任何遠端。**
- raw 放在 `scratch/overnight-2026-09-05/logs/ndt-serve-0924/live-cells-20260924T2224/`，下文簡稱 `CLOGS/`。

---

## 1. 要你裁的

1. **兩條 walk 在等你下判定。** 走到 verdict 那一步我就停了，**我沒有代你判**。要判的話：

   ```bash
   python3 tools/ndt_serve/serve.py --owner adam --ndt ~/.local/bin/ndt     # 在這個 worktree 裡跑
   ```

   接著照 `tools/ndt_serve/README.md` 的 curl：

   - 先 `GET /api/v1/guided/<id>` 看每一步的 `look_at`，以及 compare 表；
   - 再 `POST /api/v1/guided/<id>/verdict`。

   兩條 walk：
   - `g20260924T142509Z-dd4f41`：`help_drops_deleted_claims`，不需要 lab；
   - `g20260924T142521Z-ad027d`：`up_target_names_a_readable_model`，需要 lab，lab 已經歸還。

   walk 存在 `~/.local/state/ndt-serve/guided/`，伺服器重啟後照樣找得回來。
2. **步驟的粒度。** 現在每一格是 4 到 8 個粗步驟：`old`、`new`、`status`、`claim`、`run`、`release`、`compare`、`verdict`。「run」一步就跑完整個 observe 加 judge 加還原。

   如果你想看的是 **observe 內部的每一個動作**（例如先 `ndt up`，停下來讓你看，再去 curl），那每一格都要另外寫一份步驟檔。代價是這份檔會跟 cell 腳本分家、漂移（兩份各自描述同一段行為）。我建議先用現在的粒度，等 GUI 出來、你實際用過之後再決定。
3. **`requires idle` 的兩格**（`up_refuses_*`）在 live 還沒有用 walk 跑過。它們會刻意在 lab 上製造「被拒絕」的情境，程式路徑跟 ovs4 那格相同，但有沒有副作用只讀過碼、沒有實測。要不要排一個 lab 時段補跑？
4. **畫面放在下一刀**，跟第一刀 §1 的第 2、3 題（GUI 放哪、token 怎麼給網頁）一起裁。

## 2. 推翻／更正

- **格子是 11 格，不是 12 格。** 我在給你的表單選項裡寫了「12 格」，那是把 `run_cells.sh` 也算進去了。`run_cells.sh --list` 實際列出的是 11 格；`REPORT.md` §4.6 沿用了這個錯字，以本檔為準。
- **流程順序在實作中途改了一次，理由是共用 lab。**
  - 第一版把 release 放在 verdict 之後，等於 walk 在等你下判定的整段時間都佔著 lab。
  - 可是判定看的是這次 run 留下的 raw，根本不需要 lab；而 lab 還要讓 orchestrator 跑今晚的驗收。
  - 所以改成 run 之後立刻 release（`940c1233`，變異 C16）。還原失敗時照舊停住、不 release。
  - 新測試先在 `727d4b00` 的 `cells.py` 上跑出紅，再轉綠。

## 3. 交付

| 項目 | 內容 | 狀態 |
|---|---|---|
| 程式 | `tools/ndt_serve/cells.py`（新檔）；`serve.py` 加上路由和 walk 邏輯；`jobs.py`、`verbs.py` 各加幾行 | ✅ `727d4b00`、`940c1233` |
| 測試 | `tests/python/test_ndt_serve_cells.py`：**25 條**，用 stub grid，不碰 lab。第一刀當時的 51 條仍然全綠（判官修正輪之後是 71 條，`REPORT.md` §3） | ✅ |
| 變異閘門 | `mutate_ndt_serve.sh` 增加 C1–C16，全部變異合計 **58 個**。在 `940c1233` 上實跑：**58 個全部被抓到、0 倖存**；`check_gate_anchors.py HEAD` 116 支閘門全部 ok | ✅ `mutate_ndt_serve.940c1233.log`、`check_gate_anchors.940c1233.log` |
| live（唯讀） | 經 API 對真的 grid（主 checkout 上的 `fd7382a3`）判 **11 格的 old/ 和 new/**：11 格 old/ 全部 FAIL，而且失敗集合都等於 EXPECTED-FAILS；11 格 new/ 全部 PASS | ✅ `CLOGS/offline/` |
| live（walk） | 兩格走到 verdict：no-lab 那格有 4 條紅轉綠；ovs4 那格有 8 條紅轉綠、still_red 為空、CELL: PASS，而且還原乾淨（down 0、clean 0、orphans CLEAN） | ✅ `CLOGS/walk-*` |
| 文件 | `tools/ndt_serve/README.md` 新增一節；本報告 | ✅ |

## 4. 細節

### 4.1 做了什麼

**11 格的清單來自 grid 自己。**

- 清單就是 `run_cells.sh --list` 印出來的內容，這同時也是白名單：不在上面的格子名稱，一律回 404，而且什麼都不會跑。
- 每一格的附帶資訊都讀 grid 自己的檔案：
  - 預期判決讀 `CELLS.md`；
  - fixture 從 `tests/fixtures/live_cells/` 讀；
  - 全部取自**被驅動的那棵樹**，live 時就是主 checkout。

**修好之前的紅、修好當晚的綠，都用 GET 看，不碰 lab。**

- 做法是用那一格自己的 `judge` 去判 `old/` 或 `new/`。
- `judge` 依 grid 的契約是純函數：它讀的只有 raw 目錄本身，不碰 lab、不連網路、不看時鐘、不動 git。
- 回應裡附上：
  - ASSERT 逐列；
  - 最後的 `CELL:` 行；
  - 失敗集合是否等於人工審過的 `EXPECTED-FAILS`；
  - `PROVENANCE.md` 原文；
  - 一段提醒：「old/ 的紅不一定都是證據，有些只是 fixture 缺檔」。

**重跑一格是一個 job。**

- 它跟 up/down 共用同一個槽，argv 就是 grid 自己的：`run_cells.sh --cell <name> --raw-root <state>/cells-raw/...`。
- raw 存在服務自己的目錄裡：同一天重跑不會覆蓋之前的結果，也不會寫進主 checkout 的 `.test_run`。
- `run_cells.sh` 回 0 代表 PASS **或** SKIP，所以 job 會另外附上那一格自己印的 `CELL:` 行，並分成 `pass`、`skip` 兩類。SKIP 永遠不會被顯示成 pass。
- 回 2 代表還原失敗、lab 不乾淨，分類成 `harness`，不會被當成「這格紅了」。

**逐步引導（walk）：**

- 每一步都附上「要看哪裡」，以及 CELLS.md 寫的「綠長什麼樣」。
- 任何一步沒有達到預期，整個 walk 就停住，`next` 只會重做那一步：
  - claim 被拒，不會接著去跑格子；
  - 還原失敗，不會接著 release；
  - `next` 不肯代你下 verdict。
- GET walk 時，每一步的狀態都從 job 當場推導，不寫任何檔案。

**紅線的沿用：**

- 所有 POST 照樣要 token、JSON body、同源的 Origin；修正輪之後，cells 和 walk 的每一個 GET 也要 token 和同源 Origin（判官第 1 項，orchestrator 裁定：除 `/health` 外所有 GET 一律照寫入的規矩檢查）；
- 全部都用 argv 呼叫，不經過 shell；
- 讀 raw 檔的路徑一律先取 realpath，並限制在 fixture 或 raw root 之內，symlink 逃不出去。

### 4.2 live：11 格的修前紅和修後綠（經 API，唯讀，22:24）

| 格子 | requires | old/ | 失敗集合 == EXPECTED-FAILS | new/ |
|---|---|---|---|---|
| default_round_plane_is_classified | none | FAIL（1 條） | ✅ | PASS |
| half_stack_is_not_clean | ovs4 | FAIL（8 條） | ✅ | PASS |
| help_drops_deleted_claims | none | FAIL（4 條） | ✅ | PASS |
| link_failure_cuts_both_ends_or_neither | ovs4 | FAIL（5 條） | ✅ | PASS |
| northbound_write_reply_names_the_lab_claim | ovs4 | FAIL（12 條） | ✅ | PASS |
| orphans_blind_probes_not_checked | none | FAIL（3 條） | ✅ | PASS |
| recovery_refuses_foreign_netem | ovs4 | FAIL（6 條） | ✅ | PASS |
| stale_app_pidfile_does_not_frame_the_fabric | ovs4 | FAIL（7 條） | ✅ | PASS |
| up_refuses_a_model_of_another_network | idle | FAIL（7 條） | ✅ | PASS |
| up_refuses_while_a_down_is_in_flight | idle | FAIL（6 條） | ✅ | PASS |
| up_target_names_a_readable_model | ovs4 | FAIL（8 條） | ✅ | PASS |

⚠️ 這張表是**重判存檔**的結果：拿 fixture 讀出當年的紅和綠，不是今天重跑。今天真的重跑的只有 §4.3 那兩格。

### 4.3 live：兩條 walk（22:25）

- **條件**：
  - 伺服器用 `940c1233` 的碼，驅動 `~/.local/bin/ndt`（sha256 `cb134ccc…`），也就是主 checkout 的 `fd7382a3`；
  - owner 是 `ndt-serve-0924`；
  - 開跑前 claim 是 none、measuring 是 nothing；
  - knob 前後都是未提交的 4。
- **`help_drops_deleted_claims`**：步驟是 old、new、run、compare，停在 verdict。
  - 格子的判決：`CELL: PASS … ndt=3273df8b…`。
  - 紅轉綠的斷言：`help_drops_this_checkout_claim`、`help_scopes_the_residue_rc`、`help_drops_blanket_env_guarantee`、`help_keeps_the_scoped_knob_claim`。
  - still_red：無。
- **`up_target_names_a_readable_model`**：步驟是 old、new、status、claim、run、release、compare，停在 verdict。
  - 22:25:20 到 22:25:52，佔用 lab 約 30 秒。
  - 格子的判決：`CELL: PASS`。
  - `h4nl_*` 共 8 條紅轉綠；still_red：無。
  - 還原：`3-down.rc=0`、`4-clean.rc=0`、`VERDICT: CLEAN`（只查了行程那一半；kernel 已經關掉，網路那一半沒查，這是 run_cells 本身的設計）。
  - 結束後 claim 是 none，knob 仍是 4。
- **raw**：
  - `CLOGS/walk-*/` 裡是每一個請求的回應全文；
  - `CLOGS/raw-up_target_names_a_readable_model/` 是那次 run 的完整 raw；
  - 驅動用的腳本是 `CLOGS/walk.py`。

### 4.4 證據：跑過 vs 只讀過

| 性質 | 跑過（單元，用 stub grid） | 跑過（live） | 只讀碼、未實測 |
|---|---|---|---|
| 格子只能是 grid 自己列的 | C1 | 11 格都出自 `--list` | — |
| old/ 和 new/ 唯讀 | C2（改成 observe 會被抓到） | 22 次判定，lab 的 claim 沒有被動到 | judge 本身的純函數性，靠的是 grid 自己的契約，以及它的 `mutate_live_cells.sh` |
| raw 檔讀不出界 | C3 | — | — |
| run 佔用同一個槽 | C4 | — | — |
| SKIP 不是 pass，還原失敗是 harness | C5、C8 | 兩格都是真的 PASS | 真的 SKIP 和真的還原失敗，在 live 都沒有遇到 |
| 寫入要 token | C6 | — | — |
| 告訴 grid 驅動哪一棵樹（`NDT_ROOT`） | C7 | raw 裡的 `ids.txt` 寫著 `ndt_root=` 主 checkout | — |
| 紅轉綠的標記 | C9 | 4 條加 8 條 | — |
| claim 被拒不跑、還原失敗不 release | C10、C11 | — | live 沒有去製造 claim 被拒或還原失敗 |
| 沒印出 verdict 的 run 會卡住 | C12 | — | — |
| verdict 是你的 | C13 | 兩條都停在 verdict | — |
| GET 不寫檔 | C14 | — | — |
| old/ 不再 FAIL 時流程會停 | C15 | — | — |
| 先 release 再判定 | C16 | ovs4 那格在 compare 之前就已經 release | — |

閘門全部 58 個變異的結果：`scratch/overnight-2026-09-05/logs/ndt-serve-0924/mutate_ndt_serve.940c1233.log`。判官修正輪之後閘門合計 77 個，在 `5c07acf3` 上 77 個全部抓到（`logs/ndt-serve-0924/final-5c07acf3/mutate_ndt_serve.log`），C1–C16 一個都沒有少。

### 4.5 沒做的事、已知限制

- **沒有畫面**：walk 是後端狀態機，用 curl 走得通但不好用。畫面放下一刀。
- **沒有 observe 內部的逐動作步驟**：見 §1 第 2 題。
- **cells 的讀取沒有限流**：`run_cells.sh --list` 每次都會對 11 格各跑一次 `meta`，大約 1 秒；第一刀的 status 和 apps 有兩個名額的限流，這裡沒有。
- **cells-raw 和 guided 目錄會一直長大**，跟 job 目錄一樣沒有保留期限。
- **沒有歸檔進 audit-raw**：orchestrator 說要等你看過第一刀再決定。
