# 七個外部 app 的開機清單（2026-09-04 整機測試用）

[Co-developed with claude code -- Adam]

寫的人：9/4 auditor，09-04 16:1x。Adam 16:0x 裁「先整理一頁清單，開跑後照著開」。
清單的資料來源分三級，每一格都標：🟢 我親自查過（指令、檔案、log）；🟡 轉述（09-02 手動測試、09-03 夜巡的紀錄）；🔴 沒人驗過，今晚第一次看。

**「app 從沒對著活 kernel 用過」（#90）這句不成立**：sim／energy 在 09-03 凌晨第二輪、viz 在 09-02 live round、nsr 在 09-02 22:04、te 在 09-03 00:17 都對著活 kernel 起過（🟢 各自的 log 與輸出檔還在）。成立的只有：**沒有一次是為了驗 app 本身而開的**。Web-GUI 與 NTG 我沒找到對著活 kernel 的紀錄。

## 0. 共同前提（開任何 app 之前）

- kernel 先起：`NDT_OWNER=adam tools/test_workflow/ndt up ovs`（或 `ndt up p4`）。七個 app 全部指向 `http://localhost:8000`（🟢 逐一查過：ESA `include/app/settings.hpp:16`、TE `Traffic-engineering-App.py:32`、NSR `setting/recorder_setting.yaml:4`、NTG `setting/Mininet.yaml:5`、viz `config.properties:3`、Web-GUI 容器裡烤進去的字串）。
- 五個走 `ndt apps`：`energy sim nsr viz te`。Web-GUI 與 NTG 刻意不在裡面（🟢 `ndt` 的 apps 段註解）。
- 起停一律 `ndt apps start|stop <name>`，**不要用各 repo 自己的 stop script**：NSR 的用 `pgrep -f`，會連坐殺掉同一個 shell 的東西（#43，未修）。
- log 在 `.test_run/logs/app_<name>.log`；energy／sim 另可看 tmux pane：`sudo -n /usr/local/sbin/ndtwin-lab energy-out 40`／`sim-out 40`。
- 開跑前一次：`ndt apps trim viz`。viz 的舊 log 363 MB，已超過 256 MB 上限（🟢 `ndt apps status`）。
- **順序：sim 先、energy 後**。沒有 sim 的 energy 什麼都不會關，而且第一個被拒的 case 就讓它永久卡死並抱著 `routing_lock`（🟡 round 2 §4；#37 未修）。
- 兩個會改網路：energy 關交換機、te 裝 flow rule。要量「乾淨」數字的段落先別開這兩個。
- 兩個平面的差別：P4 上 group／meter 六個端點回 501（設計如此）；OVS 上剛裝的 flow 要等下一次輪詢 3–13 s 才進表，kernel.log 會有 `withholding`／`not evidence` 的 WARN（修法不是 bug，N22）。

## 1. 逐個 app

### sim — Simulation-Platform-Manager

| | |
|---|---|
| 怎麼開 | `ndt apps start sim`。root、tmux session `sim`、`script` 落檔（🟢 `ndtwin-lab sim-start`） |
| 連哪裡 | 聽 `127.0.0.1:9000`；kernel 會 POST 到 `http://127.0.0.1:9000/submit`（🟢 `ports.sh:59`）。啟動時 `mount -t nfs localhost:/srv/nfs/sim /mnt/nfs/sim`（🟢 09-02 log）。本機 `/etc/exports` 有 `/srv/nfs/sim 127.0.0.1(rw,…)`、nfsd 在跑、三個目錄都在（🟢） |
| 正常看到 | log 前幾行 `Logger Loads Successfully!` → `Mount NFS` → server started；`ss -ltn` 有 `:9000`；`ndt apps status` 列 running |
| 已知的坑 | 🟡 出貨 VM 上 NFS mount 會阻塞 >25 s（開機手冊 D15）；本機 09-02 21:43 起過、跑到 01:38 才被 Ctrl-C。🟢 binary 09-02 21:00 建；`registered/energy_saving_simulator/1.0/executable` 在 |
| 怎麼收 | `ndt apps stop sim`（送 Ctrl-C，它自己解 mount） |

### energy — Energy-Saving-App

| | |
|---|---|
| 怎麼開 | `ndt apps start energy`。root、tmux session `energy`。**sim 必須已經在跑** |
| 連哪裡 | kernel `localhost`、request manager `localhost`（就是 sim）、NFS `localhost:/srv/nfs/sim/<app_id>` 掛到 `/mnt/nfs/app`（🟢 `include/app/settings.hpp:12-32`） |
| 正常看到 | pane 裡 `acquire_lock succeeded` → 送 case → 之後 `Power On/Off Task Complete`；kernel.log 出現 `set_switches_power_state`；`/ndt/get_switches_power_state` 有台變 OFF |
| 已知的坑 | 🔴 #37 未修：sim 沒在、case 被 502 拒絕一次，app 就永久卡死並抱著 `routing_lock`，之後 te 拿不到鎖。🟡 關機方向零驗證：回傳碼被丟掉，印 Complete 不代表真的關了（記憶 09-01）。🟢 跑的是分支 `fix/power-decision-per-group` `9facb78`（08-11 修三個電源決策 bug，沒推上游），binary 09-02 21:00 建。決策靠鏈路使用率，網路閒著可能整晚不關任何一台 |
| 怎麼收 | `ndt apps stop energy`。收完打一次 release `routing_lock`：回 412 `not_held` 才算乾淨（🟢 round 3 `12_leadE…log` 的用法） |

### nsr — Network-State-Recorder

| | |
|---|---|
| 怎麼開 | `ndt apps start nsr`。用 `~/miniconda3/envs/ntg-env/bin/python`（🟢 有 nornir／loguru／orjson／requests） |
| 連哪裡 | `http://127.0.0.1:8000`，每 5 s 抓 flow 與 graph，每 2 min 落檔（🟢 `setting/recorder_setting.yaml`） |
| 正常看到 | `recorded_info/` 出現 `YYYY_MM_DD_HH-MM-SS_{flowinfo,graphinfo}.json`，再壓成 `_json.zip`；`logs/NSR_2026-09-04.log` 有 `All components started successfully.`／`NSR is running.`。`app_nsr.log` 0 B 是正常的（`display_on_console: false`） |
| 已知的坑 | 🟢 09-02 22:04–22:06 對著活 kernel 錄過，檔案還在。🔴 不要跑 repo 的 `stop_network_state_recorder.sh`（#43） |
| 怎麼收 | `ndt apps stop nsr` |

### te — Traffic-Engineering-App

| | |
|---|---|
| 怎麼開 | `ndt apps start te`。用 `~/miniconda3/envs/te-env/bin/python`（🟢 有 requests／loguru／networkx）。程式是互動式的（問 mode 1/2 與秒數），nohup 下吃預設值照跑（🟢 09-03 00:17 log） |
| 連哪裡 | `http://localhost:8000/ndt/`（🟢 `:32`）。每 1 s `get_graph_data`；擁塞門檻 70%、大象流 10 Mbps 才搬，搬的時候 `acquire_lock` → `install_flow_entry` → `release_lock` |
| 正常看到 | log 每秒一行 `get_graph_data_api_call`。閒網路只有輪詢行，有大象流且擁塞才裝規則 |
| 已知的坑 | 🟡 #87：install／modify group 只信 Ryu 的 200。🟢 09-03 00:17 對著活 kernel 跑過 1 分鐘，有 `release_lock succeeded`。energy 卡死時它拿不到鎖 |
| 怎麼收 | `ndt apps stop te` |

### viz — Network-Traffic-Visualizer

| | |
|---|---|
| 怎麼開 | `ndt apps start viz`。要有 DISPLAY；`./mvnw javafx:run` 從原始碼編譯再跑，第一次要幾分鐘。**從有桌面的 shell 起**（我這個 session 的 shell 有 `DISPLAY=:0`、`WAYLAND_DISPLAY=wayland-0`，🟢） |
| 連哪裡 | `NDT_API_URL` 預設 `http://localhost:8000`（🟢 launcher） |
| 正常看到 | JavaFX 視窗畫出拓樸。P4 4-host 拓樸＝14 nodes／40 links（🟢 09-02 log `TopologyCanvas.draw() - nodes: 14, links: 40`）；有流量時 flows > 0 |
| 已知的坑 | 🟢 每個 frame 印一行 DEBUG，09-02 兩小時 835 MB；現在有 256 MB 上限，開前先 `ndt apps trim viz`。🟢 working tree 有 4 個未提交改動（`InfoDialog.java`、`SideBar.java`、`settings.json`、`node_positions.json`），誰改的不明；HEAD `9b56b30` 含 `b5e039c`。🟡 run-06 說 main 頂端編不過（`WindowStateRestore`），但本機這份 09-03 13:23 編過、跑了 43 分鐘 |
| 怎麼收 | `ndt apps stop viz`（#6 已修，會殺到 JVM） |

### Web-GUI

| | |
|---|---|
| 怎麼開 | 已經在跑：docker `ndt-frontend :3000`、`ndt-node-positions-api :3001`、`ndt-postgres :5433`，Up 2 days（🟢 `docker ps`）。瀏覽器開 `http://localhost:3000` |
| 連哪裡 | 瀏覽器直接打 `http://localhost:8000/ndt/get_graph_data`、`get_cpu_utilization` 等（🟢 `src/api/index.ts`；容器裡烤進去的就是 `http://localhost:8000`）。Assistant 走 `/ndt/intent_translator/text`（🟡 kernel 要 `--ai`） |
| 正常看到 | 拓樸圖、面板、Assistant |
| 已知的坑 | 🔴 **CORS 沒人驗過**：kernel 原始碼裡零 `Access-Control-Allow-Origin`，瀏覽器從 `:3000` 打 `:8000` 是跨來源，可能整頁拿不到資料。第一件事按 F12 看 console。真的擋就記 finding，今晚不改碼。🟢 CPU% 在 MININET 是 `10 + hash(ip) % 50` 的常數，GUI 會當真（`ndt status` 的 note）。🟡 run-04 從零部署失敗（BUG-5，pnpm），本機 image 兩個月前建好，不受影響 |
| 怎麼收 | 不用收，容器本來就在 |

### NTG — Network-Traffic-Generator

| | |
|---|---|
| 怎麼開 | 不是獨立行程。兩條路：(a) `ndt ntg prompt` 再 `ndt up ovs`，拓樸的 tmux session 裡出現 `NTG>`；(b) 維持 `cli` 模式（現在是 cli，🟢），另開 shell 到 `/home/adam/Network-Traffic-Generator` 跑 `~/miniconda3/envs/ntg-env/bin/python network_traffic_generator.py`（🟡 run-06 F15 這樣起過；要不要 root 我沒查到） |
| 連哪裡 | `http://127.0.0.1:8000`（🟢 `setting/Mininet.yaml:5`） |
| 正常看到 | `NTG>` 提示（kernel 沒起會一直 `retrying...`）。`flow --config flow_template.json` → `SUCCESS : Experiment completed.`，期間 `get_detected_flow_data` 筆數上升（🟡 run-06 F16：173 → 213） |
| 已知的坑 | 🟢 working tree 髒：`NTG.yaml`、`setting/Mininet.yaml`、`testbed_topo.py` 有未提交改動（#84 那兩行 bootstrap 在這裡）。🟡 在 `NTG>` 按 Ctrl-C 會拆掉整個 fabric（run-06 F-interrupt）。`ndt up ovs` 現在跑的是本 repo 的 `testbed_topo.py`，不是 NTG 那份（#77 已修） |
| 怎麼收 | 路 (a) 隨 `ndt down` 一起走；路 (b) 打 `exit` |

## 2. 今晚每個 app 至少看三件事

1. 起得來：`ndt apps status` 列 running，log 第一頁沒 traceback。
2. 真的拿到 kernel 的資料：各自「正常看到」那一格。
3. 收得掉：`ndt apps stop <name>` 之後 `ndt status` 的 apps 欄回 none、`ndt apps orphans` 空。

## 3. 我沒驗的（開的時候先看這幾個）

- Web-GUI 的 CORS。
- viz 這份 working tree 今晚編不編得過（09-03 過了）。
- NTG 路 (b) 要不要 root。
- energy 在閒網路上會不會做出任何一個關機決定。
