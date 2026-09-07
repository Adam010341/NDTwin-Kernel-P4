# G-13 — P4 平面沒有時間軸：proxy 在裝入規則時記時間戳，讓 `duration` 有值

分支 `fix/g13-p4-rule-install-time`，基底 **trunk `1a284f75`**。無 C++ 建置、無實驗室、全部離線。
裁決正本 `DECISIONS.md:242`（E-10：「從根本修：開單 G-13，proxy 在 install 時記時間戳給 P4 規則裝入時間」）。
[Co-developed with claude code -- Adam]

## 1. 一句話

bmv2 的 table entry **沒有年齡**——P4Runtime 的 `TableEntry` 有 match、action、priority、
（掛了 direct counter 的話）byte／packet 計數，就是沒有「什麼時候裝的」。所以
`ryu_flow_stats.entry_to_ryu` 只能把 `duration_sec`／`duration_nsec` 寫死 0，
而 kernel 的 `GET /ndt/get_switch_openflow_table_entries` 原封不動把它端出去；
修法是**讓寫的那一方記**：proxy 的六條寫入路徑在**交換機接受之後**蓋時間戳，
`ryu_flow_stats` 相減，**沒有紀錄的規則維持 0/0**（＝`ndt` 已經在讀的 UNKNOWN）。

## 2. 缺陷的實測依據（不是我跑的，逐字轉述）

`DECISIONS.md:211-215`（09-07 01:0x，orchestrator 記）：

> **不可信——恆 0**（P4 4 hosts、trunk `862c4bf8`、`logs/w163-*`）：裝一條 10.0.0.3 路由，
> +12 s 與 +32 s 兩次讀 `get_switch_openflow_table_entries`，該條與**所有**既有條目
> `duration_sec:0, duration_nsec:0`（`packet_count`／`byte_count` 有值）。

⇒ 這一輪**沒有重跑**那個實驗；我拿它當缺陷的既有證據。反向實驗（裝一條路由、
`duration` 應該遞增）由 orchestrator 用本分支的 proxy 做，**本文件不宣稱它跑過**。

## 3. 修法：一個 key，兩邊共用

### 3.1 新模組 `p4_proxy/proxy_agent/rule_install_times.py`

| 元件 | 做什麼 |
|---|---|
| `entry_key(dpid, table, priority, match)` | 一條 entry 的身分。**寫入端與讀取端都呼叫這一個函式。** |
| `normalise_match` / `_spec_key` / `_value_key` | match 正規化：**bytes 一律轉整數**（bmv2 讀回來會把前導 0 位元組剝掉，`b"\x00\x00\x00\x04"` 進去可能 `b"\x04"` 出來——比 raw bytes 會**每一條都對不上**）；欄位排序；未知 match type 保留自己的形狀而不是被丟掉。 |
| `is_dont_care(spec)` | ternary 的 mask 為 0 ＝ 不在這條 entry 裡。**`ryu_flow_stats._match_to_ryu` 改成呼叫它**，所以「什麼叫 don't care」全 repo 只有一份定義。 |
| `RuleInstallTimes.record/forget/clear` | 記／清一條／清全部。時鐘可注入（`monotonic=`、`wall=`）。 |
| `RuleInstallTimes.age_seconds` | 秒數，**沒有紀錄回 `None`**（不是 `0.0`）。 |
| `installed_at_epoch` | 牆鐘時間，**由 monotonic 年齡推導**、不另存一份。存兩個時鐘＝兩個會互相打架的答案。 |
| `action_key(action)` | action 指紋，**只拿來比對相等**，見 §3.3。 |

**key 只包含 dpid／table／priority／match**（單子指定的四項），action 指紋是 value 不是 key。

### 3.2 寫入端：`p4_proxy/proxy_agent/p4_client.py` 六條路徑

（行號對 `71fc9d90` 的 `p4_proxy/proxy_agent/p4_client.py`）

| 方法 | 動作 | 時機 |
|---|---|---|
| `insert_ipv4_route` | `record` | `stub.Write` **回來之後**（`:954`） |
| `modify_ipv4_route` | `record` | 同上（`:1108`） |
| `delete_ipv4_route` | `forget`（`_forget_route`，定義在 `:1004`） | **三條成功路徑都清**（`:1038` 乾淨成功、`:1047` NOT_FOUND、`:1063` UNKNOWN＋讀回來確認不在） |
| `insert_5tuple_rule` | `record` | `:847` |
| `modify_5tuple_rule` | `record` | `:885` |
| `delete_5tuple_rule` | `forget` | `:913` |
| `set_forwarding_pipeline_config` | `clear()` | RPC 回來之後，緊接 `table_generation`（`:355`） |
| `__init__` | 建 `RuleInstallTimes()` | `:107` |

寫入端交給 record 的 match 是**用 `read_table_entries` 的形狀**建的
（`_lpm_match`／`_five_tuple_match`，後者走 `_encode_5tuple_value`，也就是真的送上線的那些 bytes）。
表名與 LPM 的 priority 提成 `IPV4_LPM_TABLE`／`FIVE_TUPLE_TABLE`／`LPM_ENTRY_PRIORITY`
（`:761`／`:762`／`:767`），理由是**兩邊各拼一次字串就是兩個 key**。

🔴 **`insert_ipv4_route` 的 MODIFY 退路不需要另外記**——退路走的是 `modify_ipv4_route`，它自己會記。

### 3.3 🔴 為什麼「內容沒變的覆寫」不重算時間

`install_initial_routes` 是**刻意冪等**的（`insert_ipv4_route` 撞到就退成 MODIFY），
而 link watchdog **每一次 link 狀態轉換都會整批重跑**它（`topology_manager.py:1889`），
LLDP 發現新 link 時也會（`:1494`）。若 MODIFY 一律重算時間戳，
**一條每幾秒抖一次的 link 會讓全 fabric 每幾秒重新變成「剛裝的」**，沒有任何規則會老過上一次抖動
——那等於沒修，而且 orchestrator 的 live 反向實驗（+12 s／+32 s 遞增）也會失敗。

所以 `record` 比對 action 指紋：**寫成跟原本一樣 ⇒ 保留舊時間戳；寫成不一樣 ⇒ 重算。**
語意是「**這條 entry 上一次變成現在這個樣子是什麼時候**」——這正是 W16 要問的問題，
因為一支 app 把 bring-up 路由改道，留下的殘留跟它新增一條規則一樣真實。

⚠️ **與 OpenFlow 的差異，要寫進手冊**：OVS 的 `duration` 是「自 ADD 起算」，MODIFY 不重算。
P4 這一側是「自**上一次內容改變**起算」。兩者在「app 改過這條規則」上會給不同答案，
**L4 differential 若要比 duration 會看到這個差**（目前 `tools/contract_test/spec.py:319` 只驗
`Int(min=0)`，沒有比值，所以本輪不受影響）。

### 3.4 讀取端：`ryu_flow_stats.py` ＋ `api_routes.py`

- `render_flow_stats(dpid, entries, install_times=None)`（`ryu_flow_stats.py:229`）：逐條查
  `age_seconds`，`entry_to_ryu(entry, age_seconds=...)`（`:173`）換成 `(sec, nsec)`（`:191`、`:219`）。
- `_duration_fields`（`:152`）：`None` → `(0, 0)`；負數夾到 0（`duration_sec` 在線上是無號的，
  一個負數會變成 42.9 億秒）。
- `api_routes.get_flow_stats`（`api_routes.py:562-563`）傳 **`client.rule_install_times`**，
  **直接取屬性、不用 `getattr(..., None)`**：finding #71 的形狀就是「production 忘了傳，
  而每個測試都自己注入」，而這裡忘了傳的後果是**永遠 0/0**——跟缺陷本身長得一模一樣。

## 4. proxy 重啟：一致，不是有損（單子 §2 要求先確認的那一項）

查 `fix/a4c-proxy-restart-honesty` 的 `05976e27`（commit message 逐字）：

> Restarting the proxy re-pushes the pipeline to all ten switches, and a VERIFY_AND_COMMIT
> SetForwardingPipelineConfig empties every table. … install_initial_routes then refills the
> bring-up shortest paths.

再查 `main.startup()`（`:267-277`）：**每一台有 `json_path` 的交換機都會被 push**。所以：

- **重啟＝先清空、再由 `insert_ipv4_route` 重灌** ⇒ 重灌的每一條都拿到**真實的**新時間戳，
  **沒有任何規則會帶著錯的年齡活過重啟**。⇒ **一致**，寫進本文件，不需要在手冊開但書。
- 🔴 **例外一種，而它是誠實的**：pipeline push **失敗**的交換機（`broken`，startup 逐台 try/except）
  **不會被清空**，它上一代的規則還在，而新 client 的紀錄是空的 ⇒ 那些規則報 0/0＝「不知道」。
  正確答案，因為新 proxy 確實不知道它們是什麼時候裝的。
- `readopt_switch` 同理：它換掉 client 物件（紀錄跟著換新的、是空的）並 push pipeline（清空交換機），
  然後 `install_initial_routes(only_dpid=dpid)` 重灌並重記。

## 5. 閘門看紅（逐字在 SUMMARY §3）

`tests/shell/mutate_p4_rule_install_time.sh`，**19 mutations / 0 survived**，
兩個方向都測：M1–M10 把缺陷放回去；N1–N9 是「記更多、宣稱更多」的實作
（在交換機接受之前就蓋章、冪等重寫也重算、未紀錄的規則也給年齡、pipeline 清空後不清紀錄、
key 保留 don't-care 欄位、負數年齡、丟掉 nsec、key 忘記是哪一台交換機）。
**沒有 N 組的話，這個閘門會替一個「勤勞地記、而數字不能信」的實作背書。**

## 6. 殘餘（誠實聲明）

1. **紀錄在記憶體，重啟就沒了。** §4 說明為什麼這是一致的而不是有損的。
2. **年齡剛好為 0 的規則跟「不知道」的規則在 payload 上分不開**（都是 0/0）。
   payload 形狀沒有第三個值，而編一奈秒出來就是對時鐘說謊。
   `test_a_rule_installed_this_instant_is_indistinguishable_from_an_undated_one` 釘住這件事。
3. **這個修法只讓 proxy 知道「它自己裝的」規則的年齡。** 別的寫入者（另一個 controller、
   上一代 proxy 留下且 push 失敗的）永遠 0/0。這是設計，不是缺口。
4. **`installed_at_epoch()` 目前的 reader 只有測試。** 它是**推導**出來的（沒有第二份存下來的
   時鐘會腐爛），但它確實還沒有 production 呼叫點；自然的 reader 是 `/p4/switch_state`
   加一個 additive key（a4c 對 `boot_id`／`table_generation` 就是這樣做的）——**本輪沒做**，
   見 SUMMARY §7。
5. **5-tuple 那條路徑只有單元測試，沒有 live 驗。** orchestrator 的反向實驗裝的是一條路由（LPM）。
   若 bmv2 讀回 ternary entry 時會**補上寫入端沒指定的 don't-care 欄位**，
   LPM 路徑不受影響、5-tuple 路徑也不受影響（key 會把 mask 為 0 的欄位排除，見 §3.1），
   但**這件事我沒有對真的 bmv2 驗過**。
6. **`ndt` 側還沒翻面。** 見 SUMMARY §6。
