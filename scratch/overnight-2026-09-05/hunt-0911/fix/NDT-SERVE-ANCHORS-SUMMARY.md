# SUMMARY：ndt serve 的 rc 錨點在 cafd518a 上跑掉（段 W 造成的 CI 新紅）

- **分支**：`fix/ndt-serve-anchors-0926`，從 trunk `cafd518a` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-ndt-serve-anchors-0926`。
- **Head**：`60194b09f3b97e35c91b3988372a1aaeeea42fa2`，1 個 commit。
- 沒 push、沒 merge、沒碰 lab 也沒碰主 checkout、沒 sudo。

[Co-developed with claude code -- Adam]

## 1. 原因與修法（OBSERVED）

**原因**

- 段 W 在 `tools/test_workflow/ndt` 加了 125 行、刪了 1 行，淨增 +124。
- 六個 hunk（2926、2961、3351、3413、5132、6755）全都在 cmd_status 的判定之前，所以它下面的 11 個 `RC_SOURCE` 錨點都往下移了 124 行。

**修法：逐列搬，不是跑到綠為止**

- 每一列的舊行號，都在 `580767a8`（W 的起點）上核對過：當時 19 列全部正確。
- 再用 ndt `580767a8 → cafd518a` 的逐行 diff，把舊行映射到不變區塊裡的新行，逐一確認文字 byte-identical，而且在同一個函數裡：

| 表 | 舊 → 新 | 函數 |
|---|---|---|
| status.check rc 3/0/1 | 6939/6944/6948 → 7063/7068/7072 | cmd_status |
| status rc 0 | 6950 → 7074 | cmd_status |
| apps.start rc 0/1/1 | 8771/8775/8848 → 8895/8899/8972 | app_start |
| apps.stop rc 1/2/0 | 10289/10292/10295 → 10413/10416/10419 | cmd_apps |
| apps.status rc 0 | 10222 → 10346 | cmd_apps |

- claim／release 的 8 列都在 W 所有 hunk 的上面，所以沒動。

**有沒有哪個 rc 的意義被 W 改掉：沒有。**

- W 在 cmd_status 裡只加了一個顯示用的 `heartbeat` 列：`heartbeat_row` 只負責印，不會往 `problems[]` 加東西。
- 所以 `--check` 的 0／1／3 判定照舊；apps 那幾個動詞附近 W 完全沒碰。
- `RC_TABLE` 沒改，測試也沒放寬。

**比照 `1a1944ea` 的前例，只做同樣的重新編號、不做別的**

- 閘門 `mutate_ndt_serve.sh`：
  - M61 的錨點引用了 apps.status 那一列，跟著改；
  - M63 的錨點引用 apps.start rc 1。它的替換值是 proc_checkout 的 `return 1`（文字相符、函數不符），這行也從 8315 移到了 8439，所以一併改到 8439，讓它繼續只測「函數」這一半。
- 註解裡引用的 ndt 行號：
  - `verbs.py`：cmd_status 的 problems 相關行；
  - `serve.py`：lock_probe、up_ovs 的 guard、claim_line；
  - 兩個測試的註解。
- 這些新行號同樣是在同一個函數裡，用舊行的文字找到的。

## 2. 閘門（`logs/gates-0910/*.ndtserve-<sha>.log`，全部經 guard `JOBS=1 LOCK_WAIT=10800`）

| 閘門 | cafd518a（red first） | 60194b09 |
|---|---|---|
| `test_ndt_serve.py` | rc 1，`FAILED (failures=1)`：只有 RcProvenance，和 CI 一樣（`test_ndt_serve_tmpshort`） | rc 0，`Ran 73`、`OK` |
| `test_ndt_serve_cells.py` | rc 0 | rc 0 |
| `mutate_ndt_serve.sh` | rc 2：baseline 是整套測試，在 base 上是紅的 | rc 0，**91 mutations、0 survivors**，M57／M61／M63 都抓到 |
| `check_gate_anchors` | 120/120 | 120/120 |
| tests/python 全部（本機 L1 用的 ryu-env Python 3.8） | 11 個檔不是 PASS | 10 個：**只少了 `test_ndt_serve.py`** |
| tests/python 全部（python3 3.13、沒有 ryu，最接近 CI） | 8 個檔不是 PASS | 7 個：**只少了 `test_ndt_serve.py`** |

**temp 目錄要短，而且不能是 symlink**

- cafd518a 上第一輪兩個 log 各多一個紅，都是 temp 路徑造成的：
  - `test_claim_note_reaches_ndt_as_one_argv_element` 會把兩條 mkdtemp 路徑放進上限 200 字的 note，而 scratchpad 路徑長約 110 字；
  - `Identity.test_jobs_run_the_ndt_resolved_at_start` 在 symlink 的 TMPDIR 下也會紅，因為服務會把 ndt 解析到 realpath。
- 之後的每一輪都改用真實的短目錄 `/tmp/claude-1000/nd6e0a`，跑完就清掉。舊 log 保留，並在結尾加註了原因。

**和 CI 對照**

- CI 前一輪（36233414349）是 14 個 problem group，這一輪（36251857977）是 15 個；兩輪差異**只有** `test_ndt_serve.py`。
- 本機的差異同樣只有這一個檔。
- 本機另外有幾個檔不是 PASS，但在 base 上本來就一樣紅，屬於本機環境，這個修正前後沒有變化：
  - ryu-env 3.8：chaos 系列、`l3_dispatch_drift`、`sflow_stats_endpoint`；
  - py3：`find_host_by_ip`、`walk_instrumentation`、`check_gate_anchors` 的 skip。

## 3. 其他會釘住 ndt 行號或文字的測試（OBSERVED，讀碼）

- `tests/python`、`tests/shell`、`tools/*/tests` 裡引用 `ndt:NNNN` 的地方，除了上面那幾處，其餘都只是註解裡的出處說明，沒有任何斷言：
  - `test_preflight_instrument_self_failures.sh`、`test_redirection_order.sh`；
  - `test_ndt_*.sh` 裡的幾處。
- 會比對 ndt 文字的 shell suite，已在段 W 的 `ndt_suites` 和各個 `mutate_ndt_*` 跑過；CI 的兩輪差異也證實除了 `test_ndt_serve.py` 沒有別的新紅。
- **缺口（我們的，不是測試的）**：段 W 的閘門和 orchestrator 的 intake 重跑都沒有包含 `tests/python/test_ndt_serve.py`。之後任何會改到 ndt 的 ticket，閘門都應該加上它和 `mutate_ndt_serve.sh`。

DELIVERED 60194b09f3b97e35c91b3988372a1aaeeea42fa2
