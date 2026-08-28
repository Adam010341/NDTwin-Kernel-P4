# 預註冊：install-p4dev-v10.sh 的失敗是 v10 的性質，還是我執行方式的性質？

**寫於 2026-08-27 23:29，在對照實驗開始之前。append-only —— 底下只准新增，不准改上面。**
[Co-developed with claude code -- Adam]

## 為什麼要做這個對照

2026-08-27 23:00，`install-p4dev-v10.sh` 在乾淨的 Ubuntu 24.04 VM 上跑了約 10 分鐘後
`rc=1`，`simple_switch_grpc` 與 `p4c-bm2-ss` **都不存在**。我據此改了官網文件
（`8e36eab`：釘 v8，並寫入「v10 在 24.04 實測失敗」）。

23:20 重跑同一支腳本，**它正常建置**（clone z3、build libbpf、裝了 89.8 MB 套件）。

兩次之間我找到一個**具名的、有機制的**嫌疑，來自第一輪的 log：

```
debconf: (Dialog frontend will not work on ... without a controlling terminal.)
debconf: (This frontend requires a controlling tty.)
dpkg-preconfigure: unable to re-open stdin:
```

我為了讓建置活過 ssh 斷線而用 `setsid nohup … < /dev/null` **卸離執行**，
代價是**沒有 stdin、沒有 controlling tty**。
🔑 **真實使用者在終端機裡跑 `./install-p4dev-v10.sh` 不會處於那個狀態。**

⇒ **「v10 在 24.04 上失敗」有可能不是 v10 的性質，是我的執行方式的性質。**

## 設計

**一個變數，其餘完全相同。** 兩臂都從**同一個快照**開始（同一個起始狀態），
跑**同一支** `install-p4dev-v10.sh`，判準是**產物**不是 rc。

| 臂 | 啟動方式 | controlling tty |
|---|---|---|
| **TTY** | `ssh -tt … './p4-guide/bin/install-p4dev-v10.sh'` | 有 |
| **NOTTY** | `setsid nohup bash -c '… < /dev/null'` | 無（＝ 23:00 那輪） |

**判準（兩臂相同）**：`command -v simple_switch_grpc` 與 `command -v p4c-bm2-ss` 是否都存在。
**不看安裝器的 exit status。**

## 🔴 四種結果的判讀 —— 全部先寫死

| # | 結果 | 判讀 | 對文件的動作 |
|---|---|---|---|
| 1 | **TTY 成功、NOTTY 失敗** | 成因是**我的執行方式**。v10 本身沒問題 | 🔴 **刪掉「v10 在 24.04 實測失敗」那句**；§6.1 是否仍釘 v8 另議 |
| 2 | **兩臂都成功** | 第一次失敗**不可複製**（網路？當時的套件狀態？） | 🔴 **同樣要刪那句** —— 一次不可複製的觀察不足以寫進對外文件 |
| 3 | **兩臂都失敗** | v10 真的裝不起來，與 tty 無關 | ✅ 那句成立，**且這個對照本身就是證據**；v8 需要自己的乾淨室證據 |
| 4 | **TTY 失敗、NOTTY 成功** | **沒有現成解釋** | ⛔ **記成獨立結果，不要塞進最近的分支**；文件那句暫停，另開調查 |

⚠️ **第 1 和第 2 的動作相同（刪），但理由完全不同，紀錄時不可以合併。**

## 為什麼要有第 4 列

今晚已經發生過一次：我事前寫的判讀規則是
`rc=124 ⇒ 仍卡在互動提示 ⇒ 修正 2 失敗`，**實測真的回 124，而成因是我的 `timeout` 太短**。
觀察逐字符合預註冊的判準，結論卻是錯的。

🔑 **這次的防法是讓「成因是我的執行方式」成為判讀表上的一個具名選項**，
而不是等結果出來再去想它。**第 4 列的存在，就是承認我可能兩邊都猜錯。**

## 已知會混淆結果的東西（先寫下來）

1. **網路**：今晚已經出現一次 `IncompleteRead`（conda）。若某一臂死在下載，
   **那不算該臂的結果**，要重跑。判別法：log 裡有 `Connection broken` / `IncompleteRead` / `Could not resolve`。
2. **磁碟**：VM 內 `/dev/vda1` 51 GB 可用，文件要求 25 GB。**若某一臂 ENOSPC，同樣不算結果。**
3. **起始狀態**：兩臂必須從同一個快照開始。**23:00 那輪之後的 VM 已經被 v10 動過**，
   不能拿它當任何一臂的起點。
4. **`p4-guide` 自己會變**：`git clone` 不指定 commit ⇒ 兩臂之間 upstream 可能更新。
   **兩臂要 clone 同一個 commit**，開跑前記下 `git rev-parse HEAD`。

## 尚未決定、需要在跑之前定案

- **用哪個快照當共同起點**：`post-6.6-16h26` 或 `ovs-complete`。
  ⚠️ **今晚 A 段跑完的那個狀態沒有存快照**（我的疏漏），所以兩臂的起點會與 23:00 那輪不完全相同。
  **這是一個已知的不對等，要寫進結果**。
- **每臂的時間上限**：v10 第一次 10 分鐘就死、第二次超過 10 分鐘仍在跑
  ⇒ **上限給寬（≥3 小時），而 timeout 到期只代表「我停止等待」，不代表原因。**

---

## 結果（跑完之後 append 在這裡，不要改上面）

_（尚未執行）_

---

## 補註 2026-08-28 09:5x（**在兩臂都還沒有結果之前寫**，append-only）

### 起點的決定，以及一個偏離原本兩個候選的理由

原文列的候選是 `post-6.6-16h26` 或 `ovs-complete`。實際採用 **`post-6.6-16h26`**，
理由是**讀者走到 §6.1 時的機器就是那個狀態**，所以從它出發的裁決直接回答
「§6.1 對我們的讀者管不管用」。

但真正決定成敗的不是選哪個快照，是**乾淨度**——這一點由 2026-08-27 深夜那輪證實：
它 `rc=0` 而 bmv2 沒建，log 指名了原因是 `[ -d behavioral-model ]` 命中前一輪的殘留而跳過建置。
**混淆因子 #3 照著寫的樣子發作了。** 所以新增一個共同起點 `ab-base`：

- 建立時斷言 `DIRTY_COUNT=0`（`~/behavioral-model`／`~/p4c`／`~/PI`／`~/tutorials`／
  `~/p4setup.bash`／`~/.local`／`/usr/local/bin/{p4c-bm2-ss,simple_switch,simple_switch_grpc,p4c}`／
  `/usr/local/lib/libprotobuf.a`／`/usr/local/include/bm`／`/usr/local/lib/lib{bm,simpleswitch,pi}*`）
- **每一臂開跑前再驗一次**，防「restore 靜默 no-op」
- p4-guide 在 base 裡就 clone 並釘在 `a2f9f8c5fd64f37d10ea2ce06f8821893a79a841`，
  安裝器 sha256 `8e3e0615ebde5b66cc6bcbce2a2cf6750b046a193096ac2a2a69ca2fec5c74dc`
  ⇒ **混淆因子 #4 消除，不再只是記錄**

⚠️ `~/p4-guide` **刻意不列入** dirty 清單：它是安裝器自己的原始碼，不會造成跳過，
且準備腳本無條件 `rm -rf` 後重 clone。同一次把清單**改嚴**（補上 `/usr/local` 的建置產物），
淨結果比原本嚴。

### 兩臂怎麼分辨，以及每臂如何斷言自己是哪一臂

| 臂 | 啟動 | 預期 |
|---|---|---|
| NOTTY | `setsid nohup bash -c '… < /dev/null'` | `controlling_tty: NO` |
| TTY | `tmux new-session -d`（配 pty） | `controlling_tty: YES` |

用 tmux 而非原文寫的 `ssh -tt`：`-tt` 會把「臂能不能活幾小時」綁在我的連線上，
那是**第二個差異**，不是一個。兩臂都與我的 shell 卸離，只差 controlling terminal。

🔑 **每臂在安裝器啟動前先斷言自己的注入成功**，判準是 `exec 3</dev/tty` 能不能開——
正是 debconf 說它缺的那個東西。**不符就中止該臂**，因為在沒有 tty 的情況下跑「TTY 臂」
會讓實驗靜默退化成同一臂跑兩次，而且不會有任何跡象。

### 🔴 新增第 5 條混淆因子：資源不足會偽裝成實驗結果

**由審查員指出，在結果出來之前寫下。**

`simple_switch_grpc: MISSING` **同時是合法的實驗結果、也是資源不足的簽名**。
本次的驗收判準（產物在不在）**分辨不出這兩者**——這正是「儀器不能長得像自己的發現」。

host 現況：available 4 G、swap 已用 8 G、**兩個** qemu 在跑，而兩臂是**序列**執行的
4–5 小時，鄰居（mainDev 的 kernel＋churn 流量）的負載**會不平均地落在其中一臂**。

**判準（現在就定，不等看到結果）**：

1. **binary 缺席時，必須連同「最後一段建置錯誤」一起記錄**，不可以只記 `MISSING`。
   build log 裡有這個資訊，撈出來即可。
2. **因逾時、被 OOM killer 殺掉、或 qemu 消失而缺席的臂 ＝ 作廢，不是結果。**
   與 #1（網路）、#2（磁碟）同級處理。
3. 每臂記錄牆鐘時間與收工時的 host `available`／`swap`，供事後判斷是否落在不對稱的負載下。

⚠️ **不對稱在牆鐘時間，不在記憶體配額**：VM 是 `-m 6G` 固定配額，guest 看到的記憶體兩臂相同，
所以編譯本身是對稱的；host 真的殺掉 qemu 的話那一臂會整個消失，是**看得見**的失敗。


---

## 臂 1（NOTTY）結果 ＋ 跑臂 2 之前的預測（2026-08-28 09:36 / 09:5x）

### 臂 1：NOTTY ＝ **FAILURE**

| | |
|---|---|
| 注入斷言 | `controlling_tty: NO`、`stdin_is_tty: NO`、`ps tty` 欄位 `'?'` ✅ |
| 牆鐘 | 09:23 → 09:36（**13 分鐘**，與 2026-08-27 23:00 那次的約 10 分鐘同量級） |
| `installer_rc` | 1（僅供參考） |
| **產物** | `simple_switch_grpc` MISSING、`simple_switch` MISSING、`p4c-bm2-ss` MISSING |
| `/usr/local/bin` | 只有 `pi_convert_p4info`、`pi_gen_fe_defines`、`pi_gen_native_json` |
| 混淆因子 #1 網路 | 0 命中 |
| 混淆因子 #2 磁碟 | 51 G 可用 |
| 混淆因子 #3 污染 | skip-because-present **0** 命中 |
| 混淆因子 #5 資源 | dmesg 無 OOM、qemu 仍在、host available 4 G／swap 8.4 G |

### 🔑 失敗的機制已指名，而且**與 tty 無關**

```
+ PATCH_DIR=/home/tester/p4-guide/bin/patches
+ patch -p1
patching file install_deps.sh
Hunk #1 FAILED at 1.
1 out of 1 hunk FAILED -- saving rejects to file install_deps.sh.rej
```

安裝器把 `behavioral-model` clone 在**移動中的 HEAD**（`fdd3b89`，2026-08-24；
`INSTALL_BEHAVIORAL_MODEL_SOURCE_VERSION` 預設為空 ⇒ 不釘），
然後套 p4-guide 自帶的 patch。**behavioral-model 加了 SPDX 授權標頭**，
`install_deps.sh` 開頭從 `#!/bin/bash` + `set -e` 變成中間夾三行授權註解，
patch 的上下文因此對不上。

**獨立乾跑驗證**（`patch -p1 --dry-run`，每個 patch 各自記 rc，對 HEAD `fdd3b89`）：

| patch | 使用者 | rc |
|---|---|---|
| `behavioral-model-support-fedora.patch` | **v10** | **1**（Hunk #1 FAILED at 1） |
| `behavioral-model-support-venv-thrift-0.22.0.patch` | **v10** | **1**（can't find file to patch） |
| `behavioral-model-adjust-ubuntu-packges.patch` | **v8** | **0** |
| `behavioral-model-support-venv-2026-apr.patch` | **v8** | **0**（offset 4 行） |

⇒ **v10 的失敗是 p4-guide 的 patch 對 behavioral-model HEAD 過期**，
**不是 24.04 的性質、不是機器的性質、也不是 tty 的性質**。
它是**時間相依**的：在 behavioral-model 那個 commit 之前跑會成功。

### 🔴 在跑臂 2 之前寫下的預測

> **TTY 臂會在同一個 `patch -p1` 步驟失敗，產物同樣三個全缺，牆鐘同量級（10–20 分鐘）。**
> ⇒ 落在**第 3 列（兩臂都失敗）**。

**依據**：`patch(1)` 不讀 `/dev/tty`，失敗發生在任何 debconf 互動之前的純檔案操作。

⚠️ **這個預測很強，所以更要先寫**。若 TTY 臂**通過**了那一步，
那不是「tty 假說得證」，而是**我對機制的理解有洞**，要當成第 4 列（沒有現成解釋）處理，
**不可以塞進最近的分支**。這正是本檔一開始設第 4 列的理由。

📌 **明確不宣稱**：上表只證明 v8 的兩個 patch **套得上**。
**套得上是必要條件不是充分條件** —— v8 能不能真的裝完，需要它自己的乾淨室實跑，尚未執行。

