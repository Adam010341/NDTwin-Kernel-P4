# 跨元件串接測試矩陣（2026-08-14 晚，live 實測）

> 本輪目標：把 7 個兄弟元件與 kernel 實際串起來跑一次，回答「哪些建得起來、哪些起得來、
> 哪些連得上」，並標明哪些必須等 Adam。單一機器、P4 fabric（Adam 手動起
> `p4_proxy/mininet/p4_testbed_topo.py`，10×bmv2）＋`stack.sh up p4`（proxy+kernel）。
> head `b9a5bea`；機器 2026-08-14 10:35 重開機後的乾淨環境。
> 測試紀律：兄弟 repo 一律只測不改（唯一動的環境是 session scratchpad 的臨時 venv）。
> 產出：claude code session（串接輪），Adam 委託。

## 總表

| 元件 | 建得起來 | 起得來 | 連得上 | 需 Adam 才能繼續 |
|---|---|---|---|---|
| NDTwin-Kernel | ✅ | ✅ :8000 | —（被連的中心） | — |
| P4 proxy | ✅ | ✅ :8081（4s 收斂 12 路徑） | ✅ 10×bmv2 gRPC | Mininet 本身 |
| Web-GUI | ✅（compose 驗證） | ✅ 三 container（重開機自動回復） | ✅ 輪詢 :8000 全 200、CORS 通過 | — |
| NSR | ✅ | ✅ 官方腳本（conda ntg-env） | ✅ 5s 輪詢、2min zip 落檔實證 | — |
| Visualizer | ✅（mvn, JDK 21 齊） | ✅ JavaFX 於 DISPLAY=:0 存活 100s | ✅ 畫出 14 節點＋即時 flow（rate 與 kernel 一致） | 長開要真人桌面 |
| TE-App | ✅ | ⚠️ 起得來但**互動式**（見發現 3） | ✅ 1s 輪詢＋acquire/release routing_lock 完整生命週期 | 遷移觸發要 OVS 輪（發現 4） |
| NTG | ✅ | ⛔ P4 fabric 無入口（發現 1） | —（設計上綁 OVS+Ryu 同進程） | OVS 輪：起 **NTG 的** testbed_topo.py |
| Energy-App | ✅ | ⛔ mount NFS 硬門（發現 5） | ✅ 註冊腿通（App ID 2、kernel 建 /srv/nfs/sim/2） | `sudo ./energy_saving_app` |
| Sim-Platform-Manager | ✅ | request_manager ✅ :8002；sim_server ⛔ 同 mount 門 | ✅（request_manager 起且聽） | `sudo ./simulation_platform_manager` |

流量面（NTG 的 P4 代打）：mnexec + iperf/ping 實測通——kernel 同時看見 3 條 flow
（UDP 22.3 Mbps、ICMP 往返 0.6/0.32 Mbps，各 7 跳完整路徑），GUI/NSR/Visualizer/TE 四個
消費端同步吃到同一份資料。

## 結構性發現

1. **NTG 不支援 bmv2 拓撲（原樣）——已依 Adam 指示列為待完成功能**（記憶
   `ntg-bmv2-support-pending-feature`）。三層查證：local repo 零 bmv2/P4 參照、user manual
   的 Mininet 模式明定 Ryu+OVS 三終端流程、developer manual 的整合契約
   `command_line(net, config)` 需與 Mininet 同進程。**非架構性不相容**：
   `MininetCommunicator` 只用 `host.cmd`/`host.popen`（與 switch 型別無關），缺的是
   「bmv2 拓撲 + `command_line(net)`」的合體入口（~20 行 glue，含直譯器組合
   `sudo` + ntg-env python + `sys.path.append(dist-packages)` 借系統 mininet）。
2. **kernel 是 app／模擬管線的中介**：`/ndt/app_register`、`/ndt/received_a_simulation_case`、
   `/ndt/simulation_completed` 都在 `HttpSession.cpp`。Sim-Mgr 標頭裡的 10.10.10.250/251
   是他們實驗室的多主機部署；Energy repo 自身設定已是全 localhost，單機管線設計上成立。
3. **TE-App 是互動式程式**：`ask_mode()` 用 `input()` 選模式，背景/無 stdin 直接
   EOFError 崩潰。繞法：`printf '2\n10\n' |` 餵進去（週期模式，EOF 由它的 except 接住）。
   依賴注意：機器上沒有任何現成直譯器同時有 requests+loguru+networkx（conda ntg-env 缺
   networkx），本輪用 session 臨時 venv 代跑。
4. **TE 的遷移邏輯在 bmv2 上結構性觸發不了**：門檻 `congested_threshold=70`（%），
   而鏈路宣告 1 Gbps、bmv2 (`simple_switch_grpc`) 實測天花板 ~170 Mbps → 利用率上限
   ~17%。lock/輪詢/決策迴圈已全數 live 驗證（`0 entries are added` 屬正確判斷）。
   要看真遷移：OVS 輪或（需裁決）調低門檻。
5. **Energy-App 與 sim_server 的 NFS mount 是硬門、且必須 root 執行 binary 本身**：
   兩者 main() 開頭 `safe_system("mount -t nfs …")`，失敗即 `EXIT_FAILURE`（實錄：
   `mount.nfs: failed to apply fstab options`；`sudo -n` 確認 mount 不在免密白名單）。
   **不能預掛代替**：target busy 會讓它們自己的 mount 非零退出，一樣死。正確配方見下節。
   註：NFS 基建本身早佈好（nfs-server active、`/etc/exports` 有 `/srv/nfs/sim`、
   mount point 7/9 建好）——只差 root。
6. **`setupNFSForApp` 的 chown 失敗＝管線阻斷（2026-08-15 凌晨 live 實證，升級自「非致命警告」）**：
   完整鏈條——kernel（非 root）建 `/srv/nfs/sim/<id>` 後 chown nobody 失敗 → 目錄停在
   `adam:adam 775` → export 是 `all_squash`，root 跑的 energy app 寫入被壓成 `nobody`
   → 對 775 目錄無寫權 → **第一次寫 case input 就失敗** → app 的
   `canSendNextSimulation` 卡 false → 之後每 60s 週期都 "There is switch powering
   on/off, skip..."，**決策迴圈永久罷工而 app 看起來活著**（:8001 照聽、lock 照拿）。
   實測時間軸：App ID 4 於 00:18 註冊，資訊蒐集只發生 3 次（00:17:26／00:21:51／
   00:22:26），此後零 case POST、`/srv/nfs/sim/4` 零檔案。
   **修法是裁決題（明早）**：(a) kernel 以 root 跑（chown 就會成功，原設計如此？）
   (b) `setupNFSForApp` 改 chmod 777 代替 chown（kernel 非 root 也能做）
   (c) export 加 `anonuid=1000` 把 squash 對準 adam (d) 每次註冊後手動 chmod。
   另注意 app 每次重啟都重新註冊、id 遞增，`/srv/nfs/sim/` 會累積孤兒目錄（1-4 已四個）。
7. **Energy-App 的 app_id 全程用註冊回傳的數字**（`preInstall()` 先註冊再 mount
   `/srv/nfs/sim/<N>`）——一度懷疑的「app 掛 power、kernel 建數字」不對齊**不存在**。
   代價是每次啟動都註冊一次、id 遞增（本輪已到 2：curl 測試=1、app 實跑=2）。
8. **Web-GUI 的 kernel URL 是 build-time 烤死的**，compose 預設
   `NDT_API_BASE_URL=http://192.168.64.8:8000`（別台機器）；本機 `.env` 已蓋成
   localhost 所以現況正確。**換機器部署必重 build image**，是已知坑。
   另：kernel 對 OPTIONS preflight 回 204＋`Access-Control-Allow-Origin: *`，CORS 無虞。

## 給 Adam：下一步要你的三件事

```bash
# (1) Energy 完整管線（兩個 binary 都要 root——它們自己 mount/unmount NFS）
cd ~/Simulation-Platform-Manager && sudo ./simulation_platform_manager   # :9000
cd ~/Energy-Saving-App && sudo ./energy_saving_app                        # :8001，會註冊+mount+開始決策
# request_manager (:8002) 我已用一般權限起著，不用動。
# ⚠️ energy_saving_app 是真актuator：會對 twin 下 /ndt/disable_switch 與 flow 操作。

# (2) NTG 輪（OVS）：Ryu 先起，然後起「NTG 自己的」topo（不是 kernel 的）
#     stack.sh up ovs 到 [2/3] 提示 Mininet 時，改跑：
cd ~/Network-Traffic-Generator && sudo ./testbed_topo.py

# (3) Visualizer 長開（JavaFX 視窗在桌面）：
cd ~/Network-Traffic-Visualizer && ./network_traffic_visualizer.sh
```

## 本輪結束時留著跑的（供接手對照）

Mininet（Adam 的終端）、kernel :8000、proxy :8081、Web-GUI ×3 container、
NSR（背景，累積 recorded_info/）、TE-App（10s 週期）、request_manager :8002、
iperf h2→h3 20M（600s 自然結束）、ping h1→h4 500pps。
收環境順序：先 `stack.sh down`，Mininet 用 `sudo mn -c`（Adam），NSR 用它的 stop 腳本，
TE/request_manager `kill` 即可。

## 證據路徑

session scratchpad（會隨 session 消失）：`visualizer-run.log`、`te-app.log`、
`energy-app.log`、`request_manager.log`、`sim_server.log`、`integration-session-state.md`。
持久的：NSR `recorded_info/`＋`logs/`、kernel/proxy log 在 `.test_run/logs/`。

---

# 【2026-08-15 凌晨】OVS/NTG 輪（Adam 起 topo 後全 agent 自跑）

環境切換：P4 stack 收掉（Adam Ctrl-C 他的 energy/sim_server、`sudo mn -c`）→
Ryu（**6653**，見不符 #1）→ Adam 起 **NTG 自帶的** `testbed_topo.py`（ntg-env python，
見不符 #2）→ 等 `all-destination paths installed` → kernel（快照 **10 sw／128 hosts／
288 edges**）→ NTG CLI `flow --config …`。

## OVS 輪結果

| 項 | 結果 | 關鍵數字 |
|---|---|---|
| NTG 產流（第 1 輪，原廠 template） | ✅ | 35 對 iperf 全有 bytes（樣本 2MB@30M 與 template 吻合）；但窗僅 ~17s，flow 老化後才查、kernel 端無目擊者（NSR 當時已死，見下） |
| NTG 產流（第 2 輪，5 分鐘加長版 `~/flow_long_5min.json`） | ✅ | **305 對全數有 bytes、共 5.5 GB**；kernel **同時可見 39 條 flow（26 TCP/13 UDP）**，速率與 template 對得上 |
| OVS sFlow→kernel 管線 | ✅ | 對照流量 **980.3 Mbps** 含 5 跳路徑（bmv2 天花板 ~170M 的 5.7 倍） |
| NSR | ✅（復活後） | 5 分鐘窗批次 270KB+、zip 對照常（26K/188K）；**發現 #9 見下** |
| Web-GUI | ✅ | 1s 輪詢全程 200 |
| Visualizer | ✅ | 90 秒窗畫 **138 節點**、即時 flow Processed=266/Shown=226——**兩種 fabric 都證完** |
| TE-App 壅塞遷移 | ✅ **全鏈 live 證實** | 見下方專節 |

## TE 遷移全鏈（本輪壓軸）

注入 980M 重流（h1→h64，120s）→ TE 連三判壅塞（`1→6`、`6→2` @ ~69%）→
產 1 條遷移項 `{dpid:1, priority:10, match:{eth_type:2048, ipv4_dst:10.0.0.55},
actions:[OUTPUT:1]}` → kernel 批次端點（**3ms** 後收到）→ Ryu
`POST /stats/flowentry/modify` **200** → **s1 實表的 `nw_dst=10.0.0.55` 表項
actions 就地改寫為 `OUTPUT:1`**（duration/counter 保留=modify 正常語意）→ 鎖乾淨釋放。

**隨附觀察（值得再看，未列 bug）**：
- TE 用 **modify 而非 install**（程式内 `TODO: Change to mod` 的產物）：本次能生效是因
  router 先裝過**同 match** 表項；若目標表項不存在，OF1.3 的 MODIFY 是**靜默 no-op**
  ——TE 印 "1 entries are added"、kernel 200、Ryu 200 三綠但資料面不動。
- 遷移是**就地改寫 router 的表項**（同 priority 10、cookie 皆 0、無 ownership 標記）：
  router 下次全量重裝路由會**無聲蓋回**遷移結果；且 `te_flow_entry_idle_timeout=0`
  =永久表項（[[replace-vs-add 家族]]的 TE 變體）。
- ⚠️ 驗證方法論注記：查證此鏈時連續三個解析假象（追錯 priority 常數 100 vs 實際 10、
  kernel 端點回 dict 非 list、Ryu dump 用 `nw_dst` 而寫入用 `ipv4_dst`）都指向
  「no-op」假結論，字串層全文搜尋才破局——**引用表項前先看原始輸出的形狀**。

## 新增發現（續前 8 條）

9. **NSR 一次 connection refused 就永久斷氣，且無聲**（00:27:50，kernel 重啟瞬間）：
   兩條輪詢執行緒各印一行 `Error fetching data … Connection refused` 後**再無任何 log**；
   進程續活、батch 機器照轉，**之後只產 0-byte zip**（無聲資料遺失）。連帶：
   死狀態下 SIGTERM 收不掉（handler 疑似卡 join，要 `kill -9`）。與 energy app 的
   卡死 flag、TE 的三綠 no-op 同族：**「進程活著」與「在工作」是兩件事**。
10. **NSR 的 stop 腳本硬寫 `sudo kill`**：NSR 本以使用者權限跑，root 毫無必要；
    非互動環境（agent、cron）直接失敗。
11. ~~**NTG topo 撥 6653、官方文件的 Ryu 指令聽 6633**：照文件字面跑 switch 永遠連不上~~
    🔴 **2026-08-21 live 複驗否證，這條是錯的**：照文件逐字跑 **10/10 個 switch 都連上**。
    Mininet 的 `RemoteController.checkListening`（`mininet/node.py:1551`）在沒明指 port 時
    **`for port in 6653, 6633:` 兩個都探、誰回應連誰**，6653 只是兩個都不通時的退路。
    當初 `ovs-vsctl get-controller` 讀到 6653 沒讀錯，但那是**協商結果**不是**規格**。
    詳見 `doc/2026-08-16_delivery-package/docs-errata.md` 末節與
    `doc/2026-08-17_testing-manual.md` §2.2 的摺疊區。
12. **官方文件的 `sudo ./testbed_topo.py` 在本機必 ImportError**：root 的 python3 無
    nornir/loguru。可行組合=`sudo <ntg-env python> testbed_topo.py`（腳本自帶
    dist-packages append 借系統 mininet）。
13. NTG 實驗 log 完整可靠（sender/receiver 成對 JSON 含 bytes/bps），可直接當
    ground truth 對帳 kernel 偵測——本輪兩度靠它定案。

## Log 深掃(subagent,全文= `doc/audit/2026-08-15_integration-log-audit.md`,含裁決前言)

kernel 2,801 requests 零 exception;NSR 5s/TE 10s 節奏對帳吻合。**採信的新發現**:
14. **kernel.log 每次啟動被截斷**(launcher 的 `>` 重導所致)——P4 era 的 kernel log
    已無法回看,鑑識能力受損;stack.sh `start_bg` 改 `>>` 或加輪替。
15. **proxy 的 `inform_switch_entered` 推播在 stack.sh 順序下必死且無重試**,其
    「permanently degraded」警語是錯誤預測(twin 由拉取路徑填滿,live 實證 10/10)——
    警語要改真話,或補重試。
16. **kernel 啟動時 ApplicationManager 的 sudo 清理三連敗**(`exportfs -u`、`sed -i
    /etc/exports`、`exportfs -ra` 皆 exit 1)——kernel 的 NFS 管理整套假設 root/sudo,
    與發現 6 同根,修法應一起裁。且其警語「The export is still live」與事實不符
    (exports 從未寫入成功)。
17. **NTG 對被 kill 的 unlimited flow 會寫出「多份 JSON 串接」的 log 檔**(第 1 輪
    70 檔中 10 檔如此,`json.load` 會炸或只讀到 1/315)——對帳工具要用多文件解碼;
    重算後第 1 輪 35 對全有 bytes、共 2.33 GB(其中一條 unlimited 佔 1.82 GB)。
18. P4 proxy 對 route table **全量重裝 16 次**(39 add vs 368 冗餘 modify)——效率
    與冪等性觀察,非錯誤。
19. Web-GUI 對 `get_graph_data` 的輪詢是設定值的**兩倍**(120/min vs 60/min,
    最貴的端點)——前端重複抓取,小額效能票。

## 【2026-08-15 白天】修復輪(Adam 裁決:只修我們 repo 的;NFS 用 chmod 版)

| 修復 | commit | 驗證 |
|---|---|---|
| **發現 6/16(NFS 權限鏈)**:`setupNFSForApp` 以 `chmod 777`(`fs::permissions`)取代
  chown-to-nobody——owner 免特權即可讓 all_squash 客戶端寫入,root/非 root 兩種部署同解;
  per-app export 行改為 best-effort+誠實訊息(母 export 已涵蓋);cleanup 先查
  `/etc/exports` 有無該行,沒有就整段跳過 sudo(啟動三警語歸零);`chownRecursive` 移除 | `fe6a577` | 7 條新測試(anchor 語意/chmod/完整非 root 生命週期);**mutation 4/4 殺**;571/571 雙路綠 |
| **發現 14(log 截斷)**:`start_bg` 啟動前把非空 log 輪替成 `.prev`(單檔單 era、
  磁碟有界兩代) | 上表後續 commit | 7 條 shell 測試;拿掉輪替行的 mutant 紅 |
| **發現 15(死推播+誇大警語)**:`switch_entered` 失敗後背景有界重試(30×10s);訊息改述
  事實(kernel 後起是常態、其輪詢路徑 `TopologyAndFlowMonitor.cpp:566` 自會 enable);
  兩處「唯一路徑」過時註解更正並附引註 | 同上 | 4 條注入時鐘測試;**mutation 3/3 殺**(其中 sleep 順序 mutant 逼出事件序斷言);Ran 21 綠 |

**給報告用的 NFS 修法敘事**(Adam 指定要 documentation):部署以非 root 跑 kernel 時,
chown 需要的特權不存在,而 chmod-by-owner 不需要——把「誰擁有」換成「誰可寫」,
在單機實驗環境等價且兩種部署通用。修復把整條非 root 生命週期(註冊→可寫工作區→
destructor 靜默清理)第一次變成**免 root、免 sudo、免 NFS server 的可單元測試路徑**。
發現 18(route 重裝 16 次)按「觀察非 bug」歸類,**刻意不修**。

**同日新增交付**:NTG×bmv2 bridge(`p4_proxy/mininet/ntg_bmv2_topo.py`+低速率 template,
等 Adam sudo 實跑);bmv2 效能報告(`doc/2026-08-15_bmv2-performance-report.md`,
**兩個翻案**:①現裝 bmv2 是 -O0+全 logging 的 debug build(config.log 實錘),
非 bmv2 本身的極限;②「170 Mbps 本機實測」的說法是**出處錯誤**——那是文獻值
(SIGSIM-PADS '23),本機從未量過飽和點,重建驗證時新舊 build 一併量。
重建腳本 `build_bmv2_fast.sh` 備妥未執行)。

## 明早給 Adam 的清單(彙整)

1. **Energy 管線 NFS 權限鏈修法四選一**(發現 6):kernel root / chown→chmod /
   export anonuid / 手動——建議 (b) `setupNFSForApp` 改 chmod,幾行+一測。
2. `/srv/nfs/sim/` 孤兒目錄清理(1-4 已四個)+ app 重啟即重註冊的 id 遞增設計。
3. **NSR 斷線自癒**(發現 9):輪詢執行緒需 retry-on-refused;上游回報或我們修,裁決。
4. NSR stop 腳本的 sudo(發現 10)——一行改掉,順手。
5. **NTG port 6653/6633 文件矛盾**(發現 11)+ 直譯器組合(發現 12)——文件更新或
   topo 改 port,upstream 事務。
6. TE 的 modify-not-install 與 ownership 觀察(上方專節)——要不要回報 TE 上游,裁決。
7. (原有)NTG×bmv2 待完成功能、l0 的 L0_WEBGUI_DOCKER_BUILD 全量建置未跑過。

## 【2026-08-15 下午】NTG×bmv2 結案輪(修復複驗 + 三個新 NTG 發現 + 一個潛伏五週的 P4 測試床 bug)

**結果:待完成功能 [[ntg-bmv2-support-pending-feature]] 交付並 live 驗證**——NTG 經 bridge
驅動 bmv2 fabric,TCP/UDP 流真實完成(首批 10 sender/19.7MB 時 kernel 同見 **39 條 flow**),
10 隻 bmv2 全程存活。同輪順帶完成:**四個上午修復全部 live 複驗**(NFS chmod=管線 0.4 秒
決策鏈真關機、proxy 重試=推播史上首次送達、stale cleanup=零警告、log 輪替);Energy 管線
全鏈第一次跑通(register→case→sim→callback→`s9 -> off`,fabric 10→7 台整併全程連通);
bmv2-fast 以 clone 法編裝完成(`/usr/local/bmv2-fast`,旗標 no/no/no 驗證)。

**主發現 #22(本輪之星):P4 測試床的 host 從未關 NIC offload,bulk TCP 從拓撲誕生起就
不通。** 機制:bmv2 的 pcap 路徑逐 byte 轉發,checksum offload 未填的 TCP 段到對端即被
丟——握手能過(小段),資料流卡零。五週未爆是因為 P4 側歷來只測 UDP/ICMP;NTG 的 iperf3
一上(17×"unable to connect" vs ping 8ms 同時成立)立即現形。ethtool 實驗定罪:關
offload 後同一對 host 16.8MB@23.9Mbps。修復=`disable_host_offloads()` 進共用 topo 基座
(`c97d9e2`)。**這是「只有真串接才抓得到」的教科書案例:每個元件單獨全綠,組合即死。**

**NTG 發現三連(#20-21,upstream 材料)**:

> ⚠️ **#20 已於 2026-08-16 凌晨被同 fabric 重測推翻大半,引用前先讀
> `doc/2026-08-15_ntg-upstream-report-draft.md` 第 1 條的更正紀錄**。一句話版:
> 「卡 3/永久洩漏」的真機制是 fixed_traffic 的維持性重啟尾巴(最後一代跑滿 duration,
> 300s interval 實際 ~570s 收尾),重測兩輪都自我善終、計數器歸 0;「~1% 遺失」作廢,
> 錯誤路徑與 SIGINT 兩個子主張降級為「單次觀察待重測」。本節以下原文保留當歷史紀錄。

- **#20 失敗流讓 RUNNING 計數器永久洩漏**:錯誤路徑不走完成回呼 → 「waiting for all
  connections to be restored: 303」無限等待 → 同進程後續實驗全數卡死;**連它自己的
  SIGINT 清理路徑也在等同一個計數器**(Ctrl-C 被吞、退出流程死鎖,只能 SIGTERM)。
  反向驗證(含更正):offload 修復後流量正常完成,`decreasing running count by 1` 正常
  扣減,計數器 303 排水到 **3**——**但那 3 對永遠卡住**(296 成功+4 錯誤+3 失蹤=303),
  等待迴圈依舊無限。即成功輪也有 ~1% 完成回呼遺失,實驗**不會**真正自我善終,
  收尾仍需人為中斷(這次計數小,Ctrl-C 的清理路徑有走完、拓撲乾淨收掉)。
  upstream 回報時這是最有力的量化證據。
- **#21 空距離桶=整隻工具崩潰**:`_handle_flow_command` 對空 `conns` 做 `randrange(0)`,
  無驗證無錯誤訊息。本 fabric 的分類真相(裝甲保命後 debug dump 直讀):**全部 host pair
  落在 far**(near/middle 皆空)——兩種路徑長度 {3,5} 被 3-way k-means 分成「far 獨大」。
  ⚠️ 我第一次的 template「修正」方向猜反(zip 順序推理 vs 實測 dump),
  [[arithmetic-that-fits-is-not-the-mechanism]] 又添一例。
- **bridge 裝甲的兩課**:NTG 的 `command_line` 不可重入(loguru `remove(0)` 單發)→
  重入前要 no-op 其 logger_config;崩潰預算防熱轉。v2 實測:崩潰印一次、fabric 存活、
  提示符可用(連 link relationships 都重算成功)。

**操作性結論**:多 actor 同時放行會互踩(energy 整併 vs NTG 起流的 race 讓首輪 iperf 全
夭折)——串接測試要**一次一個 actor、前一個穩定再放下一個**。`ndtwin-lab` wrapper
(tools/test_workflow/,**未 commit**——安全面檔案留 Adam 過目後自行 commit/安裝)裝好後
topo/NTG 打字/energy/sim 全部可由 agent 自駕。

## 環境現況(01:05,本輪結束時)

在跑:NTG 的 Mininet(Adam 終端的 NTG CLI)、Ryu :8080/:6653、kernel :8000(OVS)、
Web-GUI ×3、NSR(新進程 119019)、request_manager :8002、TE-App(10s 週期,殘留的
遷移表項在 s1)。已收:P4 全套、energy/sim_server(Adam 手動)、我方測試流量(自然結束)。
收環境:kernel/Ryu/TE/request_manager 皆 `kill` 即可,Mininet 要 Adam(`exit` NTG CLI
或 `sudo mn -c`),NSR 用 stop 腳本(注意發現 10 的 sudo)。
