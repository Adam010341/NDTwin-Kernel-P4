---
name: shell-outs-need-timeouts
description: "kernel 用 popen(curl) 做 HTTP;一個註解裡寫明「會問錯對象但沒關係」的呼叫,在 localhost 走 IPv6 黑洞時卡了 131 秒,把整顆 kernel 的 API 擋住"
metadata:
  node_type: memory
  type: project
  originSessionId: 50445b3c-51cd-4c3b-9364-d120dd6a72ff
  modified: 2026-08-21T08:35:22.886Z
---

2026-08-21 實查。症狀:`ndt up` 報 `kernel did not open :8000`,**但環境是好的**,
等一下再查就全綠。kernel 要 2-3 分鐘才開 port(以前約 1 秒)。

## 因果鏈(每一環單獨量過)

1. **kernel 不用 HTTP 函式庫,它 `popen("curl -s ...")`**
   (`utils::execCommand`,`include/utils/Utils.hpp:544`)。所以主執行緒卡在讀 pipe。
2. `main()` 在開北向 HTTP server **之前**呼叫 `collector->start()`,而它**同步**抓路徑
   → **`:8000` 被它擋住**。
3. 那個當下拓樸還沒載完,`controlPlaneHostAndPort()` 還是**預設的 Ryu `localhost:8080`**
   —— P4 模式下沒人在聽。
4. 🔑 **這台機器上 IPv6 loopback 的 SYN 被丟掉而不是拒絕**:

   | | 耗時 |
   |---|---|
   | `curl http://127.0.0.1:8080/x` | **0 s**(refused) |
   | `curl -4 http://localhost:8080/x` | **0 s** |
   | `curl http://localhost:8080/x` | **135 s**(timeout) |

5. 那行 curl **沒有 `--max-time` 也沒有 `--connect-timeout`**。

## 兩條可重用的教訓

🔑 **「已知會失敗」不等於「失敗很便宜」。** 那個函式上方的註解**早就寫明**第一次會問錯
對象、「gets nothing and returns」—— 作者知道會失敗,只是假設失敗是即時的。
**承認無害的失敗路徑,要量它的成本,不是假設。**

🔑 **`localhost` 和 `127.0.0.1` 可以差 131 秒。** 缺陷一直都在,環境只決定它花 0 秒還是
131 秒。查「為什麼突然變慢」時,先問**這一版跟上一版之間,機器改了什麼**,而不是只讀碼。

## 修法(commit `b539be7`,已重建 binary)

- curl 加 `--connect-timeout 2 --max-time 10`
- **刪掉 `start()` 裡那個同步呼叫** —— 它照註解自己的說法就不可能成功,
  唯一的效果是讓 kernel 在失敗期間不能用。刪掉之後第一次抓取變成 **5.7 秒、
  而且問對人**(`localhost:8081`),因為那時拓樸已經載完。

實測:`ndt up` 167 s＋報失敗 → **39 s** 成功,`:8000` 第一次 poll 就開。

## 同形狀但沒修(回報過,Adam 未裁決)

`TopologyAndFlowMonitor.cpp:472` 和 `:485` 的拓樸輪詢也是無逾時的 `curl -s -X GET`。
在背景執行緒上,所以同樣的黑洞位址是**分身資料變舊**而不是開機卡死 —— 比較小,
但缺的是同一個東西。

**抓法**:`ps -eo pid=,args=` 從 `/proc/<pid>/cmdline` 讀出那個 curl 的完整 argv,
再量它活多久。主執行緒卡在 `anon_pipe_read` 就是 popen 的簽名。

相關:[[arithmetic-that-fits-is-not-the-mechanism]]、[[ndt-one-command-lab-lifecycle]]。


## 第二式（2026-08-24）：**可以從內部規避的 deadline 不是 deadline**

不是 shell-out，是同一族的另一面。`_await_host_discovery` 有 40 秒上限，寫得很清楚，
**而且完全沒有用**——因為它是**在兩次 poll 之間**檢查 deadline 的，而卡住的那次 poll
**永遠不會回到「兩次之間」**。

```python
while learned < expected and waited < deadline_s:   # ← 檢查點在這
    hub.sleep(1)
    learned = self._hosts_with_ipv4()               # ← 這一行可以永遠不回來
```

`_hosts_with_ipv4` → `get_all_host` → `send_request` → `reply_q.get()`，**Ryu 這條 request-reply
自己沒有逾時**。回覆方是另一個 app，那個 app 當時正卡在往我這邊的滿 buffer 發事件。兩邊都沒逾時
⇒ 環永久。08-24 的 USR2 dump 當場抓到這個 frame（`d1d973d` 修掉，包 `hub.Timeout`）。

🔑 **判準：寫下一個 deadline 之後，問「它保護的那個操作能不能在單次迭代內卡住？」**
能的話那個 deadline 是裝飾品。迴圈的檢查點只在迭代邊界，卡在迭代裡面它看不到。

相關：[[punt-window-host-learning]]（那個環的全貌）
