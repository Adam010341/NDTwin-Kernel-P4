---
name: fabricated-switch-cpu-in-mininet-mode
description: "🔴 `/ndt/get_cpu_utilization` 在 MININET 模式回的是 `10 + hash(ip) % 50` 的假值——恆定、與負載無關、Web-GUI 直接顯示它。任何 CPU 主張都不能用這個端點"
metadata: 
  node_type: memory
  type: project
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-20T07:10:00.843Z
---

**Adam 2026-08-20 主動警告：「有一種 CPU 使用率是我們自己亂數編造出來的，注意不要用到那個數字。」**
查證後定位到 `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`。
🔴 **而且不只 CPU 一個——同一天稍後查出是三個**，全都在 MININET 分支：

| 端點 | 假值公式 | 值域 |
|---|---|---|
| `get_cpu_utilization` | `10 + hash(ip) % 50` | 10–59 |
| `get_memory_utilization` | `10 + hash(ip) % 50` | 10–59 |
| `get_temperature` | `25 + hash(ip) % 25` | 25–49 |

```cpp
if (m_mode == utils::DeploymentMode::MININET)
{
    cpu = 10 + (std::hash<std::string>{}(ip_str) % 50);
}
```

**Web-GUI 三個都在呼叫**（它呼叫的 12 個 `/ndt/` 端點裡就有這三個）。所以「裝置資訊」那一整塊
在實驗室環境下沒有一個數字是真的。**我原本只查了 CPU 就下結論，是 Adam 的用詞（「有一種」）
讓我以為只有一個**——查一個就該把同一個檔裡同形狀的鄰居一起查。

**它比隨機更危險，因為它穩定。** 隨機值會抖動、看起來可疑；這個是 IP 字串的 hash，
所以每台交換機**永遠回同一個數字**，看起來像一筆真實而平穩的量測。實測（fabric 閒置、
間隔 3 秒兩次呼叫）十台全部一字不差：`.11:14 .12:54 .13:36 .14:44 .15:39 .16:56
.17:25 .18:28 .19:52 .20:26`——全部落在 `[10,59]`。**跑滿流量也不會變。**

🔴 **Web-GUI 直接呼叫 `/ndt/get_cpu_utilization` 並顯示它**（在它呼叫的 12 個 `/ndt/`
端點清單裡）。所以畫面上的每台交換機 CPU% 都是假的。示範時不要指著它講。

TESTBED 模式走的是真的 SNMP（HPE5520 與 Brocade 各一組 OID），`-1` 是查詢失敗的哨兵值
（`DeviceInformation.tsx` 兩端都處理了）。**假值只在 MININET，而兩套實驗室 stack 都是
MININET**——也就是說我們跑過的每一輪，這個端點都是假的。

## 要量 CPU 只能自己讀 /proc

`tools/test_workflow/cpu_probe.py`（2026-08-20 寫的）讀 `/proc/<pid>/stat` 的
utime/stime 與 `/proc/stat`，這是唯一可信的來源。**2026-08-20 那輪的所有 CPU 數字都出自
它，沒有碰過那個端點**——但那是運氣好，不是我先查過。下次先查。

兩個順帶查到的 /proc 陷阱都寫進那支工具了：`/proc/<pid>/stat` 的 comm 可能含空白與括號
（要從最後一個 `)` 切），以及 `/proc/<pid>/comm` **15 字元截斷**讓
`simple_switch_grpc` 變成 `simple_switch_g`（同一天用 `pgrep -c` 沒加 `-f` 又踩了一次，
見 [[process-liveness-checks-lie-in-two-ways]]）。

相關：[[ndtwin-current-state]]、[[cross-repo-component-ecosystem]]（Web-GUI 的位置）、
[[bmv2-scale-ceiling-and-sflow-sample-math]]

**2026-08-20 補**：`10 + hash(ip) % 50` 在 **28b8b13 就有**（`DeviceConfigurationAndPowerManager.cpp:455/853/1110`，git grep 直接確認）——假數字是**繼承的**。報告裡歸屬要寫對：我們沒修它，但也不是我們發明的。
