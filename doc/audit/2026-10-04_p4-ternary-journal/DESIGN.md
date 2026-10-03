# P4 generic table writer：ternary／range／optional＋priority，與 API 寫入的 journal — 設計稿 r1

[Co-developed with claude code -- Adam]

- **範圍**：Adam 2026-10-01 選的下一刀。只設計，不改碼、不上 lab、不 sudo。
- **基準**：分支 `design/p4-ternary-journal`，從 trunk `229ed30c` 開；以下行號都是這顆 commit 的。
- **證據等級**（不混用）：
  - 【讀】這次 session 親自讀過的碼或檔；
  - 【觀測】這次 session 跑了指令看到的（protobuf descriptor、已安裝 binary 的 `strings`、`readelf`），**沒有執行 bmv2**；
  - 【轉述】別份文件的說法，沒有重新驗證；
  - 【推論】由上面三種推出來，沒有證據直接證明。

## 0. 一段話講完

`POST /p4/table_entry` 照 tutorials 的 JSON 形狀，加上 ternary `[value, mask]`、range `[low, high]`、optional（一個值），以及頂層 `priority`。
- **在本機就拒絕 PI 會拒絕的寫法**，回 400，什麼都沒寫：
  - 需要 priority 的表，priority 漏掉或為 0；
  - 給 default entry 帶 priority；
  - `value & ~mask` 不是 0；
  - 用遮罩 0、整段 range、lpm /0 來表示 don't-care。
- **開機 entry 走同一個 builder**，pre-flight 與 writer 共用一份形狀檢查。
- **只 journal API 的寫入**：
  - 開機 entry 每次都從 package 檔重新算出，不進 journal；
  - 存在新檔 `.run/table_entry_journal.jsonl`；
  - 順序是 gRPC 先成功、fsync 後才回 200，同一台交換機的寫入用一把鎖串起來；
  - proxy 重啟與 readopt 時，先把 log 依 entry 身分**折疊**成淨狀態，再重放；
  - 重放完寫回一份 snapshot。**重放的寫入不再追加**，這就是 replace-vs-add 的防線。
- 舊的 kernel-routing journal 照舊只記不放。

## 1. 今天的碼

### 1.1 writer（`p4_proxy/proxy_agent/p4_client.py`）【讀】

- 能建的 match type 寫死在 `BUILDABLE_MATCH_TYPES = ("EXACT", "LPM")`（`:133`）。
  - 其他型別在 `build_table_entry` 裡丟 `TableEntryUnsupported`（`:1204-1208`），route 譯成 501。
  - 例外的分工：`:90-103` 是 Unsupported，`:106-117` 是 Invalid（400），`:46-62` 是 ControlPlaneReadOnly（409）。
- `encode_value`（`:136-217`）的規則：
  - 值放不下就拒絕、**不截斷**（`:152-157`）；
  - 布林不算 1。
- `table_honours_priority`（`:1132-1145`）的判斷：表裡有任何一個欄位不是 EXACT/LPM，就算有 priority 欄。
- priority 的處理（`:1284-1296`）：
  - 非整數 → 400；
  - 非 0 卻落在沒有 priority 欄的表 → 400；
  - **priority 是 0 或缺漏，在有 priority 欄的表上不檢查**。今天碰不到這條路，因為 ternary 在 `:1204` 就先 501 了。
  - **default entry 帶 priority 也不檢查**。
- `write_table_entry`（`:1318-1392`）：
  - 刻意沒有 MODIFY fallback（`:1327-1335`）；
  - default entry 的 insert 會換成 modify，並在回應裡揭露（`:1354-1356`）；
  - `stub.Write` 在 `:1368`，之後才記 install time（`:1370-1377`）。
- `_built_entry_match`（`:1300-1316`）只認 exact/lpm。⇒ ternary entry 的 install-time key 會跟讀回來的對不上。
- 讀取側 `read_table_entries` 認 ternary、range（`:1487-1494`），**不認 optional**（會被丟掉）。
- don't-care 的寫法是「不放進 entry」（`:1655-1662`），5-tuple 路徑就是這樣做的。
- `insert_5tuple_rule` 遇到 ALREADY_EXISTS／UNKNOWN 會改送 MODIFY（`:1800-1808`），原因是 bmv2 對「已存在」也回 UNKNOWN（`:1802-1804` 的註解）。

### 1.2 route（`p4_proxy/proxy_agent/api_routes.py`）【讀】

- `POST /p4/table_entry` 在 `:841-957`。
  - 狀態碼表在 `:866-886`。400／404／409／501 都在 `stub.Write` 之前，測試斷言 `stub.requests == []`。
  - 501 的 remedy 寫著 "wait for the ternary writer"（`:925-930`）。
- 每次成功都回 `journaled: False` 加 `TABLE_ENTRY_NOT_JOURNALED`（`:837-838`、`:954-957`）。
  - 這是 Adam 09-18 裁 (a)【轉述 `TICKET-P2-exercise-dataplane.md:5,68`】。
  - **同一個常數也被 `POST /p4/multicast_group` 用**（`:1130`）。
- `switch_state.table_entries.journaled` 是常數 false（`:765-767`；`main.py:797-807`）。
- `_refuse_unhonourable_priority`（`:413-470`）只管 OpenFlow 形狀的 delete／modify：
  - 09-03 實測：在 `ipv4_lpm` 上用 priority 777 modify、999 delete，**改到、刪到了本來就在的那一筆**，而且都回 200（`:427-432`）；
  - 09-11 實測：838 bytes 的 body 被 `briefly(body, 200)` 從中間切斷，所以 remedy 要放在前 200 bytes（`:448-457`）。
  - generic writer 不走這條，它自己在 `p4_client.py:1289-1295` 擋 priority。

### 1.3 開機 entries 與 pre-flight【讀】

- `main.apply_package_entries`（`main.py:618-665`）對每一筆呼叫 `client.write_table_entry(spec, op)`（`:657`）。
  - 一筆失敗不擋其他筆，結果計進 `failed`。
- startup：**只在外來 pipeline、沒有 broken、不是 read_only** 時套用（`:2009-2020`，條件在 `:2015`）。
- readopt：pipeline push 清空交換機之後重套，計數**重新記錄、不累加**（`:1754-1760`）。
- `tools/p4_exercise/preflight.py` 的 `check_entry`（`:200-288`）：
  - 不在 `_SUPPORTED_MATCH = ("EXACT", "LPM")`（`:59-60`）的欄位一律 FAIL「G5 not done」（`:224-234`）；
  - **完全不檢查 priority**；
  - 它的值檢查是 `encoded_width`（`:153-184`），和 writer 的 `encode_value` 是兩份實作，寬鬆程度不同（例如 IPv6 字串、任意字串）。
- PF-T 的 fixture `tools/p4_health/exercise/runtime/s2-runtime-pft.json:267-280` 是一筆 `HcIngress.t_ternary`：
  - match `["10.0.1.1", "255.255.255.255"]`，`priority: 10`；
  - 寫法就是 tutorials 的形狀。

### 1.4 rule_journal 與它從沒被叫過的 replay【讀】

- `rule_journal.py` 記的是 kernel routing 的請求，接線在 `main.py:40-111`：
  - `journal = build_rule_journal()`（`:97`），`TopologyManager(..., journal=journal)`（`:111`）；
  - 寫入點是 `topology_manager._note_in_journal`（`:1081-1107`），**只記交換機收下的**。
- 格式（`rule_journal.py:149-181`）：
  - 一行一個 JSON，欄位 `{t, op, dpid, match, actions, priority}`，也就是 OpenFlow 形狀；
  - 每次 append 都 fsync；
  - 鎖只包住 append 本身（`:145-148`、`:167-178`）。
- replay 有實作（`:247-278`），報告是四值的 `ReplayReport`（`:64-128`）。**但沒有呼叫點**：
  - `main.py:51-53` 明寫 "RECORDING ONLY ... still has no call site anywhere"；
  - grep 整個 repo，`.replay(` 只出現在 `p4_proxy/tests/test_rule_journal.py`【觀測】。
- 為什麼沒接，碼裡寫明的理由：
  1. **journal 記的是請求，不是理由**。為了壅塞裝的 TE 繞路，二十分鐘後壅塞早就沒了，還留在 journal 裡；重放會裝出一條沒人要的路（`:27-31`）。⇒ 預設關閉、opt-in（`REPLAY_ENV_VAR`，`:54-61`）。
  2. **開關要放在呼叫端**（`:256-258`）。而呼叫端從沒寫，因為「該不該重放」本身是一個決定（`main.py:51-53`）。
- 碼裡沒寫、我推出來的兩點：
  3. **`quarantine` 也沒有呼叫點**（grep 結果只有定義，`:280-296`）【觀測】。⇒ 這個檔案從來沒分過代，每次重啟的紀錄都堆在同一份。它自己的 docstring 說得很清楚：這樣重放會把三次重啟以前刻意刪掉的規則裝回來（`:285-288`）。所以就算有人把開關打開，重放的也是所有世代的歷史【推論】。
  4. 重啟後 `install_initial_routes` 會重鋪最短路徑，而 `insert_ipv4_route`／`insert_5tuple_rule` 都帶 MODIFY fallback（`p4_client.py:1800-1808`）。⇒ 重放與重鋪誰後寫誰贏，結果取決於順序，不取決於意圖【推論】。

### 1.5 roles、owner、external【讀】

- `app_package.py`：`mode` 只能是 `ndtwin`／`external`（`:93-95`），`read_only` 就是 `mode == external`（`:298-300`）。
- `route_binding.py`：
  - `OWNER_NDTWIN` 表示 NDTwin 獨占那張表，package 自己的 entry 在 pre-flight 就被拒（`:52-57`；`preflight.py:470-500`）；
  - `OWNER_PACKAGE` 表示 NDTwin 只讀。
- external：client 不仲裁，每一個寫入方法都先過 `_refuse_write` → `ControlPlaneReadOnly`（`p4_client.py:495-506`）→ 409。
  - startup 也跳過 push（`main.py:1978`）。
- 🔴 **generic writer 不看 binding**：
  - `write_table_entry` 只呼叫 `_refuse_write`（`:1344`），沒有 `_writable_route_binding`（`:455-467`）。
  - ⇒ 今天 operator 可以把 entry POST 進 baseline 的 `MyIngress.ipv4_lpm`，也可以 POST 進 owner ndtwin 的路由表。
  - baseline 的 `MyIngress.flow_5tuple` 全是 ternary 欄位（`ndtwin_switch.p4:329-347`），**今天被 501 擋著，這刀之後會變成寫得進去**。見 Q2。

### 1.6 bmv2／PI／P4Runtime 要求什麼

| 事實 | 等級與來源 |
|---|---|
| `TableEntry.priority` 是 int32 | 【觀測】venv 裡 p4runtime 1.5.0 的 descriptor，type 5 |
| MatchType 編號：EXACT=2、LPM=3、TERNARY=4、RANGE=5、OPTIONAL=6 | 【觀測】同上；與 `p4_client.py:1121-1130` 一致 |
| `FieldMatch.Ternary{value, mask}`、`Range{low, high}`、`Optional{value}` | 【觀測】同上 |
| PI 前端（`/usr/local/lib/libpifeproto.so.0`，sha16 `987b243193959872`）裡的錯誤字串："Zero priority for ternary match"、"Non-zero priority for non-ternary match"、"Non-zero priority for default entry"、"Invalid ternary value, make sure value & mask == value"、"... omit match field instead of using 0 mask"、"... omit match field instead of using low=0 and high=2**bitwidth-1"、"Invalid range value, make sure low <= high"、"Invalid reprsentation of 'don't care' LPM match, omit match field instead of using a prefix length of 0"、"Missing non-ternary field in match key" | 【觀測】`strings`。**字串存在不等於一定會觸發**：哪條路徑會走到它是【推論】 |
| 兩個 `simple_switch_grpc`（`/usr/local/bin`、`/usr/local/bmv2-fast/bin`）都 NEEDED `libpifeproto.so.0` | 【觀測】`readelf -d`。bmv2-fast 的 RUNPATH 底下沒有這個檔，所以用的是 `/usr/local/lib` 那份【推論】 |
| `libbmpi.so.0` 有 `PriorityInverter::pi_to_bm` 與 `from <= BM_MAX_PRIORITY` | 【觀測】`strings`。⇒ bmv2 內部的 priority 是反轉過的，thrift dump 看到的不是 P4Runtime 的數字；而且有上限，值不知道【推論】 |
| 「數字大的贏」 | 【轉述】P4Runtime spec（這次沒讀）。碼裡有兩處同樣的說法：`p4_client.py:1759-1763`、`topology_manager.py:319` |
| tutorials 要求 TERNARY/RANGE/OPTIONAL 的表帶非 0 priority；ternary 寫 `[v, m]`、range 寫 `[lo, hi]`；optional 不支援 | 【讀】`~/tutorials/utils/p4runtime_lib/simple_controller.py:150-167`、`helper.py:98-107` |

### 1.7 這一刀要轉綠的健檢格【讀】

- 依據 `doc/audit/2026-10-03_p4-health-check/expected_today.tsv` 與 DESIGN.md §2.3 `:284-289`。
- T4／T5／T6 今天都是 RED，原因是 501（`api_routes.py:925-930`）。
- T7 是 NOT RUN，因為它依賴 T4。
- T8 是 RED，原因是 `journaled` 恆為 false。
- PF-T 是 RED，原因是 pre-flight 回「G5 not done」。
- 判定碼在 `tools/p4_health/cells/table.py`：
  - T4–T6 是 `wtr` 寫後讀（`:306-323`）：要 200，而且 thrift 的 `present_after`／`mask_ok`／`priority_ok` 都成立；
  - T7 看 `order_ok`（`:326-334`）；
  - T8 讀 switch_state 的 `journaled is True`（`:337-347`），重啟那一半在健檢裡延後（DESIGN `:288,661`）；
  - PF-T 看 pre-flight 是否 rc 0（`:350-363`）。
- **T4–T7 的收集器還沒寫**：`tools/p4_health/collect/` 只有 `post_table_entry`（`collect/proxy.py:51`）。那是健檢 Cut 2 的事。
- S0 自檢斷言「PF-T 只在 ternary 那一列 FAIL」（`tools/p4_health/s0.py:259-277`）。**這一刀一合併，這條自檢就會轉紅。**

## 2. 決定一：API 形狀、驗證、錯誤碼

### 2.1 形狀

body 照舊（`api_routes.py:852-857`），match 的值依 p4info 的 `match_type` 解讀，**不從值的長相猜**（`p4_client.py:1160-1166`）：

| match_type | 值的寫法 | 上線（wire） |
|---|---|---|
| EXACT | 照舊：純值，或一個元素的 list | `exact.value` |
| LPM | 照舊：`[value, prefix_len]`，**prefix_len 改成 1..bitwidth**（見 Q3） | `lpm` |
| TERNARY | `[value, mask]`，兩個都用 `encode_value(x, bitwidth)` 編碼，所以點分、MAC、整數、`"0x.."` 都能用 | `ternary{value, mask}` |
| RANGE | `[low, high]`，編碼同上 | `range{low, high}` |
| OPTIONAL | 純值，或一個元素的 list，與 EXACT 相同 | `optional.value` |
| 其他（`UNSPECIFIED`、`other`） | 照舊 501 | — |

- ternary／range／optional 欄位**省略＝don't-care**。這和 `p4_client.py:1655-1662`、PI 的訊息一致。
- **EXACT 欄位不能省略**：新增本機 400。今天這種情況會一路送到交換機才被拒（"Missing non-ternary field"），回 502。
- `priority`：頂層整數，與今天同一個鍵（`api_routes.py:915`）。
- 刻意只收一種拼法（list），不收 `{"value":..,"mask":..}` 物件。兩種拼法就是兩種身分，見 §3.2。
- 回應：
  - 照舊的欄位，加上 `"priority": <上線的值>`；
  - `journaled` 依 §5.4；
  - `note` 只在 `journaled: false` 時出現。

### 2.2 驗證（全部在 `stub.Write` 之前，回 400 `TableEntryInvalid`）

- **V1 arity**：TERNARY、RANGE 必須剛好兩個元素；OPTIONAL 收兩個元素也是 400（它和 ternary 或 range 長得一樣，接受了就是在猜）。
- **V2 編碼**：value、mask、low、high 都走 `encode_value`。放不下就拒絕，不截斷（`:152-157`）。
- **V3 ternary**：`value & ~mask != 0` 時 400。⇒ 不替作者遮罩，作者可能寫錯的是遮罩。
- **V4 range**：`low > high` 時 400。
- **V5 don't-care 拼法**：遮罩全 0、range `[0, 2^w-1]`、lpm `/0` 都是 400，訊息照 PI 的意思寫「omit the field」。見 Q3。
- **V6 priority**：在 `table_honours_priority(table)` 為真的表上：
  - insert、modify、delete 都**必須**帶，且 `1 ≤ priority ≤ PRIORITY_MAX`；
  - 在 exact/lpm 表上非 0 照舊是 400；
  - **default entry 帶非 0 priority 是 400（新增）**。
  - `PRIORITY_MAX` 先定為 int32 上限。bmv2 的 `BM_MAX_PRIORITY` 不知道，**要在第一步用拋棄式 bmv2 實測**（§7 Cut A0），量到以後收緊成兩者中較小的那個。
  - 刻意不做 OpenFlow 那條路的 `p4_priority` 的 +1 平移（`topology_manager.py:314-333`）：這個 endpoint 講的是 P4Runtime 自己的數字，平移只會讓讀回來的值和寫進去的不一樣。
- **V7 owner**：見 Q2。建議回 409，`error: "owned by NDTwin"`，`outcome: "owned_by_ndtwin"`，`remedy` 放在前 200 bytes（理由同 `api_routes.py:448-457`）。

錯誤碼表（取代 `api_routes.py:866-882`）：

- 200：照舊。
- 400：加上 V1–V6。
- 404：照舊。
- 409：external 照舊；加上 V7（`error` 字串不同）。
- 501：只剩 `UNSPECIFIED` 與 `other`。
- 502：照舊。
- 503：新增「replay pending」，見 §5.5。

### 2.3 共用一份形狀檢查（G5 的前提）

新增模組 `p4_proxy/proxy_agent/match_shape.py`，不依賴 gRPC：

- 內容是 `encode_value`（從 `p4_client.py:136-217` 搬過來，`p4_client` 再 re-export）、V1–V6，以及「哪些表要 priority」。
- `p4_client.build_table_entry` 與 `preflight.check_entry` 都呼叫它。⇒ 兩邊用同一句話拒絕同一份 package。
- 先例是 `route_binding.resolve` 的「一個函式、兩個呼叫端」（`route_binding.py:32-36`）。
- pre-flight 現有 exact/lpm 的 `encoded_width` **這一刀不換**：換了會改變既有 package 的 PASS/FAIL，那是另一個決定。差異寫進 §9。

## 3. 決定二：modify／delete 的身分，以及怎麼避開 replace-vs-add

### 3.1 身分

- entry 的身分是 `(dpid, table, priority if table_honours_priority else 0, 正規化後的 match)`。
- 這就是 `rule_install_times.entry_key`（`rule_install_times.py:132-141`）已經在用的 key，只要讓 `_built_entry_match`（`p4_client.py:1300-1316`）也輸出 ternary、range、optional，形狀與讀取側一致。
- 讀取側（`:1487-1494`）要補上 optional。
- priority 有欄的表：
  - modify／delete **必須**帶 priority（V6）。priority 是身分的一部分，這和 `delete_5tuple_rule` 的 docstring 相同（`p4_client.py:1842-1850`）。
  - priority 錯了，交換機回 NOT_FOUND，這裡回 502 `grpc_status: NOT_FOUND`。**不會像 09-03 那樣改到別筆**：那個事故只會發生在沒有 priority 欄的表上（`api_routes.py:427-432`），而那種表本來就拒絕非 0 priority。
- **modify 不能改 priority**：改 priority 是 delete 加 insert，兩個 POST。文件與 400 訊息都要寫明，因為 tutorials 的使用者會以為 modify 什麼都能改【推論】。
- 照舊不做 MODIFY fallback（`p4_client.py:1327-1335`）。replay 也不做（§5.5）。

### 3.2 replace-vs-add 會從哪裡進來，各自怎麼擋

記憶檔 `replace-vs-add-bug-shape.md` 的一句話：「舊的資料什麼時候消失？」逐一問：

1. **journal 本身**：
   - 如果重放的寫入又走一次 append，每重啟一次檔案就翻倍，下一次重放的就是兩份歷史。
   - ⇒ 重放**不**追加；重放完用 snapshot 取代整份檔（§5.5）。
2. **身分拼法**：
   - 如果折疊用的是呼叫者的拼法（`"10.0.1.1"` 和 `167772417` 是兩個 key），在拼法 B 下 delete 就移不掉拼法 A 的 insert，重啟後那條規則復活。
   - ⇒ 折疊用 §3.1 的 key，也就是**編碼後的 bytes**。V5 拒絕 don't-care 的第二種拼法，也是為了讓同一個 entry 只有一個 key。
3. **世代**：
   - `quarantine` 沒有呼叫點（§1.4 第 3 點），所以舊 journal 跨所有世代。
   - ⇒ 新 journal 每次 startup 都把舊檔改名留存，並寫一份新的 snapshot；fabric 重新 bring-up 時整份隔離（Q1）。
4. **計數**：
   - replay 的計數比照 `_record_table_entries`（`main.py:818-819`），**重新記錄、不累加**。readopt 兩次，數字要一樣。
5. **與 NDTwin 的寫入者重疊**：
   - 在 NDTwin 擁有的表上，`install_initial_routes` 會重寫，`insert_*` 會 MODIFY fallback，API entry 和 kernel routing 互相覆蓋，誰在最後誰贏。
   - ⇒ Q2 (a) 讓兩邊的表不相交。

## 4. 決定三：開機 entries（G5）

- `apply_package_entries` 不用改。它已經對每一筆呼叫 `write_table_entry`（`main.py:652-657`），builder 會建 ternary 之後，開機的 ternary entry 就會自動裝上去。
  - 一筆失敗不擋其他筆，照舊。
  - 失敗訊息帶 V1–V6 那句話，進 `errors`，再進 `table_entries.failed`。
- pre-flight 的 `check_entry` 改成：
  - 刪掉 `:224-234` 的「G5 not done」；
  - 對三種新型別呼叫 `match_shape`；
  - 加上 priority 規則：要 priority 的表缺漏或為 0 就 FAIL，default entry 帶 priority 也 FAIL；
  - **模組 docstring 的 `:33-34` 與 `_SUPPORTED_MATCH` 的註解 `:59` 一起改**。
  - ⇒ PF-T 的 fixture（priority 10，遮罩全 1）會通過。
- startup 的條件不動。在 NDTwin 自己的 pipeline 上，package 的 entry 照舊只記錄、不套用（`main.py:1999-2008` 那段 🔴 的理由不變）。
- 開機 entry **不進 journal**：
  - 每次 startup 與 readopt 都從 package 檔重算（`main.py:2016`、`:1757`），本來就活得過重啟。
  - 如果也進 journal，重放時它和 package 檔重算的那份會撞成 ALREADY_EXISTS，或者在 bmv2 上撞成 UNKNOWN（`p4_client.py:1802-1804`）。
  - ⇒ 每次重啟都會報出假的失敗；而 package 檔一改，舊的那份 journal 會把舊 entry 寫回去。

## 5. 決定四：journal

### 5.1 記什麼

- **只記 API 的寫入**，也就是 `POST /p4/table_entry`。
- 記 insert、modify、delete，**只記交換機收下的**。這是 `RuleJournal` 本來的契約（`rule_journal.py:135-136`）。
- 被拒的寫入（400／404／409／501／502）一概不記。
- 開機 entry 不記（§4）。kernel routing 照舊記在舊檔，照舊不重放（§5.7）。

### 5.2 檔案與格式

- 路徑 `.run/table_entry_journal.jsonl`，推導方式比照 `default_journal_path`（`main.py:62-82`），錨在檔案位置、不看 cwd。
  - 覆寫用 env `NDTWIN_TABLE_JOURNAL_PATH`；關閉用 env `NDTWIN_TABLE_JOURNAL=off`。
- **不和 `rule_journal.jsonl` 混在一起**：
  - 兩者的重放政策相反：這份預設開，那份預設關；
  - 紀錄形狀也不同；
  - 舊檔的 19 個測試與 `tests/shell/mutate_rule_journal_is_wired.sh` 的錨點都不動。
- 實作是 `rule_journal.py` 裡的 `TableEntryJournal`：
  - 沿用 `entries()` 容忍撕裂行的讀法、`ReplayReport`、`quarantine`；
  - 自己的 `record` 收下面的 v1 紀錄；
  - 新增 `write_snapshot(records)`：寫 tempfile、fsync，再 `os.replace`。

一行 v1 紀錄：

```
{"v":1,"t":<epoch s>,"boot_id":"<BOOT_ID>","dpid":3,"op":"insert|modify|delete",
 "p4info_sha256":"<16 hex>","key":"<entry_key 的 hex 摘要>",
 "spec":{"table":..,"match":..,"action_name":..,"action_params":..,
         "default_action":..,"priority":..}}
```

- `spec` 是呼叫者送來、**已經過驗證**的原文。replay 時再走一次 `write_table_entry`，所以驗證、409 與將來新增的拒絕條件都會再套一次。
- `p4info_sha256` 用 `_p4info_fingerprint`（`main.py:511-523`）。replay 只套用和交換機**現在的** p4info sha 相同的紀錄，其餘報 `stale_pipeline`、不套用。
  - 理由是「名字相同不等於同意」（`route_binding.py:10-12`）：換了 package，同名的表可能是另一張。
- `key` 用來折疊。

### 5.3 和 gRPC 寫入的先後

**先寫交換機，再寫 journal，最後回應**。在 route 裡：

```
with _dpid_lock(dpid):                       # 每台交換機一把，存在模組層，readopt 換 client 也不變
    written = client.write_table_entry(spec, op)       # 失敗就 raise → 4xx/5xx，不記
    ok = table_journal.record(dpid, op, spec, key, sha)  # 會 fsync；不 raise，回 bool
return 200 {..., "journaled": ok, "note"?}
```

- **在兩者之間當掉**：
  - 交換機上有這筆，journal 裡沒有；
  - 下次重啟 push 清空交換機，replay 不知道這筆，規則就丟了；
  - 但 operator **沒拿到 200**（連線斷了），本來就不知道結果。
  - ⇒ 沒有被確認的寫入可以丟，**被確認過的一定在 journal 裡**。
- **反過來，先寫 journal 的話**：
  - 在兩者之間當掉，journal 裡就有一筆從沒裝上去的規則，可能還是交換機會拒絕的；
  - 重放會裝出從來不存在的東西，違反 `rule_journal.py:135-136`。
  - 兩階段（intent 加 commit 標記）也只是讓結果等同「後寫」，外加一個 in-doubt 清單。這一刀不做。
- **journal 寫失敗**（磁碟滿，`record` 回 False）：
  - 回 200，`journaled: false`，note 寫「on the switch, not journaled: lost on restart」；
  - `switch_state` 的 `journal.failures` 加 1。
  - 見 Q4。
- **為什麼要那把鎖**：
  - `RuleJournal` 的鎖只包住 append（`rule_journal.py:167-178`），而 route 跑在 threadpool（`api_routes.py:919`）。
  - 兩個 POST 可能「A 寫交換機 → B 寫交換機 → B 記 → A 記」，journal 的順序就和交換機上實際發生的相反。
  - 「同一個 entry 先 insert 再 delete」重放出來會變成「先 delete 再 insert」，**規則復活**。
  - 代價：同一台交換機的 POST 會被串起來，一次 gRPC 來回加一次 fsync【推論：每筆 ms 級】。

### 5.4 揭露

- POST 回應：`journaled: true|false`。
- `switch_state.table_entries`（`main.py:795-807`、`api_routes.py:762-767`）：
  - `journaled` 由常數改成算出來的：**journal 開著、這台不是 read_only、而且這台本次開機沒有任何一筆寫失敗**。
  - 新增 `journal: {"writes": n, "failures": n, "replay": <ReplayReport.as_dict() + stale_pipeline + skipped_reason>}`。
- 健檢 T8 讀的就是 `journaled`（`cells/table.py:337-347`）。
- `TABLE_ENTRY_NOT_JOURNALED` 拆成兩個常數。multicast 那份（`api_routes.py:1130`）**保持原文**，因為 PRE entry 這一刀不 journal（Q5）。

### 5.5 重放：proxy 重啟

- 位置：`startup` 裡 entries 的那個迴圈（`main.py:2009-2020`），每台交換機在 `apply_package_entries` 之後、PRE 之前。
- 條件：`i not in broken and not read_only`，而且 journal 開著。
- 步驟：
  1. 讀檔：`entries()` 加上 unreadable 計數。
  2. **折疊**：依 `key` 與檔案順序，每個 key 算出淨效果。
     - 第一個 op 是 insert，表示 API 之前不存在；是 modify 或 delete，表示之前就在，例如 package entry 或 default action。最後一個 op 決定之後在不在、spec 是什麼。
     - 「之前不在、之後在」→ insert(最終 spec)；「之前在、之後在」→ modify(最終 spec)；「之前在、之後不在」→ delete；「之前不在、之後不在」→ 不做。
     - default entry 的 key 是 `(dpid, table, "default")`，永遠是 modify。
  3. 只留 `p4info_sha256` 和交換機現在相符的，其餘算 `stale_pipeline`。
  4. 依 key 的首次出現順序，對每一筆淨 op 呼叫 `write_table_entry`，包在 `RuleJournal.replay` 的 applier 裡，**不做 MODIFY fallback**。
     - 失敗的那筆連同理由進 `ReplayReport.failed`。理由可能是 ALREADY_EXISTS／UNKNOWN（例如 package 檔改了，撞到新的開機 entry），或 NOT_FOUND（例如被 delete 的那筆開機 entry 已經不存在）。
  5. **寫 snapshot**：
     - 先把舊檔 hard-link 成 `quarantine` 的名字（`<path>.<boot_id>.<t>`），留下證據；
     - 再用 `os.replace` 換成新內容：成功重放的淨紀錄，加上沒有嘗試的那些（broken 交換機的、journal 關閉時的）；
     - 失敗與 stale 的紀錄不留在新檔，只留在隔離檔與 replay 報告裡。⇒ live journal 描述的是交換機現在的樣子。保留失敗的那筆也沒用：它不在交換機上，API 刪不掉（delete 會 NOT_FOUND，不會被記下來），只會每次重啟都報一次錯。
  - **步驟 5 中途當掉**：hard link 之後、replace 之前當掉，live 檔還是舊的完整 log。下次再折疊一次，結果相同，因為折疊是冪等的。
- 在這台交換機的重放完成之前，`POST /p4/table_entry` 對它回 **503 `replay pending`**。
  - 端點在 startup 完成前就開始回應（`main.py:1805-1806` 的註解）。
  - 先寫進去的 POST 會被後到的 replay 撞掉，或撞掉 replay。
  - replay 期間持有 §5.3 那把鎖。

### 5.6 重放：readopt，與 owner、external 的互動

- **readopt**：`main.readopt_switch` 在外來 pipeline 的分支重套 package entries 之後（`:1757-1760`），對**這一台**做 §5.5 的步驟 2–5，報告放進 `result["table_entries"]["replay"]`。
  - 理由與重套 package entries 相同：readopt 裡的 push 剛把交換機清空（`:1754-1756`、`p4_client.py:746`）。
  - baseline 交換機在 `:1743` 就 return 了。在 Q2 (a) 底下 baseline 沒有 generic writer 能寫的表，所以那裡不需要 replay。如果 Q2 選 (c)，要在 `:1743` 前補一次。
- **external（409）**：
  - API 寫入在 `_refuse_write` 就被擋，什麼都不記；
  - startup 也不 replay、不寫 snapshot，journal 一個 byte 都不動；
  - 報告寫 `skipped_reason: "external control plane"`。
  - 下次用非 external 的 package 起來，sha 符合的話照常重放【推論：這是對的，因為 journal 描述的是上一個 NDTwin 主控時的意圖】。
- **owner**：在 Q2 (a) 底下，owner ndtwin 的表在 V7 就被擋，journal 裡不會有。owner package 的表是作者的，API 寫得進去，journal 記得到，也會重放。

### 5.7 舊的 kernel-routing replay：這一刀不接

- 這一刀不接舊 replay，§1.4 的第 1、3、4 點都還成立。
- API table entry 不同：
  1. 它的理由**不是 proxy 算出來的**，沒有「過期」這回事。operator 或 app 明確 POST 了，就該一直在，直到它自己 delete。
  2. 除了 journal，沒有任何東西能重算它。路由由 `install_initial_routes` 重算，開機 entry 由 package 檔重算。
  3. 這一刀有世代管理（§5.5 步驟 5、Q1）。
- 有一個殘留風險：會在自己重啟後重送規則的論文 app，會在已經重放回來的 entry 上拿到 502 ALREADY_EXISTS【推論】。⇒ 回應裡的 `boot_id`／`table_generation` 讓 app 判斷得出來（`boot_identity.py:27-33`）。寫進手冊。

## 6. 決定五：測試與 mutation gate

### 6.1 先看紅

每一顆都先在 `229ed30c` 上跑一次，記下紅的那一行，再寫實作。

| # | 測試（檔案） | 在 229ed30c 上為什麼紅 |
|---|---|---|
| R1 | ternary spec 建出 `ternary{value,mask}` 與 priority（`tests/test_p4_client_writes.py`） | `TableEntryUnsupported`（`:1204`） |
| R2 | range 建出 `range{low,high}`；R3 optional 建出 `optional.value` | 同上 |
| R4 | 要 priority 的表 insert／modify／delete 缺 priority 或為 0 → 400，`stub.requests == []` | 先撞到 501 |
| R5 | ternary 表上的 default entry 帶 priority → 400 | **今天可以建出來、送上 wire**（`:1289` 只看 `table_honours_priority`）。今天就是一顆真的紅 |
| R6 | `value & ~mask`、`low > high`、遮罩 0、整段 range、lpm /0 → 400，什麼都沒寫 | 前四個先撞到 501；**lpm /0 今天建得出來**（`:1249`） |
| R7 | EXACT 欄位漏掉 → 400 | 今天建得出來、會送出去 |
| R8 | `_built_entry_match` 對 ternary 輸出的形狀與 `read_table_entries` 相同（install time 不是 0/0） | 只認 exact/lpm（`:1300-1316`） |
| R9 | `read_table_entries` 讀回 optional | `:1487-1494` 沒有 optional |
| R10 | route：200 時 `journaled: true`，journal 多一行，`key` 是正規化之後的 | 常數 false（`:957`） |
| R11 | stub raise → journal 沒有新行 | 今天沒有 journal：vacuous green ⇒ **要在 mutant 下看紅**（M-J1） |
| R12 | 同一台交換機兩個 POST，用 hook 強迫交錯：journal 順序＝stub 收到的順序 | 今天沒有 journal ⇒ 只能在 mutant 下看紅（M-J2） |
| R13 | 折疊：insert A、modify A、delete A，再以兩種拼法 insert B 與 delete B ⇒ snapshot 是空的 | 新程式碼 ⇒ mutant M-J3 |
| R14 | `test_startup.py`：假 client 跑重啟兩次，第二次與第一次的 journal 一樣長，交換機上的 entry 相同 | 新程式碼 ⇒ M-J4 |
| R15 | sha 不符 → 不套用，`stale_pipeline: n` | M-J5 |
| R16 | external：不 replay，journal byte-identical | M-J6 |
| R17 | `test_readopt.py`：readopt 後在 package entries 之後重放；readopt 兩次，計數一樣 | 今天 readopt 不重放 |
| R18 | pre-flight：PF-T 的 fixture 通過；缺 priority 的 ternary 那句話 FAIL；`value & ~mask` FAIL（`tools/p4_exercise/tests/test_preflight.py`） | 「G5 not done」 |
| R19 | V7：baseline 交換機上 POST `flow_5tuple`／`ipv4_lpm` → 409 `owned_by_ndtwin`（照 Q2） | 今天分別是 501 與 200 |
| R20 | replay pending → 503 | 新的 |

### 6.2 要退役或反轉的既有 gate【讀】

這些 mutant 描述的行為，這一刀之後就是正確行為：

- `tests/shell/mutate_table_entry.sh`：M-B6（`:244-247`，ternary 回 200）、RANGE 那一個（`:282-283`）、M-B7／M-B14（`:333-339`，`journaled` 變 true）、M-B20（`:344-350`）。
- `tests/shell/test_ndt_app_package.sh:1001` 的 fixture 寫死了 `journaled: False`。

反轉的做法：同一個錨點改成新的行為，再加一個「改回舊行為」的 mutant，也就是把 `BUILDABLE_MATCH_TYPES` 改回 `("EXACT","LPM")` 必須被 R1 抓到。

`tests/shell/mutate_p4_health.sh` 的 M9（`:146-150`）測的是格子本身，不動。

### 6.3 新的 mutation gate（`tests/shell/mutate_table_journal.sh`）

- M-J1 先記 journal 再寫交換機；M-J2 拿掉 dpid 鎖；M-J3 折疊改用 spec 的拼法當 key；M-J4 重放時又 append；M-J5 不檢查 sha；M-J6 external 也 replay。
- M-J7 拿掉 V3；M-J8 拿掉 V6 的 default 分支；M-J9 讀取側拿掉 optional；M-J10 readopt 的計數改成累加；M-J11 snapshot 改成原地覆寫。
  - M-J11 的觀察點：`write_snapshot` 用 fault injection 在寫入中途 raise，舊檔必須完整。
- 加上一個只改註解的負對照。
- 規矩照現有的 gate：baseline byte-identical、0 survivor、`check_gate_anchors` 通過。

### 6.4 健檢格的預測（這一刀合併後；T4–T7 另外要等健檢 Cut 2 的收集器）

| 格 | 預測 | 根據與風險 |
|---|---|---|
| T4 ternary | GREEN | 200 加上 thrift dump 有這一筆。⚠️ `priority_ok` 的 oracle 要把 bmv2 的反轉算進去（`PriorityInverter`，§1.6）【推論】，否則就是一顆假紅 |
| T5 range | GREEN | 同上 |
| T6 optional | GREEN | ⚠️ thrift 可能把 optional 顯示成 ternary 加全 1 遮罩【推論】，oracle 要容許 |
| T7 priority 次序 | GREEN（T4 綠才會跑） | 同 T4 的反轉風險；`order_ok` 必須比較的是 P4Runtime 的數字次序 |
| T8 journaled | GREEN | static：`switch_state.table_entries.journaled == true`。重啟那一半：這一刀用 `test_startup.py` 離線證明，live 的重啟留給健檢（DESIGN `:661`） |
| PF-T | GREEN（rc 0） | ⚠️ S0 的自檢 `s0.py:275`「PF-T 只在 ternary 那一列 FAIL」會轉 FAIL。要和健檢那條線一起改：PF-T 改成必須 PASS，`expected_today.tsv` 的 T4–T8、PF-T 也要重寫 |

## 7. 決定六：cut 計畫（行數都是【推論】估計）

| Cut | 內容 | 大小 | 驗收 |
|---|---|---|---|
| A0 | 拋棄式 bmv2 實測（不用 lab，比照 S0 的 `ndt-hc-*-bmv2`）：`BM_MAX_PRIORITY`、priority 上下限、thrift 怎麼顯示反轉、optional 怎麼顯示。只寫量測腳本與 log | 腳本約 120 行 | log 在 audit-raw；V6 的上限依量測結果定 |
| A | `match_shape.py`、`build_table_entry` 三種新型別與 V1–V7、讀取側 optional、`_built_entry_match`、route 的錯誤碼、pre-flight G5 | 程式約 300 行，測試約 400 行 | R1–R9、R18、R19 先紅後綠；§6.2 的反轉；`mutate_table_entry.sh` 0 survivor |
| B | `TableEntryJournal`、route 的鎖、先寫交換機再記、揭露（§5.4）、拆開常數 | 程式約 200 行，測試約 300 行 | R10–R13；M-J1–M-J3、M-J7–M-J9 |
| C | startup 與 readopt 的重放、折疊、snapshot、503 pending、Q1 的世代 | 程式約 250 行，測試約 400 行 | R14–R17、R20；M-J4–M-J6、M-J10、M-J11 |
| D | 與健檢線協調：S0 的 PF-T 期望、`expected_today.tsv`、T4–T7 oracle 的反轉（那幾個檔屬於健檢線，不屬於這刀） | 由健檢線估 | 健檢 S0 COMPLETE |

- 合計：程式約 750 行，測試約 1,100 行，shell gate 約 300 行。
- C 依賴 B，B 依賴 A 的 key（§3.1）。
- A 可以單獨合併：它轉綠的是 T4–T7 與 PF-T；T8 要等 B。

## 8. 要 Adam 決定的

**Q1 fabric 重新 bring-up 時，journal 怎麼辦？**

- 背景：proxy 自己分不出「warm fabric 上重啟」和「`ndt up` 剛起的全新 fabric」，兩種情況都會 push、都會清空交換機。
- (a)【建議】**`ndt up` 起 bmv2 的那一步，順便把 table-entry journal 隔離**。
  - 隔離是 rename，`quarantine` 第一次有呼叫點，用途就是它當初寫的那個。
  - 不是由 `stack.sh:1085-1087` 起 proxy 的那一步做；確切插入點【推論】要在 Cut C 讀 `ndt`／`stack.sh` 定。
  - 後果：手動重啟 proxy、proxy 當掉再起來，都會重放；新的 fabric 從空的開始。
  - 要改一處 shell，加它自己的測試。
- (b) proxy 自己判斷：每筆紀錄記下交換機的 bmv2 pid（取自 `/tmp/ndtwin_p4_switches.json`，`p4_testbed_topo.py:33,494-532`），pid 不同就不重放。
  - 後果：不用改 shell。但 power-cycle 會換 pid，readopt 要另外處理。而 power helper 會不會改寫 manifest 裡的 pid（`tools/p4_power_helper.py:120-136`）是【推論】。manifest 不存在時（不是 Mininet 起的）也要另訂規則。
- (c) 不分世代，只看 p4info sha。
  - 後果：昨天的 operator 規則會被寫進今天的新 fabric。**不建議。**
- 其他：

**Q2 generic writer 能不能寫 NDTwin 擁有的表？**

- (a)【建議】**不能**：baseline 綁定的交換機上每一張表（`ipv4_lpm`、`flow_5tuple`、`l2_forward`），以及 `roles.ipv4_route` owner ndtwin 的表，一律回 409 `owned_by_ndtwin`。
  - 後果：Adam 的 ruling 8-1「NDTwin 獨占、package 不得宣告」在 pre-flight 已經成立（`preflight.py:470-500`），這等於把它延伸到 runtime API；journal 與 kernel routing 永遠不會在同一張表上互相覆蓋（§3.2 第 5 點）。
  - 代價：今天 POST 進 baseline `ipv4_lpm` 回 200，之後變 409。這是一個行為變更。`test_table_entry_route.py` 用的是 `MyIngress.ipv4_lpm`（`:202`），會有測試要改【推論：要看它的假 client 綁的是不是 baseline】。
- (b) 只擋這一刀才新打開的 `flow_5tuple`，`ipv4_lpm` 維持今天的 200。
  - 後果：不改既有行為。但 `ipv4_lpm` 上的 API entry 會被 `install_initial_routes` 在下一次鏈路變化時改寫，journal 重放時也會和重鋪互撞。
- (c) 都放行，只揭露。
  - 後果：`insert_5tuple_rule` 的 MODIFY fallback（`p4_client.py:1800-1808`）會把 operator 同 key 的 entry 默默覆蓋。這正是「被拒的請求仍然做了事」的反面。
- 其他：

**Q3 don't-care 的第二種拼法（遮罩 0、整段 range、lpm /0）**

- (a)【建議】**400，訊息寫「omit the field」**。
  - 後果：一個 entry 只有一個身分（§3.2 第 2 點），和 PI 自己的拒絕一致。lpm /0 今天是 502，之後變 400，嚴格來說是變好。
  - 代價：int-v1 手寫的 entry 裡，L4 port 的遮罩寫成 `0x0000`【轉述 健檢 DESIGN `:828`】，要改成省略那兩個欄位。
- (b) 正規化成「省略」，並在回應裡用 `normalised: [...]` 揭露。
  - 後果：tutorials 風格的檔案直接能用。但 journal 的 key 一定要用正規化之後的，否則就是 §3.2 第 2 點那顆雷。
- 其他：

**Q4 journal 寫失敗（磁碟滿）時怎麼回應？**

- (a)【建議】**200，`journaled: false`，加 note，`journal.failures` 加 1**。
  - 後果：規則確實在交換機上，回應說的是實話。T8 會紅，這是對的。
- (b) 把那筆 delete 回去，回 507。
  - 後果：「寫入了」與「記錄了」綁成一件事。但 rollback 本身也可能失敗，那時就是一筆既沒記錄、又回錯誤碼的規則。
- 其他：

**Q5 multicast／PRE 的 API 寫入要不要一起 journal？**

- (a)【建議】**這一刀不做**，保留 `api_routes.py:1130` 原本的「not journaled」。
  - 後果：範圍不擴大，健檢這幾格也不需要它。
- (b) 一起做。
  - 後果：Cut B／C 各多約 100 行。PRE 的身分是 group id，比 table entry 簡單。
- 其他：

## 9. 讀了什麼、沒讀什麼

- **讀了**：
  - `api_routes.py:360-470,740-960,1036-1132`；
  - `p4_client.py:40-220,438-510,1100-1400,1470-1530,1650-1870`；
  - `rule_journal.py` 全文；
  - `main.py:1-140,600-830,1613-1830,1955-2040,2270-2300`；
  - `topology_manager.py:314-345,615-640,1030-1110`；
  - `route_binding.py:1-80`，以及 grep 過的 owner 相關行；
  - `app_package.py` grep 過的行；
  - `preflight.py:25-62,150-290,455-500`；
  - PLAN-0917 §8.4；
  - 健檢 DESIGN §2.3、`expected_today.tsv`、`cells/table.py:300-365,915-930`、`s0.py` grep 過的行、PF-T fixture；
  - `ndtwin_switch.p4:329-347`；
  - `boot_identity.py:1-47`；
  - `stack.sh:1060-1092`；
  - tutorials 的 `helper.py:85-125`、`simple_controller.py:145-185`；
  - 記憶檔 `replace-vs-add-bug-shape.md`。
- **觀測了**：venv 的 p4runtime 1.5.0 descriptor；`libpifeproto.so.0`、`libbmpi.so.0` 的 `strings`；兩個 `simple_switch_grpc` 的 `readelf -d`。**都沒有執行。**
- **沒讀**：
  - P4Runtime spec 原文；
  - PI 原始碼（只看了已安裝 binary 的字串）；
  - `ndt` 的 `up_p4`（`ndt:3227` 起）；
  - `p4_power_helper.py` 的 on 路徑；
  - `test_table_entry_route.py` 假 client 的 binding。
  - Q1 (a)／(b) 與 Q2 (a) 的代價都繫於這三處，Cut C／A 動手前要先讀。
- **已知的分歧，這一刀不處理**：pre-flight 的 `encoded_width` 比 writer 的 `encode_value` 寬鬆（IPv6、任意字串），exact/lpm 的值可能 pre-flight PASS、上線卻是 400。
