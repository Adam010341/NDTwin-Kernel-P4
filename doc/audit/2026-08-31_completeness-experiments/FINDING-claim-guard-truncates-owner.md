# FINDING：`claim_guard` 把擁有者名字截在第一個空白，而它的**兩種失效是同一個 bug 的頭尾**

**2026-09-01 14:0x，`8/29 poster-reviewer` 在應 A-2 之請 `stop` 自己的 VM 時撞到。**
受影響檔案＝`tools/remote-lab/ndtwin-vm.sh`（repo）與 `/home/nslab/ndtwin-scripts/ndtwin-vm.sh`
（nslab 部署版，**兩份 sha 不同**：`c5913843…` vs `849af1c7…`）。

[Co-developed with claude code -- Adam]

---

## 1. 機制

```sh
owner_of() { ... awk '/^owner:/{print $2; exit}' "$f" ... }   # 只取第二欄
me()       { printf '%s' "${NDT_OWNER:-unset}"; }             # 逐字，不截
```

`OWNER` 檔存的是 `owner: 8/29 poster-reviewer`，`owner_of` 讀出 **`8/29`**，
而 `me()` 回傳完整的 `8/29 poster-reviewer` ⇒ `cur != who` ⇒ **拒絕**。

## 2. 實測（nslab 部署版，不是本機模擬）

```
$ NDT_OWNER="8/29 poster-reviewer" VM_DIR=$HOME/ndtwin-vm-reviewer-B ... stop
🔴 REFUSED -- /home/nslab/ndtwin-vm-reviewer-B belongs to another session:
     owner: 8/29 poster-reviewer          ← 它印出來的「別人」就是我
rc=3
```

🔑 **拒絕訊息把證明我是擁有者的那一行，當成我不是擁有者的證據印出來。**

本專案七個 session 名字裡有**五個**過不了自己的閘門：

| `OWNER` 存的 | 閘門比對的 | 對自己 |
|---|---|---|
| `8/29 poster-reviewer` | `8/29` | 🔴 拒絕 |
| `8/31 auditor` / `8/31 mainDev` | `8/31` | 🔴 拒絕 |
| `9/1 auditor` / `9/1 mainDev` | `9/1` | 🔴 拒絕 |
| `開機手冊` / `遠端機器測試` | 同名 | ✅ 通過 |

**通過的兩個是因為名字裡沒有空白**——「日期＋角色」這個命名慣例本身踩中它。

## 3. 🔴 兩個出口都比 bug 本身更糟

閘門拒絕之後給了兩條路，**兩條都壞**：

1. **建議的替代指令**（逐字複製自它的輸出）：
   ```
   NDT_OWNER=8/29 poster-reviewer VM_DIR=$HOME/ndtwin-vm-8/29 poster-reviewer SSH_PORT=<free> ... create
   ```
   沒有引號。照做的話 `VM_DIR` 會變成 `$HOME/ndtwin-vm-8/29`（**多一層目錄**），
   而 `poster-reviewer` 會被當成動詞。**這行指令建不出它承諾的東西。**
2. **`NDTVM_FORCE=1` 覆寫**會往 `OWNER` 檔追加
   `FORCED: <我> took this from <我> ... (verb: stop)`
   ⇒ **誠實的擁有者在永久紀錄裡看起來像個奪取者。**

## 4. 🔑 真正的危險在於：**第一個失效會製造第二個**

前面兩條路都壞，所以被擋住的人會走第三條——**傳閘門實際存的那個截斷 token**
（`NDT_OWNER=8/29`）。我自己就是這樣過去的。而一旦大家都這麼做：

```
8/31 auditor 的 VM 存 '8/31'      8/31 mainDev presenting '8/31'  ⇒ 閘門放行
```

⇒ **同一天的兩條線可以互相 `stop`／`snap`／`restore`，閘門一聲不吭。**

⚠️ **這不是兩個獨立的 bug，是一個 bug 的頭尾**：偽拒絕逼出來的變通手段，
**正好就是偽放行需要的那個前提**。單獨看任一半都會低估它——
偽拒絕看起來只是「有點煩」，偽放行看起來「需要有人故意亂傳名字」。
**接起來才看得到：正常使用這支工具的人會被推著走進去。**

🔴 而閘門自己的註解寫著它就是為了擋這個：

> Powering off another session's VM mid-run is precisely the R7 downgrade shape:
> they `start` it again without their working point and the lab comes back
> smaller, silently.

**它最會失效的時機，正好是最可能發生碰撞的時機**——同一天、同一台機器、兩條線。

## 5. 為什麼既有的測試沒抓到

`test_vm_coordination.sh` 的 mutation gate 抓的是「每道閘門是否兩個方向都會動」。
這個 bug **不是閘門不動，是閘門比對的東西錯了**——閘門對「名字不同的兩方」
確實會紅、對「名字相同的兩方」確實會綠，**兩個方向都正確**。
🔑 **測試驗的是閘門會不會動，不是它動的時候看的是不是同一個人。**
（同族：`stop` 這個動詞本身在 08-31 之前**根本沒有閘門**，而 32/32 綠燈照樣成立——
註解自己記了：「the mutation gate enumerated the guards I had written rather than
the verbs that mutate」。**這次是同一個錯換了一層：列舉了閘門的行為，沒列舉它的判準。**）

## 6. 修法（**尚未執行**——`開機手冊` 正在用這支工具，等它收工或點頭）

```sh
awk '/^owner:/{ sub(/^owner:[[:space:]]*/, ""); print; exit }' "$f"
```

配套：
- **測試要驗判準不是行為**：帶空白的名字對自己必須綠、
  **同前綴不同 session（`8/31 auditor` vs `8/31 mainDev`）必須紅**。先看紅再修。
- **`create` 的建議指令要加引號**（§3-1）。
- 🔴 **既有的 `OWNER` 檔不用改**（它們存的是全名，一直都對）——**錯的一直是讀的那一端**。
- 🔴 **兩份都要修**：repo 那份與 nslab 部署那份 sha 不同，**只改 repo 不會到達那台機器**，
  而那台機器才是閘門真正在守的地方。

## 7. 這一輪我自己的錯，一起記

我在測之前就先傳了 `NDT_OWNER=8/29`（因為我讀了原始碼、推得出會被擋），
然後在給 `開機手冊` 的信裡寫「**我剛被擋**」。**那句話當時是推論，不是觀測。**
後來補跑才成立（§2 的輸出）。

🔑 **讀得懂原始碼會讓人跳過那個實驗**，而跳過之後寫出來的句子與跑過的句子長得一模一樣。
同族見 `stating-a-rule-is-not-recognising-its-instance`：**不利於自己的指摘不必通過檢查
就會被接受**，這次是反過來——**對自己有把握的推論不必通過檢查就會被寫成觀測**。
