# F1 force 測試證據（auditor 的附條件：新條款自己要先見過紅）

**做於**＝機器 1（Adam 筆電），claim `poster-reviewer-F1-forcered` 15:49–16:0x，
`ndt up 4` → 測 → `ndt down`（回報 `clean`）→ `release`。
**override 檔全程未被修改**（`cmp` 驗過）。**零量測、零效能數字。**

## 一、check 自身的五紅一綠（`arm_binary_assert.sh --selftest`）

| 強迫的失效模式 | 要求 | 實得 |
|---|---|---|
| 跑的是別顆 binary | rc=10 | ✅ 10 |
| 空 pid | rc=11 | ✅ 11 |
| pid 不存在 | rc=11 | ✅ 11 |
| expected 檔不存在 | rc=13 | ✅ 13 |
| exe 讀不到（pid 1） | rc=12 | ✅ 12 |
| **綠燈且理由正確**（輸出須含完整 64 hex） | rc=0＋hash | ✅ |

## 二、對**真實執行中的 switch** 測——結果是紅，而這一紅比綠更有價值

對 `ndt up 4` 起的活 switch（pid 1288033，四顆之一）跑檢查：

```
ABORT[12]: cannot read /proc/1288033/exe even with sudo -n (permission, or process gone)
```

診斷（逐項查過，非推論）：
- **pid 存在**（`/proc/1288033` 在）；
- **switch 以 root 執行**，本 uid 讀不到其 `exe` 連結——**此限制已在案**：
  `FINDINGS-1b.md:184`「kernel-verified, because this uid cannot read a root process's
  exe link. AMENDMENT-1 §8.5」；
- **`sudo -n readlink` 要密碼**（免密碼白名單不含它）⇒ 提權路徑在機器 1 上不可用；
- 而 **`ps -eo args` 看得到 argv**＝`/usr/local/bmv2-fast/bin/simple_switch_grpc`。

🔑 **兩個收穫**：
1. **檢查在「看不到」時中止，沒有掉回綠燈。** 這正是 auditor 要求先見紅的理由——
   一個有沉默失敗模式的檢查只會把缺陷往上搬一層，而這個沒有。
2. 🔴 **argv ≠ exe，而機器 1 上只拿得到 argv。** study 自陳「②③＝argv＋fabric 連續性、
   較弱」的根因就是這個：**argv 是「被要求跑什麼」，exe 是「正在跑什麼」**，
   換掉磁碟上的檔案不會改變 argv。

## 三、由本測試賺到的 prereg 收緊（v1.2 候選，交 auditor）

> **若 `/proc/<pid>/exe` 不可讀，該臂作廢——argv 不是可接受的替代品。**

nslab guest 已驗**免密碼 sudo 可用**（bootstrap 時實測），所以 B 輪跑的那台**具備**強檢查
的條件；機器 1 不具備。⇒ **強檢查要在 B 實際執行的機器上做，不是在這台。**

## 四、尚未執行：RED-B（F1 的端到端失效模式）

原計畫＝改寫 `bmv2_binary_override` 指到另一顆 → 重起 fabric → 臂仍期待自己那顆 ⇒ 應紅。
**在機器 1 做不出有意義的結果**：exe 讀不到，任何情況都會停在 rc=12 而非 rc=10。
⇒ **改排在 nslab（B 實際執行處）**，作為上機後、正式臂前的最後一道 force。

## 五、附帶抓到的兩個 harness 缺陷（都不是 check 的缺陷）

1. `pgrep -x simple_switch_grpc` **恆零命中**——comm 上限 15 字元（`ndt:44` 記過同一坑）；
   `pgrep -f` 禁用（會自我匹配）⇒ 改為直接走 `/proc/*/comm` 比對 `simple_switch_g`。
2. 第一版把 pid 探測寫在 harness 而非 check 裡，探測失敗時 **check 回 rc=11「沒有 pid」**
   ——**又一次沒有假綠**。

[Co-developed with claude code -- Adam]
