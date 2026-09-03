# FIX-NDT-OVS-TOPO — `ndt up ovs` 改跑本 repo 的 `testbed_topo.py`（Finding #77）

分支 `fix/ndt-up-ovs-runs-repo-topo`（off `trunk` `0be954ad`）。
裁決依據：Adam 2026-09-03 20:2x N13 選 **(b)**——`ndtwin-lab` 必須跑本 repo 的
`testbed_topo.py`；NTG repo 那份從 `ndt` 的路徑上退役；**不改 NTG repo**。
本次全程未觸碰 `/home/adam/Network-Traffic-Generator`（只讀）。

---

## 1. 缺陷

`tools/test_workflow/ndtwin-lab` 的 `ovs-topo-start` 在 root 的 tmux 裡起的是

```
$TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \
    "$NTG_PY" /home/adam/Network-Traffic-Generator/testbed_topo.py
```

**另一個 repo 的檔案**。而本 repo 裡指名這座 128 主機 OVS 拓樸的兩個地方都指向自己：

| 位置 | 指的是哪一份 |
|---|---|
| `tools/test_workflow/components.env:80` | `OVS_TOPO_SCRIPT=$KERNEL_DIR/testbed_topo.py`（本 repo 根目錄） |
| `tools/test_workflow/stack.sh:775` | 同上，而且**印給操作員照抄**：`sudo python3 /home/adam/Desktop/NDTwin-Kernel/testbed_topo.py` |
| `tools/test_workflow/ndtwin-lab`（修法前） | `/home/adam/Network-Traffic-Generator/testbed_topo.py` |

⇒ **手冊教的那條路徑與 `ndt up ovs` 實際跑的路徑，是兩個不同的檔案。**
Finding #42 把本 repo 那份的橫幅改成從 ping 自測導出（有計數、兩項未量測寫 NOT MEASURED、
失敗 exit 1）之後，走 `ndt up ovs` 的操作員看到的**仍然是 NTG 那份的常數橫幅**。

### 1.1 這次才發現的第二半：本 repo 那份**根本啟動不了**

修法過程中量到一件 #77 原文沒寫、而且比原文更難堪的事：

```
$ /home/adam/miniconda3/envs/ntg-env/bin/python -c "import mininet"
ModuleNotFoundError: No module named 'mininet'
```

`ndtwin-lab` 用的直譯器是 conda 的 `ntg-env`（`NTG_PY`），mininet 卻裝在系統
`/usr/lib/python3/dist-packages`。NTG 那份檔頭一直有兩行 `sys.path.append(...)`，
本 repo 的姊妹檔 `tools/test_workflow/ovs_4host_topo.py:60` 也有一行（它的 docstring 還寫著
「testbed_topo.py already uses」）——**只有本 repo 的 `testbed_topo.py` 沒有**，是搬進 repo 時掉的。

⇒ 若只改 `ndtwin-lab` 指向本 repo 那份，tmux 視窗會在第一個 import 就死，
`ovs-topo-start` 照樣印 "started"，而 `ndt up ovs` 會對著一座沒人在蓋的 fabric 等 300 秒。

🔴 **推論（要 Adam 知道）**：本 repo 的 `testbed_topo.py` 在 trunk 上**從來沒有被任何
`ndt` 路徑執行過**——它在 trunk 的直譯器下連 import 都過不了。所以 **#42 的修法在
「跑起來」這一層從未被驗證**，只被單元測試驗過。本次是它第一次真的被執行（見 §5）。

### 1.2 第三半：sweep 的路徑後綴

`ndtwin-lab cleanup`（`ndt down` 的 `[3/3]`）用 `sweep_matches` 認行程，規則是
**某個 argv 元素以 `/<pattern>` 結尾**，而 pattern 是兩段式路徑後綴——
`sweep_matches` 自己的註解就說，那正是「能指名這一個 testbed_topo.py 而不是另一個」的機制。

⇒ **換掉跑哪一份，就換掉了認它的後綴。** 只改啟動不改 sweep 的話，
`ndt down` 會在一座活著的 128 主機 fabric 上回報「乾淨」。

---

## 2. 修法

兩個檔案，缺一不可。

### 2.1 `tools/test_workflow/ndtwin-lab`

啟動從 root-only 的 dispatch 裡搬出來，變成三個函式（source 之後非 root 測試就叫得到）：

```bash
ovs_topo_script()  { printf '%s/testbed_topo.py' "$KERNEL_DIR"; }
ovs_topo_pattern() { printf '%s/testbed_topo.py' "${KERNEL_DIR##*/}"; }
ovs_topo_start() {
    local script; script="$(ovs_topo_script)"
    [[ -r "$script" ]] || die "no readable OVS topology at $script ..."
    $TMUX new-session -d -s topo -c "$KERNEL_DIR" "$NTG_PY" "$script"
    echo "OVS topo session started from $script (attach: ...)"
}
```

- **從 `KERNEL_DIR` 導出，不是第二個常數**：G-7 的安裝期設定檔搬樹的時候，這裡跟著搬。
  寫死第二個常數就是 FINDING-01 的形狀（兩處指名一棵樹、不一致時沒人出聲）。
- **`cleanup` 掃兩個後綴**：新的（`$(ovs_topo_pattern)`）與 NTG 的（保留）。
  保留的理由：`cleanup` 的語意是「重置 lab」，舊輪次留下的 NTG 孤兒仍然是要收的孤兒；
  拿掉它只是把一個無聲倖存者換成另一個。
- **檔案不存在就指名拒絕**：原本會產生一個瞬間結束的 tmux 視窗，而動詞照樣印 "started"。

### 2.2 `testbed_topo.py`

補回兩行直譯器 bootstrap，附上為什麼（哪兩個直譯器會跑它、拿掉會怎樣、它們是從哪裡掉的）。

```python
import sys
sys.path.append('/usr/lib/python3/dist-packages')
sys.path.append('/usr/local/lib/python3/dist-packages')
```

（實測：只留 `/usr/local/...` 那行仍然 import 不到 mininet，所以 M9 變異拿掉的是有效的那行。）

---

## 3. BEFORE / AFTER（逐字）

### 3.1 跑的是哪一個檔案

**BEFORE**（`ndt up ovs`，trunk 的碼、安裝副本 `/usr/local/sbin/ndtwin-lab`，21:36–21:46）：

```
740844  tmux -L ndtwinlab new-session -d -s topo -c /home/adam/Network-Traffic-Generator
        /home/adam/miniconda3/envs/ntg-env/bin/python /home/adam/Network-Traffic-Generator/testbed_topo.py
740845  /home/adam/miniconda3/envs/ntg-env/bin/python /home/adam/Network-Traffic-Generator/testbed_topo.py
```

**AFTER**（本分支的檔案，23:17–23:24；`/proc/<pid>/cmdline` 逐元素讀回，不是 `ps`）：

```
/home/adam/miniconda3/envs/ntg-env/bin/python
/tmp/.../wt-ovstopo/testbed_topo.py
```

兩份的身分（`before_06_topo_sha.log`）：

```
ead4d84a…  /home/adam/Network-Traffic-Generator/testbed_topo.py   ← BEFORE 跑的
efbc4f88…  /home/adam/Desktop/NDTwin-Kernel/testbed_topo.py       ← trunk 的本 repo 副本
60509362…  本分支的 testbed_topo.py                                ← AFTER 跑的
```

### 3.2 橫幅

**BEFORE 的橫幅本機拍不到**，這點要說清楚而不是含糊帶過：拓樸的 stdout 只活在 root 的
tmux pane（socket `/tmp/tmux-0`），而 `sudo tmux` **不在免密碼清單裡**。
所以 BEFORE 那半的橫幅宣稱**只有讀 NTG 原始碼的依據**（其 `:233-234` 無條件印那三個 OK），
不是本機實測。這是本次證據裡最弱的一環，如實記在這裡。

**AFTER 的橫幅是實跑印出來的**（`after_03_topo_stdout.log` 尾端）：

```
--- Final Configuration Active ---
host reachability: FAIL -- 0/128 pings replied, 128 lost (100.0% loss)
  the Mininet CLI below is still available -- the fabric is built, not forwarding
sFlow reachability: NOT MEASURED (configured above, never read back here)
switch identification: NOT MEASURED (agent IPs assigned above, never verified here)
```

🔑 **這一段本身就是 #42 的活體證明。** 0/128 不是 fabric 壞了——拓樸的自測跑在
`intelligent_router.py` 裝完全對路徑之前（stack.sh 記 `converged after 59s`）。
收斂之後我從三對主機各打 3 個 ping，**全部 0% loss**（`after_06_forwarding_probe.log`）。
也就是說：**在同一個時刻、同一座 fabric 上，舊橫幅會印「Host internet: OK |
sFlow reachability: OK | Switch identification: OK」三個 OK，而新橫幅說了實話。**

---

## 4. 測試：紅 → 綠

新測試 `tests/shell/test_ndt_ovs_topo_script.sh`（41 個 check）。
它**執行**程式碼而不是 grep 字串——把 `$TMUX` 換成一支記錄器，呼叫 `ovs_topo_start`，
再把 root 本來會收到的 argv 讀回來。（grep NTG 路徑的測試，正好是缺陷還活著的那天會綠的測試：
那個字串在檔案裡出現兩次。）

六段：① 啟動交給 root 的是哪一個檔案 ② 路徑是從 `KERNEL_DIR` 導出的（換樹會跟著換）
③ 檔案不在就拒絕、且什麼都沒啟動 ④ **sweep 還找得到它**（生一個真的行程穿上那條命令列，
讓 `sweep_count` 去找；並釘住舊 pattern 找不到它）⑤ 用**會啟動它的那個直譯器**把它 import 起來、
並確認它的橫幅是 #42 的形狀 ⑥ **兩個 dispatch 分支被實際 eval 執行**
（`ovs-topo-start` 與 `cleanup`，PATH 清空當安全帶）——因為前五段都在測函式，
而動詞可以停止呼叫它們，「存在不等於接線」正是 #77 的形狀。

### 對 trunk 的碼跑（紅）

`red_01_trunk_lab_and_topo.log`（trunk 的 `ndtwin-lab` ＋ trunk 的 `testbed_topo.py`）：

```
the launch is reachable at all
  FAILED   ndtwin-lab defines ovs_topo_script
             expected: defined
             actual:   not defined -- the launch is inline in the root-only dispatch
  FAILED   ndtwin-lab defines ovs_topo_pattern
  FAILED   ndtwin-lab defines ovs_topo_start
  ... the remaining sections need ovs_topo_start and cannot run
Ran 5 checks, 3 failed          (rc 1)
```

`red_02_trunk_topo_only.log`（修好的 lab ＋ **trunk 的** `testbed_topo.py`）：

```
  FAILED   it imports under /home/adam/miniconda3/envs/ntg-env/bin/python
             expected: 0    actual: 1
  FAILED     and its banner is finding #42's, not the constant one
Ran 41 checks, 2 failed         (rc 1)
```

### 對本分支跑（綠）

```
Ran 41 checks, 0 failed
```

其他既有套件同步驗過（`gate_05_related_suites.log`）：
`test_testbed_banner.py` 45 OK、`test_ovs4_sflow.py` 21 OK、
`test_ndtwin_lab_sweep.sh` 29 全過、`test_ndtwin_lab_config.sh` 59 全過。

---

## 5. 變異閘門

`tests/shell/mutate_ndt_ovs_topo_script.sh`——**12 個變異，9 個 fire 全滅，3 個 widening 全綠，0 倖存**。

| | 變異 | 必須變紅的那一個 check |
|---|---|---|
| M1 | 啟動又指回 NTG 那份 | the topology comes from the kernel tree |
| M2 | 只有工作目錄退回 NTG（半個 revert） | tmux's working directory is the tree |
| M3 | sweep pattern 留在舊的後綴 | cleanup's pattern matches the launched argv |
| M4 | 拿掉「檔案不在就拒絕」 | rc is non-zero |
| M5 | 路徑變成第二個常數（不隨 `KERNEL_DIR`） | a different KERNEL_DIR moves the script |
| M6 | 動詞把舊啟動 inline 回去（存在≠接線） | the ovs-topo-start branch launches that file |
| M7 | `cleanup` 不再掃它自己起的那個 | cleanup sweeps the pattern the launch uses |
| M8 | `cleanup` 不再收 NTG 孤兒 | and still sweeps the NTG suffix (orphans) |
| M9 | `testbed_topo.py` 掉了直譯器 bootstrap | it imports under … |
| N1 | *widening*：pattern 改成完整路徑後綴（更嚴格） | 必須維持綠 ✅ |
| N2 | *widening*：兩個 sweep 對調並多掃一次 | 必須維持綠 ✅ |
| N3 | *widening*：拒絕條件用 `-e` 而非 `-r` | 必須維持綠 ✅ |

- 變異一律作用在**影子 repo 的副本**上（兩個 subject ＋ 測試一起搬），
  結束時斷言兩個正本 **byte-identical**（已印在 log 裡）。
- 影子 harness 自己也有 baseline 斷言：否則每個 `testbed_topo.py` 變異都可能是
  「harness 壞了」而被讀成「抓到了」。
- **變異套不上＝倖存，不是 skip**（`ANCHOR-FAILED` 走 SURVIVED 分支）。

錨點檢查：`python3 tests/shell/check_gate_anchors.py HEAD --gates mutate_ndt_ovs_topo_script.sh`
→ **`ok(8)`，1/1 cells ok，rc 0**（8＝12 個變異去掉 4 組共用錨點）。

讀同一批檔案的兩支既有閘門重跑，**都維持綠**：
`mutate_ndt_up_target.sh` 8 個變異 0 倖存；`mutate_ovs4_has_sflow.sh` 24 個變異 0 倖存。

---

## 6. Live 證據與它的邊界

| 項目 | BEFORE | AFTER |
|---|---|---|
| 誰啟動 | `ndt up ovs` → `sudo -n /usr/local/sbin/ndtwin-lab ovs-topo-start` | `sudo -n mnexec`（見下） |
| 跑哪個檔 | NTG `ead4d84a` | 本分支 `60509362` |
| fabric | 139 host/switch，`up. ready`，四項驗證全綠 | 139 host/switch，kernel graph 128 hosts / 288 edges |
| 橫幅 | **拍不到**（root tmux pane，`sudo tmux` 非免密碼） | #42 的形狀，逐字見 §3.2 |
| 收尾 | `ndt down` five verify-clean 全 ok | `ndt down` five verify-clean 全 ok |

🔴 **AFTER 這一臂沒有走 `ndt up ovs`，原因要講清楚**：`ndt:55` 把
`LAB=/usr/local/sbin/ndtwin-lab` 寫死，而那是 root 擁有的安裝副本。
要讓修好的 `ndtwin-lab` 真的被 `ndt up ovs` 執行，必須

```
sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
```

——**那需要密碼、是 Adam 的動作**（repo 自己的 KNOWN-ISSUES 也是這樣寫的：
「改 repo 那份不會生效，要重裝」）。我沒有裝，也沒有繞過 sudoers 去 root-run 我的腳本。
所以 AFTER 這一臂證明的是**檔案與橫幅**，不是 tmux 那段接線；
tmux 那段由測試的記錄器證明（§4 第六段，實際 eval 了 dispatch 分支）。

附帶：安裝副本 `288b71cb`（**Aug 30 20:20**）與 trunk 的 repo 副本 `b11b53ee` **早已不同**——
G-7（設定檔）與 G-9（sweep 取代 `pkill -f`）都不在機器上跑的那份裡，而**沒有任何東西會說**。

---

## 7. `git merge-tree --write-tree trunk fix/ndt-up-ovs-runs-repo-topo`

```
rc = 0
baede2afca08b4429145868dbc6dce4a77f3200f
```

只有一行 tree oid、沒有 conflict 區段 ⇒ **可乾淨合併**。

合併基準是 `0be954ad`；`trunk` 在我做事期間已前進到 `92a79392`，**對新的 trunk 再跑一次
也是乾淨的**（`rc 0`、`0b4d39ecf3c6585831061f2095ff3468df288d9d`、一行）。
本分支只碰五個檔案（`git diff --stat 0be954ad..HEAD`）：

```
 doc/audit/2026-09-03_fix-ndt-ovs-topo/FIX-NDT-OVS-TOPO.md  | 335 +
 testbed_topo.py                                            |  22 +
 tests/shell/mutate_ndt_ovs_topo_script.sh                  | 226 +
 tests/shell/test_ndt_ovs_topo_script.sh                    | 306 +
 tools/test_workflow/ndtwin-lab                             |  86 +-
```

分支 commit：

| sha | 內容 |
|---|---|
| `87612059` | 修法本身（`ndtwin-lab` ＋ `testbed_topo.py`） |
| `425a124f` | 測試套件 ＋ 變異閘門 |
| `c4b38c73` | 閘門改寫成 anchor checker 讀得懂的形狀 |

raw：`audit-raw` `643420a3`，28 個檔案於
`doc/audit/2026-09-03_fix-ndt-ovs-topo/raw/`，逐檔 sha256 對帳 **0 mismatch**。

---

## 8. 我**沒有**做的事

1. **沒有動 NTG repo**（唯讀確認過檔案內容與 sha，沒有寫入）。
2. **沒有安裝**修好的 `ndtwin-lab` 到 `/usr/local/sbin/`。需要密碼；也沒有用 `mnexec` 之類
   已授權的洞去繞過那條 sudoers 規則——`ndtwin-lab` 檔頭明講該規則存在的理由就是
   「不要對 adam 可寫的腳本開 NOPASSWD」。
3. **沒有實跑修好的 `ndt up ovs` 全程**（同上）。
4. **沒有改 `ndt:55` 讓 `LAB` 可被環境覆寫**——那正是 `ndtwin-lab` 檔頭花二十行反對的形狀。
5. **沒有處理 `sweep_matches` 的一個既有限制**：某個 argv 元素若**剛好以**目標路徑結尾
   （例如 `bash -c "echo restarting /…/testbed_topo.py"`，後面沒有別的字），
   會被認成那個程式。這對新舊兩個 pattern 一視同仁，不是本次改動引入的。
6. **沒有把 `ndt ntg` 那條路徑一起處理**：本 repo 那份結尾是 `CLI(net)`（Mininet CLI），
   NTG 那份是 `command_line(net, "NTG.yaml")`（NTG 自己的 prompt）。見 §9 Q2。
7. **沒有修**「安裝副本與 repo 副本不一致而沒人會說」這件事（§6 附帶）。
8. **沒有修** anchor checker 讀不到那三支閘門的問題（§9 Q4）。

---

## 9. 給 Adam 的問題

**Q1（必答，否則這個修法在機器上不生效）** 要不要現在重裝 `/usr/local/sbin/ndtwin-lab`？
在合併之後跑一次：

```
sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
```

裝完之後 `ndt up ovs` 才會跑本 repo 那份。裝完我可以再補一趟真正的 `ndt up ovs` AFTER 臂。

**Q2 `ndt up ovs` 之後掉進哪個提示字元？** 換成本 repo 那份之後是 **Mininet CLI**
（`CLI(net)`），不再是 NTG 自己的 prompt——所以 **`ndt ntg cli|prompt` 對 `ndt up ovs`
不再有作用**（它改的是 NTG repo 的 `setting/Mininet.yaml`）。
好處是 `ndt up ovs` 與 `stack.sh` 印給操作員的那條指令終於一致。
要不要 (a) 就這樣、(b) 把 NTG prompt 的選項移植進本 repo 那份、(c) 讓 `ndt ntg` 明說它
現在只對手動路徑有效？我建議 **(a)**，並在下一輪把 `ndt ntg` 的說明改成 (c)。

**Q3 `ovs-topo-4host` 要不要一起收斂？** 它已經跑本 repo 的檔案，形狀與修法後的
`ovs-topo-start` 一致，但兩者的路徑組法還是各寫各的。要不要讓它也走
`ovs_topo_script` 那一族？（本次刻意沒動，因為它沒有壞。）

**Q4 anchor checker 有三支閘門讀不到**：`mutate_ndt_up_target.sh`、
`mutate_g7_ndtwin_lab_config.sh`、`mutate_g9_cleanup_no_pkill_f.sh` 目前都回 **NO-ANCHORS**
（`cat > $A/m1.old` heredoc 那種寫法）。Finding #19 的修法沒有涵蓋這個形狀。
本次的閘門已改成讀得懂的寫法而**沒有**去動那三支——要不要另開一張工單？

**Q5 #42 的驗證等級要不要更正？** 依 §1.1，本 repo 的 `testbed_topo.py` 在 trunk 上
連 import 都過不了，所以 #42 的修法在合併前**從未被執行過**（只有單元測試）。
今晚是它第一次真的跑起來。要不要在 #42 的文件補一句更正？
