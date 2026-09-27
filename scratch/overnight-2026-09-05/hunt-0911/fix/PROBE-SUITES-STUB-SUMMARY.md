# SUMMARY：六支唯讀探測 suite 內建自己的 sudo stub（a）

- **分支**：`fix/probe-suites-stub-0927`，從 trunk `8746c1bc` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-probe-stub-0927`。
- **Head**：`f9c59a44e39ea9e0c5ad74bdd1a9af26b5ea0a72`，共 5 個 commit（§4）。第 5 個是 judge「MERGE AFTER FIXES on 356d4e4e」的修正輪（§0）。
- 與 trunk `c34a643a` 的 `git merge-tree` 乾淨；與 (b) `fix/stale-suites-0927` 沒有共用的檔案。
- 沒 push、沒 merge、沒 sudo、沒碰 lab 也沒碰主 checkout。
- 每一次執行都走 guard（`JOBS=1 LOCK_WAIT=10800`），nolab shim 在 PATH 最前面，driver 一律從唯讀的凍結副本執行，tripwire 放在最後。

[Co-developed with claude code -- Adam]

## 0. 修正輪（judge-PSTUB-356d4e4e：B1、B2、N2、N5、N10；`f9c59a44`）

**B1：stub 的字句——偏離裁決，已由 orchestrator 追認**
- 裁決要的是「像今天的 R 輪那樣回答」。R 輪 shim 的字句是 `sudo: refused by the nolab shim (a lab command)`；stub 用的是真實 sudo 在沒有 NOPASSWD 時的字句 `sudo: a password is required`。**這是偏離裁決，orchestrator 09-27 追認保留。**
- 我原本寫「ndt 只拿字句選措辭（wording only）」「就是 CI 和各閘門今天看到的答案」「a live lab cannot change its path」，這三句都錯了，已從 lib、六支 suite 的註解和本檔刪改：
  - ndt 靠字句**做判定**：`ndt_sudo_probe`（sudo_surface.sh:179-182）用 `ndt_sudo_refused` 認的五種字句決定 granted 或 refused。
  - stub 固定的是 sudo 的**回答**，不是 suite 走的**路徑**：ps、`command -v`、lab 埠、curl :8000、p4 manifest 仍然決定要不要探。
- test_lab_handoff 的 `ndt status` 在三種環境走三個分支。它的判定沒變，只是因為這支 suite 只讀 `lab` 那一段：

  | 哪裡 | `sudo -n` 回什麼 | ndt 的 sudo grants 行 | 證據 |
  |---|---|---|---|
  | 這支 stub 之前的閘門（R 輪 shim） | refused by the nolab shim，rc 1 | `all 3 granted` | OBSERVED（redfirst_stubfix B1） |
  | 這支 stub | a password is required，rc 1 | `refused`，外加三行 REFUSED 和授權說明 | OBSERVED（同上） |
  | CI（ubuntu-24.04，沒有 mnexec／ndtwin-lab／OVS） | 不會被問：`command -v` 先失敗 | `could not be tested` | 讀 ci.yml 與 sudo_surface.sh:176-177，未執行 |

**B2：「PATH 上的 sudo 不是這支 stub」那一行，現在看過紅了**
- 新增 P9：cell_gate 的 stub 裝好之後，在 PATH 最前面再放一支別的 sudo。closing check 必須紅，**而且理由必須是** `the sudo on PATH is`（`report()` 新增第 4 個參數，指定紅的理由）。
- red first（OBSERVED）：在 HEAD 的 sandbox 裡刪掉 lib 的那一行，整個 gate 跑一次，結果是 **P9 SURVIVED，而且只有 P9**。

**N2：P5／P6／P8 的前提——我選的是「拒絕」，不是用假 ps 固定路徑**
- 這三個 mutant 只有在 ndt 走 OVS 路徑時才殺得到：ovs-vsctl 在 PATH 上、ovs-vswitchd 在跑、而且沒有 bmv2 在跑。
- gate 開頭先檢查；不成立就 rc 2 拒絕，並寫出缺的是哪一項。
- 不用假 ps 的原因：PATH 上的假 `ps` 也會被 apps_stop 和 app_orphans 自己的行程檢查讀到，等於改了它們測的東西。
- red first（OBSERVED）：用一支不列 ovs-vswitchd 的 ps——
  - 356d4e4e 的 gate：P5、P6、P8 **SURVIVE**，gate 完全沒說為什麼；
  - HEAD 的 gate：還沒跑任何 suite 或 mutant 就 rc 2 拒絕，寫明 `no ovs-vswitchd running`。

**N5：非特權的 tc stub 只回答 `qdisc show`**
- `tc qdisc show` 回 rc 0、沒有輸出；其他任何 argv 都記錄並**拒絕**（rc 1），不再捏造成功。
- 「CI's answer」那句註解已更正：CI 的 `tc qdisc show` 會列出它預設的 qdisc，只是沒有 netem；suite 讀的只是「沒有 netem」這一部分。
- gate 新增 stub 契約檢查（stub_contract），再加一個 mutant T1：tc 對任何 argv 都回 0。
- red first（OBSERVED）：356d4e4e 的 lib 對 `tc qdisc add ...`、`tc qdisc del ...` 都回 rc 0；HEAD 的 lib 契約成立。

**N10：找不到 lib 的早退也印摘要行**
- 現在印 `Ran 1 checks, 1 failed`，和 `source "$NDT"` 失敗時一致。
- red first（OBSERVED）：六支都測了——
  - 356d4e4e：最後一行是 FAILED，L1 lane 的 scorer 讀成 0 ran、0 failed；
  - HEAD：`Ran 1 checks, 1 failed`，讀成 1／1。

## 1. 做了什麼（照你的裁決）

新增 `tests/shell/lib_probe_stub.sh`。六支 suite 各自在自己的 temp dir 放一支 `sudo`，排在 PATH 最前面：

- 每一次呼叫都記錄下來，並以 **rc 1 拒絕**，stderr 用 sudo 自己的字句（`sudo: a password is required`）。**沒有任何捏造的 rc 0「沒有 lab」答案。**
- 字句的效果見 §0 B1：ndt 靠它做判定，這是 orchestrator 追認過的偏離。（這裡原本寫著「wording only」「就是 CI 和各閘門的答案」「HEAD 三輪相同所以字句沒差」，三句都不對，已刪。R／L／L2 三輪裡外層 sudo 一次都沒被問到，所以那個比較根本量不到字句。）

兩支 suite 另外 stub 了**不經 sudo** 的指令：

- test_lab_handoff：`tc` 全部記錄；只有 `tc qdisc show` 回空、rc 0（沒有 netem），其他 argv 一律拒絕（§0 N5）。
- test_ndt_sample_rate_reads_both_bounds：`ovs-vsctl` 記錄後拒絕。

每支 suite 都在結尾加一條 closing check。記錄到的呼叫只要有任何一條不在它的允許清單裡，就判紅。

| suite | 允許清單 |
|---|---|
| test_apps_stop_kills_the_group | `sudo ndtwin-lab status` |
| test_ndt_app_orphans | `sudo ndtwin-lab status` |
| test_cell_gate_suspect_wiring | `sudo ndtwin-lab status`、`sudo ndtwin-lab topo-out *` |
| test_lab_handoff | `sudo ndtwin-lab status`、`sudo ovs-vsctl list-br`、`sudo mnexec -a 1 true`、`tc qdisc show` |
| test_ndt_honesty | `sudo ovs-vsctl list-br` |
| test_ndt_sample_rate_reads_both_bounds | `sudo ovs-vsctl list-br` |

**closing check 不會因為什麼都沒記到就過（我自己抓到的缺陷，已修）**

- 第一版（`f47f3b45`）有三支 suite 先 source 了 ndt：apps_stop、app_orphans、sample_rate。
  - ndt 會把 `HERE` 改成它自己的目錄，結果 `source "$HERE/lib_probe_stub.sh"` 找不到檔案。
  - stub 從頭到尾沒有裝上，**但 closing check 把「空的呼叫清單」讀成乾淨**。
- 發現經過：這條分支的 red-first gate 在 L／L2 輪發現外層 shim 收到了 16／32／8 次 sudo，當場判紅（log `redfirst_stub.pstub-f47f3b45.log`）。
- 修正 `f970d5b3`：
  - 從 suite 自己的 `BASH_SOURCE` 目錄載入 lib；找不到就直接紅。
  - `probe_stub_outside` 在兩種情況下各自印一行，讓 closing check 變紅：stub 根本沒裝，或 PATH 上的 sudo 不是這支 stub。
  - closing check 也會讀 stub 的 stderr。
- 加了 mutant P8：拿掉 stub 的安裝，closing check 必須紅。

**P8 改成密封的（`356d4e4e`，照你 c34a643a 那則的指示）**

- 缺陷：f970d5b3 的 P8 拿掉 stub 之後，sample_rate 的 `sudo ovs-vsctl list-br` 就落到 PATH 上的下一支 sudo。那一輪是 driver 的 nolab shim，tripwire 記到 4 次（`nolab_tripwire.pstub-f970d5b3.log`）。
- 修正：`mutate_probe_stubs.sh` 開頭自己做一支記錄並拒絕的 sudo（rc 1，sudo 的字句），放在 PATH 最前面，**每一個 mutant 都在它底下跑**。
  - baseline：任何一支 suite 有呼叫漏到它那裡，就以 rc 2 拒絕。
  - P1–P7：漏到它那裡的必須是 0，否則算 SURVIVED。
  - P8：漏到它那裡的必須 **> 0**，而且 closing check 必須紅，兩者都成立才算 caught。「漏出去但哪裡都沒到」不算 kill。
- 結果（OBSERVED，`mutate_probe_stubs.pstub-356d4e4e.log`）：P8 caught，**4 escaped**，closing check 紅在 `outside the allow-list: 1 NO STUB: probe_stub_install never ran`；P1–P7 都是 0 escaped。driver 的 tripwire **0**，shim log 全檔 0 行。
- red first（OBSERVED，`redfirst_p8.pstub2-356d4e4e.log`）：把 gate 的副本改成記錄寫到 `/dev/null`（仍然拒絕，只改那一行，diff 印在 log 裡）。
  - gate rc 1，`8 mutation(s), 1 survivor(s)`；
  - P8 報 `SURVIVED ... no call reached this gate's sudo -- the escape it tests went nowhere`；
  - P1–P7 仍然 caught；
  - 那一輪的 tripwire 也是 0。

## 2. red first（OBSERVED，`redfirst_stub.pstub-356d4e4e.log`；f970d5b3 那一輪結果逐條相同）

**跑法**

- 每支 suite 在 8746c1bc（放在原檔旁的副本）和 HEAD 各跑三輪：
  - R：拒絕型 shim；
  - L：會回答的 sudo，裝成 bmv2＋OVS＋主機都是活的；
  - L2：只有 OVS＋主機是活的。
- 任何一輪都沒有呼叫到達 root。前後都沒有真的 mininet 主機。

**結果**

- **8746c1bc**：test_ndt_sample_rate_reads_both_bounds 在 L2 下**紅 4 條**（rc 1），其他各輪都綠。
- **HEAD**：
  - 六支在 R／L／L2 **全綠**，而且三輪的 check 逐條相同（ok 對 ok）。
  - 每支的 check 數都是 base 加 1，多的那一條就是 closing check。
  - 在 L／L2 下，外層那組會回答的 shim **一次 sudo／ovs 呼叫都沒收到**，全部被 suite 自己的 stub 接走。

| suite | base（R／L／L2） | HEAD（R／L／L2） |
|---|---|---|
| test_apps_stop_kills_the_group | 71 綠 ×3 | 72 綠 ×3 |
| test_cell_gate_suspect_wiring | 12 綠 ×3 | 13 綠 ×3 |
| test_lab_handoff | 18 綠 ×3 | 19 綠 ×3 |
| test_ndt_app_orphans | 103 綠 ×3 | 104 綠 ×3 |
| test_ndt_honesty | 345 綠 ×3 | 346 綠 ×3 |
| test_ndt_sample_rate_reads_both_bounds | 6 綠、6 綠、**6 中紅 4** | 7 綠 ×3 |

## 3. 閘門

全部經 guard，nolab shim 在最前面，driver 從凍結副本執行。第一行是完整 sha，最後一行是 `# rc=`。

**修正輪，head `f9c59a44`（`logs/gates-0910/<gate>.pstub3-f9c59a44.log`）**

| gate | rc | 結果 |
|---|---|---|
| redfirst_stubfix | 0 | §0 的 B1（兩列觀測）、B2、N2、N5、N10 |
| test_apps_stop_kills_the_group | 0 | Ran 72 checks, 0 failed |
| test_cell_gate_suspect_wiring | 0 | 13 passed, 0 failed |
| test_lab_handoff | 0 | Ran 19 checks, all passed |
| test_ndt_app_orphans | 0 | Ran 104 checks, all passed |
| test_ndt_honesty | 0 | Ran 346 checks, 0 failed |
| test_ndt_sample_rate_reads_both_bounds | 0 | Ran 7 checks, 0 failed |
| mutate_probe_stubs | 0 | 前提成立（ovs-vswitchd 在跑、ovs-vsctl 在 PATH、沒有 bmv2）；stub 契約成立；10 mutation(s), 0 survivor(s)：P1–P8、P9（紅在 `the sudo on PATH is`）、T1 |
| mutate_apps_stop_kills_the_group | 0 | 13 mutations, 0 survived |
| mutate_cell_gate_suspect_wiring | 0 | survivors=0，harness-errors=0 |
| mutate_redirection_order | 0 | 22 mutations, 0 survived |
| mutate_ndt_honesty | 0 | 67 mutations, 0 survived |
| mutate_live_cells | 0 | 35 mutations, 0 survived；3 controls, 0 wrongly caught；16 fixture checks, 0 failed |
| mutate_ndt_sample_rate_reads_both_bounds | 0 | 3 mutations, 0 survived |
| check_gate_anchors | 0 | 121/121 cells ok |
| nolab_tripwire | 0 | **0 lab call(s)**，shim log 全檔 0 行（我自己讀過） |

- 附帶一點：P1–P4、P7 的理由欄現在印得出來了。report() 改成抓 closing check 的 `actual:` 整行；原本的正規式只認 `actual: [` 開頭的格式。
- (b) 修正輪的 predict_ci 在 `c34a643a`＋這個 `f9c59a44`＋(b) `1d5180ce` 的合併樹上跑過：(b) 的新 group C 對這六支 suite 是綠的，96/0。

**356d4e4e 那一輪（`pstub`、`pstub2`）**

| gate | rc | 結果 |
|---|---|---|
| redfirst_stub | 0 | sample_rate 在 base 的 L2（活的 OVS）下紅；HEAD 六支在 R／L／L2 逐條相同 |
| test_apps_stop_kills_the_group | 0 | Ran 72 checks, 0 failed |
| test_cell_gate_suspect_wiring | 0 | 13 passed, 0 failed |
| test_lab_handoff | 0 | Ran 19 checks, all passed |
| test_ndt_app_orphans | 0 | Ran 104 checks, all passed |
| test_ndt_honesty | 0 | Ran 346 checks, 0 failed |
| test_ndt_sample_rate_reads_both_bounds | 0 | Ran 7 checks, 0 failed |
| mutate_probe_stubs | 0 | 8 mutation(s), 0 survivor(s)；P8 4 escaped |
| mutate_apps_stop_kills_the_group | 0 | 13 mutations, 0 survived |
| mutate_cell_gate_suspect_wiring | 0 | survivors=0，harness-errors=0 |
| mutate_redirection_order | 0 | 22 mutations, 0 survived |
| mutate_ndt_honesty | 0 | 67 mutations, 0 survived |
| mutate_live_cells | 0 | 35 mutations, 0 survived；3 controls, 0 wrongly caught；16 fixture checks, 0 failed |
| mutate_ndt_sample_rate_reads_both_bounds | 0 | 3 mutations, 0 survived |
| check_gate_anchors | 0 | 121/121 cells ok |
| nolab_tripwire | 0 | **0 lab call(s)** |
| redfirst_p8（pstub2） | 0 | 記錄寫到 /dev/null 的 gate：rc 1，P8 SURVIVED（escape 哪裡都沒到），P1–P7 caught |
| nolab_tripwire（pstub2） | 0 | **0 lab call(s)** |

## 4. Commits（`8746c1bc..f9c59a44`）

- `bd0145bc` tests/shell: six suites answer their own lab probes -- recorded and refused, as CI refuses them
- `f47f3b45` mutate_probe_stubs: one allow-list entry out, that suite's closing check must go red
- `f970d5b3` probe stubs: load the lib from the suite's own directory; a stub that is not there is red
- `356d4e4e` mutate_probe_stubs: its own sudo recorder first on PATH; P8's kill requires the escape
- `f9c59a44` probe stubs: say what the stub fixes and what it does not; P9, the tc contract, the gate's precondition

## 5. 沒做的（開放的想法）

- **live-answer 變體**，依你的裁決不在這次範圍。
  - 做法是讓 stub 在某幾格回答「lab 是活的」，讓每支 suite 固定也跑過那條分支。
  - 那是新的測試範圍，要另外設計。
- 用絕對路徑或從 Python 發出的呼叫，stub 看不到，R-N4 的限制仍在。
  - 這六支 suite 裡，絕對路徑是 0 處。
  - Python HTTP 只有 honesty 經由 cmd_check 走到的那一處，而它已被 stub 成函數。
- 其他 suite 沒有動。
- （356d4e4e 那一輪的小瑕疵：P1–P4、P7 的理由欄是空的。修正輪已修，見 §3。）
- judge 排隊的 NOTE（這一輪依指示不做）：
  - **N1**：路徑仍會隨 ps、`command -v`、埠、curl、manifest、`lab_sha` 改變。§0 B1 已寫明；要固定路徑，得和 live-answer 變體一起另立範圍。
  - **N3**：caught 的判準應該要求 FAILED 區塊裡含有被拿掉那一項的正規化字串。
  - **N4**：兩個 red first 還沒做——baseline 遇到漏出時以 rc 2 拒絕；P1–P7 漏出 > 0 時判 SURVIVED。
  - **N6**：closing check 不檢查 tc／ovs-vsctl 的 stub 是否在 PATH 上。
  - **N7**：allow-list 以 basename 比對，`sudo -n /任意目錄/ndtwin-lab status` 也會被當成允許。
  - **N8**：lab_handoff 和 app_orphans 沒有自己的 mutation gate。
  - **N9**：tripwire 的 `NOLAB_SUITE` 整輪固定，無法歸屬到是哪個 gate；driver 註解裡有舊輪的殘字。
- judge 在 §2 指出的另一個限制：子 shell 用 `PATH=/usr/bin:/bin cmd`、`env PATH=…` 重設 PATH 時會繞過 stub，closing check 看不到；目前六支和它們 source 的程式都沒有這種寫法。

DELIVERED f9c59a44e39ea9e0c5ad74bdd1a9af26b5ea0a72
