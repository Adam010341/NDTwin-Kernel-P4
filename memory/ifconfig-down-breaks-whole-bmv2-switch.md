---
name: ifconfig-down-breaks-whole-bmv2-switch
description: "`ifconfig <iface> down` stops a bmv2 switch forwarding entirely, so it cannot simulate a single link failure. Use `tc netem loss 100%` on both ends instead — measured side by side."
metadata: 
  node_type: memory
  type: reference
  originSessionId: b955baee-a646-4fe6-9986-df69b65478e6
  modified: 2026-08-27T13:57:25.862Z
---

**To break one link on the bmv2 testbed, use `tc netem`, never `ifconfig down`.**

```bash
sudo -n tc qdisc add dev s5-eth4  root netem loss 100%   # both ends = a full link failure
sudo -n tc qdisc add dev s10-eth1 root netem loss 100%
sudo -n tc qdisc del dev s5-eth4  root                   # restore
sudo -n tc qdisc del dev s10-eth1 root
```

NOPASSWD was granted 2026-08-10 in `/etc/sudoers.d/ndtwin-mininet`, **scoped to Mininet interfaces**
(`/usr/sbin/tc qdisc {add,del,show} dev s[0-9]*-eth[0-9]* ...`) so a mistyped device cannot touch a
real NIC — verified: `tc` on the WiFi interface still demands a password.

Measured side by side, same link (`s5<->s10`), same stack, same day:

| | `ifconfig down` | `tc netem loss 100%` |
|---|---|---|
| link-down reports | **5, of which 3 false** | **2, none false** |
| `edges up` | 35/40 | 38/40 |
| switch keeps forwarding | **no** | yes |
| ping | 38% loss, never recovered | 9.67%, recovered in ~15 s by itself |
| can failover be observed | **no** | yes |

`ifconfig down` takes the interface's link state down, and the whole switch then stops moving
traffic — not merely the documented packet-in stall (`2026-07-29_environment_gotchas.md`), which is about
received packets not reaching the CPU. No amount of rerouting rescues a switch that is not
forwarding, so failover is untestable with it. `tc netem` leaves the interface UP and only drops on
the egress queue, so every other port of that switch is untouched.

**Why this took a whole investigation:** the evidence that seemed to prove "the fault spreads to
unrelated switches" was my own error — I checked only the *forward* path of a supposed control
pair. See [[investigation-briefs-separate-observation-from-inference]]. The genuine finding is the
narrower one above.

**Note the baseline was never misusing it:** `OVSPowerStrategy::powerOff` uses `ifconfig down` on
*every* port followed by `ovs-vsctl del-br` — i.e. as one step of shutting a whole switch down,
which is exactly what it is good for. Related: [[live-runs-find-what-tests-cannot]];
the phase plan and how the OVS baseline powers a switch off are in
`doc/2026-07-27_p4_bmv2_support_plan.md`.

## ⚠️ sudoers 只授權會弄壞 htb 的那個形式（2026-08-13 實測）

`sudo -n -l` 的 tc 授權**只有三條**，全部是 `root`：

```
/usr/sbin/tc qdisc add dev s[0-9]*-eth[0-9]* root netem *
/usr/sbin/tc qdisc del dev s[0-9]*-eth[0-9]* root
/usr/sbin/tc qdisc show dev s[0-9]*-eth[0-9]*
```

**也就是說唯一免密碼的注入形式，正好就是會靜默替換掉 TCLink htb 的那個。**
安全的 `parent 5:1` 形式**沒有授權**——實測 `sudo -n tc qdisc add dev s1-eth1 parent 5:1
netem loss 1%` 直接回 `sudo: a password is required`。

還有兩個一 token 之差的陷阱（sudo 逐字比對參數列）：
- `qdisc del dev X root netem` **不在授權內**（多了 `netem`）。`faults.sh` 曾因此注入成功、
  還原失敗、故障留在原地——被 qdisc 前後置快照抓到才沒變成假證據。
- `kill` 完全不在授權內，所以**送信號給 root 起的 bmv2 需要繞路**。

**繞法**（同日實測可用）：`mnexec` 是整支授權的、以 uid 0 執行，所以 tc/kill 放進去就不需要
各自的授權：

```bash
TOPO=$(ps -eo pid,args | grep '[t]estbed_topo.py' | awk '{print $1}' | head -1)
sudo -n mnexec -a "$TOPO" tc qdisc add dev s1-eth1 parent 5:1 netem loss 100%
sudo -n mnexec -a "$TOPO" kill -STOP <bmv2_pid>
```

這實質上繞過了 sudoers 對參數的限制。要嘛照這樣用，要嘛請 Adam 補一條 `parent` 規則
——**後者比較誠實，Adam 尚未表態**。P4 testbed 不用 TCLink（無 shaping），
所以那邊 `root netem` 本來就無害；有 shaping 的是 OVS 的 `testbed_topo.py`。
