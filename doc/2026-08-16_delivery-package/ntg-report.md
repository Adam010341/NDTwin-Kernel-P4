# NTG 缺陷回報:三個缺陷(附重現步驟與量化證據)

環境:NTG 於 Mininet 模式驅動一個 10-switch bmv2 fabric(4 host),
`flow --config` 跑 303 個 connection 的實驗,2026-08-15。NTG 程式碼未做任何修改。

### 1. 【docs/UX】interval 結束 ≠ 實驗結束——fixed 流的重啟尾巴無文件記載,等待訊息不透明

**現象**:`fixed_traffic` 以「維持 N 條」語意運作——fixed 流結束就重啟以補足數量,
最後一代在 interval 結束前起跑、跑滿自己完整的 duration。**收尾時間實際是
`interval + fixed_duration`**(270s duration + 300s interval 實測 ~570s 才
`Experiment completed`,誤差秒級)。這個行為沒有任何文件記載,而收尾期的
「waiting for all connections to be restored: N」不說明在等哪些流、還要多久——
使用者(包括我們)會把合法尾巴誤判成 hang 而人為中斷。

**建議方向**:①文件明載 fixed 流的重啟語意與收尾預算②等待訊息印剩餘流清單
(host pair/port/預計結束時間)。

> **調查紀錄(給維護者的誠實註腳,也是我們自己的更正)**:我們最初把這個尾巴
> 誤讀成「完成回呼洩漏、計數器永卡」。針對性重測(2026-08-16)三項全數無法重現:
> ①兩輪同構實驗完整自我善終(counter→0、prompt 回歸);②實驗中途以 45 秒
> kill 風暴打死途中所有 iperf3(process-death + connection-refused 兩類錯誤),
> 183/183 全走完成路徑、counter 照常排空、實驗照常善終——錯誤路徑**不會**漏
> 遞減;③對等待中的 NTG 送 SIGINT,12 秒內乾淨退場。原「洩漏/死鎖」主張撤回。

**重現(尾巴行為)**:任何 `fixed_traffic` 配置,`duration` 接近 `interval_duration`
時最明顯;掐錶對照 interval 結束與 `Experiment completed` 的時間差。

### 2. 距離分桶為空時,flow 指令直接崩潰(randrange(0))

**現象**:`_handle_flow_command` 從距離桶(near/middle/far)抽 connection 時,
對空桶做 `randrange(0)`,無驗證、無錯誤訊息,整隻工具直接 traceback 崩潰。

**成因場景(實測)**:host pair 的路徑長度分佈太集中時,3-way k-means 會產生空桶。
我們的 4-host fabric 只有 {3,5} 兩種路徑長度,分類結果 far 獨大、near/middle 皆空
——任何要從 near/middle 抽樣的 flow config 立即崩潰。這不是 bmv2 特有:任何小型或
均質拓撲都會踩到。

**重現**:4 host、路徑長度只有兩種的拓撲 + 預設 flow config。

**建議方向**:抽樣前驗桶非空;空桶給出可讀錯誤(哪個桶空、分類分佈長怎樣)而不是
traceback;或 k-means 的 k 隨距離種類數自適應。

### 3. `command_line()` 不可重入(loguru remove(0) 單發)

**現象**:`command_line()` 進入時的 `logger_config` 呼叫 loguru 的 `remove(0)`;
handler 0 只在第一次存在,第二次呼叫在還沒到提示符前就死(network_traffic_generator.py
line 307 附近)。單一進程內想重回 NTG 提示符(例如上層想在 crash 後恢復 CLI)不可能。

**重現**:同一進程呼叫 `command_line(net, config)` 兩次。

**建議方向**:`logger.remove()` 改為冪等(remove 全部或 try/except),或 logger 設定
移到模組層只做一次。

---

### 附:與 NTG 相關但屬別處的兩件(供知悉,不需 NTG 動作)

- bulk TCP 在 bmv2 fabric 上不通的問題,根因是我們 P4 測試床的 host 未關 NIC offload,
  已在我方修復,與 NTG 無關——但 NTG 的 iperf3 實驗是把它逼出來的功臣。
- 官方文件站的 NTG 頁有兩處與實際不符(Ryu 監聽 port、testbed_topo 的直譯器),
  另包投遞 docs 維護者。
