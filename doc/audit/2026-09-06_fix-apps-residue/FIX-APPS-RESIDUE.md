# W16 — `ndt apps stop`／`ndt apps orphans` 列出該 app 留在網路上的規則與鎖，不自動刪

分支 `fix/w16-apps-stop-lists-rules`。KNOWN-ISSUES **G-12**。
裁決：Adam 09-05 grill 第五輪，「K-3 `ndt apps stop/orphans` 列出該 app 的規則、不自動刪」。

[Co-developed with claude code -- Adam]

## 1. 缺陷

R6 於 2026-09-05 實測（1/1，OVS）：一支拿了 `graph_lock`、在 s2 裝了一條 `pri=96`
`["OUTPUT:2"]` 規則的 app，被依 pidfile 取得的 pid 指名 `kill -TERM`（**沒有用 `pkill -f`**）
之後，兩樣殘留都還在，而**每一個既有的乾淨度動詞都是綠的**：

```
ndt apps orphans          ok  no untracked app processes        rc 0
ndt status --check                                              rc 0
POST /ndt/acquire_lock graph_lock -> 423 {"held_by_lease": 4, "retry_after_s": 30}
s2 仍然照 pri=96 轉發
```

兩個動詞都沒有壞：它們回答的是**行程**的問題。沒有任何一支工具負責回答另一個問題。

## 2. 歸屬判得到多準（這一節是本單的重點）

**判不準，而且報告每一次都要自己說出來。** 沒有任何可以拿來歸屬的欄位：

| 想拿來歸屬的東西 | 實際狀況 | 出處（親自讀過） |
|---|---|---|
| flow entry 的 `cookie` | 恆 0 | `src/ndt_core/collection/Classifier.cpp:229`：「Many hardware switches export cookie=0 for all rules, so cookie cannot be used as identity」；`p4_proxy/proxy_agent/ryu_flow_stats.py:181` 合成的每一列都寫死 `"cookie": 0`；kernel 的 install 路徑一個字都沒有寫過 cookie（`grep -rn cookie src/ include/` 只有上面那兩處註解） |
| 鎖的 owner | **故意沒有** | `include/ndt_core/lock_management/LockManager.hpp`：lease id「is deliberately not an owner field ... the kernel does not and cannot [know who is calling] without a credential on the wire」（KNOWN-ISSUES B-2②） |
| 鎖的唯讀查詢 | **沒有這種端點** | `grep -o '/ndt/[a-z_]*' src/ndt_core/http/HttpSession.cpp`：只有 `acquire_lock`／`release_lock`／`renew_lock` |

⇒ **唯一的判別依據是時間**，而時間分不開兩個時間窗重疊的呼叫者。

- **窗**：起點＝該 app 的啟動時刻（行程還活著就問 `ps -o etimes=`；行程沒了就用 `app_spawn`
  在 fork 之後立刻寫下的 pidfile 的 mtime）；終點＝現在。
- **每一條規則的到達時刻**＝`now - duration_sec`（交換機自己報的）。
- 落在窗內 ⇒ 列出來，標 **SUSPECTED**。

**它一定會多列**：同一個窗內別的 app 裝的、Ryu 裝的、有人拿 curl 裝的，全都在裡面。
它仍然有價值，因為它**排除掉 fabric 自己的 baseline**（`ndt up` 裝的那幾千條），
而 baseline 才是把那一條 `pri=96` 淹掉的東西。

🔴 **量不到的不算沒有。** 沒有 `duration_sec`（或型別不對、是 bool、是負數）的規則
**不會被丟掉**，而是以 `age=UNKNOWN` 單獨列出並註明「它既不能被放進窗內、也不能被放到窗外」。
把它悄悄丟掉會產生一份比較短、比較乾淨、而且已經停止觀察的報告——那正是 G-12 本身的失效形狀。

**沒有窗的情況**（pidfile 沒了、行程也沒了）：報告直說「沒有窗，任何規則都無法對它定年」，
並明寫 **NOT 'this app left nothing'**。

## 3. 做了什麼

`tools/test_workflow/ndt`，新增（都在 `apps_orphans` 之前）：

- `app_started_at <name>` — 兩個來源，精度高的優先，**兩個都不是發明的**。
- `http_get_flow_entries` — `GET /ndt/get_switch_openflow_table_entries`。
- `lock_probe <type>` — `held <lease> <retry>` / `free` / `unknown <why>`。
- `json_field <json> <key>` — 壞 JSON 回 `?`，不猜。
- `residue_rule_lines <started> <now>` — 內嵌 python，純函式 `suspect_rules` 夾在
  `# --- BEGIN residue_rules ... # --- END residue_rules ---` 之間供測試逐字抽出。
- `residue_report <app>...` — 整份報告。**一次 kernel 抓取、一次鎖探測**（`apps stop all`
  否則要 POST 十五次 acquire）。

接線兩處，各一行：`cmd_apps` 的 `stop`（在迴圈之後、三個 verdict return 之前
⇒ **包含「什麼都沒得停」那一支**，那正是 G-12 被量到的那一支）與 `orphans`。

### 鎖是怎麼問的，以及它的副作用

**沒有唯讀端點**（見 §2），所以只能用 acquire 問。用 `ttl: 0`——API 手冊 §27 逐字寫
「`ttl: 0` and negative values are accepted, and both mean "already expired," not "unlimited."」
⇒ 它在一把**空著的**鎖上做的 acquire **排除不了任何人**（下一個 acquire 立刻成功）。
這是這顆 kernel 提供的最小侵入探測，但它**仍然是一個 POST**，所以輸出裡它被寫成「探測」而不是「讀數」。

**它唯一的副作用**：對一把持有者讓 TTL 過期卻沒 release 的鎖，這次探測會把那個死 lease 收回，
於是**下一個**合法的 acquire 看到的 `reclaimed_expired_lease` 會是 `false` 而不是 `true`。
過期的 lease 本來就已經對任何人開放；損失的是一條麵包屑，而且只在持有者已經走掉的情況下損失。

### 沒有動的

- **`apps orphans` 的 rc 沒有改。** 它回答的是行程的問題，`arm_up.sh` 與其他呼叫者就是這樣讀它的；
  悄悄重新定義它會在修不到東西的同時弄壞它們。殘留報告印在它**旁邊**。（見 §7。）
- **什麼都沒刪。** 鎖會自癒（TTL 到期、接管者拿到 `reclaimed_expired_lease`）；
  規則不會（**沒有 TTL、沒有 owner、沒有任何清理路徑**）。報告把手動刪除的指令交給操作者。

## 4. 兩個順手抓到的實作缺陷（都是閘門抓的，都留成 mutation）

1. **`python3 - <<'PY'` 把腳本本身放在 stdin**，所以 `json.load(sys.stdin)` 讀到的是自己原始碼的尾巴，
   整張流表被判為 unreadable——**一份看起來乾乾淨淨的「沒有殘留」報告**。改成 `3<&0` 先把
   呼叫者的管線複製到 fd 3。留成 **M12**。
2. **`set -- $lock` 會改寫函式自己的位置參數**，而那正是要報告的 app 清單：第一把 HELD 的鎖
   把 `energy` 換成了 `held 4 30`，後面每一個 app 都被報成「沒有窗」。
   `tests/shell/test_apps_residue.sh` 5G 在 2026-09-06 抓到，改用 `read -r _ lease retry`。留成 **M13**。

## 5. 給 KNOWN-ISSUES G-12 的補丁（**本分支沒有套，見 §6**）

把「狀態」那一行改成下面這樣，**「規則不會自癒」那一段整段保留**：

```markdown
- **狀態**：**已修（分支 `fix/w16-apps-stop-lists-rules`，未併）。** 2026-09-05 夜巡 R6 實測（1/1），
  2026-09-06 登記。Adam 2026-09-05 grill 第五輪裁定：**`ndt apps stop`／`ndt apps orphans` 要把該 app
  裝的規則列出來，但不自動刪**——工單 **W16**。
  2026-09-06 W16 已實作：`ndt apps stop`／`ndt apps orphans` 收尾時印出該 app 時間窗內新增的規則
  （標 **SUSPECTED**）與三把鎖的持有狀態（含 `held_by_lease`），**一條都不刪**。
  🔴 **歸屬只到「時間窗」這個精度**：flow entry 的 cookie 恆 0（`Classifier.cpp:229`）、
  鎖的 lease id 故意不是 owner 欄位（`LockManager.hpp`、B-2②），所以窗內別人裝的規則也會被列進去；
  沒有 `duration_sec` 的規則以 `age=UNKNOWN` 列出而**不是**被丟掉。
  🔴 **`ndt apps orphans` 的 exit code 沒有改**——它仍然只回答行程的問題，殘留印在它旁邊。
  🔴 **鎖是用 `ttl: 0` 的 acquire 探測出來的**（kernel 沒有唯讀的鎖查詢端點）。
```

## 6. 為什麼本分支沒有動 `doc/KNOWN-ISSUES.md`

G-12 是手冊員在 `1536ff17`（trunk）登錄的，而本分支的 base 是 `2285c63c`，**看不到那一條**
（`git merge-base --is-ancestor 1536ff17 HEAD` → 不是祖先；`grep -c G-12 doc/KNOWN-ISSUES.md` → **0**）。
在這裡把整條 G-12 寫進來，合併時會變成**兩條 G-12**；而只寫「狀態」那兩行則沒有錨點可以落。
協調員明講**不要 rebase**，所以補丁文字放在 §5，等這條分支與 `1536ff17` 相遇時再套一次。

## 7. 跑過 vs 讀過未執行

**跑過（本機，2026-09-06 凌晨，離線、沒有碰實驗室）**：
`tests/shell/test_apps_residue.sh` 41 checks 0 failed；
`tests/python/test_app_residue_rules.py` 22 tests OK；
`tests/shell/mutate_apps_stop_lists_rules.sh` **13 變異、0 存活**、baseline byte-identical；
`check_gate_anchors.py HEAD` 全格 ok；既有 11 支 ndt／stack 測試全綠。

**讀過未執行**：G-12 條目本身（`git show 1536ff17:doc/KNOWN-ISSUES.md`）；R6 的 console-only 三行
（手冊員已標 🟠「寫進驗收條件前要重跑存檔」——本單沒有把它們當驗收條件，只當缺陷描述）；
API 手冊 §5／§10／§27；`LockManager.hpp`、`Classifier.cpp`、`ryu_flow_stats.py`、`HttpSession.cpp` 的端點表。

**沒有跑過的（需 live 驗）**：真的 `ndt apps stop`／`ndt apps orphans` 對活 kernel 的輸出；
`lock_probe` 對真 kernel 的 423／200；`duration_sec` 在 **P4 平面**的保真度
（`ryu_flow_stats.py` 是合成的，本單沒有量它）；G-12 自己宣告沒測的
「`ndt down` 會不會清掉這些規則、`ndt up` 會不會繼承」。
