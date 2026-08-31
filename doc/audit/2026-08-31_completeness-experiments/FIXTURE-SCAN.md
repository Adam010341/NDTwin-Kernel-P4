# Fixture 掃描：每一個 force，注入點在基線之前還是之後？

[Co-developed with claude code -- Adam]

**為什麼有這份**：同一個 fixture 缺陷已出現**兩次**（`lib_e.sh` 早上修、`run_f5.sh` 沒鏡射，
下午被步驟 5b 抓到）。**一個缺陷出現在兩個檔案，就要假設有第三個。**
對兩輪的**全部** force／fixture 逐一問同一個問題：

> **這個強制值，是套在「基線已經存在之後」，還是套在「會變成基線的那次讀數」上？**

答案是後者的，那個 force **看起來完全正常而實際上零鑑別力**。
**零命中也逐項列出**——今天已經有兩次「零命中被誤讀成沒有」的紀錄。

## 掃描結果：找到第三個實例，而且它比前兩個嚴重

| force / fixture | 輪 | 注入點 | 基線已存在？ | 判定 |
|---|---|---|---|---|
| `bootid` | E | `assert_same_boot` | ✅ 有守衛 | 已修（早上） |
| `bootid` | F-5 | `assert_same_boot` | ✅ 有守衛 | **本次修**（步驟 5b 抓到） |
| `edgecount` | E | `assert_topology_invariant` | ✅ 有守衛 | 已修（早上） |
| `edgecount` | F-5 | `assert_topology_invariant` | ✅ 有守衛 | **本次修**（步驟 5b 抓到） |
| 🔴 `exedrift` → **括號 open/close** | **E ＋ F-5** | `running_kernel_sha` | ❌ **兩端被強制成同一個值** | 🔴 **第三個實例，本次修** |
| 🔴 `exeunreadable` → **括號 open/close** | **E ＋ F-5** | 同上 | ❌ **`assert_running_arm` 先跑先中止，括號從未被抵達** | 🔴 同上 |
| `claim` | 兩輪 | preflight 比對 owner | n/a（狀態檢查） | 有效 |
| `fabric` | 兩輪 | reader 是否答話 | n/a | 有效 |
| `fabricup` | E | baseline 模式的拒絕支 | n/a | 有效 |
| `staged` | E | staged binary 存在性 | n/a | 有效 |
| `iperf3` | E | 外來 iperf3 列舉 | n/a | 有效 |
| `restore` | 兩輪 | `assert_*_restored` 的各項斷言 | n/a | 有效（且紅綠雙向都驗過） |
| `recompute` | E | `assert_recompute_running` | n/a | 有效 |
| `fabricshort` | F-5 | `assert_fabric_complete` | n/a | 有效 |
| `config` | F-5 | `assert_sampling_config` | n/a | 有效 |
| `--force-zero` | E | `recompute_rate.py` | n/a | 有效 |
| `--compare` ×3 | E | 跨臂比值規則 | n/a（讀兩個檔） | 有效 |
| `--make-forcered` | E | `ratio_gate.py` | n/a — **前後各斷言一次**（來源必須先綠、產物必須後紅） | 有效 |
| `--dry-scenario` ×3 | F-5 | `f5_sampler.py` 的 FakeFabric | n/a — POST 前的 control 是前置條件不是基線 | 有效 |
| `baseline_range_check` ×3 | E | fixture 檔 | n/a | 有效 |
| build gtest expect pass/fail | E | `build_1khz_binary.sh` | n/a（真跑 ctest） | 有效 |
| 🟡 `--record-baseline` **本身** | E | CPU 基線寫檔 | — | **無法 force**，見下 |

## 第三個實例：括號**不是測不到，是從未被執行**

前兩個實例是「force 什麼都沒測」。這一個更糟——**兩種獨立的方式讓它零覆蓋**：

1. **`exedrift` 把兩端強制成同一個值** ⇒ 就算抵達，比較的也是**兩個相等的值**
   ⇒ 從未證明它能偵測「不同」。
2. **`assert_running_arm` 先跑、先中止** ⇒ 括號**根本沒被抵達**。
   實測：`DRY_FAIL=exedrift` 的中止來自 `ABORT(§4 running-arm)`，不是括號。

⇒ 新增 **`DRY_FAIL=exedriftmid`**：**只有收尾那次讀數漂移**，開頭那次是對的
（所以 `assert_running_arm` 通過、括號被真正抵達，而 open ≠ close）。兩輪皆已落地並實測：

```
E   ABORT(identity): ... the running kernel changed mid-cell (b000…0 -> d000…2)
F-5 ABORT(§4 F4):    ... the running kernel changed during arm q1-p4-post (a000…0 -> d000…2)
```

🔑 **修法本身第一次也是錯的，而且錯得一樣**：初版用**數讀取次數**（`> 1`）觸發漂移，
但 E 每格讀三次（身分檢查／open／close）、F-5 讀兩次 ⇒ **數字與呼叫點耦合**，
E 那邊靜靜地沒有觸發。改成**由呼叫端標記階段**（`_DRY_PHASE=close`）——
那才是 fixture 真正的意思：「binary 在 open 與 close 之間變了」。
**這是同一天內第四次「fixture 自己沒有鑑別力」，而它是在「跑一次看看」時現形的，不是在讀碼時。**

## 唯一無法 force 的一項（誠實列出，不假裝有覆蓋）

🟡 **`--record-baseline` 自己**：若錄基線的當下就有外來負載，那個負載會被**永久吸收進基線**，
之後不再是「超出量」。**沒有辦法 force 它**——錄基線的那一刻，定義上還沒有一個「乾淨」的參考
可以對照。

- **已有的緩解**：§0-ter 要求基線取 **≥3 次並記全距**，全距逼近門檻就揭露。
  但那只抓得到**變動**的污染，抓不到**恆定**的污染。
- ⇒ **這是申報過的限制，不是覆蓋**。PREREG-E §0-ter 的「不可偵測區間 0–0.5 核」已涵蓋它。

## 掃描的邊界（下一個人要知道我沒查什麼）

只掃了兩輪自己的 force／fixture。**沒有**掃：`measure.sh`、`cell_verdict.py`、
`traffic_mesh.sh`、`tr3_f5_window.py` 等**重用的既有儀器**內部的 fixture
——它們不是本輪寫的，且改它們會分叉儀器（見 KNOWN-ISSUES 的 `pkill -f` 兩難）。
**若要擴大範圍，那是另一張單。**
