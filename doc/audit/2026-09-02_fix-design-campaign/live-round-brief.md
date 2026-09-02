# 09-02 整機一輪（live round）派工稿 —— 合進 trunk 後立即派（Adam 19:1x 授權：不用等他；19:2x：所有 tool 都要測過）

## 前置
- 基底：trunk 合併後的 HEAD（記 sha）。主 worktree 沒有 build/：先照 KNOWN-ISSUES §G「生產線 kernel 重建配方」在主 worktree 建 `build/`（shim PATH、JOBS=2），記 `build/bin/ndtwin_kernel` sha256 與 commit。
- `NDT_OWNER=auditor ndt claim 240 "整機一輪：p4 128 + ovs4，所有 tool"`；結束 `ndt down` → 寫 `.test_run/lab.handoff` → `ndt release`。
- raw 全部落 `doc/audit/2026-09-02_live-round/raw/`（不 commit 到 trunk；auditor 之後推 audit-raw）。每個數字旁邊寫 binary sha＋commit。
- 兩輪：`ndt up p4 128` 與 `ndt up ovs4`（P4 與 OVS 分兩輪，中間 `ndt down`＋`ndt clean` 要 0 殘留）。

## 每支 tool 都要有「跑過」的證據（指令、rc、輸出摘要、raw 檔名）
tools/test_workflow: `run_layers.sh`（L0–L3）、`l0_build_check.sh`、`l1_unit_tests.sh`、`local_ci.sh`（若含 asan/tsan 只跑允許時間內的）、`stack.sh up/wait/down`、`ndt up/status --check/down/clean/claim/release`、`cpu_probe.py`／`cpu_report.py`、`faults.sh`、`qdisc_snapshot.sh`、`p4_coverage_gate.sh`、`test_ndt_lab_session.sh`、`test_teardown_guards.sh`、`manifest_backfill.sh`、`derive_p4_topology_json.py`、`test_topo_from_json.py`、`test_topo_model_guards.py`、`greenlet_dump_smoke.py`、`ovs_4host_topo.py`（由 ndt up ovs4 帶）。
tools/contract_test: `run_contract_test.py`（live 全套，兩平面）、`l3_component_check.py`、`check_logs.py`（含 B-3 allowlist 新條目）、`compare_baseline.py`。
tools/twin_audit/twin_audit.py、tools/make_topology.py、tools/p4_power_helper.py。
harness：`doc/audit/2026-08-30_live-full-stack-round/harness/{00_preflight,10_r1,20_apps_lifecycle,25_apps_energy,30/35_r2_r3,40_r5_p4,50_r5_ovs,90_restore}`（A-8 三態：新路徑不可出現字面 `switch(es) not up`／`BROKEN`）；`doc/audit/2026-08-28_chaos-harness/harness/chaos.py`（含 `_c07` 路由修正後）；`doc/audit/2026-08-31_live-recipes/rider_a2-max-time.md`（Ryu 停掉、十行 listener 佔 :8080 accept 不回）；`tests/shell/check_gate_anchors.py HEAD`。
ndt harness T-9/T-10 儀器（`ndt-harness-t9-t10-instruments` 的 lib.sh：`assert_window_span`、`LISTENER-OWNER-HIDDEN` 三態）。

## 每條修法的 live 配方（各 findings §6；有負控制的要跑負控制）
A-4d（三組負控制）、A-4c（proxy 重啟後 `/p4/switch_state` 的 boot_id／table_generation）、A-4f（OVS 電源循環後 sFlow 紀錄回來、`telemetry_status`；先 `sudo -n -l | grep ovs-vsctl`）、A-8（R5 三態）、A-9（租約到期事件、`/ndt/release_lock` 對死租約的回答）、A-7（`/ndt/get_flow_dispatch_status` 的 `running`／`counters_cover`／壞 port ⇒ failed+1）、A-2（半答案 ⇒ `topology-round-partial` 一行；`--max-time` rider；vendored Ryu app 有沒有載入：`/v1.0/topology/switches` 走我們的副本——證據＝ryu-manager argv）、B-1（P4 幽靈規則被過濾；OVS 半邊：讀碼推論要實測）、B-2b（帶單引號的 body 不再指控元件、不再執行 shell）、B-4（模擬案例含單引號 ⇒ 真的送出）、B-3（MININET 下 `status=not_applicable`＋reason）、B-x（churn 下 `get_detected_flow_data` 預設只回 active）、F-1（MININET 三值＝-1、`ndt status` 註記）、F-6（讀失敗的 switch 仍在表且 `stale_since`；`inv_tables_non_empty` 預期紅的說明）、F-8（`left_link_bandwidth_source`；10G 核心邊）、F-13（六端點對不存在／已存在 group/meter 的 12 格）、F-14/16/4（switch 斷 2 poll ⇒ host 邊 down 帶 down_reason；恢復不主動 up）、F-15（`cat /proc/sys/net/ipv4/ip_local_port_range`、30051–60 全開）、NDT sample rate 行、A-1（孤兒 app rider）。

## 規則
- 不 `pkill -f`／`pgrep -f`；斷鏈路 `tc netem` 兩端；不碰實體 testbed；`ndt` 都帶 NDT_OWNER；長跑包 systemd-run unit（shim PATH）。
- 「跑過」與「讀過未執行」永不混表；每條配方寫預期／實得／判定；紅的不修，記下來回報。
- 產出：`doc/audit/2026-09-02_live-round/REPORT.md`（tool 清單逐一 ✅/❌/未跑＋原因；修法逐條 PASS/FAIL/UNVERIFIED）＋ raw。

## kernel 換裝（整機一輪必然要跑整合後的 kernel）
- 現況：`build/bin/ndtwin_kernel` = 生產版 `e3bad23c…`（Debug -O0 -g，`build/` 1.5G），備份三份：`.test_run/binaries/e-round/ndtwin_kernel.production-backup`、`~/ndtwin-artifacts/production-kernel/ndtwin_kernel.production-2026-08-31`（附 README）、活的那顆本身。
- 重建前：`cp build/bin/ndtwin_kernel .test_run/binaries/pre-integ-2026-09-02/ndtwin_kernel.e3bad23c` ＋ `.provenance`（sha、commit `236a683e`/`06bc60ac` 期間的生產版、日期）；`sha256sum` 驗三份一致。
- 重建：主 worktree `cmake --build build -j2`（shim PATH）於合併後 trunk HEAD；新 binary 旁寫 `build/bin/ndtwin_kernel.provenance`（commit sha、build type、時間、`strings` 驗兩條修法字串各出現）。
- 一輪結束：**新 binary 留在 `build/`**（示範候選），handoff 寫「build/ 是整合後 <sha>，生產版備份在 …」；要退回就 `cp` 備份回來（記進 REPORT）。

## 追加（usertest run-01）
- `ndt apps sim|energy|nsr` 三支：起了之後 `tmux ls`＋行程存活斷言（⑤：ndt 只看 ndtwin-lab rc，印 ok 什麼都沒起）；`ndtwin-lab` 缺席時 `ndt up` 的失敗訊息要清楚（③）。

- 每次 `ndt down`／`stack.sh down`：記 kernel 行程 exit code（wrapper 與真 pid）與 kernel log 末 5 行；預期會看到 `terminate called without an active exception`（run-01 補驗發現，待本機複驗）。
- `ndt apps stop all` 對未啟動 app 的回應（預期假 ok，⑤ 家族）。
