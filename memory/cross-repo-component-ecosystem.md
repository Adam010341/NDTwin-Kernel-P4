---
name: cross-repo-component-ecosystem
description: "NDTwin 是 8 個元件的系統,7 個兄弟 repo 在 ~/ 底下(不在 workspace);串接測試的現成入口、跑得起來/跑不起來的界線、以及「這些是別人的碼」"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 7d45c16b-81a8-47c1-b671-54d6b29c02cc
  modified: 2026-08-19T15:08:41.910Z
---

2026-08-14 Adam 問「web-gui、NTG 這些工具我能不能存取、在不在 workspace」時盤點出來的。
**答案:能存取,但不在 workspace** —— 它們是 `/home/adam/` 底下的獨立 repo,跟
`~/Desktop/NDTwin-Kernel` 平行。

## 路徑不要背,repo 已經記錄了

**`tools/test_workflow/components.env` 是唯一真實來源**,已經宣告全部 7 個兄弟 repo:
`ENERGY_APP_DIR` / `SIM_MGR_DIR` / `VISUALIZER_DIR` / `WEBGUI_DIR` / `NSR_DIR` /
`NTG_DIR` / `TE_APP_DIR`。而且它用「往上找 `Energy-Saving-App`」定位 `WORKSPACE_ROOT`,
不是寫死路徑,所以換 checkout 也能動。**要路徑就讀它,不要憑記憶。**

實際目錄(2026-08-14 `ls` 確認存在):`~/Web-GUI`、`~/Network-Traffic-Generator`、
`~/Network-Traffic-Visualizer`、`~/Network-State-Recorder`、`~/Simulation-Platform-Manager`、
`~/Traffic-Engineering-App`、`~/Energy-Saving-App`。

## 串接測試已經有現成入口,不要從零寫

**`tools/test_workflow/l0_build_check.sh` 已經會建全部 8 個元件**
(`kernel p4 energy sim visualizer webgui python contract`),每個回報 PASS / FAIL / SKIP,
`--list` 可列、可只跑指名的。所以「把 tools 串起來測一次」缺的**不是建置,是 runtime 互通**。

## 推導不出來、會影響計劃的三件事

1. **這台機器沒有 Node**:`node` / `npm` / `pnpm` 全部不存在。所以 **Web-GUI 只能走 Docker** ——
   `l0_build_check.sh:113` 也是這樣分支的(預設只 `compose config` 驗證,
   `L0_WEBGUI_DOCKER_BUILD=1` 才真的 build image)。同一個限制也咬過簡報工具鏈,
   見 [[slide-deck-generator-python-pptx]]。
2. **Docker 可用**:29.5.3,daemon 實測活著。Web-GUI 的 compose 會起三個 container
   (frontend :3000、node-positions-api :3001、postgres),**前端打的是 `http://localhost:8000`
   ＝ kernel API 的 port**,所以 GUI 要有東西看,kernel 必須在跑。
3. **流量工具的實際盤點**(2026-08-14 逐一 `command -v`):
   ✅ `iperf` `iperf3` `ping` `mnexec` `curl` `wget` ／ ❌ `hping3` `scapy`(venv 也沒有)
   `tcpreplay` `nping` `netperf` `ostinato` `trafgen`。
   NTG 本身是 Python(`network_traffic_generator.py` 54KB ＋ worker node 版),
   有 `flow`/`dist` 兩種設定與 template,`flow_logs/` 有 61 個歷史紀錄,支援 Mininet 與實體機。

## ⚠️ 這些是別人的碼

git log 幾乎都是 "Add files via upload"(NTG 還有 AlenChen02 的 merge)。
**預設只測不改**,要動先問 Adam。唯一的例外是 `Energy-Saving-App`,我們修過 3 個 bug、
commit `9facb78`,而且**刻意不推** —— 見 [[energy-saving-app-power-bug-fix]]。

## 界線:agent 自己能走到哪裡

**能自己判斷的**:建得起來嗎(`l0_build_check.sh`)、起得來嗎(docker compose / python import)、
起來後有沒有在聽(curl :3000 :3001 :8000)、設定檔對不對(`compose config`)。

**要 Adam 的**:端到端「真的會動」需要 fabric,而起 Mininet 是唯一非他不可的一步
(見 [[agent-can-do-live-tests-except-start-mininet]])。沒有 fabric 時 Web-GUI 起得來但畫面是空的,
NTG 也沒有 host 可以打流量。

## 🔴 2026-08-19:我否認了 Web-GUI 的存在,而答案就寫在這個檔裡

Adam 說「我們平常都在 web-gui 跟 NTG/mininet 裡面操作」時,我先用
`ls -d ~/*/ | head -20` 掃了一遍,**`Web-GUI` 排第 21 個被 head 截掉**,
於是我寫進簡報 template:「七個兄弟 repo 裡沒有 Web-GUI 這個東西,那行註解是舊的」。

**它不但存在,而且當下正在跑**(三個容器 up 9 小時,`localhost:3000`)。
**上面第 22 行就寫著 `~/Web-GUI`,第 39 行就寫著 frontend :3000。**

🔑 **兩層教訓,第二層才是新的**:
1. `| head -N` 截斷後不能當成完整清單(這是 [[grep-endpoints-misses-concatenation]] 的第三式,又犯)。
2. **我有記憶、沒去讀,反而用一次被截斷的即時查詢去覆蓋它,還把否定結論寫進交付物。**
   記憶說「有」而即時查詢說「沒有」時,**先假設是查詢的問題**——
   否定結論在結構上就比肯定結論脆弱([[no-in-repo-callers-is-not-dead-code]] 同族)。

## NTG 的 prompt 與 Mininet CLI 是二選一(2026-08-19 查證)

`~/Network-Traffic-Generator/setting/Mininet.yaml` 的 `mode:` 決定
`ntg_bmv2_topo.py` / `testbed_topo.py` 最後把 net 交給誰:

| `mode` | 拿到的介面 | 能做什麼 |
|---|---|---|
| `cli` | **Mininet 的 CLI**(`CLI(net)`,`network_traffic_generator.py:308-310`) | `h1 ping h33`、`link s1 s5 down`、`pingall` |
| `custom_command`(目前值) | **NTG 自己的 prompt** | `flow --config`、`dist --config`、`exit` |

**一次只能有一種**,所以「斷鏈 demo」與「NTG 打流量 demo」是兩次不同的拓撲啟動。
兩者都用 `sudo tmux -L ndtwinlab attach -t topo` 進去(`ndtwin-lab` 是 tmux socket `ndtwinlab`)。
⚠️ **`ndtwin-lab topo-cmd` 送的是 keystroke 到這個 prompt**,所以它送什麼指令有效,取決於 `mode`。

**Web-GUI 是唯讀視覺化**:Topology / FlowInformation / LinkFlowInformation /
DeviceInformation / SwitchPortPanel / trace / llm,**沒有電源或改路由的控制項**
(2026-08-19 `ls src/components` ＋ grep power 全空)。改路由要走 Mininet CLI 或 TE app。

相關:[[ndtwin-current-state]]、[[check-env-state-dont-ask]]。

**2026-08-15 後補:** NTG 的 bmv2 路已通(bridge `p4_proxy/mininet/ntg_bmv2_topo.py`,
地雷圖見 [[ntg-bmv2-support-pending-feature]]);全 8 元件的實測矩陣落在
`doc/2026-08-14_cross-component-integration-matrix.md`(22 條發現)——**本檔的「界線」節
維持有效,但 Sim-Mgr/Energy 已可全鏈跑(root 跑 binary 即可,NFS 基建本就在)。**

---

# 🏁 2026-08-31：六個 app 的建置與啟動需求（為了把它們裝進 P4 demo VM 而逐一實測）

🔴 **先自首**：本檔最後一行 08-15 就寫著「**root 跑 binary 即可，NFS 基建本就在**」，
而我 08-31 花了三個階段重新推導出同一件事。成因是 `MEMORY.md` 的鉤子只寫
「`components.env` 是路徑真實來源」——**鉤子只講了這個檔的一個事實，其餘的等於不存在**。
⇒ 教訓見 [[checkpoint-skills-and-session-cost]]。
（08-15 那句在**開發機**上成立；**新做的映像裡 NFS 什麼都沒有**，下面是要補的東西。）

## 建置系統與相依（在 Ubuntu 24.04 的乾淨映像上實測）

| repo | 建置 | 會咬人的地方 |
|---|---|---|
| Energy-Saving-App | C++ `Makefile`，`-std=c++23` | 🔴 **預設目標不是 `all`**（settings header 的規則寫在 `all` 前面）⇒ `make` 只產一個 `.hpp` 就停，**要 `make all`** |
| Simulation-Platform-Manager | C++ `Makefile`，`-std=c++17` | 同上。`make all` 產 4 個：`request_manager`／`simulation_platform_manager`／`app`／`registered/simple_sim/1.0/executable` |
| Traffic-Engineering-App | 單一 `.py` | 要 `python3-networkx`＋`python3-loguru`（**apt 有，不必 venv 也不必 `--break-system-packages`**）；`input()` 互動選單，**stdin 給 `/dev/null` 會當場死** |
| Network-Traffic-Visualizer | Java / Maven `mvnw` | pom 寫死 **release/source/target 21** ⇒ JDK 17 直接 `release version 21 not supported`。shaded jar **不含 JavaFX runtime** ⇒ 要 `openjfx` 並 `--module-path /usr/share/openjfx/lib --add-modules javafx.controls,javafx.fxml,javafx.swing,javafx.media,javafx.web` |

apt 清單：`openjdk-21-jdk maven build-essential libspdlog-dev libfmt-dev libssl-dev
libboost-{system,thread,filesystem}-dev python3-networkx python3-loguru openjfx
nfs-kernel-server nfs-common`（GUI 要無頭啟動再加 `xvfb`）。

## 🔴 ESA 把**建好的執行檔 commit 進 repo**

`energy_saving_app`／`energy_saving_simulator` 是版控裡的檔案，不是建置產物。
⇒ **「這個路徑上有可執行檔」分不出「我建的」與「clone 帶來的」**——我的驗收就這樣拿到一個
假 PASS。**建置驗收要先刪再建**；順帶那也把別人在未知 glibc 上編的執行檔清出映像。

## 兩個 C++ app 開機就掛 NFS，失敗即 abort

`energy_saving_app` 與 `simulation_platform_manager` 在 `main()` 裡 shell out
`mount -t nfs localhost:/srv/nfs/… /mnt/nfs/…`，失敗就 `[critical] Mount NFS Failed` 退出。
⇒ **必須 root 跑**（非 root 會拿到 `mount.nfs: failed to apply fstab options`）。
SPM repo 自帶 `etc.exports`，但**寫死 `192.168.50.21`**——那是實驗室位址，
要發出去的映像必須改綁 `localhost`。
需要的目錄：`/srv/nfs/sim`、`/srv/nfs/sim/power`、`/mnt/nfs/sim`、`/mnt/nfs/app`。
⚠️ **未驗**：若開機時 fstab 已經掛好，app 再掛一次會不會回非零而照樣 abort——沒測過。

## 起來之後各自佔的埠

`:8000` kernel（別人）／`:8001` `energy_saving_app`／`:8002` `request_manager`／
`:9000` `simulation_platform_manager`。四個都是實測 `ss -tlnH` 看到的。

## 🔴 Network-Traffic-Visualizer 的 `main` 編不起來，而且**已經三個月了**

`WindowStateRestore` 在 `SideBar.java`（3 處）與 `InfoDialog.java:981` 被呼叫，
**整個 repo 從未宣告過它**；13 個 commit 的歷史裡那個檔從未出現。
引入者是 **`9ef655f`（2026-03-31，"debug:windows problem"）**，`main` 是 `9b56b30`（04-20）。

🔑 **Adam 本機那份跑得起來，是因為 `~/Network-Traffic-Visualizer` 有未提交的修改**：
**2026-06-09 15:03 把那四個呼叫全部註解掉**（`git status` 顯示兩個檔 `M`，diff 就是那四行）。
⇒ **「在我這邊會動」與「公開的 repo 是壞的」同時為真三個月**，而唯一會發現的人正是修好它的人。
同型見 [[two-writers-one-worktree]] 第九式。

**功能差多少？零。** `b5e039c`（03-30）→ `main` 那兩個 commit **沒有新增功能**：
Top-K 與更新間隔對話框在 `b5e039c` 就有，那兩個 commit 只是把它們包進 window-state
保存的 wrapper（`preserveMainAndOwnerStageWhile` → `WindowStateRestore`），
外加 `NetworkTopologyApp.getPrimaryStage()` 與一個 license header 檔。
**而那個 wrapper 對任何人都沒生效過。** ⇒ `b5e039c` 與 Adam 本機那份功能等價。

📌 **官方 17.9 GB demo VM 裝的是 `cdd816b`（2026-01-29）**，早於 regression ⇒ 那份是好的。

🔴 **Adam 裁：不回報上游**（那是 xxxPatty 的 repo），只記在我們自己的 audit 裡。
