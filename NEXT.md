# NEXT：`ndt:638` 掃除失敗被丟棄（G-9 的副產品，**今晚刻意不做**）

2026-09-03 02:30 寫。[Co-developed with claude code -- Adam]
auditor（`ndtwin-kernel-c4`）2026-09-03 裁決：寫成 NEXT，今晚不改。

**這個 commit 可以單獨 drop，不影響 G-9 的修法。**

---

## 為什麼是 G-9 的副產品

G-9 之前，`ndtwin-lab cleanup` **結構上不可能失敗**——每個 kill 都 `|| true`，
最後一行 `echo "cleanup done"` 無條件印。所以「呼叫端丟棄 rc」在當時**沒有後果**：
沒有東西可丟。

G-9 之後它會回 rc 1（有東西扛過 TERM＋KILL）。
**一個從不失敗的東西開始會失敗，它的呼叫端就是新的風險面。**

## 缺陷

`tools/test_workflow/ndt:630-639`（`up_p4`）：

```bash
if [[ "$n" -gt 0 ]] && ! topo_session; then
    # Orphans outlive `mn -c` and hold :3005x, which makes the next fabric fail to
    # bind with an error that reads like a P4 problem.
    warn "$n orphan bmv2 process(es) with no topo session; sweeping first"
    sudo -n "$LAB" cleanup >/dev/null 2>&1
fi
```

rc **完全丟棄**（`>/dev/null 2>&1` 之後沒有任何判斷），然後直接往下建 fabric。

因果鏈，全部寫在它自己的註解裡：

1. 有 orphan bmv2、沒有 topo session ⇒ 先掃除；
2. G-9 之後，掃不乾淨會回 **rc 1**——而這裡看不到；
3. 於是**就在那個 orphan 上面建 fabric**；
4. orphan 佔住 `:3005x` ⇒ 下一個 fabric 綁不上；
5. 而綁不上的錯誤**看起來像 P4 的問題**。

🔑 **這個缺陷會把自己偽裝成別人。** 那是它值得修的理由，也是它難被發現的理由——
去 debug 的人會去查 P4，而根因是一個被丟棄的退出碼。

第二處，同族但輕：`tools/test_workflow/ndt:1083`（`cmd_down`）

```bash
sudo -n "$LAB" cleanup 2>&1 | sed 's/^/      /'
```

`ndt` 是 `set -uo pipefail`（`:51`），所以管線的 rc **會**變成 cleanup 的非零；
但 `cmd_down` 沒有讀它，下一行就繼續。行為上等同丟棄，只是路徑不同。

## 驗收條件

### `up_p4`（`ndt:638`）— auditor 原文

**掃不乾淨時 `up_p4` 必須拒絕並指名是哪些 orphan 佔住哪些 port，不能繼續建。**

### `cmd_down`（`ndt:1083`）— auditor 2026-09-03 裁決，三條

1. **絕不中途放棄。** teardown 就是盡力而為——一個 component 收不掉，剩下的還是要全部收。
   中途 `die` 會把「一樣東西沒關掉」放大成「一半的東西沒關掉」。
2. **退出碼要說話，而且要跟 `ndt apps stop` 同一套語意**（那支已在 G-6 改成三態，
   **兩支不一致比兩支都錯更糟**）：
   **0 ＝ 收乾淨了；1 ＝ 收過了但有東西活下來；2 ＝ 本來就沒有東西要收。**
3. 🔴 **退出碼本身不構成可行動的資訊——必須指名活下來的是什麼。**
   一個腳本看到 rc 1 不知道它能不能繼續；看到 `residue: bmv2 pid 12345 holding :30051` 就知道。
   stderr 要印出殘留的**行程與它佔住的 port**，因為**下一個 `ndt up` 會撞上的正是那個 port**。

🔴 **這三條裡有兩條已經成立了——動手前先讀這一節，否則會重做已有的東西、並漏掉真正缺的那個。**
（我在寫這份 NEXT 時去讀了 `cmd_down`／`cmd_clean` 的現況，發現與裁決的前提不完全相符。）

| 裁決 | 現況 | 還缺什麼 |
|---|---|---|
| ① 絕不中途放棄 | **已成立**。`cmd_down` 從頭跑到尾，沒有中途 `die`；每一段都是 `\|\| true` 或忽略 rc。 | 無 |
| ② 退出碼要說話 | **一半成立**。`cmd_down` 的最後一句是 `cmd_clean`，而 `cmd_clean` 的檔頭就寫著「Exits non-zero if anything survived」——所以 **`ndt down` 現在已經會回非零**。 | **第三態**。目前只有 0／1，「本來就沒東西要收」與「收乾淨了」都是 0，與 G-6 之後的 `ndt apps stop`（0／2／1）不一致。 |
| ③ 指名活下來的是什麼 | **一半成立**。`cmd_clean` 已經指名 topo session、switch manifest，以及 **`:8000`／`:8080`／`:8081`**（還附「the next up would measure it」）。 | 🔴 **bmv2 只有數量沒有身分**：`err "bmv2 switches: $n still running"`，沒有 pid、沒有 port。而 **`:3005x` 在整個 `ndt` 裡只出現一次，就是 `:635` 那行註解**——`cmd_clean` 不查它，`deep_sweep` 也只處理 8000／8080／8081。 |

🔑 **所以這條線最尖的一點是：`ndt:638` 那條因果鏈所轉的那個 port，正好是唯一沒有任何地方回報的 port。**
註解知道 orphan 會佔住 `:3005x`，而 teardown 的驗收、深度清除、殘留報告三者都不看它。
修法要補的是這個，不是「讓 `ndt down` 回非零」——那個已經有了。

### 變異閘門要能證明三個方向

- 有殘留 → 紅
- 沒殘留 → 綠
- **本來就沒東西可收 → 不能被算成失敗**（這一態現在不存在，所以它同時是新功能與新測試）

### 🔴 這是行為變更，合併前先盤點呼叫端

`ndt down` 開始回 rc 2（而不是 0）會讓寫 `ndt down && ...` 的腳本看到非零。
今晚的 audit／測試輪腳本多數是 `|| true`，**不會壞**——但它們會**明示地忽略一個真的失敗**，
而那正是我們要它們停止做的事。盤點清單可以從本分支 `RATIONALE.md` 附錄二起手。

## FINDING（獨立於上面的修法項）：殘留報告涵蓋的是「容易指名的 port」，不是「會擋住下一次啟動的 port」

auditor 2026-09-03 要求把它從修法項升格成一條 finding。**它的形狀比它的實例重要，因為同型的還有第二個。**

### 實例一：`:3005x`（bmv2 gRPC）

`:3005x` 在整個 `tools/test_workflow/ndt` 裡**只出現一次**——`:635` 的一行註解：

```
# Orphans outlive `mn -c` and hold :3005x, which makes the next fabric fail to
# bind with an error that reads like a P4 problem.
```

`cmd_clean`（`:1099-1123`）不查它。`deep_sweep`（`:1112`）也不查——它只處理 8000／8080／8081。
所以 **`ndt:638` 那條因果鏈所轉的那個 port，正好是唯一沒有任何地方回報的 port。**

### 實例二：`:6653`／`:6633`（Ryu OpenFlow）— 同一個形狀，而且**比實例一凶**

`ndt` 裡**一次都沒有出現**。但它是 OVS 路徑的啟動相依：

- `tools/test_workflow/ndtwin-lab:337,348`：「Ryu must already be listening on 6653」；
- `tools/test_workflow/ovs_4host_topo.py:31-33`：port 明寫而不是讓 Mininet 探測，因為
  「with no port, RemoteController tries 6653 then 6633 and falls back to 6653 when neither
  answers, **which silently masks a controller that is** [不在那裡的]」；
- `tools/test_workflow/stack.sh:676-684` 記著同一件事。

**為什麼比實例一凶**：`:8000` 上殘存的 kernel 會被報成 “up”，而 `stack.sh:507-531` 就是為那件事
寫的防護——**那條路已經有人守著**。`:6653` 沒有，而且它的失敗形狀更糟：
`RemoteController` 的 fallback 順序把「**controller 不在**」變成「**controller 在，只是不是你的**」。
下一輪 OVS 會安靜地接上一個它沒有啟動、也沒有記錄配置的 controller，
而每一個結構檢查都會說 topology 是通的。

### 實例四：`:6343`（sFlow collector）— **唯一一個當場咬人的**

**我親自查證的部分**：`grep -c '6343'` 在 `tools/test_workflow/ndt` 與
`tools/test_workflow/stack.sh` **兩者皆 0**（2026-09-03），而 `cmd_clean` 的清單仍是
`for p in 8000 8080 8081`。

**auditor 轉述、我未讀原文的部分**：第三輪與安裝手冊那條線同一夜實測到
**一個佔著 `:6343` 的 kernel 擋掉合法操作，而 `ndt down` 的五條斷言全綠**。

⇒ 前三個實例是「會咬人但當晚沒咬」，**這個是當場咬了**——而且它的形狀最完整：
殘留擋掉了操作，而 teardown 的每一條斷言都說乾淨。**「五條全綠」正是判準④**
（鑑別力只在被檢查的那一組上成立）**的又一個實例**。

### 實例三：`:9000`（sim app）— **已經在 repo 裡，不必等它出現**

`ndt` 與 `stack.sh` 裡各出現 **0 次**（`grep -c '9000'` 兩者皆 0，2026-09-03 親自查）。
但今晚 live round 的檢查表把它當成 app 是否起來的判準之一：

- `doc/audit/2026-09-02_live-round/CHECKPOINT.md:54`：
  「`ndt apps sim` / `energy` … tmux session + **`:9000` listener** + app pane output asserted per app」
- 同檔 `:113`：T-10 儀器 `LISTENER-OWNER-HIDDEN` 在
  「`:9000` HAS a listener whose owner is not visible to this uid」上**實跑觸發**過。

⇒ **測試輪的 harness 知道 `:9000`，產品自己的 teardown 檢查不知道。**
這同時是判準①最乾淨的例子：知識存在，只是不在該保護它的那段碼裡。

🔑 **所以「第三個實例出現時」不是未來式——第三個已經在了。**

### 形狀

1. **殘留報告涵蓋的是「容易指名的 port」，不是「會擋住下一次啟動的 port」。**
   8000／8080／8081 是這個 stack 自己 listen 的三個、`port_open` 現成、`wait_for_port`
   已經在用——它們是**最早被注意到的那一組**。3005x 是 bmv2 動態配的、6653 是別的 component 的、
   9000 是 app 的，三個都比較難指名，於是三個都沒進去。
   🔑 **做得最完整的是最早被注意到的那一組，不是最重要的那一組。**

2. **「哪個 port 會擋住下一次啟動」這件知識只存在於註解與別人的 harness 裡。**
   `ndt:635`、`ndtwin-lab:337/348`、`ovs_4host_topo.py:31`、`stack.sh:676` ——
   四個地方都寫了，四個都是註解。**註解不會被執行，所以它擋不住任何事。**
   `:9000` 更遠：它只活在測試輪的檢查表裡。

3. **`cmd_clean` 內部的不對稱本身就是線索。** 同一個函式裡：
   - bmv2：`err "bmv2 switches: $n still running"` —— **只有數量，沒有身分**；
   - port：`err ":$p still listening -- the next up would measure it"` —— **指名到 port，還附上後果**。

   一個函式裡兩種完整度，通常代表其中一種是後來補的、另一種沒跟上。

4. 🔴 **「這個檢查有鑑別力」的證據，可能只在被檢查的那一組上成立。**
   `CHECKPOINT.md:52`（已提交，我親自讀）記著 `ndt clean` 的鑑別力驗證：
   「standalone assertion run three times: `CLEAN_RC=1` while **`:8081`** was held,
   `CLEAN_RC=0` twice after. **It discriminates**」——
   而 `:8081` 正是清單裡的三個之一。**對 3005x／6653／9000，`CLEAN_RC` 的鑑別力是零**，
   但那句「It discriminates」讀起來是對整個 `ndt clean` 說的。

## 修法：一張宣告式的表，不是各補一次

auditor 2026-09-03 裁決：**不要當成兩個（現在是三個）port 各補一次 if。**
把「哪些 port 會擋住下一次啟動」**從註解移進碼裡，成為一張宣告式的表**，
`cmd_clean` 與各個 up 守衛**讀同一張表**。每一列三個欄位：

| port（或範圍） | 屬於誰 | 佔住它的後果 |
|---|---|---|
| `:3005x` | bmv2 switch（動態配） | 下一個 fabric 綁不上，**錯誤看起來像 P4 的問題** |
| `:6653`／`:6633` | Ryu（OVS 路徑） | 下一輪 OVS **安靜地接上一個不是你的 controller** |
| `:9000` | sim app | app 是否真的起來的判準；殘存 listener 讓下一次 `ndt apps sim` 的驗活失真 |
| `:6343` | sFlow collector（kernel 側） | **當晚實測咬人**：一個佔著它的 kernel 擋掉合法操作，而 `ndt down` 五條斷言全綠 |
| `:8000`／`:8080`／`:8081` | kernel／proxy／Ryu REST | （既有）the next up would measure it |

為什麼是表不是三個 if：

- **第四個實例出現時，修法是加一列，不是再想一次**——而三個實例已經證明會有第四個。
- 殘留報告要印的「指名＋後果」直接從那一列來，不必每個 case 各寫一次文案。
- 那四處註解（`ndt:635`、`ndtwin-lab:337/348`、`ovs_4host_topo.py:31`、`stack.sh:676`）
  改成**指向那張表**——**過期的註解跟著修法一起死**。

🔴 **`:6653` 不是一個獨立決定，它是那張表的第二列。**
（我原本標成「另一個決定、不要順手做」——那在**只有一個實例**時是對的；
有了第二、第三個實例，分開做會讓那張表永遠不存在，然後下一個實例又是一次臨時判斷。
auditor 2026-09-03 改判，理由成立。）

另外仍要補**第三態**（本來就沒東西要收 → rc 2），它同時是新功能與新測試。

### 一個當晚的候選實例（⚠️ auditor 轉述，**我未親自查證**）

auditor 說測試輪的 finding 1 記著：一次失敗的 `ndt up ovs4` 留下 Ryu（含 `:6653`），
接著 `ndt down`（`CLEAN_RC=0`）才重試——而 `cmd_clean` 不查 `:6653`，
所以那個 0 對「Ryu 死了沒」**零鑑別力**。

**可信度分級**：那條 finding 的原文我**沒有讀過**（`doc/audit/2026-09-02_live-round/` 在
本分支 base `6283ff5e` 上沒有那個檔）。
**我親自查證的只有推論的後半**：`cmd_clean` 確實不查 `:6653`（`ndt` 裡 6653 出現 0 次），
所以 `CLEAN_RC=0` 對它零鑑別力——這一點是碼的事實，與那次 round 無關。
auditor 已要求該 session 用現有證據判定那個 Ryu 是否活到重試之後；**結果出來再補進這裡**。

## 為什麼今晚不能改

1. **測試輪整晚都在跑 `ndt up`。** 改它等於在別人腳下換地板。
2. **讓 `ndt up` 開始拒絕，正是 Adam 要親自看的那種行為變更**——
   一個原本會安靜繼續的路徑改成擋下來，會直接影響每一輪的起跑。

## 給接手的人

- G-9 分支的 `RATIONALE.md` 附錄二有完整的呼叫端盤點（產品碼兩處、audit 腳本六處以上，
  後者全是 `setsid $LAB cleanup ... || true`，明示忽略）。
- 🔴 **不要順手修 `mn -c` 那一半。** KNOWN-ISSUES §G
  「`ndtwin-lab cleanup` 可能殺掉呼叫它的 shell」講的是 `mn -c` **內部**的 `pkill -9 -f`
  （KNOWN-ISSUES §G 同一則），G-9 **沒有碰它** ⇒ 那條沒有解除，
  **所有腳本的 `setsid` 紀律仍然必要**。兩件事長得像，容易被讀成一起修好了。
- 測試要能分辨「cleanup 回 0」與「cleanup 回 1」兩條路徑。
  `ndt` 可以被 `source`（檔尾有 sourced-guard），把 `sudo` 換成 shell function 就能驅動 `up_p4`。
  🔴 **假 `sudo` 的呼叫紀錄要寫檔案不要寫變數**——`ndt` 的函式常在 `$( )` 裡跑，
  子 shell 的賦值父層看不到，斷言會變成空的（G-6 實測踩過）。


---
---

<!-- merged 2026-09-03: the G-7 branch wrote its own NEXT.md; both kept, G-9 first -->

# 交接：`fix/ndt-sudo-surface`（第四件，未開始）

2026-09-03 01:30 寫。[Co-developed with claude code -- Adam]

**分支從這一支（`fix/g7-ndtwin-lab-config`）的頭長出去**——它要動的兩個檔，其中
`tools/test_workflow/ndtwin-lab` 我在 G-7 已經改過。合併順序 auditor 已裁：
**G-9 → G-7 → 這一支**。

**為什麼今晚沒做**：三支已交付的分支各自帶著會紅的變異閘門，這一支要動的是**提權面**，
而且要證明兩個方向（沒權限紅／有權限綠）。在做了四小時之後趕一支安全相關的分支，
換來的是一個「大概有測」的閘門——auditor 的裁決是品質壓過涵蓋率，所以停在這裡。

## 出處

- 來源是手冊線 `ndtwin-kernel-d8` 的 desk check；auditor（`ndtwin-kernel-c4`）轉述給我。
  **要逐行原文直接找 `d8`，不用經過 auditor**（auditor 2026-09-03 明講）。
- 下面的行號與引文是**我自己在 base `6283ff5e` 上讀過**的，不是轉述。

## 病灶一：`ovs_bridge_count` 的吞噬鏈

`tools/test_workflow/ndt:1177`：

```bash
ovs_bridge_count() { sudo -n ovs-vsctl list-br 2>/dev/null | grep -c . || true; }
```

sudo 被拒 → stderr 被 `2>/dev/null` 丟掉 → `grep -c` 對空輸入得 `0` → `|| true` 吃掉非零 rc
⇒ **回 0，與「真的沒有橋」無法區分**。

消費者在 `ndt:647-648`（`up_p4` 的守衛）：

```bash
if topo_session && [[ "$(ovs_bridge_count)" -gt 0 ]]; then
    err "an OVS fabric is running ($(ovs_bridge_count) bridges) under the topo session."
```

⇒ 在沒有 `ovs-vsctl` NOPASSWD 規則的機器上，**守衛永不觸發，`ndt up` 會靜靜拆掉別人正在跑的
OVS fabric**。碼裡的註解說這個行為已經修掉了；在沒有額外規則的機器上它原樣復活。

## 病灶二：`dataplane_ok` 把「沒權限問」翻譯成一句關於資料平面的斷言

`ndt:1203-1208`（檔頭 `:1192` 自己寫著 `0 forwards, 1 does not, 2 could not be tested`）：

```bash
dataplane_ok() {
    local pid; pid="$(host_pid "$1")" || return 2
    [[ -n "$pid" ]] || return 2
    sudo -n mnexec -a "$pid" ping -c 2 -W 2 -q "$2" >/dev/null 2>&1 || return 1
    return 0
}
```

sudo 被拒 → `|| return 1` ⇒ 走「不通」那條，於是 `verify_dataplane`（`:1211-1223`）印出：

```
data plane: h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding
```

**這不是誤報，是把「沒權限問」翻譯成一句關於資料平面的具體斷言。**
誤報會被懷疑；具體的錯誤訊息會被相信，然後有人去 debug 一個不存在的轉發問題。

`ndt:1201` 的註解本身就把假設寫死了：
「mnexec is the form **this machine's** sudoers allows without a password」。

## 修法方向（auditor 已裁，不要重新討論）

**走 `ndtwin-lab`（已經是 root，不必再 sudo，也不擴大提權面），不要擴 sudoers。**
擴 sudoers 是每台機器都要重做一次的修法，且把「使用者忘了設」變成永久的失敗模式。

會動兩個檔：`ndtwin-lab` 加子命令（`ovs-br-count`、`host-ping` 之類）、`ndt` 改呼叫點。

## 驗收條件（auditor 原文，寫進測試）

- 沒有權限時 `dataplane_ok` **必須回 2，不准回 1**。**這是這條案的核心，不是附帶。**
- `ovs_bridge_count` 在**無法查詢**時必須與**真的是 0 座橋**可區分——
  回 0 然後被當成「沒有 OVS」正是缺陷本身。
- 變異閘要能證明兩個方向：把權限拿掉要紅、權限正常要綠。
  模擬「權限被拒」**不要用真的改 sudoers**，用一個會回非零的假 `sudo` shim 放在 PATH 前面即可。

🔴 **不要改 `/etc/sudoers`、不要 `visudo`、不要動已安裝的 `/usr/local/sbin/ndtwin-lab`。**
全部只在 repo 內的副本做。

## 🔴 要寫進那一支的 RATIONALE 的一句話

這條缺陷**四輪 usertest 都沒抓到，因為 tester VM 給了全域免密碼 sudo**——
**我們為了讓測試跑得動而放寬的條件，正好關掉了被測物最重要的一條失敗路徑。**
測試設計要避免重蹈：不要用「反正我有 root」的環境去驗這條。

## 給接手的人：三支已交付分支裡可以直接抄的東西

- **假 `sudo` shim 的寫法**：`fix/g6-ndt-apps-liveness` 的
  `tests/shell/test_ndt_apps_liveness.sh` 已經有一個——它把 `sudo` 換成 shell function，
  記錄呼叫、可設 rc。🔴 **注意那裡踩到的坑**：所有 `app_*` 都在 `$( )` 裡跑，
  函式內對變數的賦值留在子 shell，父層看不到；**呼叫紀錄要寫檔案不要寫變數**
  （第一版斷言在變數上，那條斷言是空的，怎麼改程式都會過）。
- **變異閘門骨架**：三支的 `mutate_*.sh` 同一個形狀（anchor 唯一性、逐一變異、
  記錄**具名檢查**、只註解的對照組、`cp -p` 快照 + EXIT trap + 結束 `cmp` 對帳）。
  直接複製改 `NDT=` / `SUITE=` / 案例即可。
- **`ndtwin-lab` 已經可以被 `source`**（G-7 與 G-9 各自加了 sourced-guard，
  合併後只會有一份），所以新子命令的邏輯測得到，不必用 root 跑。
  🔴 但 `ndtwin-lab` 帶 `set -euo pipefail`，**source 之後測試要 `set +e`**，
  否則第一個故意觸發的失敗會讓套件中途離開、而且已跑過的每一條仍印成 `ok`，
  看起來像通過只是提早結束（G-7 實測過這個坑）。

## 今晚新定的環境規則（auditor 2026-09-03）

- **不要輸出到共用的 `build/`**，要編就用自己的 `build-<name>/`。
- **不要用套件安裝的執行檔當當機素材**（`bash -c 'kill -ABRT $$'` 會在 Adam 螢幕上彈出
  Ubuntu 當機視窗，已經發生過一次）。
- lab claim 在 auditor 手上到 01:51；不要 `mn -c`、不要拆別人的 fabric。


---
---

<!-- merged 2026-09-03: the G-6 branch wrote its own NEXT.md; appended -->

# NEXT：viz orphan 的修法，**現在有實測輸入了**（G-6 沒有修這個）

2026-09-03 05:10 寫。[Co-developed with claude code -- Adam]
**這個 commit 可以單獨 drop，不影響 G-6 的修法。**

---

## 為什麼在這裡

G-6 的 `RATIONALE.md` 有一節「這支分支**沒有**修什麼」——viz 的 orphan JVM
（`ADDENDUM-01-viz-orphan-contamination.md`：1h54m、111% CPU、875 MB log，
而三個通道全說沒在跑）。當時修法方向指得出來，但**缺一個事實：存活 JVM 的完整 argv**，
所以標成推測、寫明「要 L6 驗過才能當修法依據」。

**L6 的輸入到手了**，在第三輪測試裡：
`doc/audit/2026-09-03_night-rounds/round3-restart-concurrency/14_viz_process_chain.log`（已 commit）。
**下面每一條都是我親自讀那份 log 得到的，不是轉述。**

## 🔴 先更正我自己一個錯誤

我先前從 launcher 的內容推導出**四層**（`launcher.sh → mvnw → maven JVM → app JVM`）。
**實測是三個 process**：

```
[depth 0] pid=1320231  comm=network_traffic  rss=3MB    /bin/bash ./network_traffic_visualizer.sh
[depth 1] pid=1320234  comm=java             rss=214MB  .../java -classpath /home/adam/Network-Traffic-Visualizer/.mvn/wrapper/maven-wrapper.jar ...
[depth 2] pid=1320294  comm=java             rss=318MB  .../java --module-path /home/adam/Network-Traffic-Visualizer/target/classes:...
```

`./mvnw` 是 shell script，它 **exec 進 java**，所以不留下自己的 process。
⇒ **我從腳本文字推導行程結構，而行程結構要用量的。**
這正是我整晚在標的那個錯誤，我自己犯了一次；記在這裡而不是刪掉，因為
**下一個人也會想從 launcher 讀出鏈路長度**。

## 實測到的三個事實

**① 名字式 signature 在結構上找不到存活者。**

| 字串 | launcher (1320231) | maven JVM (1320234) | app JVM (1320294) |
|---|---|---|---|
| `network_traffic_visualizer.sh`（現行 `app_sig viz`） | 1 | **0** | **0** |
| `Network-Traffic-Visualizer`（**目錄名**） | **0** | **2** | **1** |

🔑 **launcher 自己 0 次**這點是關鍵：signature 必須挑一個**存活者才有**的字串。
用 launcher 的檔名，在結構上永遠找不到該找的東西——**因為要找的正是 launcher 死掉之後剩下的。**

**② 缺陷當場重現，rc 是 0。** 同一份 log：

```
  ok  viz stopped (was: running)
STOP_RC=0
  pid 1320231 gone
  SURVIVOR pid 1320234 comm=java rss=214MB
  SURVIVOR pid 1320294 comm=java rss=317MB
```

531 MB 活著，`ndt apps stop viz` 說 `ok`。auditor 回報同一輪的 `ndt apps orphans`
也答「沒有未追蹤的 app process」——**對 viz 而言兩個 witness 的鑑別力都是零**。
（`orphans` 那一句我沒在這份 log 裡讀到，是 auditor 轉述。）

**③ 孤兒已用精確 pid 清掉（SIGTERM 就夠）**——auditor 轉述，我沒讀到那段。

## 修法（兩個要素，都有實測支撐了）

1. **路徑式 signature**：`app_sig viz` 從 `network_traffic_visualizer.sh` 改成
   `Network-Traffic-Visualizer`（或該目錄的絕對路徑）。
   實測命中 2 個存活 JVM、不命中 launcher——**這正是要的方向**。
   ⚠️ 要一併想：目錄名出現在 `-classpath`／`--module-path` 裡，所以
   **任何 argv 提到那個目錄的行程都會命中**（例如一個開著該目錄的編輯器）。
   `pid_is_app`（`ndt:1683-1692`）現行規則是「某個 **argv 元素**等於 sig，或以 `/sig` 結尾」——
   目錄名是**路徑中段**而不是元素或結尾，所以**現行比對規則吃不下它**，要一起改。
   這是設計上的取捨，不是加一個字串就好。
2. **`app_spawn` 用 `setsid`／自己的 process group**，讓 stop 停得掉整棵樹。
   目前它只 TERM 一個 pid（launcher），子孫被 reparent。

## 順帶：一個我在讀那份 log 時發現的獨立缺陷

那份 log 裡有一行**洩到 stderr 的噪音**：

```
tools/test_workflow/ndt: line 1687: /proc/1320231/cmdline: No such file or directory
```

`ndt:1687`：

```bash
mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
```

**`2>/dev/null` 在 `<` 之後**。redirection 由左而右套用，所以開檔失敗的訊息在 stderr
還沒被轉走之前就印出去了——而這個函式的**全部意義就是那個 pid 可能已經不在**。
同族還有 `ndt:1999`、`ndt:2034`（`tr '\0' ' ' < ... 2>/dev/null`）。

**正確寫法**（我在 G-9 的 `ndtwin-lab` 已經這樣修，那裡的註解也記著同一個坑）：

```bash
mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || return 1
```

🔑 **這又是「同一個缺陷在一支潛伏、在另一支可見」**：`ndtwin-lab` 那份是我自己跑測試時看到的，
`ndt` 這份要等到一個行程剛好在掃描中途消失才會冒出來——而它今晚在一份 audit log 裡冒出來了。
**修 `ndt:1687` 不屬於 viz 那支修法，但屬於同一趟。**

## 給接手的人

- G-6 的 `RATIONALE.md` 有完整背景，含 L5／L6 的定義與「這支沒修什麼」。
- 🔴 **energy／sim 不受這個形狀影響**（兩個都是 ELF 執行檔，存活者自己帶 signature），
  但那是**結構論證不是實測**，殘差由 L5 關掉——L5 仍未做。
- 🔴 **不要順手改 `app_sig` 的比對規則而不改測試**：`tests/shell/test_ndt_app_orphans.sh`
  與 `tests/shell/test_ndt_apps_liveness.sh` 都綁著現行的「元素相等或 `/sig` 結尾」語意。
