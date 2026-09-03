# 待辦工作項目

Adam 交辦、但還沒有 session 在做的事。**這個 build 沒有 `TaskCreate`／`TaskUpdate`**（工具集裡不存在），
所以待辦放在這裡，不放在某個 session 的腦裡——那樣 Adam 看不到，session 一結束也就沒了。

一件事開工之後，把它從這裡移到它自己的分支／文件，並在這裡留一行指過去。

[Co-developed with claude code -- Adam]

---

## W-1 — 在 NDTwin 上跑 p4lang/tutorials 的 exercise 1–5

**來源**：教授交辦，Adam 2026-09-03 轉達，並指定「你自己決定什麼時候做」。

**材料已經在機器上**：`~/tutorials`（p4lang/tutorials，13 個 exercise）。不需要重新 clone。

### 「1–5」是哪五個 —— 這個要 Adam 確認

`~/tutorials/README.md` **不是平面編號**，它分成四個主題群。照 README 由上而下取前五個是：

| # | exercise | 主題群 |
|---|---|---|
| 1 | `basic`（Basic Forwarding） | 1. Introduction and Language Basics |
| 2 | `basic_tunnel`（Basic Tunneling） | 1. 同上 |
| 3 | `p4runtime` | 2. P4Runtime and the Control Plane |
| 4 | `flowcache` | 2. 同上 |
| 5 | `ecn` | 3. Monitoring and Debugging |

⚠️ 教授說的「1–5」也可能是指**第 1 群到第 5 個主題**、或課程投影片自己的編號。
**開工前先跟 Adam 確認一次**，這是唯一會讓整件事白做的分歧。

### 🔴 開工前一定要知道的四件事（不要重新踩一次）

正本：記憶 `p4lang-tutorials-as-local-control.md`（2026-08-13 實際用過）。

1. **exercise 目錄裡的 `.p4` 是編不過的填空骨架。** 完整版在各自的 `solution/`。
   要「跑起來」用的是 `solution/`，要「當練習做」才用骨架。
2. **教學拓撲（2–4 台）與我們的 topology JSON 不相容。** 這是整件事最大的一個決定，見下。
3. **它的 `utils/p4runtime_lib/` 對 bmv2 會卡死**：`MasterArbitrationUpdate()` 等回應，
   而 bmv2 對重複 election id 是直接殺 stream ⇒ 永遠等不到。要繞過它的 stream 封裝手寫低階 gRPC。
4. **它需要 `p4.tmp`，我們的 venv 沒有**——用 `/home/adam/p4dev-python-venv/bin/python`。

### 要 Adam 裁的：「在 NDTwin 上跑」是哪一層

這句話有兩個差很多的讀法，成本與產出都不同：

- **(a) 只跑 bmv2 管線本身**：用 tutorial 自己的 `make run`／Mininet，我們只提供機器與 bmv2 build。
  便宜、幾乎一定跑得起來，但**沒有用到 NDTwin 的任何東西**——證明的是工具鏈能用，不是孿生體能用。
- **(b) 讓 NDTwin kernel 管理它們**：要把每個 exercise 的拓撲翻成我們的 topology JSON、
  接上 p4_proxy、讓 kernel 認得那些 pipeline。**這才是有意義的那個**，但每個 exercise 的
  pipeline 不同（不同 table、不同 action），我們的 proxy 目前只認 `ndtwin_switch.json` 的表結構。
  ⇒ 這是一件**每個 exercise 都要單獨接線**的工作，不是跑五次同一個腳本。

**我的建議**：先做 (a) 把五個都跑通並存下 raw（成本低、而且是 (b) 的對照組——
沒有 (a) 的話 (b) 失敗時分不出是我們的問題還是 exercise 的問題），
然後只挑 **`basic`** 做 (b)，把「接一個外來 pipeline 進 NDTwin 要做哪些事」寫成一份可重複的清單。
五個都做 (b) 之前先讓 Adam 看那份清單的成本。

### 需要實驗室

(a) 與 (b) 都要起 Mininet／bmv2 ⇒ **不能在 Adam 需要實驗室的時段做**。開跑前 claim。

---

## W-2 — finding #6／#48：`ndt apps stop` 停不掉 viz（沒有人在修）

2026-09-03 13:1x Adam 本人現場撞到：`ndt apps stop` 之後 visualizer 仍在跑。
**`fix/g6-ndt-apps-liveness` 不修這個**（已查證，見 `AUDITOR-VERIFICATION.md`）——
它改善的是「回報有沒有在跑」，而 `app_spawn` 仍是 `( cd "$dir" && exec nohup "$@" ) &`，
**沒有 `setsid`、沒有自己的 process group**，`app_stop` 仍只對單一 pid 送 TERM。

修法形狀：`app_spawn` 加 `setsid`（或 `systemd-run --user`），停止時殺**整個 process group**，
並且停止之後用**獨立管道**確認（`/proc/<pid>/fd` 反查誰開著它的 log，比 pidfile 可靠）。

🔴 **連帶**：`.test_run/logs/app_viz.log` 在 09-03 長到 **364 MB**（每一幀一行 DEBUG），
根目錄一度到 98%。09-02 同一個機制長到 875 MB 塞爆磁碟。**log 要有上限**，這是同一張工單的一部分。

---

## W-3 — finding #3：失敗的 `ndt up` 不回滾（沒有人在修）

`ndt up ovs4` 失敗後 Ryu（:8080/:6633/:6653）、tmux topo session、15 個行程／36 條 veth 全留著，
而沒有 kernel。`:8000` 被佔用的檢查在 `stack.sh` 的 [3/3]，**在 fabric 建好之後**。
證據：`round1-ovs/02_ndt_up_failure_leaves_fabric_running.log`（對照組 `03_`）。
同事線把它列為 BUG-3，未查證。需要實驗室才驗得完。
