# NDTwin-Kernel 測試說明書（權威入口，2026-08-17）

**這一份是入口。** 想知道「我現在該跑什麼」，讀這份就夠；其餘七份測試文件是背景、歷史
或深入細節，各自的地位列在最後一節。這份刻意保持短——長文件會腐爛得比它被讀的速度快。

**適用範圍**：本 repo（kernel + P4 proxy）。跨元件串接看
`doc/2026-08-14_cross-component-integration-matrix.md`。

[Co-developed with claude code -- Adam]

---

## 1. 依意圖分派

| 我剛做了什麼 | 就跑這個 | 要多久／要什麼 |
|---|---|---|
| 改了任何程式碼，還沒 commit | `bash tools/test_workflow/run_layers.sh selftest` | 秒級，完全離線 |
| 改完想確認沒弄壞既有行為 | `bash tools/test_workflow/run_layers.sh quick` | 約 2 分鐘，不需要 Mininet |
| 準備 commit／想跑「CI」 | `bash tools/test_workflow/local_ci.sh` | 實測 234–272 秒，6 個 job（GCC 建置+直跑+ctest、Python L1、ASan+UBSan、TSan、clang、p4 覆蓋閘門）。**不 fail-fast**——一次看完所有壞掉的東西 |
| 只想跑單元測試 | `bash tools/test_workflow/l1_unit_tests.sh` | **ctest 與直跑兩種都跑**——ctest 每個 TEST_F 各自一個 process，跨測試污染只有直跑抓得到 |
| 改了 `.p4` | `tools/test_workflow/p4_coverage_gate.sh` | hash 沒變時 14ms；`--force` 強制實測 |
| 動了資料面／要驗一輪 live | 見 §2、§3 | 要起 fabric |
| 想確認 twin 沒說謊 | 見 §4 | 要起 fabric＋有流量 |

**Python 一律用 `p4_proxy/venv/bin/python`。** conda 的 `python3` 缺 grpc/networkx，壞掉的
套件在它底下看起來是綠的。且本 repo 走 `unittest` 不是 pytest——**看 `Ran N` 不要只看 `OK`**，
`__main__` guard 底下的測試根本不會被收集。

**目前基準線（2026-08-17 實測）**：C++ **579 tests / 78 suites**、`p4_proxy/tests` **Ran 454**、
`tests/shell/test_faults.sh` **Ran 60 checks**。數字對不上就是有人動了碼或收集壞了。

---

## 2. 起停 stack

兩種 fabric 不能同時開（`s1..s10` 介面名會撞），切換要收乾淨再起另一套。

### P4／bmv2

```bash
sudo -n /usr/local/sbin/ndtwin-lab topo-start      # 起 Mininet + 10 台 bmv2
bash tools/test_workflow/stack.sh up p4            # proxy -> 等收斂 -> kernel
bash tools/test_workflow/stack.sh wait             # 擋到每台 switch 都 up 且 enabled
```

收：`stack.sh down` 然後 `sudo -n /usr/local/sbin/ndtwin-lab topo-stop`。
收完驗 `pgrep -ax simple_switch_g` 應為空——**不要用 `pgrep -cx`**，comm 有 15 字元上限，
對 `simple_switch_grpc` 恆回 0。

### OVS／Ryu

```bash
sudo -n /usr/local/sbin/ndtwin-lab ovs-topo-start  # NTG 自帶 topo，128 hosts
bash tools/test_workflow/stack.sh up ovs           # Ryu -> Mininet -> 等 -> kernel
```

⚠️ **官方手冊（ndtwin.org/docs）有兩處與本機不符，照抄會失敗**（勘誤已寫成
`doc/2026-08-16_delivery-package/docs-errata.md`，尚未轉交，所以站上仍是舊的）：

1. Ryu 要聽 **6653**，文件寫 `--ofp-tcp-listen-port 6633`。照文件跑 switch 永遠連不上
   controller，**而且沒有任何錯誤訊息指向 port**，只會看到拓撲永不收斂。
2. `sudo ./testbed_topo.py` 會走到 `/usr/bin/python3`（缺 `nornir`/`loguru`，立刻
   ImportError）。要用 ntg-env 的直譯器，或直接讓上面的 `ovs-topo-start` 起。

**Port 佈局**：kernel API **:8000**、P4 proxy **:8081**、Ryu **:8080**。任何寫
「kernel :8080」的舊筆記都是錯的。

---

## 3. 對跑著的 stack 驗契約（L2–L4）

```bash
bash tools/test_workflow/run_layers.sh api p4 --traffic     # 或 api ovs
bash tools/test_workflow/run_layers.sh baseline ovs --traffic   # 建 L4 基準（健康的 OVS 輪）
bash tools/test_workflow/run_layers.sh compare                  # P4 對 OVS 基準
```

`api` = L2 契約 + L3 元件依賴 + log 檢查。`--traffic` 額外要求真的有 flow/path/rate，
`--mutations` 才會去打寫入端點。工具本身在 `tools/contract_test/`，那裡的 README 解釋
為什麼「7 個元件與 kernel 之間唯一的介面就是 `/ndt/*`」使得在一處驗契約等於驗了全部地基。

**規格對照**：`doc/2026-01-02_ndt_api.md` 記載全部 **41** 個端點（§1–§41，與 dispatcher
逐條相符）；其中 **32** 個有機器檢查（2026-08-17 補上 `historical_logging` 三條與
`intent_translator/text` 的錯誤路徑一條）。剩下九條沒有：group／meter 各三（Tier 2，
裁決不動）、`link_failure_detected`／`link_recovery_detected`／`inform_all_destination_paths`
（proxy 每輪 live 都在打，只是沒契約測試）。

⚠️ **MUTATE 類檢查要 `--allow-mutations` 才會跑**，所以它們很久沒被執行過——2026-08-17
第一次跑就抓到兩條**自己壞掉的檢查**（`modify_nickname` 送 `nickname`、`modify_device_name`
送 `device_name`，文件規定的是 `new_nickname` 與 `new_name`，kernel 一直正確地回 400）。
**定期跑一次帶 `--mutations` 的輪次**，否則這一半的套件會靜靜爛掉。

---

## 4. 專用工具

| 工具 | 一句話 | 指令 |
|---|---|---|
| twin 測謊器 | 對帳 twin 宣稱的活流量與實際封包，說謊就 exit 1 | `p4_proxy/venv/bin/python tools/twin_audit/twin_audit.py audit` |
| 故障注入（L5） | 照 `faults.txt` 注入一個具名故障、證明它生效、還原 | `tools/test_workflow/faults.sh list` / `run L-2 --pair 10.0.0.1,10.0.0.2 --iface s1-eth1` / `run-all` |
| qdisc 前後快照 | 每輪注入的前後置，diff 不為空就作廢該輪 | `tools/test_workflow/qdisc_snapshot.sh`（`faults.sh` 自動呼叫） |
| sFlow fuzzer | libFuzzer harness（`-DFUZZING=ON`，clang-only） | `./build-fuzz/bin/fuzz_sflow <corpus> -max_total_time=5400 -timeout=5` |

**跑 `faults.sh` 前要知道的兩件事**（兩件都是它首役當場學到的）：

- **P4 stack 要 `export PATHS_URL=http://localhost:8081`**，否則 `criteria.py` 預設打 Ryu 的
  :8080，paths 通道整輪回 unknown，三通道法定人數**靜默**降成兩通道。
- **訊號注入不要用裸 `sudo -n kill`**：本機 sudoers 沒有 bare `kill` 的 NOPASSWD，注入會
  無聲失敗成 not-injected，而下游 capture 與 verdict 一切「正常」。用
  `FAULTS_KILL="sudo -n mnexec -a 1 kill"`。注入後一律斷言它宣稱的狀態改變
  （訊號驗 `/proc/<pid>/status` 的 `State`，qdisc 驗 `tc qdisc show`）。

**tc 的部分已經好了**：2026-08-15 Adam 補上兩條 `parent` 規則，`sudo -n -l`（08-17 複查）
四條全在，所以 `faults.sh` 預設的安全形式現在直接可用，不必再繞 mnexec。

---

## 5. 環境陷阱（只列最常咬人的，完整清單見 `doc/2026-07-29_environment_gotchas.md`）

- `ifconfig down` 在 bmv2 上會讓**整台 switch** 停止轉送，不是斷一條鏈路。斷單鏈路一律
  `tc netem loss 100%`，**兩端都要下**。
- Mininet 只隔離網路 namespace，**PID 空間與 host 共用**：在 h2 裡 `pkill` 一樣殺全場。
- 監看用的 shell 迴圈要用 `pgrep -f "poll_al[l].sh"` 這種 bracket 寫法，否則會匹配到自己、
  永遠不結束（真的掛過 8 小時）。
- TSan 一定要 `setarch "$(uname -m)" -R`，否則在 main 之前就 FATAL（`local_ci.sh` 已寫死）。
- 對未 commit 的檔案做 mutation 之前先 commit——`git checkout --` 洗掉過未提交的修復。

---

## 6. 其餘七份測試文件現在的地位

| 文件 | 地位 | 什麼時候才需要它 |
|---|---|---|
| `2026-08-07_testing_tools_overview.md` | **參照**：每個工具的完整說明 | 要深入某個工具的設計與取捨時 |
| `2026-07-27_testing_workflow.md` | **參照**：L0–L5 五層架構的定義與理由 | 要新增一層或搬動層界時 |
| `2026-07-28_test_coverage_gaps.md` | **參照**：涵蓋範圍與已知缺口 | 要判斷某個東西有沒有被測到時 |
| `2026-08-10_p4_manual_test_runbook.md` | **手動 runbook**：P4 逐步一步一確認 | 要人工走一輪 P4、或本文件的自動路徑失效時 |
| `2026-08-10_ovs_manual_test_runbook.md` | 同上，OVS | 同上 |
| `2026-07-30_full_test_runbook.md` | **歷史**：OVS+P4 各一輪的早期執行腳本 | 追溯當初怎麼建立基準時 |
| `2026-07-29_p4_status_and_test_guide.md` | **歷史**：2026-07-30 當時的 P4 進度與測法 | 追溯 P4 支援的演進時 |

**唯一的權威是這一份加上它指到的工具本身。** 上表任何一份與這裡衝突，以這裡為準；
與**程式碼**衝突，以程式碼為準，並回來修這一份。
