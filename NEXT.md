# NEXT：viz orphan 的修法，**現在有實測輸入了**（G-6 沒有修這個）

2026-09-03 05:10 寫。[Co-developed with claude code -- Adam]
**這個 commit 可以單獨 drop，不影響 G-6 的修法。**

---

## 為什麼在這裡

G-6 的 `RATIONALE.md` 有一節「這支分支**沒有**修什麼」——viz 的 orphan JVM
（`ADDENDUM-01-viz-orphan-contamination.md`：1h54m、111% CPU、875 MB log，
而三個通道全說沒在跑）。當時修法方向指得出來，但**缺一個事實：存活 JVM 的完整 argv**，
所以標成推測、寫明「要 L6 驗過才能當修法依據」。

**L6 的輸入到手了**，在第三輪測試裡：
`doc/audit/2026-09-03_night-rounds/round3-restart-concurrency/14_viz_process_chain.log`（已 commit）。
**下面每一條都是我親自讀那份 log 得到的，不是轉述。**

## 🔴 先更正我自己一個錯誤

我先前從 launcher 的內容推導出**四層**（`launcher.sh → mvnw → maven JVM → app JVM`）。
**實測是三個 process**：

```
[depth 0] pid=1320231  comm=network_traffic  rss=3MB    /bin/bash ./network_traffic_visualizer.sh
[depth 1] pid=1320234  comm=java             rss=214MB  .../java -classpath /home/adam/Network-Traffic-Visualizer/.mvn/wrapper/maven-wrapper.jar ...
[depth 2] pid=1320294  comm=java             rss=318MB  .../java --module-path /home/adam/Network-Traffic-Visualizer/target/classes:...
```

`./mvnw` 是 shell script，它 **exec 進 java**，所以不留下自己的 process。
⇒ **我從腳本文字推導行程結構，而行程結構要用量的。**
這正是我整晚在標的那個錯誤，我自己犯了一次；記在這裡而不是刪掉，因為
**下一個人也會想從 launcher 讀出鏈路長度**。

## 實測到的三個事實

**① 名字式 signature 在結構上找不到存活者。**

| 字串 | launcher (1320231) | maven JVM (1320234) | app JVM (1320294) |
|---|---|---|---|
| `network_traffic_visualizer.sh`（現行 `app_sig viz`） | 1 | **0** | **0** |
| `Network-Traffic-Visualizer`（**目錄名**） | **0** | **2** | **1** |

🔑 **launcher 自己 0 次**這點是關鍵：signature 必須挑一個**存活者才有**的字串。
用 launcher 的檔名，在結構上永遠找不到該找的東西——**因為要找的正是 launcher 死掉之後剩下的。**

**② 缺陷當場重現，rc 是 0。** 同一份 log：

```
  ok  viz stopped (was: running)
STOP_RC=0
  pid 1320231 gone
  SURVIVOR pid 1320234 comm=java rss=214MB
  SURVIVOR pid 1320294 comm=java rss=317MB
```

531 MB 活著，`ndt apps stop viz` 說 `ok`。auditor 回報同一輪的 `ndt apps orphans`
也答「沒有未追蹤的 app process」——**對 viz 而言兩個 witness 的鑑別力都是零**。
（`orphans` 那一句我沒在這份 log 裡讀到，是 auditor 轉述。）

**③ 孤兒已用精確 pid 清掉（SIGTERM 就夠）**——auditor 轉述，我沒讀到那段。

## 修法（兩個要素，都有實測支撐了）

1. **路徑式 signature**：`app_sig viz` 從 `network_traffic_visualizer.sh` 改成
   `Network-Traffic-Visualizer`（或該目錄的絕對路徑）。
   實測命中 2 個存活 JVM、不命中 launcher——**這正是要的方向**。
   ⚠️ 要一併想：目錄名出現在 `-classpath`／`--module-path` 裡，所以
   **任何 argv 提到那個目錄的行程都會命中**（例如一個開著該目錄的編輯器）。
   `pid_is_app`（`ndt:1683-1692`）現行規則是「某個 **argv 元素**等於 sig，或以 `/sig` 結尾」——
   目錄名是**路徑中段**而不是元素或結尾，所以**現行比對規則吃不下它**，要一起改。
   這是設計上的取捨，不是加一個字串就好。
2. **`app_spawn` 用 `setsid`／自己的 process group**，讓 stop 停得掉整棵樹。
   目前它只 TERM 一個 pid（launcher），子孫被 reparent。

## 順帶：一個我在讀那份 log 時發現的獨立缺陷

那份 log 裡有一行**洩到 stderr 的噪音**：

```
tools/test_workflow/ndt: line 1687: /proc/1320231/cmdline: No such file or directory
```

`ndt:1687`：

```bash
mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
```

**`2>/dev/null` 在 `<` 之後**。redirection 由左而右套用，所以開檔失敗的訊息在 stderr
還沒被轉走之前就印出去了——而這個函式的**全部意義就是那個 pid 可能已經不在**。
同族還有 `ndt:1999`、`ndt:2034`（`tr '\0' ' ' < ... 2>/dev/null`）。

**正確寫法**（我在 G-9 的 `ndtwin-lab` 已經這樣修，那裡的註解也記著同一個坑）：

```bash
mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || return 1
```

🔑 **這又是「同一個缺陷在一支潛伏、在另一支可見」**：`ndtwin-lab` 那份是我自己跑測試時看到的，
`ndt` 這份要等到一個行程剛好在掃描中途消失才會冒出來——而它今晚在一份 audit log 裡冒出來了。
**修 `ndt:1687` 不屬於 viz 那支修法，但屬於同一趟。**

## 給接手的人

- G-6 的 `RATIONALE.md` 有完整背景，含 L5／L6 的定義與「這支沒修什麼」。
- 🔴 **energy／sim 不受這個形狀影響**（兩個都是 ELF 執行檔，存活者自己帶 signature），
  但那是**結構論證不是實測**，殘差由 L5 關掉——L5 仍未做。
- 🔴 **不要順手改 `app_sig` 的比對規則而不改測試**：`tests/shell/test_ndt_app_orphans.sh`
  與 `tests/shell/test_ndt_apps_liveness.sh` 都綁著現行的「元素相等或 `/sig` 結尾」語意。
