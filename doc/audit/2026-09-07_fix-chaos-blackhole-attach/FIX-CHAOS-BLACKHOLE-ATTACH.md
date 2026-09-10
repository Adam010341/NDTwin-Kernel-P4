# FIX — chaos harness `link_blackhole` attaches netem under the shaper, not over it (W8-8)

[Co-developed with claude code -- Adam]

分支 `fix/chaos-blackhole-attach-under-shaper`，base＝trunk `1536ff17`。2026-09-07。
裁決：`scratch/overnight-2026-09-05/DECISIONS.md`「grill §4D 第七輪」W8-8 ⇒ **開單**。
缺陷來源：`scratch/overnight-2026-09-05/fix/W8-SUMMARY.md` §6 與 §7 第 8 條（W8 的 agent 修 B-6
時順手查到的，不在那張單的範圍）。

## 1. 缺陷

`doc/audit/2026-08-28_chaos-harness/harness/actions.py`（trunk `1536ff17` 的 `:516-563`）：

| | trunk 的行為 |
|---|---|
| apply | `sudo tc qdisc add dev <iface> root netem loss 100%` — **無條件 `root`**，沒有讀 qdisc 樹 |
| verify | `"netem" in out and "loss 100%" in out` |
| undo | `sudo tc qdisc del dev <iface> root` |
| note | `"reversible; undo removes the qdisc"` |

在 Mininet TCLink 介面上 `add ... root netem` **不是疊一層，是把 htb 換掉**，而 `del ... root`
還回來的是 kernel 預設不是 htb。這件事 2026-08-13 逐字量過
（`doc/audit/2026-08-12_overnight-review/C-live-ovs-runbook.md` P1）：

```
$ tc qdisc show dev s1-eth2
qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000
$ sudo -n tc qdisc add dev s1-eth2 root netem loss 100%      # 沒有任何錯誤輸出
$ tc qdisc show dev s1-eth2
qdisc netem 8005: root refcnt 15 limit 1000 loss 100%        # htb 5: 與 class 5:1 都不見了
$ sudo -n tc qdisc del dev s1-eth2 root
$ tc qdisc show dev s1-eth2
qdisc noqueue 0: root refcnt 2                               # 既不是 netem 也不是 htb
```

而這台機器的 NOPASSWD 沒有放行「加回 htb」⇒ **這條路徑造成的破壞，harness 自己修不回來。**

🔴 **讓它在 harness 裡活下來的不是 attach point，是 verify。**
`netem ... loss 100%` 在「安全地掛在 htb class 底下」與「剛剛把 htb 換掉」**兩種結果裡都成立**，
所以那個 G2 檢查在它親手破壞掉的介面上會回報「fault landed」。
**一個看不見自己造成的破壞的 G2 檢查，比沒有這個 action 更糟。**

**沒有實際發生過破壞**：`link_blackhole` **不在 `CHAOS_ACTIONS` 裡**，`chaos.py:544` 只有
`--dry-run` 那條路會建出它 ⇒ 這是「還沒被踩到的地雷」，不是「已經炸掉的現場」。

## 2. 修法

規則**不是這裡發明的**，是 `tools/test_workflow/faults.sh` 的 `netem_attach_point`／
`netem_delete_point`（2026-08-13 那一輪的產物）與 `include/utils/NetemLinkFault.hpp` 的
`planAttach`／`findExistingNetem`（同一條規則在 kernel 裡的版本，在分支
`fix/w8-declared-link-failure-sticky` 上，**尚未併進 trunk**）的直譯：

- 介面上已經有 netem ⇒ **拒絕**（疊上去會讓還原分不清誰是誰）
- root qdisc 是 `htb`（TCLink）⇒ 掛在 `parent <handle><default>`，**在 shaper 底下**
- 其他（沒有 shaper）⇒ `root` 是對的，這也是 P4 runbook 那份 root-netem 配方成立的地方

undo **重讀一次樹**才決定刪哪裡，而不是記得自己掛在哪：樹才是狀態。

檔:行（本分支 `doc/audit/2026-08-28_chaos-harness/harness/actions.py`）：

| 位置 | 東西 |
|---|---|
| `:517-561` | 缺陷說明區塊：2026-08-13 的逐字量測、為什麼舊 verify 看不見、規則的三個出處 |
| `:575-585` | `_KERNEL_DEFAULT_ROOT_QDISCS`——**列的是「丟掉也沒關係」的那一邊**，所以沒見過的 shaper 是被保護的（fail-closed） |
| `:588-598` | `_qdisc_lines`／`_root_qdisc`——`root`／`parent` 一律當 **token** 找，兩種 `tc qdisc show` 拼法（有 `dev` 與沒有）都吃 |
| `:601-635` | `netem_attach_point` |
| `:638-661` | `netem_delete_point` |
| `:664-804` | `_LinkNetem`：apply／verify／undo 共用同一個物件，因為 verify 現在要比對注入**前後**的樹 |
| `:807-825` | `link_blackhole`：`note=` 不再宣稱一句它做不到的 reversible |

三個行為改變，逐條：

1. **apply 先讀樹再決定 attach point**；讀不到就是失敗的注入（`injection_round` 會 ABORT），
   dry-run 讀不到就明說「planned: none」而**不再印一條它沒有讀出來的指令**。
2. **verify 兩半**：netem 落地了，**而且**注入前的 root qdisc 若不是 kernel 會自己還回來的那幾種，
   它必須還在。這一半是 2026-08-13 那一輪需要而沒有的。
   🔴 判準只看樹，**不看 `self.attached`**——用「我本來就打算掛 root」去豁免，會讓唯一要抓的那個
   變異（shaped 介面上 attach point 退回 root）自己豁免自己。
3. **undo 讀樹找 netem 實際掛在哪**，刪在那裡；沒有 netem 就**一個 tc 都不下**（舊版會 `del root`）；
   刪不掉會往 stderr 吼一行（舊版 `except Timeout: pass`，靜默留下 fault）。

順手的兩處，都寫在這裡免得看起來像偷渡：

- `sudo` → `sudo -n`。沒有 `-n` 時被拒絕的授權會變成「卡 5 秒然後 Timeout 被吞掉」，
  也就是靜默殘留；`-n` 只是不問密碼，既有的 credential 一樣用得到。
- delete 的兩種形式都**不帶尾巴的 `netem`**。root 形式是量過的硬限制（sudoers 逐字比對，
  多一個 token 就 `a password is required`，2026-08-13）；parent 形式 `NetemLinkFault.hpp`
  的 restore 也不帶，而 faults.sh 帶。**兩種寫法在 `del dev … parent *` 這條 grant 下都應該可以，
  我選了嚴格子集的那一種，而且我沒有實跑過任何一種**（本輪不碰 lab）。

`STATUS.md` 的 §4 那一列與「3 of ~50」那一段一起更正——舊文字寫著「`tc netem` 不是
`ifconfig down`」，而它用的正是會毀掉 testbed 的那一種 `tc netem`。

## 3. 測試與閘門

- `tests/python/test_chaos_link_blackhole_attach.py`：**30 支**，stdlib、不建置、不碰 fabric、
  不跑 `tc`（`probes.run` 被換掉，而且會**記錄每一條 argv**——一半的宣稱是關於「送出去的指令」，
  不是關於「回來的答案」，因為 shaped 介面上 `add … root netem` 是會成功的）。
  餵進去的樹**有真實擷取就用真實擷取**（2026-08-13 那三行），其餘用
  `tests/shell/test_faults.sh` 拿來驅動 shell 正本的同一組。
  其中一支**直接在 subshell 裡問 `faults.sh` 本人**同一棵樹的答案再比對——這條規則現在在 repo 裡
  有三份實作，而「port 跟正本漂開了」正是要防的失效。
- `tests/shell/mutate_chaos_blackhole_attach.sh`：W1–W8（拿掉規則的一片 ⇒ 指名的 case 要紅）、
  X1–X4（合約允許的放寬 ⇒ 整套要綠）、U1（惰性編輯 ⇒ 必須 SURVIVED，這是 scorer 自己的對照）。
  變異寫進 harness 的**複本**（`NDT_CHAOS_HARNESS`），`doc/audit/…/harness/` 一個 byte 都不寫。

看紅逐字在 `scratch/overnight-2026-09-05/fix/R2-PY-SUMMARY.md` §3。

## 4. 沒做的

- **沒有 live 驗**：本輪不碰 lab，`tc` 一次都沒真的跑過。所有 tc 行為的宣稱都是
  「讀 2026-08-13 的量測」＋「假的 `tc qdisc show` 輸出」，不是這一輪量到的。
- **沒有把 `link_blackhole` 加進 `CHAOS_ACTIONS`**：那會改變 `--full` 跑什麼，不是這張單的範圍。
- **`needs_opt_in` 沒設**：`chaos.py:164` 只在 `--controls` 那條路檢查它，對這個 action 設了也不會生效。
- **`sudo -n -l` 我讀過（唯讀查詢），但沒有實測 `del … parent H:D` 這個 argv 會不會被 sudoers 收**。
- **同型盤點沒做**：harness 裡還有沒有別的「檢查條件在兩種結果下都成立」的 verify。**不宣稱不存在。**
