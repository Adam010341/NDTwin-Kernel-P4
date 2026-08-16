# NTG 缺陷回報稿(給 NTG 維護者,2026-08-15)

> **內部前言(投遞前刪)**:Adam 2026-08-15 晚裁決「NTG 三條正式回報」的執行稿。
> 三條都是 2026-08-15 把 NTG 接上 bmv2 fabric 實測時抓到的(NTG 本身零修改,經
> `p4_proxy/mininet/ntg_bmv2_topo.py` bridge 驅動);其中 #1/#3 與 fabric 種類無關,
> 在 NTG 自家 OVS 拓撲上也會發生。完整脈絡在
> `doc/2026-08-14_cross-component-integration-matrix.md`「NTG×bmv2 結案輪」節。
> docs 站的兩條 errata(Ryu port 6653、testbed_topo 直譯器)走另一包(隨 bmv2 手冊
> 條目一起),不在本稿。

---

## 回報:三個 NTG 缺陷(附重現步驟與量化證據)

環境:NTG 於 Mininet 模式驅動一個 10-switch bmv2 fabric(4 host),
`flow --config` 跑 303 個 connection 的實驗,2026-08-15。NTG 程式碼未做任何修改。

### 1. ⚠️ 主張大幅縮水(2026-08-16 凌晨重測)——「計數器洩漏」是誤讀,投遞前要 Adam 重裁

> **更正紀錄(2026-08-16)**:本條原主張「成功輪也漏 ~1%(303→3 永卡)、實驗不會
> 自我善終」。當夜對同一 fabric 重跑同構實驗(varied 1 flow/s + fixed 3×8M,300s
> interval)兩輪,**兩輪都完整自我善終**:計數器排水到 0、印出 `Experiment completed`、
> 提示符回歸,零流失蹤。「卡 3」的真機制是 **fixed_traffic 的維持性重啟**:fixed 流
> 結束時 NTG 會重啟它以維持數量(「waiting for all connections to be restored」的
> 字面意思),最後一代在 interval 結束前才起跑、還要跑滿自己完整的 duration——
> 270s duration 的設定下,300s 的 interval 實際要 **~570s** 才收尾(實測 02:41:41
> interval 結束 → 02:45:47 完成,與 270s 尾巴吻合到秒級)。08-15 的「永久卡住」
> 是在尾巴走完之前就人為中斷所致,「3 無聲失蹤」= 還在合法運行的最後一代 fixed 流。
> 「~1% 遺失率」的統計基底既然是這 3 條,一併作廢。

**尚未被推翻、但降級為「單次觀察,機制未確認」的兩件**(2026-08-16 重測時無流量錯誤
發生,無從檢驗):
- 錯誤路徑(iperf3 連不上對端)是否跳過完成回呼——08-15 曾見 4 條有錯誤訊息的流,
  但依當晚「卡 3」的對帳,那 4 條**有**遞減,反而不支持原機制主張。
- 等待期間 SIGINT 被吞(只能 SIGTERM)——若等待本身是合法尾巴,這仍是個獨立的
  可用性問題(等待迴圈不響應 Ctrl-C、也不印還剩哪些流/還要多久),但需針對性重測。

**可轉為文件性建議的部分**:interval 結束不等於實驗結束——fixed 流的最後一代會跑滿
duration,收尾預算是 `interval + fixed_duration`。這個行為完全沒有文件記載,等待訊息
也不說明在等什麼,值得回報為 docs/UX 缺陷(等待迴圈印出剩餘流清單與預估時間)。

**投遞裁決(Adam)**:本條要嘛降級為 docs/UX 回報,要嘛先做針對性重測
(關掉一個目標 host 逼出錯誤路徑)再決定。原三條裡的 #2/#3 不受影響。

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
  已在我方修復(`c97d9e2`),與 NTG 無關——但 NTG 的 iperf3 實驗是把它逼出來的功臣。
- 官方文件站的 NTG 頁有兩處與實際不符(Ryu 監聽 port、testbed_topo 的直譯器),
  另包投遞 docs 維護者。
