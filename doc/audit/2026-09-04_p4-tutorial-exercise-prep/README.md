# P4 tutorial exercise 測試材料整備（2026-09-04 14:0x–14:2x）

Adam 14:00 交辦（auditor 轉達）：「叫 P4 tutorial exercise 先去準備一下我們接下來測試
p4 tutorial exercise 要用到的材料。」

**這一輪只做整備，一個封包都沒送。** 下面每一條都標了「實跑過」或「未執行」，兩者不混表。

✅ **範圍已由 Adam 15:2x 裁定**（auditor 轉達）：「tutorial exercise」＝ p4lang/tutorials 的
exercise（不是官網的 Tutorials 頁）；順序 **`source_routing` → `basic` → `flowcache` → `p4runtime`**；
今晚的整機測試範圍是「兩個平面＋七個外部 app」**不含 tutorials**，所以這支不趕今晚，
`--go` 與 9090 那個 dashboard 都等 Adam 自己來（9090 照舊不動）；**不要推**。

第一支 `source_routing` 的逐步表已交：**[`M7-source_routing.md`](M7-source_routing.md)**。

[Co-developed with claude code -- Adam]

---

## 1. 三個會擋住今晚的東西（都是實測，都不是我能自己解的）

### 🔴 B-1 `make run` 在這台機器上必定失敗，跟 P4 程式無關

upstream `utils/Makefile` 的 `run` 目標逐字是：

```make
run: build
	sudo PATH=$(PATH) ${P4_EXTRA_SUDO_OPTS} python3 $(RUN_SCRIPT) -t $(TOPO) $(run_args)
```

這台的 sudoers 有 `secure_path`，所以 sudo **拒絕**那個 `PATH=` 指派，
在 python3 起來之前就中止：

```
$ sudo -n PATH=/zzz /usr/bin/mnexec /usr/bin/true
sudo: sorry, you are not allowed to set the following environment variables: PATH        # rc=1
```

⇒ **13 支 exercise 沒有一支能用 `make run` 起來**，而失敗訊息完全不提 P4，
去 debug 的人會先懷疑 P4。

**解法（已寫成腳本，但未實跑）**：不要透過 sudo 傳 PATH，直接指名絕對路徑的直譯器——
見 `run_exercise.sh`。它印出指令就停，加 `--go` 才真的跑（要互動式 sudo ⇒ **Adam 跑**）。

### 🔴 B-2 三個 `python3` 裡只有一個能跑這個 harness，而預設那個不行

`run_exercise.py` 在 module level `import p4runtime_lib.simple_controller` 與 `mininet.*`。

| 直譯器 | 版本 | mininet | grpc | scapy | 可用？ |
|---|---|---|---|---|---|
| `python3`（PATH 上的，＝ `~/miniconda3/bin/python3`） | 3.13.13 | ❌ | ❌ | ❌ | **不行** |
| `/usr/bin/python3`（sudo `secure_path` 會挑到的那個） | 3.12.3 | ✅ | ❌ | ❌ | **不行** |
| `/home/adam/p4dev-python-venv/bin/python` | 3.12.3 | ✅ | ✅ | ✅ | ✅ **只有這個** |

venv 那支對 `run_exercise.py` 的 7 個 import **全部通過**（實跑）。
`send.py`／`receive.py` 的 shebang 是 `#!/usr/bin/env python3` ⇒ 在 xterm 裡直接
`./receive.py` 會用到 conda 那支、`ModuleNotFoundError: scapy`。
**在 xterm 裡要先 `source /home/adam/p4dev-python-venv/bin/activate`。**

### 🔴 B-3 thrift port 9090 已經被佔住

tutorials 的第一台交換機固定要 thrift **9090**（`utils/p4runtime_switch.py:20`，
`run_exercise.py` **沒有**對應的 CLI 旗標可以改）。現在：

```
127.0.0.1:9090   users:(("python3",pid=1685271,fd=3))
   cmdline: python3 cli.py dashboard      cwd: /home/adam/claude-usage      起於 09-03 11:09
```

⇒ 那是 Adam 昨天開的 claude-usage dashboard，**不是任何 P4 行程、不是別的 session 的實驗**。
但它會讓 s1 綁不上 thrift port。**我沒有碰它**（也不會用 `pkill -f`）。
要跑之前請 Adam 自己收掉，或接受 s1 起不來。
gRPC 那側 50051–50060 目前**全空**。

---

## 2. 材料清單與狀態

| # | 材料 | 狀態 | 位置／證據 |
|---|---|---|---|
| M1 | 13 支 exercise 的 P4 編譯產物（`.json` ＋ `.p4info.txtpb`） | ✅ **已生成，實跑** | `~/.cache/p4-tutorial-kit/build/`，832 KB／50 檔；`compile_all.sh` 可重生 |
| M2 | 編譯結果矩陣（26 支程式：13 骨架＋13 solution） | ✅ **實跑** | `COMPILE-MATRIX.txt` |
| M3 | 工具鏈身分（sha256 ＋ 版本字串） | ✅ **實跑** | 本文 §3 |
| M4 | 每支 exercise 的拓樸／控制面／測試腳本盤點 | ✅ **實跑** | 本文 §4 |
| M5 | 環境 pre-flight（可重跑） | ✅ **實跑** | `preflight.sh` |
| M6 | 起動指令（繞過 B-1） | ⚠️ **寫好、dry-run 過；`--go` 一次都沒跑**。🔴 **第一版有 bug，已修**（見 §7） | `run_exercise.sh` |
| M7 | 逐步表＋每步預期輸出 | ✅ **`source_routing` 已交**；`basic`／`flowcache`／`p4runtime` 待做 | [`M7-source_routing.md`](M7-source_routing.md) |
| M8 | 要對照的文件 | ✅ **已釐清**＝各 exercise 自己的 `README.md`（**它也在受測**），不是官網 Tutorials 頁 | 見 §6 |

---

## 3. 工具鏈身分

版本字串**分不出**這台機器上那兩顆 `simple_switch_grpc`——它們的 `--version` 一模一樣、
sha256 不同。要指認只能用 sha。

| 執行檔 | sha256（前 16） | `--version` |
|---|---|---|
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | `1.2.5.15 (SHA: 5b948b037a BUILD: Release)` |
| `/usr/local/bin/simple_switch_grpc` | `327fa7d172217397` | `1.15.3-f0b7d201` |
| `/usr/local/bmv2-fast/bin/simple_switch_grpc` | `3ff54b5c1901c9d3` | **`1.15.3-f0b7d201`（同字串）** |
| `/usr/bin/mn` | `f9b8dd49efef28fb` | `2.3.0` |

🔑 **tutorials 會用哪一顆**：`BMV2_SWITCH_EXE = simple_switch_grpc`（名字，不是路徑）
⇒ 走 sudo 的 `secure_path` ⇒ 解到 `/usr/local/bin` 那顆（`327fa7d1`）。
而 `ndt status` 顯示 NDTwin 自己的 lab 用的是 `bmv2-fast` 那顆（`3ff54b5c`）。
**兩顆不同的 binary。** 任何拿 tutorial 跑出來的數字要跟我們的比，這一行必須先講清楚。

---

## 4. 13 支 exercise 的盤點（實測）

| exercise | 預設程式 | 拓樸 | hosts/sw | `*-runtime.json` | 測試腳本 |
|---|---|---|---|---|---|
| basic | `basic.p4` | `pod-topo/`（另有 `triangle-topo/`） | 4/4 | 4＋3 | `send.py` `receive.py` `runptf.sh` |
| basic_tunnel | `basic_tunnel.p4` | `topology.json` | 3/3 | 3 | `send.py` `receive.py` `myTunnel_header.py` |
| calc | `calc.p4` | `topology.json` | 2/1 | 1 | `calc.py` |
| ecn | `ecn.p4` | `topology.json` | 5/3 | 3 | `send.py` `receive.py` |
| firewall | **`basic.p4`** ⚠️ | `pod-topo/` | 4/4 | 4 | —（用 `mininet> iperf`） |
| flowcache | `flowcache.p4` | `topology.json` | 3/3 | **0** | `mycontroller.py` |
| link_monitor | `link_monitor.p4` | `pod-topo/` | 4/4 | 4 | `send.py` `receive.py` `probe_hdrs.py` |
| load_balance | `load_balance.p4` | `topology.json` | 3/3 | 3 | `send.py` `receive.py` |
| mri | `mri.p4` | `topology.json` | 5/3 | 3 | `send.py` `receive.py` |
| multicast | `multicast.p4` | `sig-topo/` | 4/1 | 2 | —（用 `mininet> pingall`） |
| p4runtime | `advanced_tunnel.p4` | `topology.json` | 3/3 | **0** | `mycontroller.py` |
| qos | `qos.p4` | `topology.json` | 5/3 | 3 | `send.py` `receive.py` |
| source_routing | `source_routing.p4` | `topology.json` | 3/3 | 3 | `send.py` `receive.py` |

三件會咬人的：

- ⚠️ **`firewall/` 的 `DEFAULT_PROG` 是 `basic.p4` 不是 `firewall.p4`**（`exercises/firewall/Makefile:5`）。
  該目錄同時有兩支 `.p4`；`make build` 兩支都編，但 `make run` 載入的是 `basic.json`。
  拿它做「防火牆有沒有生效」的測試時，**載入的程式要自己指定**，不能靠預設。
- ⚠️ **`flowcache` 與 `p4runtime` 沒有 `*-runtime.json`**：規則不是開機時灌的，
  要跑起來之後另外執行 `mycontroller.py`（走 P4Runtime）。
  `p4runtime/solution/` 裡只有 `mycontroller.py`，**沒有 `.p4`**。
- ⚠️ **`basic` 有兩套拓樸**：`pod-topo`（Makefile 的預設）與 `triangle-topo`。
  講「basic 跑過了」要指明哪一套。

### 編譯矩陣的結論（`COMPILE-MATRIX.txt`，26 支全部實編）

**25 支 rc=0，只有 1 支失敗**：`flowcache/flowcache.p4`（骨架）——
5 個 `--Werror=type-error`，因為 `packet_in`／`packet_out` header 的欄位**還沒被宣告**
（README 第 29 行明講那就是第一項作業）。**那是設計上的失敗，不是環境壞掉。**

🔴 **這推翻我記憶裡的一條**：`p4lang-tutorials-as-local-control` 寫「exercise 的 `.p4` 是
未填空的骨架（**編不過**）」。實測 **13 支骨架有 12 支 rc=0**。骨架缺的是 table entry／
action 內容，不是語法 ⇒ **編得過，但行為不對**。這個差別對「Step 1 應該看到什麼」很關鍵：
Step 1 的預期不是「編譯失敗」，是「起得來但 ping 不通」。記憶已更正。

其餘可注意的：`qos/solution/qos.p4` 有 **25 個 unused 警告**（全部是 `IP_PROTOCOLS_*` 常數），
是 26 支裡最多的；`firewall/basic.p4` 是唯一 0 警告的骨架。

---

## 5. 逐步表（M7）

13 支的 `README.md` 都是同一個骨架：
**Step 1**（跑未完成的起始碼，預期「起得來但功能不對」）→
**Step 2**（填 `TODO`）→ **Step 3**（跑 solution，預期功能對）→ Troubleshooting → Cleaning up。
每一步的預期輸出在 upstream README 裡是散文（`You should ...`）。

| 順序 | exercise | 狀態 |
|---|---|---|
| 1 | **`source_routing`** | ✅ **已交** — [`M7-source_routing.md`](M7-source_routing.md) |
| 2 | `basic` | ⏸ 待做。⚠️ 有**兩套拓樸**，要先定 `pod-topo` 還是 `triangle-topo` |
| 3 | `flowcache` | ⏸ 待做。⚠️ **骨架編不過**（那正是它的第一項作業）⇒ Step 1 的預期跟其他支不同 |
| 4 | `p4runtime` | ⏸ 待做。⚠️ 無 `*-runtime.json`、`solution/` 裡**沒有 `.p4`**，規則靠 `mycontroller.py` 灌 |

**Step 2（填 TODO）我們不做**——測的是 exercise 本身不是做作業，直接載入 `solution/`。
做法見 `M7-source_routing.md` §4（編到骨架的輸出檔名，不覆蓋原始檔）。

---

## 6. 我沒做、以及為什麼

| 沒做的事 | 原因 |
|---|---|
| 跑任何一支 exercise（`make run` / `run_exercise.sh --go`） | 要互動式 sudo。NOPASSWD 只放行 `mnexec`／`ovs-vsctl`／`ifconfig`／`tc`／`ndtwin-lab`／`ndtwin-p4-power`，**不含 `mn`、`python3`** ⇒ 只有 Adam 能跑 |
| `ndt up` | auditor 說 15:30 前不要動 lab（主 checkout 要重建）。**現在 lab `claim none`／`measuring nothing`，我沒有 claim** |
| 任何 C++／kernel build | auditor 的建置鎖 |
| 收掉佔住 9090 的行程 | 那是 Adam 的 dashboard，不是我的；而且守則禁止 `pkill -f` |
| 改 `~/tutorials` 裡任何**被追蹤**的檔 | 它是對照組。🔴 **更正**：我原本宣稱「樹裡零寫入」——**做不到，而且那樣做會壞掉**。`run_exercise.py` 把 `sX-runtime.json` 與該檔裡的 `p4info`／`bmv2_json` **全部相對於 cwd 解析**（`run_exercise.py:274` 傳 `workdir=os.getcwd()`）⇒ **cwd 必須是 exercise 目錄，產物必須在它的 `build/`**。現在寫入僅限 `build/`／`logs/`／`pcaps/`，三個都在該樹的 `.gitignore`（用 `git check-ignore` 驗過），**被追蹤的內容零改動**（`git status` 前後相同，實測） |
| 對照官網的 Tutorials 頁 | ✅ **已裁定不是那個**：這一輪的「tutorial exercise」＝ p4lang/tutorials 的 exercise。官網那兩頁（`TrafficEngineeringApp.md`／`EnergySavingApp.md`）是另一件事，A-12e 已實跑過 ⇒ **M8 的對照對象就是各 exercise 自己的 `README.md`**，而它本身也在受測（見 `M7-source_routing.md` 的三級標記） |

### ⚠️ `~/tutorials` 現在不是乾淨的

```
 M exercises/basic/basic.p4        （3 行，全部是註解；HEAD = c80d83e）
?? antoninbas.vscode-p4-0.2.1.vsix
?? antoninbas.vscode-p4.vsix
```

改動只有註解（`*action data*` 掉了收尾的 `*`、一行 `table_add` 範例被移到行首），
**不影響編譯或行為**——但 `2026-08-27_p4guide-v10-tty/PREREG.md:99` 對 `~/tutorials`
斷言過 `DIRTY_COUNT=0`。**要拿它當對照組之前，這一行得先講清楚是誰改的。**

---

## 7. 檔案

| 檔 | 用途 | 跑過？ |
|---|---|---|
| `preflight.sh` | 可重跑的環境檢查（唯讀、不殺行程、不寫 `~/tutorials`） | ✅ 跑過，並且**修過自己的兩個 bug**（見下） |
| `run_exercise.sh` | 繞過 B-1 的起動指令；預設只印不跑，`--go` 才跑 | ⚠️ 13 支 dry-run 全過；`--go` **一次都沒跑** |
| `compile_all.sh` | out-of-tree 編譯全部 26 支 | ✅ 跑過 |
| `COMPILE-MATRIX.txt` | 上者的輸出 | ✅ |

🔑 **`preflight.sh` 第一版說謊，被自己的輸出抓到**：sudo 那一項印「accepted」，
而我五分鐘前才手測到它是 refused。原因是 `set -o pipefail` ——
`sudo ... 2>&1 | grep -q` 這個 pipeline 的 rc 變成 **sudo 的 1**（不是 grep 的 0），
於是 `if` 走了 else。**新工具是第一個該被測的東西**；已改成先接字串再比對，並在碼裡註記原因。
（第二個 bug 較輕：`p4c-bm2-ss --version` 把版本印在**第二行**，`head -1` 只拿到程式名。）

🔴 **`run_exercise.sh` 第一版對 13 支裡的 11 支是壞的，而 dry-run 驗不出來。**
它用絕對路徑餵 `-t`／`-j`、不切 cwd，看起來很乾淨——但 `run_exercise.py` 是
`open(sw_dict['runtime_json'])`（相對路徑）＋ `program_switch(..., workdir=os.getcwd())`，
而 `sX-runtime.json` 裡寫的是 `build/source_routing.json`。⇒ **有 `*-runtime.json` 的 11 支
都會在 P4Runtime 設定那一步 `FileNotFoundError`**，而我的 dry-run 只印指令、根本走不到那裡。
已改成 `cd` 進 exercise 目錄，並把選中的程式（骨架**或** solution）編到
**骨架的輸出檔名** `build/<prog>.json`——`sX-runtime.json` 指名的就是它，
載入位元相同，而 `.p4` 原始檔一個字沒動。
🔑 **教訓**：dry-run 驗的是「指令長得對不對」，不是「指令跑起來對不對」。
這個 bug 只有讀被呼叫端的原始碼才看得到。
