<!-- opus-judge a8ed6d7da8b264752 on feat/p4-roles-first-cut-0924 @ 57aae1bf; extracted verbatim from the agent transcript by orchestrator-0924 2026-09-24 -->

**Verdict：MERGE AFTER FIXES**

基線相關的主要宣稱，證據大致成立：
- NDTwin pipeline 的 WriteRequest 與 `/stats/flow` 不變，沒有 `roles` 的 package 載入、以及 convert 不帶旗標的輸出也不變。
- unbound 和 `owner: package` 的寫入回 501；宣告鏈路不通知 kernel；§2.4 入口兩個分支都看過紅。
- 變異閘門 108 個變異 0 存活。

但有三個問題要先處理：一個 SUMMARY 沒揭露、也沒有測試的行為缺口；一個只做了一半的契約閘門；幾處 SUMMARY 的說法和它自己的證據或碼不一致。都不用重寫，修完或由 orchestrator 裁定後就能併。

路徑縮寫：`WT`＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924`，`LOG`＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`，`SP`＝`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad`。

## 發現（依嚴重度）

**1.［中｜沒揭露、沒測］混合 fabric 上 readopt 一台 NDTwin 交換機，會把路由寫過宣告鏈路。**
- 呼叫鏈：`main.py:1336-1338` 以 `install_routes=ndtwin` 呼叫 → `topology_manager.py:1437-1438` 的 `install_initial_routes(only_dpid)` → `:1238` 在整張 `net` 上算路徑。
- 本刀在任何有外來交換機的 fabric 都 seed 了宣告鏈路（`main.py:1863`）。
- 所以：只要有一台 unbound，啟動時整個 fabric 都跳過 routes（`main.py:1838-1849`）；但那台 NDTwin 交換機 power-cycle 之後，會被寫進穿過 unbound 交換機的遠端路由。這正是 `main.py:1841-1845` 自己寫的 "a path half-installed"。
- 刀前這種 fabric 的 `net` 沒有交換機間的邊，refill 只寫得到直連主機。
- `test_readopt.py:859-928` 只測全外來的 fabric；D8 和 INFERRED 都沒提到這個情況。

**2.［中｜§2.2-1 只做了一半］字面常數閘門只查 5 個名字裡的 2 個。**
- 閘門 `test_route_binding.py:209-218` 只比對 `BASELINE.table` 和 `BASELINE.action`；`:223-237` 只看 p4_client 的寫入函式。
- 我自己 grep 的結果：
  - 表名和 action 名：在 BASELINE（`route_binding.py:110,112`）之外，程式碼裡只剩已揭露的 `p4_client.py:1695`。這部分成立。
  - match field `"hdr.ipv4.dstAddr"` 還在 `ryu_flow_stats.py:49`。那是 NDTwin 路由列讀回時用的 `FIELD_TO_RYU`，而同一個 renderer 的 action 已經改走 BASELINE（`:64-67`）。
  - 另外在 `p4_client.py:1648` 和 `topology_manager.py:197-198,222` 也有，但這三處是 flow_5tuple 的 key，可以辯。
  - `"dstAddr"` 只出現在 BASELINE；`"port"` 太常見，grep 沒有意義。
- 所以 D3 說「只有一個揭露的例外」，只對表名和 action 名成立。

**3.［中低｜證據不足］「fixture 是在 base 錄的」證據鏈少一環。**
- `SP/baseline_bytes.sh:20-26` 讓兩棵樹各跑「自己的」測試檔，跑完就把 at-d492 樹刪掉（`:32`）。
- 這證明了 d492a346 的常數等於 base 的輸出、HEAD 的常數等於 HEAD 的輸出，但**沒有證明 HEAD 的常數就是 d492a346 的常數**。
- 旁證：`SP/baseline_writes_clean.py`、`render.txt`、`conv.txt`、`pkgloads.txt` 和 HEAD 的常數逐字相同。但這些檔 SUMMARY 沒有引用、沒有出處標頭，而且放在共用的 session scratchpad，只能算參考。
- 比對的粒度：
  - WriteRequest 確實是序列化位元組比對（`test_p4_client_writes.py:1969-1970, 2102-2105`）。
  - `/stats/flow` 比的是 `json.dumps(sort_keys=True)`（`test_ryu_flow_stats.py:420-422`），不是 HTTP body 的位元組，key 順序變了看不出來。
  - convert 的 package.json 是重新序列化之後才算雜湊（`test_convert.py:800-803`）。
- 四類都是拿錄好的常數比對，不是測試時重推期望值，這點成立。

**4.［中低］`unrendered_entries` 的測試資料和它引用的 fixture 對不上。**
- 計數規則：只有 match 對得上 Ryu 詞彙的列才算（`ryu_flow_stats.py:307-313`）。
- `a_tag_row()`（`test_ryu_flow_stats.py:491-494`）宣稱是模擬 renamed fixture 的那一列，用的 key 是 `hdr.ipv4.protocol`；但 fixture 實際是 `hdr.ip4.proto`（`renamed_route/pod-topo/s1-runtime.json:69-71`、p4info `:41`）。
- 用 fixture 真正的 key，那一列既不列出也不計數，`unrendered_entries` 會是 0。M-R11 的殺手測試靠的是 fixture 永遠不會產生的列形狀。
- 這和 `ryu_flow_stats.py:258-260` 說的 "absent and counted" 不符；真實 exercise 的非路由表大多會被漏算。

**5.［低｜被 SUMMARY 自己的證據推翻］** §0 說「§3.4 每一支閘門都在最終 head 跑過而且綠」。
- 實際上 `merged_checks.sh` 沒有整支跑（D12）；改成七項逐項跑，這七項和 `merged_checks.sh:26-32` 完全對得上，替代本身是忠實的。
- tools 全套用真 `~/tutorials` 時是紅的（OBSERVED 3，base 也紅）。
- 另外 D12 說 `cd` 在第 18 行，實際是 `merged_checks.sh:20`。

**6.［低］external 模式。**
- `_refuse_write` 在綁定之前：成立（`p4_client.py:1879-1880 / 1958-1959 / 2004-2005`，變異 PC4）。
- 但 `/stats/flowentry/*` 沒有接住 `ControlPlaneReadOnly`，全檔也沒有 exception_handler，所以回 500，和 base 一樣，不是契約括號裡寫的 409。這點 D11 有揭露。
- HTTP 狀態碼從來沒被斷言：`test_route_binding.py:563-568` 只斷言例外會拋出。

**7.［低］capabilities。**
- 五個鍵和 §2.5-2 一致。
- `link_discovery:"none"` 的理由成立。D4、碼註解（`main.py:1094-1097`）、兩處測試（`test_switch_state.py:903-907`、`test_declared_links.py:305-309`）說法一致；但 §0 和 OBSERVED 沒提，附錄 A（G 的規格）也沒有這個值。另外 seed 因為任何原因拋錯（`main.py:1238` 是 broad except）也會得到 `"none"`，讀的人分不出是 external 還是 seed 失敗。
- D5 說「有 roles 綁定寫 package、沒有寫 unbound」，和碼不符：`main.py:1116-1118` 對任何非 None 的綁定都寫 `package`，包括 BASELINE。測試 `:903-907` 釘的正是「baseline→package」，會產生 `ipv4_route:"package"` 配 `binding_source:"baseline"` 的組合。

**8.［低｜證據不足］07 的自測。**
- L1–L6 對 §5 的逐條實作成立：L4 hold 40 秒在 `07_roles_basic.sh:611-614`，L5 兩頭都驗在 `:655-671`。
- 「看過紅」只有 13 個判定函式裡的 5 個（`SP/live07_mutants.py:13-25`）。
- 有些檢查拿掉之後自測照樣 PASS：
  - `refused_501` 的反例 fixture 只改了狀態碼（`:389`），拿掉 reason 或 outcome 的檢查不會紅。
  - `dispatch_refused_unbound` 拿掉 `"unbound"` 子字串（`:257`）也不會紅。
- L5 的探針目的地是 10.0.9.9（`:57-58`），不是作者的 /32，所以沒有演練「同一 /32 被悄悄 MODIFY」這個 hazard。

**9.［資訊｜成立，附但書］變異閘門。**
- `LOG/mutate_roles_binding.p4r-57aae1bf.log` 證實 108/0、C1 和 C2 綠、159/159、M-R1 紅了 13 顆。
- 殺手測試只用方法名比對（`mutate_roles_binding.sh:157`）；我確認過這些名字都是唯一的，所以歸屬成立。
- `NEW_CLASSES` 是手打的清單（`:64-82`），和 OBSERVED 4 說的「不是手打」不完全一致；我用類別行號比對 base 和 HEAD，新類別都在清單裡。
- M-R1 的 renamed-only 檢查是字串比對，但我逐顆讀了那 13 顆測試，都確實用了 renamed_route。
- PF11 拆成 PF11/PF12 的解釋和 `preflight.py:465-478` 相符。
- anchor checker 對這支閘門回報 ok(106)，閘門裡是 110 個 mutant()；這不影響結果。

**10.［資訊］SUMMARY 沒提到的未跑閘門。**
- `mutate_a7_dispatch_status.sh` 的錨點在 `api_routes.py`（`:50`），這是本工單改過的檔，而且它有不用建置的 `--python-only` 模式（`:31`），卻沒跑。
- `mutate_ndt_app_package` 裡的 sudo 是 stub（`test_ndt_app_package.sh:217`），所以 `final_gates.sh:77-80` 說它「會呼叫 sudo」不準；不過它變異的是 ndt，和 R 無關。

**11.［資訊］fail-open 的殘餘風險。**
- 類別預設值（`p4_client.py:260`）和 `__init__`（`:429`）都綁 BASELINE。任何繞過 `build_p4_client` 的建構點，都會對外來 pipeline 寫字面常數，也就是這張工單要修的 bug。
- 目前 production 唯一的建構點是 `main.py:245`。這個設計是被「不准改既有測試」逼出來的，可以接受，但應該記名揭露。

**12.［資訊］所有權與口徑。**
- 用工單標記 grep 加上 §7 的 diff stat，沒發現 §0-9 以外的 production 變更（我沒跑 git，不能完全排除）。
- D7（external 不 seed）是對 §2.3-1 的窄讀，需要裁定。
- 主 checkout 的 `host_count_override` 有未提交的修改（4；worktree 是 128），所以「主 checkout 的相同檔案＝base」對這個檔不成立。我拿來當 before 比對的 proxy_agent 檔都沒有未提交修改。

## SUMMARY 各宣稱的判定

| 宣稱 | 判定 |
|---|---|
| §0 §3.4 全綠 | CONTRADICTED（見 5） |
| §0 108/0、控制組、159、M-R1 13 顆 | SUPPORTED |
| §0 口徑 | SUPPORTED |
| §0 §2.4 入口存在、未接線 | SUPPORTED（grep 確認無呼叫者，加上 TM10） |
| OBS1 四類 fixture 兩棵樹都綠 | SUPPORTED |
| OBS1 HEAD 常數是 base 錄的 | UNDER-EVIDENCED（見 3） |
| OBS1「無 roles 逐位元不變」當作行為宣稱 | 過寬：外來無 roles 的 `/stats/flow` 會漏列未知 action，D1 也承認 |
| OBS2、5、8、9 | SUPPORTED |
| OBS3 base 也紅 | SUPPORTED；「別人重編的」是推論 |
| OBS4 | SUPPORTED（「不是手打」一句小誤） |
| OBS6 | SUPPORTED；basic 那一行沒有 log，由 `test_convert.py:1075-1086` 在 fixture 副本上佐證 |
| OBS7 | 5 個判定 SUPPORTED；「每個檢查」UNDER-EVIDENCED |
| OBS10 | SUPPORTED；`_withmodel` 兩份 log 不是 `final_gates.sh` 產的（標頭格式不同），不受它的 HEAD 重驗保護 |
| INFERRED 1–6 | 標示正確；INFERRED 6 的讀碼我覆核一致 |
| §5 變異表、§6、§7 | SUPPORTED（7722＝7610＋112，34 個檔） |
| D17（行號抽查） | SUPPORTED（逐一在 base 抽查過） |
| D19 | SUPPORTED |
| D3、D5 | CONTRADICTED（見 2、7） |
| D12 | 內容 SUPPORTED；行號錯 |

## 我會跑、報告沒跑的測試
- 拿 d492a346 的四個 fixture 測試類別跑 HEAD 的 production 碼（或 diff 四個常數區塊）。
- NDTwin client 的 `/stats/flow` 以實際 HTTP body 位元組比對。
- 混合 fabric、有一台 unbound，readopt NDTwin 交換機後不得寫入遠端路由（見 1）。
- 用 fixture 真正的 `hdr.ip4.proto` 列測未知 action 的計數（見 4）。
- 外來交換機上 5-tuple 的 delete/modify 走 HTTP 回 501（目前只測 add 和 client 層的 insert）。
- external 模式 `/stats/flowentry/add` 的 HTTP 狀態碼斷言。
- 07 其餘 8 個判定的變異，以及拿掉 reason、`"unbound"` 子字串、`is_enabled` 各一個子條件變異。
- L5 改成打作者的 /32（例如 s1 上的 10.0.1.1 換 port）的版本。
- `mutate_a7_dispatch_status.sh --python-only`。
- 字面常數閘門擴到 match field（或請 orchestrator 裁定閘門只管表名和 action）。

## 報告內部不一致
- §0「全綠」和 D12、OBSERVED 3 矛盾。
- D12 寫第 18 行，實際是第 20 行。
- §4 表「最後一行」寫 `Ran 1520, OK (skipped=1)`；`final_gates_run2.log:1` 顯示實際最後一行是 ResourceWarning。
- OBSERVED 4「不是手打」和 `NEW_CLASSES` 是手打清單不符。
- D3、D5 和碼不符（見 2、7）。
- OBSERVED 6 裡混了一筆沒有 log 的觀測。
- 數字本身都對得上：108＝17+16+5+17+10+4+5+11+11+12；diff stat 合計一致。
