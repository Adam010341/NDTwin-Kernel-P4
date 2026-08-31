---
name: ntg-bmv2-support-pending-feature
description: "✅ 已交付(2026-08-15):bridge `p4_proxy/mininet/ntg_bmv2_topo.py` 讓 NTG 驅動 bmv2,live 驗證通過;地雷圖在這裡。⚠️ 08-16 改判:『計數器洩漏』不存在=fixed 流維持性重啟尾巴(收尾預算 interval+fixed_duration),NTG 上游缺陷實剩 2 條"
metadata: 
  node_type: memory
  type: project
  originSessionId: 19a77e0e-d762-431b-a3fd-4128ec1fcd85
  modified: 2026-08-19T15:47:55.865Z
---

原始問題(2026-08-15 晨):NTG 只有 OVS 入口。**當天傍晚交付並 live 驗證**:
bridge(重用 p4_testbed_topo 類別 + `command_line(net)`)+ 低速率 template
`flow_bmv2_low.json`,NTG 的 TCP/UDP 流真實跨 bmv2 完成、kernel 同時看見 39 條 flow。

**通關前踩掉的四顆地雷(依殺傷力排序,細節在矩陣文件 2026-08-15 下午節):**

1. **P4 測試床 host 從未關 NIC offload → bulk TCP 從拓撲誕生起就不通**(bmv2 pcap 逐 byte
   轉發、checksum 未填即被對端丟;握手過、資料卡零)。五週未爆=P4 側歷來只測 UDP/ICMP。
   修復 `disable_host_offloads()` 進共用 topo 基座(`c97d9e2`)。**串接測試的教科書案例。**
> 🔑 **2026-08-19 補上這條的「所以呢」:fixed flow 的 `duration` 要設短,不要接近 interval。**
> 我寫 demo config 時設了 `interval 5m` ＋ `duration 280s`,結果 NTG 在第一批 fixed 流跑完後
> **立刻補上第二批完整的 280 秒**,prompt 卡在
> `Waiting for all connections to be restored, currently running host pairs: 3` 直到第 580 秒。
> **知道這個行為還是踩了**,因為上面那條寫的是「收尾預算」而沒寫「所以 duration 要短」。
> ✅ 正解:**duration 設 20 秒**,靠重啟維持連續流量,尾巴最多 20 秒。
> 診斷法(判斷「卡住」還是「還在跑」):`ps -eo pid,etimes,args | grep '[i]perf3'`,
> 比對它的 `-t <duration>` 與已跑秒數——差幾秒就是快好了,不是當機。

2. ~~**NTG 失敗流洩漏 RUNNING 計數器**~~ → **❌ 2026-08-16 凌晨改判:洩漏不存在**。
   「排水卡 3」的真機制=**fixed_traffic 維持性重啟**:fixed 流結束就重啟以維持數量,
   最後一代跑滿自己完整 duration → 270s 設定下 300s interval 實際 ~570s 收尾。同 fabric
   重測兩輪都自我善終(counter→0、`Experiment completed`、prompt 回歸,零失蹤;
   重啟造成新 5-tuple 佐證)。08-15 的「永久卡住」=沒等完尾巴就人為中斷。
   「~1% 遺失」作廢;錯誤路徑回呼與 SIGINT 吞沒降級為單次觀察待重測。
   **收尾預算=`interval + fixed_duration`,等它自己 complete,別急著判死。**
   upstream 稿第 1 條已改寫(投遞前 Adam 重裁);矩陣 #20 加更正橫幅。
3. **NTG 空距離桶=randrange(0) 全工具崩潰**;本 fabric 分類真相:**全部 pair 落 far**
   (兩種路徑長 {3,5} 被 3-way k-means 分成 far 獨大)——template 必須 far:1.0。
4. **NTG `command_line` 不可重入**(loguru remove(0) 單發)→ bridge 裝甲重入前要 no-op
   其 logger_config + 崩潰預算防熱轉。

**操作規則**:一次一個 actor(energy 整併 vs NTG 起流的 race 讓首輪 iperf 全夭折);
NTG 卡死時 SIGTERM bridge 全家再重開(topo 開場自掃殘骸)。
**08-16 補**:①`topo-out N` 只抓 pane 可見尾段(取樣縫隙會漏錯誤行)——要完整歷史用
`topo-out 3000` 拉整個 scrollback;②upstream 稿三條已定稿(`bb9aa7e`):#1 降級
docs/UX(kill 風暴 183/183 全走完成路徑+SIGINT 12s 乾淨退場,缺陷主張全不重現)。
**自動化**:`tools/test_workflow/ndtwin-lab`(root tmux wrapper,含 topo-cmd 打字進 NTG)
寫好未 commit,等 Adam 過目安裝;裝好後全流程 agent 自駕。

相關:[[cross-repo-component-ecosystem]]、[[ndtwin-official-docs-site]]、
[[arithmetic-that-fits-is-not-the-mechanism]](k-means 桶方向猜反那課)
