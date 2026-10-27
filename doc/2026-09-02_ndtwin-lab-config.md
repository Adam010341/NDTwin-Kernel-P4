# `ndtwin-lab` 的安裝時設定檔（G-7）

2026-09-02。[Co-developed with claude code -- Adam]

`ndtwin-lab` 的 `KERNEL_DIR` 從寫死改成「**可以**用一個只有 root 能寫的設定檔覆寫」。
**沒有設定檔的機器跑的是同一棵樹、同一個直譯器、同一個 NTG checkout。**
唯一的差別（2026-10-27）：`NTG_DIR` 指的不是 NTG checkout 時（例如沒有設定檔、NTG 又不在 `/home/adam` 底下），
`topo-start` 現在當場拒絕，而不是起一個秒死的 pane。

## 為什麼不是環境變數

檔頭那 20 行反對的是 **env override**，理由是：這支腳本 root-owned、透過 NOPASSWD sudoers 執行，
而 `BRIDGE`（`$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py`）是**以 root 執行**的。
讓環境選 `KERNEL_DIR`，等於讓任何以 adam 身分執行的東西指定 root 要跑哪一支 `.py`。

設定檔沒有這個問題，差別**不在檔案格式，在於誰選、什麼時候選**：

| | 誰選 | 什麼時候 |
|---|---|---|
| env var | 呼叫者 | 每次呼叫 |
| 設定檔 | 這台機器的管理者 | 安裝時一次 |

前者是「任何以 adam 身分跑的東西」，後者是「已經是 root 的人」。

🔑 **不要把這個修法讀成比它實際更安全。** 預設的 `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`
**本來就是 adam 可寫的**，所以「root 執行一支 adam 可寫的 `.py`」這件事今天就已經成立。
這次改的是**選哪棵樹**這個決定被關進一個只有 root 能編輯的檔案；
讓被執行的那棵樹本身變成 root-owned 是另一個決定，**這次沒有做**。

## 安裝

```bash
sudo install -o root -g root -m 644 /dev/stdin /etc/ndtwin-lab.conf <<'EOF'
KERNEL_DIR=/home/<user>/Desktop/NDTwin-Kernel-worktree
NTG_PY=/home/<user>/miniconda3/envs/ntg-env/bin/python
NTG_DIR=/home/<user>/Network-Traffic-Generator
EOF
```

🔴 **先重裝 helper，再寫 `NTG_DIR=`**（2026-10-27）：舊的 `/usr/local/sbin/ndtwin-lab` 不認識 `NTG_DIR`，
會把**整個**設定檔當成不可信而拒絕（`unknown key 'NTG_DIR'`）——之後**每一個會動東西的子命令都拒絕執行**，
包括 `topo-stop`／`cleanup`（`ndt down`）。重裝指令在本文最後一節；`ndt status` 會比對已安裝的與 checkout 裡的是否相同。

把 `<user>` 那段換成你自己的 checkout。值必須是**絕對路徑**：檔案是解析不是 `source`，`$HOME` 不會展開，寫成 `$HOME/...` 會被拒絕。

五個鍵，全部可省略（省略＝用內建預設）：

| 鍵 | 預設 |
|---|---|
| `KERNEL_DIR` | `/home/adam/Desktop/NDTwin-Kernel` |
| `NTG_PY` | `/home/adam/miniconda3/envs/ntg-env/bin/python` |
| `ENERGY_DIR` | `/home/adam/Energy-Saving-App` |
| `SIM_DIR` | `/home/adam/Simulation-Platform-Manager` |
| `NTG_DIR` | `/home/adam/Network-Traffic-Generator`（2026-10-27 加入） |

⚠️ **內建預設都在 `/home/adam` 底下。** 在其他使用者、其他機器上，P4 路徑至少要寫
`KERNEL_DIR`、`NTG_PY`、`NTG_DIR` 三個鍵。

`NTG_DIR` 是 Network-Traffic-Generator 的 checkout，P4 的 bridge（`ntg_bmv2_topo.py`）從那裡 import
NTG 的 CLI。它**不從 `NTG_PY` 推導**：`NTG_PY` 是 conda env 或 venv 的直譯器，通常不在 NTG 的 checkout 裡。
`topo-start` 把它以 `env NTG_DIR=<值>` 的形式**明確**交給 bridge——`ndt up` 呼叫端的環境變數到不了
root tmux 裡的 bridge（sudo 會重設環境），所以 bridge 舊訊息裡「override with the NTG_DIR env var」
在 `ndt up` 這條路上是做不到的。
2026-10-26 在一台全新 VM 上實測：NTG 裝在 `/home/ndt/Network-Traffic-Generator`、設定檔只有
`KERNEL_DIR`／`NTG_PY`，`ndt up p4 4` 在 185.4 秒後 rc 1、`0/10 switches`，原因只寫在 `topo.log`。
現在 `NTG_DIR` 不是 NTG checkout（沒有 `network_traffic_generator.py`）時，`topo-start` **當場拒絕**並指名這個鍵，
`sudo ndtwin-lab config` 也會在那一行標出 `topo-start will refuse`。
OVS 路徑（`ovs-topo-start`、`ovs-topo-4host`）跑的是本 repo 的拓樸檔，不 import NTG，不需要 `NTG_DIR`。

確認生效：

```bash
sudo ndtwin-lab config
```

`status` 也會在第一行印出目前的來源與 `KERNEL_DIR`，`topo-start` 會印出它是從哪棵樹起的。
這是 FINDING-01 的另一半修法——那次的問題不是「用錯樹」，是「用錯樹而且**沒有任何一行輸出說了這件事**」：
fabric 128、model 4、每一項結構檢查都綠。

## 它會拒絕什麼（以及為什麼要拒絕）

設定檔存在但不可信時**拒絕採用它**——安靜地跑預設正是 FINDING-01 再演一次，
所以拒絕的理由會印在最顯眼的位置（含檔案路徑與移除方法），而不是被吞掉。

**唯讀的照跑，會動東西的失敗關閉：**

| 子命令 | 設定檔被拒時 |
|---|---|
| `status`、`config` | **照跑**，用內建預設，先印 🔴 拒絕理由＋`sudo rm /etc/ndtwin-lab.conf` |
| 其他全部（`topo-start`、`cleanup`、`*-start`、`*-stop` …） | **拒絕執行**，同樣印出理由與救援指令 |

`status` 是打錯一個字之後你會用來搞清楚發生什麼事的那個命令，而且它什麼都不碰。
把它一起鎖掉，救援路徑就只剩「已經知道答案的人」；不知道的人會以為 lab 壞了。

- 目錄不是 root 所有、或 group／other 可寫 → 拒絕。
  **先檢查目錄再檢查檔案**，因為對目錄有寫權限＝可以把檔案整個換掉
  （把 root 的那份改名移走、放自己的進去），那樣檢查檔案本身完全沒有意義。
- 檔案不是 root 所有、或 group／other 可寫 → 拒絕。
- 檔案是 symlink → 拒絕（`stat` 報的是 link 本身；跟著走則會讓一個放在受信任目錄裡的 link
  指到別處一個 adam 可寫的檔）。
- 內容用**解析**不用 `source`；只認上面五個鍵，其他鍵是**錯誤**不是忽略
  （被忽略的一行＝寫的人以為生效了而其實沒有）。
- 值必須是絕對路徑、不得含 `..`。
- `KERNEL_DIR` 必須存在且底下真的有 `p4_proxy/mininet/ntg_bmv2_topo.py`——
  在**載入時**失敗，而不是等到 `topo-start` 跑到一半、root 已經在建 fabric 的時候。

## 已安裝的那份沒有被動過

repo 內的 `tools/test_workflow/ndtwin-lab` 與 `/usr/local/sbin/ndtwin-lab` 本來 byte-identical，
**這次改完不再相同**。要生效必須有人**刻意**重裝：

```bash
sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
```

**sudoers 不用改**（檔名、路徑不變，只多一個 `config` 子命令）。

