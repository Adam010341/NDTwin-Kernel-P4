# `ndtwin-lab` 的安裝時設定檔（G-7）

2026-09-02。[Co-developed with claude code -- Adam]

`ndtwin-lab` 的 `KERNEL_DIR` 從寫死改成「**可以**用一個只有 root 能寫的設定檔覆寫」。
**沒有設定檔的機器行為完全不變。**

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
KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel-worktree
EOF
```

四個鍵，全部可省略（省略＝用內建預設）：

| 鍵 | 預設 |
|---|---|
| `KERNEL_DIR` | `/home/adam/Desktop/NDTwin-Kernel` |
| `NTG_PY` | `/home/adam/miniconda3/envs/ntg-env/bin/python` |
| `ENERGY_DIR` | `/home/adam/Energy-Saving-App` |
| `SIM_DIR` | `/home/adam/Simulation-Platform-Manager` |

確認生效：

```bash
sudo ndtwin-lab config
```

`status` 也會在第一行印出目前的來源與 `KERNEL_DIR`，`topo-start` 會印出它是從哪棵樹起的。
這是 FINDING-01 的另一半修法——那次的問題不是「用錯樹」，是「用錯樹而且**沒有任何一行輸出說了這件事**」：
fabric 128、model 4、每一項結構檢查都綠。

## 它會拒絕什麼（以及為什麼要拒絕）

設定檔存在但不可信時**直接失敗，不會退回預設**——
有人寫了設定檔就代表他想換樹，此時安靜地跑預設正是 FINDING-01 再演一次。

- 目錄不是 root 所有、或 group／other 可寫 → 拒絕。
  **先檢查目錄再檢查檔案**，因為對目錄有寫權限＝可以把檔案整個換掉
  （把 root 的那份改名移走、放自己的進去），那樣檢查檔案本身完全沒有意義。
- 檔案不是 root 所有、或 group／other 可寫 → 拒絕。
- 檔案是 symlink → 拒絕（`stat` 報的是 link 本身；跟著走則會讓一個放在受信任目錄裡的 link
  指到別處一個 adam 可寫的檔）。
- 內容用**解析**不用 `source`；只認上面四個鍵，其他鍵是**錯誤**不是忽略
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
