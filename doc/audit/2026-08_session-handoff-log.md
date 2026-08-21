# Session handoff log, 2026-08-12 .. 2026-08-19

[Co-developed with claude code -- Adam]

Twenty-four handoff sections written by successive sessions between 2026-08-12 and
2026-08-19, moved here from the project memory file `ndtwin-state-2026-08-11.md` on
2026-08-21. They were 1,405 of that file's 1,778 lines -- 26% of the entire memory
directory -- and every session was loading them to reach the four current sections at the
bottom.

**This is history. Do not act on it.** The live state lives in memory as
`ndtwin-current-state`. Several sections here were already marked superseded by their own
authors (§5-A "consumed", §5-B "consumed and wholly superseded", §5-C "consumed, see 5-D",
§5-D "candidate ordering superseded by Adam's ruling", §5-H superseded by §5-I, §5-I by
§5-J). They are kept rather than deleted under this directory's rule: historical records
are dated, not corrected, because the reasoning behind a wrong expectation is still worth
reading.

Two things travelled the other way and are *not* here:

- **Twelve standing decisions from §2** are still in force and were kept in memory rather
  than filed here -- design rulings with their reasons that nothing else records, e.g.
  "`intelligent_router.py` does not move, it is the live OVS control plane" and "the twin
  lie-detector reconciles connectivity only, never rates".
- Three §2 decisions about the slide deck (four deferred rulings, bug-page vs
  robustness-page placement, no overnight-round page) were verified landed in
  `NDTwin-slide-template.md` at v4.7 before being filed here. One of them -- the
  asymmetric-link entry -- rests on the 291 s attribution that has since been overturned;
  the template records the correction at its own line 787.

Sections are ordered by date. Each carries a comment giving its original line range in the
source file, so a citation into the old file can still be resolved. Ordering was the only
change: no section was edited, merged or shortened.

## Context the file opened with


> 檔名日期是 08-11，**內容已更新至 2026-08-13 傍晚**。不改檔名以免打斷指向它的 wikilink。
> 取代 [[p4-phase-state-2026-08-10]]。

分支 `fix/flow-rate-divide-by-zero`，head **`c1332bb`**（C8 更正案），全部推上 `p4` remote，0 未推。

> 📁 **2026-08-13 晚：`doc/` 全面改名，每個檔名／資料夾名開頭都是建立日期**（`9e3874c`，
> 105 個改名、532 處引用同步）。舊路徑一律失效，例如 `doc/HANDOFF.md` →
> `doc/2026-07-29_HANDOFF.md`、`doc/p4_bmv2_support_plan.md` →
> `doc/2026-07-27_p4_bmv2_support_plan.md`、`doc/audit/overnight-review-2026-08-12/` →
> `doc/audit/2026-08-12_overnight-review/`。**用的是建立日不是最後更新日**（後者每次編輯都要
> 改名並修所有引用）。`doc/audit/` 本身與其 `README.md` 刻意不加日期。
> ⚠️ **踩到的坑**：批次取代時 `overnight-review-2026-08-12` 這個模式**同時命中記憶體檔名**
> `overnight-review-2026-08-12.md`（那個沒改名），把 `MEMORY.md` 的連結指到不存在的地方。
> 已還原並全掃驗證。教訓：跨目錄批次改名時，記憶體目錄要排除在「資料夾名」的取代之外。
工作區乾淨（只有 `.vscode/settings.json` 一個未提交修改，與工作無關）。

> ⚠️ **2026-08-13 晚，[[two-writers-one-worktree]] 實際發生了一次**：`8/13 mainDev` 與本
> session 同時在**主樹**寫，它的 `039446a` 在我跑 mutation 的同時疊上我的 `1a7d815`，而且它
> push 分支時把我還沒宣告完成的 commit 一起帶上 remote（**push 推的是分支不是單一 commit**）。
> 沒造成損害純屬運氣：它只動 `doc/`，我的 `git checkout --` 只碰三個原始碼檔，零交集。
> **協議（與它談定）**：後來的那個 session 該搬 worktree；它已停手把主樹讓出來。
> **教訓補充**：想 amend 之前先確認 commit 是否已在 remote——我一度以為沒推，前提是錯的。


---

<!-- from ndtwin-state-2026-08-11.md lines 34-45 (2026-08-12) -->
## 0. 2026-08-12/13 整夜測試輪（一段講完，細節全在檔案）

**完整紀錄在 `doc/audit/2026-08-12_overnight-review/INDEX.md`**（8 份
agent 報告＋修復表＋早晨清單，先讀它再讀這裡）。摘要：P4 live 輪（A）＋OVS live 輪（C）＋
5 個靜態 agent（B1-B4、S）全部完成。**當天 16 個 commit 全部驗真（零 P0/P1、7/7 mutant 殺）**；
抓到的真缺陷有三大：**readopt 對健康 switch 清表回 success**（proxy log 四行實錘：仲裁被拒→
pipeline 照推→route 全拒→success）、**Ryu 單向斷鏈黑洞**（DiGraph 不對稱穩態 → BFS KeyError →
路由永不更新，實測 291 秒 100% loss 而 twin 報健康）、**LiveSwitchTest 守衛=「proxy 不在就直連
真 switch」**（當晚真的對 s1 開火）。**三者皆已修**，加上文件批次與兩個防呆工具，共 7 個
修復 commit（`034da18`..`d2a609a`），每條新測試都 mutation gate 紅過。正面結果同樣扎實：
failover 端到端全綠（bmv2 16.63s 自癒 hitless；OVS 對照 52.42s）、949fcba/32afeb9 live 驗證通過。


<!-- from ndtwin-state-2026-08-11.md lines 46-64 (2026-08-13) -->
## 0b. 2026-08-13 下午/傍晚（整夜輪之後的第二段工作）

**又 11 個 commit（`d2a609a..3794ac1`）**，主軸是「把研究報告的建議落地成測試基礎建設」，
外加一輪 live 複驗。詳見 `~/Documents/NDTwin documentation/TESTING-INVENTORY.md`
（**Adam 指定要拿去報告用的歸檔**，一頁摘要可直接當投影片）。

新增的六件測試基礎建設：
| 工具 | 用途 |
|---|---|
| `tools/test_workflow/local_ci.sh` | 一個指令跑完 GitHub workflow 的六件（含 p4cov）；不 fail-fast |
| `tools/test_workflow/p4_coverage_gate.sh` | P4Testgen 覆蓋閘門；只在 `.p4` hash 變動時真跑（否則 14ms） |
| `tests/fuzz/fuzz_sflow.cpp` | libFuzzer harness（`-DFUZZING=ON`，clang-only、零安裝） |
| `tools/twin_audit/` | twin 測謊器（連通性對帳，OVS/P4 通用） |
| `tools/test_workflow/faults.sh` + `faults.txt` | L5 故障注入層，資料驅動、強制 qdisc 前後置 |
| `p4_proxy/tests/test_topology_properties.py` | Hypothesis 圖狀態機（**已裝 `hypothesis==6.165.5`**，已寫進 requirements） |

**live 複驗結果**（`W2-live-reverify.md`）：readopt gate 成立（規則 4→4）、P4 側單向故障
**12.5 秒自癒**（對照 OVS 的 291 秒零自癒）、qdisc 快照零漂移、32afeb9 複驗通過。


<!-- from ndtwin-state-2026-08-11.md lines 65-89 (2026-08-13) -->
## 0c. 2026-08-13 晚（本 session，5 個 commit `1a7d815..cfbbf24`）

| commit | 做了什麼 |
|---|---|
| `1a7d815` | **head-of-line P1 三層修法 + C++ seam**，live 驗證、mutation 7/7 全殺 |
| `918a23c` | 把 mutation 實測結果記進 `doc/audit/2026-08-07_mutation-evidence-cpp.md` 的 Appendix 6，**並更正 `1a7d815` 的 commit message 把預測寫成實測** |
| `ef30fde` | audit 文件從 `~/Documents` 搬回 repo（54 檔） |
| `da31795` | 八條引用修正、`debug-log/` 加 `.gitkeep`、廠商文件加警語、刪掉從未執行的十階段計劃 |
| `9e3874c` | **`doc/` 全面日期前綴改名**（105 個改名、532 處引用） |
| `eabb6eb` | **HANDOFF 逐項核對**＋補上 08-09~08-13 的空白（新的第 6 節） |
| `cfbbf24` | 查證並記錄 HANDOFF #8（OVS 路由的 stale rule），未修 |

**兩個方法論層級的產出，比修好的那個 bug 更值得記：**

1. **py-spy 一次 stack dump 同時證明「誰卡住」和「誰沒卡住」**，推翻了 `W2-live-reverify.md`
   §6.2 記載的機制（觀察對、推論錯）。見 [[py-spy-via-mnexec-under-ptrace-scope]]。
2. **文件引用檢查器的假陽性率 91%**（85 → 33 → 8）。先拿 B2 的已知發現當對照組才敢用它的輸出。
   見 [[new-tools-are-the-first-thing-under-test]]。

**我這輪犯的三個錯（都已修正，但值得下個 session 知道）：**
- 在 commit message 裡把 **mutation 的預測寫成實測**，跑完才發現數字不對——而那時 commit
  已經被另一個 session 的 push 帶上 remote，不能 amend。更正寫在 `918a23c`。
- 批次改名的字串取代**同時命中一個沒改名的記憶體檔名**，把 `MEMORY.md` 的連結改壞。
- 深掃報告裡有一條（`src/app/http.cpp`）是**我的誤判**——那個檔真的存在，在 Energy-Saving-App 裡。


<!-- from ndtwin-state-2026-08-11.md lines 90-112 (2026-08-13) -->
## 0d. 2026-08-13 深夜（收尾 session：驗證輪＋簡報 v1＋關環境）

**本 session 零 repo commit**（產出全在 repo 外）。三件事：

1. **§5 七項驗證全綠**（實跑，非沿用）：local CI 6/6（272s）、C++ 554/70、`Ran 9`/`Ran 64`、
   doc/ 前綴健在、head-of-line 三層都在、origin/main 仍= `8b61cdc`、樹上無別人 commit。
   `commit.patch`（根目錄未追蹤檔）查明= `9e3874c` 的 patch 快照，無害，留著沒動。
2. **簡報 v1 產出**：`~/Desktop/NDTwin Slide material/NDTwin-progress-report-draft-v1.pptx`
   （38 頁、每頁講者備註含素材出處與 template 頁碼）＋ `DRAFT-v1-NOTES.md`（4 個落筆裁定）
   ＋ **generator 已搬耐久**（同資料夾 `generator/build_deck.py` + `qa_deck.py`）。
   工具與環境限制見 [[slide-deck-generator-python-pptx]]。
   途中把 template A2 的 `3292653` 矛盾用 baseline 原文解開：**兩句都對、指不同 overload**
   （`28b8b13:…DeviceConfigurationAndPowerManager.cpp:368` 三參數版會照 caller 要求改 graph、
   scrape 結果只寫 log，但零呼叫點；`:689→:716` 活路徑裸 curl `rc==0`、不碰 graph）。
   deck s22 ④ 據此合寫成一條——**這是偏離 A2 排除表的落筆裁定，待 Adam 確認**。
3. **環境收掉**（Adam 指示收尾）：`stack.sh down` 已跑，kernel/proxy 已停（curl 8000/8081
   驗證不通）。**Mininet（pid 25023）只有 Adam 能收**：`sudo mn -c`。
   ⚠️ **收完預期剩一隻**：s10（pid 180154）是 helper 重啟過的 orphan（ppid= systemd --user、
   比其他九台年輕 1.5h，親代掃描實證；「活過 mn -c」是依 08-12 s6 模式的預測，未驗）→
   要再 `sudo kill 180154`。見 [[p4-orphan-switches-and-manifest-lifetime]]。

**Adam 本 session 的裁決只有一個：四項落筆裁定延後、先收尾。**


<!-- from ndtwin-state-2026-08-11.md lines 113-199 (2026-08-13) -->
## 0e. 2026-08-13（盤點 session：三分類＋七項全執行）

**Adam 指定的盤點做完了**（§3＋HANDOFF 開放項逐條對程式碼核實），結論三分類：
**甲、等他裁決（9 題）**：stale rule 三選項、readopt election-id、manifest 生命週期、
`src_ip` 型別、bmv2+OVS 並存（`stack.sh switch` 提案）、sudoers tc parent、
§1h/§1k 搬遷、completion handle（驗收 #7）、shell injection（issue #2）。
另等他本人：簡報四裁定＋版面、demo 腳本、他的手動 OVS 輪、Phase 7 設計文件過目。
**乙、刻意不修**：清單照舊（上游合併包、Tier 2、hopsCounter、VLAN、速率對帳、§3 技術債、
wedge 根因、endPass/0116、audit 深掃）。
**丙、真缺**：本機七項＋live 五項（C8-C12）＋feature 級 Phase 3。

**盤點的大發現：HANDOFF 開放項大量過期**——§1k 十條實際只剩 1 條、§2g 四步全完成
（link watchdog 存在且 live 已證）、L2 五 FAIL 全修、§4 三條剩 2。差點誤判 watchdog
「功能不存在」：呼叫點是 bound-method reference（無括號），帶括號 grep 回零——
記進 [[grep-endpoints-misses-concatenation]] 第二例。

**Adam 三個表單全選、live 組選「併入手動輪」。七項執行結果（6 commit `75b70c2..f26f42c`）：**

| 項 | 結果 |
|---|---|
| C7 清理 | 13 個舊 agent worktree 全移除（4 個髒的逐一查證內容都已落地主線）、merged branch 全刪、`commit.patch` 刪、**thrift==0.24.0 進 venv＋requirements**（`75b70c2`） |
| C5 doc | HANDOFF §2g 複驗橫幅＋§1i p4_testbed_topo 列＋§4 P4RoutingStrategy 劃線（`b675dbd`） |
| C3 ping | `criteria.py` 3→**10 發＋`-i 0.2`**（兩者必須同動：10 發×1s 會撞 timeout 變 UNKNOWN）；新增 ProbeShapeTest 4 條含 budget 算術測試；mutant 2/2 殺（`ca4b06d`）。L-3 假 FAIL 從 ~13%/方向 → <0.2% |
| C1 refusal | `RefusalReachesTheEntryPointsTest` 5 條：三入口的**拒絕先於 client 呼叫**＋malformed＋accept 對照；三個 raise→pass mutant 逐一殺（`f7ea971`）。§1k 十條全數關閉 |
| C2 AppMgr | **seam＋首批 11 條測試＋真 bug**：`cleanupAppFolder` 的 sed 未錨定子字串匹配，**清 app 1 連帶刪 app 10/11/100 的 export 行**（constructor 每次啟動都跑）。錨定＋BRE 跳脫修掉，purge 測試跑真 sed 打 temp 檔；mutant 4/4 各由指定測試殺（`0b7dfaf`+`2a97f6c`） |
| C4 spec | `doc/2026-08-13_p4runtime-mastership-spec-check.md`（`f26f42c`）：規格條文釘死——非 primary 的 SetForwardingPipelineConfig **must return PERMISSION_DENIED**，v1.3.0↔main 同文；**殺手佐證：Write RPC 同條檢查 bmv2 有做、pipeline push 沒做**。上游回報只剩 live 第三方重現 |
| C6 fuzzer | 90 分鐘長跑（本 session 背景）＋ local CI 全套複跑——結果見本節末補記 |

**測試基準線更新**：C++ **565 / 74 suites**（+11 = `test_ApplicationManager.cpp`）、
`test_unsupported_match.py` 24→**29**、`test_twin_audit_criteria.py` 59→**63**。

**§0e 末補記**：local CI 於 `f26f42c` **6/6 PASS（234s）**——gcc/python/asan/tsan/clang/p4cov，
p4 覆蓋率 0.851852 未變、未覆蓋集 [414..421] 不變。
**C6 fuzzer**：停在 **1.34 億次執行、cov 67、ft 92、corpus 15、~49k exec/s、rss 523Mb 全程穩定、0 crash**。

**§0e 續：live 組（Adam 08-13 晚重開 Mininet 後實跑）**。head 到 **`d810b8d`**（`24308a7`
requirements 配方更正＋`d810b8d` HANDOFF §4 兩條驗證）。
Adam 起的 topo **只起 10 台 switch、沒推 pipeline**（proxy 才推、proxy 沒起）——
GetForwardingPipelineConfig 回 `FAILED_PRECONDITION`，實證。grpc `50051-50060`、
thrift `9091-9100`、device 1-10、CPU port 255。三項結果：
- ✅ **C9 clone session fallback**（device 9，`p4_client.py` 現成封裝驅動）：第一次 INSERT 成功、
  第二三次 **INSERT 失敗→MODIFY fallback 冪等成功**。**坐實 HANDOFF §4 懸案**：bmv2 對重複 session
  回的是 **UNKNOWN（空 details）不是 ALREADY_EXISTS**——正是 fallback 要對「任何 INSERT 失敗」
  觸發而非 code-specific 的原因（docstring 早記，現在 live 證了）。
- ✅ **C10 counter 讀取**（device 9）：gRPC `read_egress_counter` 讀得到（但它 `except:pass` 吞錯誤回
  (0,0)，光 0 不足證）；**thrift CLI 獨立證非零**：`egress_port_counter[255] = 70 bytes / 1 packet`
  ——就是 C9 裝的 clone session 250→CPU port 255 的複製封包，**C9/C10 互證**。
  ⚠️ **配方兩個坑，`24308a7` 已更正 requirements.txt 註解**：① 裝好的 `simple_switch_CLI` wrapper
  的 `sys.path.append` 指錯（模組只在 `~/P4_Source_Code/behavioral-model/` source 樹），
  ② p4dev-python-venv 的 thrift 是壞 namespace。正解＝**proxy venv 的 thrift ＋ PYTHONPATH 指
  `$BM/targets/simple_switch:$BM/tools`＋直接跑 `sswitch_CLI.py`**（指令在 requirements.txt）。
- 🔴 **C8 mastership 重現：已做（2026-08-13 晚，`c1332bb`），結果是「上游沒有 bug」——
  推翻我們自己的發現，上游回報取消。** 第三方 raw gRPC client（`p4_proxy/reference/
  p4runtime_mastership_probe.py`）三情境實測：① 真正的非 primary（A `(0,2)` primary、
  B `(0,1)` 確認 `"Is backup"`）推 pipeline → **`PERMISSION_DENIED`，bmv2 有做那道檢查**；
  ② election id **重複** → push 過、**Write 也過**（「Write 有檢查、push 沒有」這個殺手佐證
  不存在）；③ 情境②再把在線 primary 的 stream 關掉 → 同一 client／同一 election id／同一種
  RPC 從 `OK` 翻成 `PERMISSION_DENIED`。
  **真肇因在我方**：`p4_client.py` 每個 client 都寫死 `election_id (0,1)`，readopt 開的「新
  client」拿的是現任 primary 的三元組；P4Runtime 規定 unary RPC 依**訊息裡**的三元組認身分、
  不看連線，所以 bmv2 殺掉重複的 **stream**（這才是 `mastership_confirmed=False` 的由來）
  卻照樣受理 push。route 全被拒是因為 `old.stop()`（`topology_manager.py:831`）夾在
  `install_initial_routes()`（`:836`）之前，那時已無 primary 可冒名。
  ⚠️ **下午的 log 本來就寫著 `Election id already exists`（＝重複），是寫報告時被轉述成
  「election id 較低」，機制從此建立在推論上。** 見 [[third-party-repro-catches-false-upstream-report]]。
  防呆（`topology_manager.py:800` 的 mastership gate）**不必動、反而更站得住腳**；
  只有註解寫錯，已一併更正。

**⚠️ 環境現況（2026-08-13 C8 後實測，逐台查過不是推測）**：
`s2` pipeline＋**1 條** entry、`s3` pipeline＋0、`s9` pipeline＋0（C9/C10 留下的，clone session
在 PRE 不算 table entry），**其餘七台（含 s1）全是 `FAILED_PRECONDITION` 空的**——
s1 空正是 C8 情境①「非 primary 被擋下」的副產物。kernel/proxy 都沒起，這些殘留無害，
`sudo mn -c` 一收就沒了。Mininet 還開著。Adam 收環境＝`sudo mn -c`（收完 pgrep 應 0；[[process-liveness-checks-lie-in-two-ways]]
提醒 `pgrep -cx simple_switch_grpc` 因 15 字元上限恆回 0，要用 `-ax simple_switch_g`）。

**環境**：Adam 本 session 又跑了一次 `sudo mn -c`；session 開頭 pgrep 就已 0 隻 bmv2
（**s10 orphan「活過 mn -c」的預測沒有成真**，[[p4-orphan-switches-and-manifest-lifetime]]
那條預測要記得別再引用）。netem 0。live 測試前仍要 Adam 起 Mininet。

**live 組（C8-C12）留給 Adam 手動輪當天，配方已備**：
- C10 counter：`p4_proxy/venv/bin/python "$(command -v simple_switch_CLI)" --thrift-port <9090+n>`
  ——CLI 是 `env python3` shebang、走 TCP 不用 root，venv 已有 thrift。
- C9 clone session：對活 switch 連寫兩次同 session，看 `ALREADY_EXISTS→MODIFY` fallback
  （失敗訊息已改成含 `code().name`）。
- C8 mastership 重現：手寫低階 gRPC（`p4runtime_lib` 會阻塞）；規格半邊已落檔。
- C11 soak/drift：門檻公式 `max(1.5×196√(1/c), 2%)`。C12 wedge 診斷最低優先。


<!-- from ndtwin-state-2026-08-11.md lines 372-413 (2026-08-13) -->
## 1. 目前狀態

**Phase 7（P4 電源機制）全部完成**——機制、測試、helper 安裝、live 驗收都過了，
live 抓到的三個缺陷也各自修完並各自 live 驗證。細節見 [[phase7-state-2026-08-11]]。

**Phase 8（收尾整理）過半：**

| 項目 | 狀態 |
|---|---|
| `requirements.txt` | ✅ 早就做完（protobuf 釘 3.20.3、`requests` 已補），只是沒人標記 |
| `CHANGELOG.md` | ✅ 早就做完（有 `Unreleased — P4/bmv2 support` 段） |
| `pytest.ini` / `__init__.py` | **作廢**——前提是「Python 測試收集不到」，實際 385 條跑得好好的 |
| 搬散落腳本 + 修 `test_10_routes.py` 的 port | ✅ 2026-08-12 完成（`3fc42ed`） |
| shell injection 開 issue | ✅ [#2](https://github.com/Adam010341/NDTwin-Kernel-P4/issues/2) |
| OVS 非退化驗證 | ❌ **未做**（見下方「立即下一步」） |

**測試基準線（2026-08-13 盤點 session 後）**：C++ **565 / 74 suites / 45 檔**
（+11 = `test_ApplicationManager.cpp`）、`test_flow_stats_route.py` 5→**9**、
`test_p4_client_writes.py` 61→**64**、`test_unsupported_match.py` **29**、
`test_twin_audit_criteria.py` **63**。⚠️ **venv 和 conda 都沒裝 pytest**，這套走 `unittest`
（`l1_unit_tests.sh`）——用 `pytest --collect-only` 數會直接 `No module named pytest`。
以下是 08-13 傍晚的舊數字，Python 總數未重新核對：C++ 547 / 69 suites / 43 檔、Python **625**
（`p4_proxy/tests` 395 in 14 檔＋`tests/python` 230 in 7 檔）、shell **6 支**。
一天內 426→547 gtest 是真成長（三個缺陷的迴歸測試＋四組新工具的測試）。
`tests/python/` 用**系統 python3、只能標準庫**；`p4_proxy/tests/` 用 venv——兩個目錄不同直譯器。
ctest 與直跑一致。**一定要用 `p4_proxy/venv/bin/python`** — 見
[[python-tests-need-the-venv-interpreter]]。

**Port 佈局（兩輪 live＋程式碼證實）**：kernel API **:8000**、P4 proxy **:8081**、Ryu **:8080**。
任何寫「kernel :8080」的舊筆記都是錯的。

**環境現況——⚠️ 以 §0e 續段與 §5 第 1 項為準，本段是深夜收尾時的歷史快照、已被 live 輪推翻。**
（深夜快照：kernel/proxy 由 `stack.sh down` 停、待 Adam `mn -c`＋殺 s10 orphan 180154。
**後續實況**：s10 orphan 180154 已不在、Adam 又重開 Mininet 跑 live 輪，**現在 10 台 switch
又活著、s9 被推過 pipeline**、kernel/proxy 仍停。）
`stack.sh up ovs` 有 wedge 防呆（`d2a609a`）：Mininet 活著時會拒絕重啟 Ryu。

**GitHub Actions 額度用完，且 Adam 已裁決不轉公開**（2026-08-13）。CI 改本機跑：
`tools/test_workflow/local_ci.sh`，六件（GCC 建置+直跑+ctest、Python L1、ASan+UBSan、
TSan、clang 建置、p4 覆蓋閘門），**在 `3794ac1` 上 6/6 綠**。
⚠️ TSan 一定要 `setarch "$(uname -m)" -R`，否則 main 之前就 FATAL——腳本裡已寫死。


<!-- from ndtwin-state-2026-08-11.md lines 414-505 (2026-08-13) -->
## 2. 已定案的決定（連理由一起）

- **`FlowLinkUsageCollector` 的 `flowRoutingManager` 參數：移除，不接線。** 理由三條：全 repo
  零讀取點；`FlowRoutingManager` 持有 collector 的 `shared_ptr`，接回去是**循環參照兩個都不
  析構**；`main.cpp` 321→333→339 的順序讓天真的初始化列表只會抓到 null。（`78be6b6`）
- **twin 謊報 is_up 修在 proxy 側，不是 kernel 側。** 理由：`render_switches` 的 docstring
  本來就寫著「連不到的 switch 不該出現」，**違約的是呼叫端**；而 kernel 側改法會影響 OVS 模式
  （OVS 目前正靠 `updateSwitches` 那行把 switch 標上來）。查證過安全：edges 走 `/links`
  是不同端點，且 `updateSwitches` 沒有任何「清單裡沒有就標 down」的邏輯。（`32afeb9`）
- **三態規則**：只有明確的 `False` 才把 switch 排除。「沒探過」不算死亡證據，排除它會讓
  fabric 在每次啟動的頭幾秒變成空的——跟 kernel `p4LivenessFor` 的規則刻意保持一致。
- **VLAN 先不修，只記錄。** Adam 指示。理由：只修一側比不修更糟（見 [[audit-4theme-run-2026-08-12]]）。
- **`intelligent_router.py` 不搬。** 它不是散落腳本，是 OVS 模式活的控制平面：`stack.sh`
  拿它當 Ryu app、`test_route_install_gate.py:35` 用相對路徑讀它、`.env` 指到它、16 份文件提及。
- **散落腳本放 `p4_proxy/reference/`，不是 `p4_proxy/tests/`。** 理由（2026-08-13 修正機制
  描述）：runner 會把沒測試的檔標成 `NO TESTS RAN`，但**真正弄壞 run 的是檔案自己的非零
  exit code**——「那個 label 在該 glob 分支算失敗」是錯的（B1+B2 獨立證實，README 已改）。
  結論不變：那些檔不屬於 suite 的 glob。
- **檔名不改。** 那三個 `test_*.py` 名不副實，但多份 audit 文件引用它們，那是歷史紀錄。
  更正寫在 `p4_proxy/reference/README.md`。

**2026-08-14 新增的定案（C8 之後 Adam 四題全裁）**：

- **簡報那句 bmv2 的處理＝「改寫成我們自己的 bug，而且我們自己抓到了」，但⚠️ 只改 template、
  不要動簡報本身。** 已做：`NDTwin-slide-template.md` Page 33 那一列改成「readopt 清表的真肇因
  是我方 election id 重用、已加防呆、重用本身列為已知限制」，另在該頁 `備註` 加一段完整的
  更正＋方法論亮點（三情境、`Election id already exists` 被轉述成「較低」那個關鍵細節、
  「被問怎麼確定沒搞錯就講這個」）。**`generator/build_deck.py` 與 v1 pptx 都沒動**——deck 仍凍結
  等他過目。
- **election id 重用：不修，寫進已知限制。** 理由（他選的選項描述）：mastership gate 已讓它安全
  （沒拿到仲裁就完全不碰 switch），改政策要重開 Mininet 重驗整條 readopt 流程，
  報告前三週換的是風險不是分數。**注意這也與他 08-13「readopt 強制接管：不做，永久關閉」一致**，
  選「讓 readopt 用較高 election id」會推翻那個決定。
- **Demo 場景＝③ killed switch 的 liveness 三態變化。**（他沒選我建議的斷鏈 failover）
  ⚠️ template Page 32 仍寫著【Adam 後續提供】＋三個候選，**尚未更新**（他說其餘不動）。
  真要寫腳本時：twin 測謊器已 live 驗證過會喊 LYING/exit 1，畫面變化小是已知弱點。
- **下一步＝只改簡報那句，其餘全部不動。** 甲類其他題、C11/C12 都先停。

**2026-08-13 深夜新增的定案**：

- **簡報四項落筆裁定延後。**（Adam 明言「裁定我先不做」）v1 擺著等他過目；四項內容在
  `~/Desktop/NDTwin Slide material/DRAFT-v1-NOTES.md`（s22④ TESTBED 合寫、s20⑤ stale rule
  列入、s16「11 個」保留、s28「11+」下限）。**他裁定前不要動 deck 這四處，也不要催。**
- **收尾：環境關掉。**（Adam 指示）報告素材已齊備於文件，環境不必留。

**2026-08-13 晚新增的定案**：

- **上游合併延到報告（9/03）之後。**（Adam 裁決）理由：報告完全不依賴它，而風險不對稱——
  hunk #15 解錯會靜默 revert 掉 SIGFPE 守衛，上檔則是沒有上檔。三個「想合的理由」逐條被削弱：
  回推是另一件事、上游三個月才動一次（增長不對稱）、**type 5 確定對我們沒用**（架構不同，見 §3）。
  分析已落檔（`doc/audit/2026-08-12_overnight-review/U-upstream-8b61cdc-analysis.md`）。
- **audit／review 文件搬回 repo**（`ef30fde`，54 檔）。落點 `doc/audit/` 下**保留原資料夾結構**
  （`2026-08-12_overnight-review/` 的 INDEX 用檔名互相定址，平鋪會斷）。
  **產生報告的 prompt 一起搬**——方法沒記錄的發現無法重跑。
  **刻意留在 `~/Documents` 的七類，理由寫在 `doc/audit/README.md`**，其中兩個需要留意：
  ① `TESTING-INVENTORY.md`（它自己的檔頭就寫 repo 的 `doc/2026-08-07_testing_tools_overview.md` 才是權威，
  搬進來會變成同一套測試有兩份互相競爭的描述）；② 80 份逐 commit review（給 Adam 逐一過目的
  閱讀材料，不是發現）。另外 `S-slide-review.md`／`DRAFT-message-to-patty.md` 留在原處，
  INDEX 檔頭已加註記，不留斷引用。
- **`hopsCounter` 分母膨脹：不重要，跳過。**（Adam 與 `8/13 mainDev` 討論後裁決）
  連帶：`DRAFT-message-to-patty.md` 的第 (3) 題（閒置歸零取捨）也不必問了。

**2026-08-13 下午新增的定案**：

- **Hypothesis 用在圖狀態機，不用在 live stack。** 研究報告建議驅動 live，實測判斷不可行：
  一個 rule（斷鏈→等偵測→等繞路）要幾十秒，而 stateful testing 要幾百步才有價值。
  兩次黑洞缺陷本質都是**圖狀態機**的 bug，在記憶體裡毫秒級可重現。（`3794ac1`）
- **twin 測謊器只做連通性對帳，不做速率對帳。** 理由：sFlow 1/256 取樣的誤差地板
  196√(1/c)，數值比較會產生無法行動的告警。（Adam 裁決）
- **測謊器是獨立工具不進 production。** 三週時程下不拿 demo 穩定性換架構漂亮；
  獨立工具對 OVS/P4 兩條路都適用。（Adam 裁決）
- **repo 不轉公開，CI 改本機跑。**（Adam 裁決；`local_ci.sh` 就是產物）
- **readopt 回 200 但明示 pending，不改成失敗。** 拓撲重新發現本來就要時間，
  當失敗會讓每次正常 powerOn 都報錯，而沒人能行動的狀態會被學會忽略。（Adam 裁決，`3674ddd`）
- **簡報：單向斷鏈進 bug 頁、readopt 進穩健性頁。** 照 A2 規則機械判定
  （前者在前人的 `intelligent_router.py`、後者在 Adam 自己的 proxy 碼）。（Adam 裁決）
- **不加「隔夜驗證輪」專頁**，發現併進既有頁、來源不提。（Adam 裁決）

**2026-08-13 早上的定案**：

- **readopt 修成「安全失敗」不是「真接管」。** 非 primary → 502 `step:mastership` 不碰
  switch；attempted>0 且 accepted=0 → 502 `step:routes`。理由：真接管牽涉 election-id 政策
  （與 LiveSwitchTest docstring 的 mastership 教義互動），是設計裁決，Adam 說不清楚的等他。
  （`a72a168`）
- **Ryu 單向斷鏈：BFS 只走雙向都存在的邊。** 理由：不對稱是穩態不是暫態（配對事件永遠不來）；
  這樣繞路自動發生、且嚴格不弱於舊行為（舊 crash 案變繞路、舊不可達案照舊）。（`034da18`）
- **主導者可以親手修——當佇列窄且額度只剩一個 Fable。** Adam 當面核准。「不做粗活」優化的
  是寬扇出；佇列窄＋脈絡已在頭上時，開 subagent 的冷啟動反而更貴。條件記在
  [[orchestrator-must-not-do-grunt-work]]。
- **對未 commit 的檔案做 mutation 前一定先 commit。** 我違反了一次（F4 被自己的
  `git checkout --` 洗掉重寫）——[[destructive-shell-traps]] 早寫了，還是踩。


<!-- from ndtwin-state-2026-08-11.md lines 506-634 (2026-08-13) -->
## 3. 尚未解決 / 討論到一半

- **上游合併** — 見 [[upstream-merge-state-fork-28b8b13]]。分岔點 `28b8b13`，上游只多
  `8b61cdc "Add sharding"`（patty, 8/3），但它砸在 `FlowLinkUsageCollector.cpp`。
  Adam 原本以為上游沒動過——**這個前提不成立**。
  **「還沒讀那 666 行」已不成立**（2026-08-13 U agent 讀完，報告
  `Overnight review 2026-08-12/U-upstream-8b61cdc-analysis.md`，500 行）：
  **「Add sharding」只有約 40% 是 sharding**，其餘是新增 sample type 5 parser
  （`8b61cdc:src/…/FlowLinkUsageCollector.cpp:1209`，132 行、**無邊界檢查**）、
  三個 thread 被 `// TODO` 停用、`touchEdgeFlow` map 更新被註解、`::close(m_sockfd)` 被刪、
  第 5 個檔案（`setting/` JSON 的 LAG port 重編）。衝突數 U 與 `merge-tree` 都算 **12**
  （08-12 那次算 10，演算法差異，別把 10 當精確值）：9 clean／5 機械／**7 語意**。
  ⛔ **最危險 hunk #15**（`calAvgFlowSendingRatesImmediately`）：~70 行純縮排包著一個 token
  的修正，解成「take theirs」會靜默 revert 掉 `c127a53` 與 `31b357a` 的 SIGFPE 守衛。
  **Adam 已口頭問過 patty**（2026-08-13）：她說 sharding 主要是把 flow table 切片、
  用不同的鎖避免 race condition——與 diff 推斷一致，但那是**三個關鍵問題裡最不重要的一個**。
  ✅ **2026-08-13 晚 Adam 帶回 patty 對前兩題的回答**：
  **(1) 那些 `// TODO` 是為了發 paper 時把效能衝上去才關的，東西「實際上是可以用的」。**
  → 合併策略確定：**保留我們這邊啟用的版本**，「take theirs」會把能跑的 thread 關掉。
  **(2) sample type 5 是為了 P4 新增的**，她說「p4 switch 只能生成那種格式的 flow sample」。
  **我查證過這句話的意思**（2026-08-13 晚）：type 5 **根本不是 sFlow**，是 40 bytes 的扁平定長
  struct，欄位是**已解析好的** 5-tuple（`+8` in/outPort、`+12` rate、`+16` etherType、
  `+20` frameLength/protocol、`+24/+28` src/dstIp、`+32` frag、`+34` tcpFlag、`+36/+38` src/dstPort），
  沒有原始封包、沒有巢狀 XDR record。意思是：**P4 pipeline 直接吐遙測時做不出完整 sFlow v5**
  （巢狀 XDR ＋ 內嵌 raw Ethernet frame），但吐得出一個定長 header——那些欄位本來就在 metadata 裡。
  ⚠️ **我們沒有這個限制，因為架構不同**：bmv2 clone 到 CPU port → proxy 收 packet-in →
  **proxy 用 Python 合成真正的 sFlow v5**（`sflow_emitter.py:78` `SAMPLE_TYPE_FLOW = 1`，
  含 extended_switch 1001 ＋ raw header record）。她是 switch 直送、我們是 proxy 代送。
  合併影響：我們的 collector 只認 **1/2/3/4**，type 5 是**純新增的 `else if`，不衝突、低風險**；
  但它**沒有邊界檢查**（固定 offset 一路讀到 `+38`，不驗 `sampleLen` 也不驗 buffer 長度）——
  收進來就用 `tests/fuzz/fuzz_sflow.cpp` 打它。
  ⚠️ **還沒問的第 (3) 題**：閒置歸零的取捨（見下方 hopsCounter 條）。
- **Manifest 生命週期** — [[p4-orphan-switches-and-manifest-lifetime]]。兩條都未修，等 Adam 決定。
- **同時開 bmv2 + OVS** — Adam 問過，我查完的結論是**不建議做**：控制平面沒問題
  （`:8080` vs `:8081` 已分開），但兩個 topology 都叫 `s1..s10` 會撞 Mininet 介面名，
  而 kernel 的 API port 和 `#define SFLOW_PORT 6343` 都是編譯進去的、CLI 沒有 port 參數。
  **建議的替代方案是寫 `stack.sh switch p4|ovs`**，把切換包成一步。**Adam 未表態。**
- **Phase 7 設計文件** — Adam 從頭到尾**未對它本身表示意見**。
- **Tier 2（14 條）** — Adam 明確說不動。
- ~~`hopsCounter` 分母膨脹~~ → **2026-08-13 晚 Adam 裁決：不重要，跳過。** 機制仍為
  `AutoRefreshQueue::size()` 是 const 不刷新而 `getSum()` 會，文件記在 runbook §5i，未修、無測試。
- **Adam 自己那輪手動 OVS pass** — 仍未做（agent C 的完整輪不算他那輪；[[ovs-pretest-state-2026-08-11]]）。
- **（2026-08-13 新增）readopt 的 election-id 政策**——要不要讓 readopt 能真接管健康
  switch，Adam 裁決。**⭐ C8 之後這題升級了**：現在知道「每個 client 都寫死 `(0,1)`」
  正是 08-13 清表事故的真肇因（不是 bmv2 的錯），所以這不只是「要不要真接管」，
  而是「同一組 election id 讓新 client 能冒名現任 primary」。
  實測輸入一條：**所有 controller 離線後，用同一組 `(0,1)` 重新 bid 仍可再次當選 primary**，
  所以「每次遞增」不是唯一解，「沿用固定值但確保舊 client 先退場」也在選項內。
- **（新增）§5c `src_ip` 端點回整數**——文件已改成對齊現實；「端點要不要改回字串跟其他端點
  一致」是 API 行為變更，Adam 裁決。
- ~~P4 側單向故障未測~~ → **已測（2026-08-13 下午）**：系統正確處理，canary 12.5 秒自癒、
  規則從 `OUTPUT:1` 改成 `OUTPUT:2`、proxy 零 KeyError。**P4 沒有 OVS 那個 P0。**
- ~~bmv2 疑似接受非 primary 的 pipeline push~~ → ❌ **2026-08-13 晚 C8 推翻，全案結案、
  上游回報取消。bmv2 三個情境都符合規格，肇因是我方 election id 重用。**
  詳見 §0e 續段的 C8 條與 `doc/2026-08-13_p4runtime-mastership-spec-check.md`（已改寫成
  更正稿，含三情境實測表）。W2/INDEX 兩份 audit 已加更正橫幅（歷史紀錄不改寫）。
  **殘留的是一個裁決題，不是 bug**：election id 政策要不要改（見下方 readopt election-id 條）。
- ~~進階測試研究 session~~ → **已完成並落地兩條**（R-4 覆蓋閘門、R-1 fuzzer）。
  報告在 `Advanced testing research 2026-08-13/REPORT.md`。R-3 已做（改成圖狀態機）、
  R-5 soak/drift **未做**（需長時 live）。

**2026-08-13 下午新開的：**

- ✅ **head-of-line blocking（P1）——已修並 live 驗證（`1a7d815`，2026-08-13 晚）**
  【觀察不變】一台 bmv2 被 SIGSTOP → `/p4/switch_state` **60 秒完全無回應**（正常 8ms）→
  圖從 40/40 掉到 **32/40**。單一故障放大成全 fabric 狀態遺失。
  ⚠️ **`W2-live-reverify.md` §6.2 的推論是錯的**（「該端點對每台 switch 做同步 probe」）。
  **py-spy stack dump 直接證據**（proxy pid 26024，stall 中）：event loop 的 MainThread 卡在
  `read_table_entries (p4_client.py:429)` ← `get_flow_stats (api_routes.py:254)` ←
  `run_endpoint_function (fastapi/routing.py:345)`。真正的缺陷是
  **`get_flow_stats` 是 `async def`，而 `read_table_entries` 結尾是無 timeout 的 streaming
  `stub.Read`** → 卡死整個 uvicorn event loop → **所有端點一起死**，switch_state 只是陪葬。
  同一份 dump 證明：`liveness-probe` thread **全程 idle 在正常 wait**（prober 有 1.5s timeout、
  完全健康，快取是新鮮的、Unknown 早就備好，只是沒人能讀）；`AnyIO worker thread` **也全程 idle**
  （threadpool 空著，證明改 `def` 可行）。實測 `/stats/flow/5`：s5 停 → 25s 無回應；健康 → 3ms。
  同類缺陷還有 `add/delete/modify_flow_entry`（都是 `async def` 做同步 gRPC）。
  **第二層（kernel 側）**：`fetchOpenFlowTablesInternal` 用 `curl -s` **沒有 `--max-time`**
  且逐台序列（`DeviceConfigurationAndPowerManager.cpp:997`）。
  諷刺：`readopt` 端點的 docstring 早就寫明這個危險並刻意用 `def`，三個端點沒比照。
  ⚠️ 原本記的兩個修法選項（per-switch timeout / probe 並行化）**都是針對 probe 的，兩個都無效**。
  **實作三層（Adam 裁決全做）**：① `get_flow_stats` → `def`；三個 flow-entry 端點必須維持
  coroutine（要 `await request.json()`）故改用 `run_in_threadpool`。② `read_table_entries` 的
  `stub.Read` 加 deadline。③ kernel `curl -s` → `--max-time 8`（>proxy 的 5s，讓指名 switch 的
  error body 贏過空回應；空 body 早就走 `raw.empty()` 保留舊表，所以輸掉只損失診斷）。
  **Adam 另裁決要補 C++ seam**：`buildSwitchStateCommand` / `buildFlowStatsCommand` 抽成
  protected static（比照既有的 `buildRelayPowerCommand`），`tests/test_RequestDeadlines.cpp`
  一次涵蓋三個對外請求。**live 驗證**：`/stats/flow/5` 503 in 5.004s（原本永不返回）、
  `/p4/switch_state` 全程 1.2–1.9ms、圖全程 40/40。**mutation 7/7 全殺**（5 Python + 2 C++）。
  副產物：`get_flow_stats` 的錯誤 body 原本回 `_MultiThreadedRendezvous`（gRPC 內部類名），
  改成 `e.code().name`——live run 抓到的，[[live-runs-find-what-tests-cannot]] 又一例。
- ~~**L-3 gray failure 的判定不穩定**——30% 雙向丟包下 `ping -c 3` 約 13% 機率三個全丟，
  判定隨機。~~ ✅ **已修（`ca4b06d`，2026-08-13）**：10 發＋`-i 0.2`（間隔必須跟著改，
  否則撞 `timeout_s` 變 UNKNOWN），假翻轉 <0.2%；budget 算術進了測試。
- **`hopsCounter == 0` 的閒置語意，兩邊衝突且必須擇一**（合併時）。**完整脈絡（本 session 查明）**：
  baseline `28b8b13` 本來就不一致——週期路徑 `:1304` 是裸 `continue`（保留前值、無註解），
  即時路徑 `:1427` 是明確歸零。Adam 的 `6f32bca` **拿掉了**週期路徑那個 `continue` 但留著除數
  → SIGFPE（分支名的由來）；`31b357a` 只是把守衛裝回去、忠實還原 baseline 語意，
  **不是重新設計**。patty 是唯一真正做了決定的人（兩條都歸零）。
  ⚠️ 我先前一度說「這可能是我們的 bug」——**那個判斷不對**，不一致是繼承來的。
  Adam 裁決：**作為 bug 是小問題可跳過，作為合併衝突延後到合併時決定。**
- **要不要在 sudoers 補 `tc ... parent` 規則**——目前唯一免密碼的注入形式正好是會替換掉
  TCLink htb 的那個；繞法是透過已授權的 `mnexec` 以 uid 0 跑 tc。**Adam 未表態。**

**2026-08-13 晚新開的（全部等 Adam 裁決）：**

- 🔴 **OVS 路由的「只會加、不會刪」——查證成立，未修。** `intelligent_router.py` 完全沒有任何
  刪除 flow 的路徑（零 `OFPFC_DELETE`／`del_flow`），`add_flow` 也不設 `idle_timeout`／
  `hard_timeout` → 規則永久。**安裝走訪沒走到的 switch，舊規則無限期留著。**
  兩條路徑：**(A)** BFS 走不到——實測本拓撲 20 條無向鏈路、最小度數 3，**斷 1 或 2 條永遠不分割**，
  要 3 條同時斷、只有 4 種組合；**(B) 更容易：switch 掉線重連完全不會重算**
  （`_schedule_route_reinstall` 只在鏈路 up/down 呼叫，重連處理器只 POST 通知 kernel）。
  電源開關會連帶產生鏈路事件而順帶蓋掉 (B)，沒被蓋到的是「資料面正常但控制連線斷掉」。
  ⚠️ **修法不明顯安全**：單向故障時資料面可能仍能從 BFS 已不信任的那個 port 正常轉發，
  刪規則會把「還能走的單向路徑」變成 table miss。
  三個選項：(a) 只留紀錄不動〔我建議〕(b) 只補 (B)：重連時排一次重算，不碰刪除〔小、安全、可測〕
  (c) 連 (A) 一起處理。詳見 `doc/2026-07-29_HANDOFF.md` §2b 第 8 列與 [[replace-vs-add-bug-shape]] 第 7 例。
- **`HANDOFF.md` 的 §1h／§1k 要不要搬出去**——它們是對兩輪舊審查的**逐項歷史判定**，
  混在「目前待辦」裡是這份文件難讀的主因之一。我提議搬到 `doc/audit/` 底下，**Adam 未表態**，
  所以目前只在檔頭標成「當附錄跳過」。
- **`doc/audit/` 底下 65 份剛搬進來的報告沒有深掃。** 我的判斷是**不該做**：它們是歷史紀錄
  （寫的時候正確），用「與現況相符」要求它們是錯的判準。工具（`docref.py`）跑得動，但那是
  session 專屬 scratchpad 裡的檔案，已消失，要用得重寫。

**2026-08-13 深夜新開的：**

- **簡報 v1 的四項落筆裁定**（§2 深夜段、`DRAFT-v1-NOTES.md`）——Adam 明言延後，等他開口。
- **v1 版面未經像素 QA**（機器無 LibreOffice，只做了幾何檢查＋全文校對）——Adam 開檔過
  版面前不算定稿；發現版面問題就改 `generator/build_deck.py` 重跑。


<!-- from ndtwin-state-2026-08-11.md lines 635-680 (2026-08-13) -->
## 4. 立即下一步

**簡報是 driver**（報告約 2026-09-03）。**盤點＋live 輪之後的順位（2026-08-13 更新）**：

- **收環境**：Mininet 又開著（Adam 重開跑 live 輪），**s9 已被推 pipeline**、其餘 9 台空。
  收＝`sudo mn -c`；收完 `pgrep -ax simple_switch_g` 應 0（s10 orphan 180154 已不在，§0d 的
  `sudo kill` 那步作廢——見 [[p4-orphan-switches-and-manifest-lifetime]]）。
- ~~C8 mastership 第三方重現~~ → ✅ **已做（`c1332bb`），結論是上游沒 bug、回報取消**。
  live 真缺清單只剩 **C11 soak/drift** 與 **C12 wedge 診斷**（都需長時 live）。
- **C11 soak/drift（R-5）**——需長時 live＋完整 stack，門檻公式已備（§4 第 6 項）。
- **Adam 過目 v1**：版面（無像素 QA，見 §5 第 4 項）＋ `DRAFT-v1-NOTES.md` 的四項裁定
  （他已明言延後，等他自己開口）
- **下個 session：codebase 收尾盤點**（Adam 2026-08-13 深夜指定，**優先於簡報**）——
  拿 §3「尚未解決」＋ `doc/2026-07-29_HANDOFF.md` 開放項逐條對現況核實，分成
  「等 Adam 裁決／刻意不修／真的還缺」三類，真缺的列成可直接動手的修／測清單給他挑。
- **簡報凍結**：v2 要等 Adam 給回饋才動（屆時直接改 `generator/build_deck.py` 重跑、
  不要從頭重建，venv 重建指令在 §5 第 4 項）

以下編號項是既有待辦的狀態（沿用，供追溯）：

1. ✅ **簡報初版已產出（2026-08-13 晚）**：`~/Desktop/NDTwin Slide material/NDTwin-progress-report-draft-v1.pptx`
   （38 頁、每頁講者備註含素材出處與 template 頁碼對應）。**template 與 S-review 已搬到同資料夾**
   （舊路徑 `~/Desktop/NDTwin-slide-template.md` 失效）。同資料夾 `DRAFT-v1-NOTES.md` 記錄
   **4 個落筆裁定待 Adam 確認**：① TESTBED ④ 合寫兩份實作（3292653 矛盾已用 baseline 原文解開——
   `:368` 死碼會改 graph、`:689` 活路徑 rc==0 不碰 graph，兩句都對）② stale rule 列入 bug 頁第 5 列
   ③「11 個」保留為第一輪數字 ④ mutation「11+」維持下限。A3 重量結果：296 commits、554 gtest/44 檔、
   Python 402+232、shell 6。⚠️ 產出機器無 LibreOffice，只做了幾何 QA 沒做像素渲染——請 Adam 開檔過版面。
2. ~~Adam 寄信給 patty~~ → **三題已答完兩題，第三題不必問了**（2026-08-13 晚）。
   詳見 [[upstream-merge-state-fork-28b8b13]]。結論：`// TODO` 是為了 paper 衝效能才關的、
   東西可用 → **合併時保留我們啟用的版本**；type 5 對我們無用（架構不同）。
   草稿檔仍在 `~/Documents/NDTwin documentation/Overnight review 2026-08-12/`（**刻意沒搬進 repo**）。
3. **Demo 腳本還不存在**（Page 32，2026-08-13 晚重新確認：全 repo `find` 過，零命中）。
   簡報那頁寫的是「**【Adam 後續提供】**」，只給三個候選場景：① 斷鏈 failover 即時展示
   ② Web-GUI 看 P4 拓撲與流量 ③ killed switch 的 liveness 三態變化。
   twin 測謊器已 live 驗證過會喊 LYING/exit 1，但「上台怎麼演」沒寫。
4. **Adam 自己的手動 OVS 輪**——仍未做，他說另找時間（也是 demo 手感）。
5. ~~修 `/p4/switch_state` 的 head-of-line blocking~~ → **已修並 live 驗證（`1a7d815`）**，見 §3。
6. **soak + drift 量測（R-5）**——需長時 live，尚未開始。
   門檻公式已有：`max(1.5 × 196√(1/c), 2%)`，其中 `c = R×T / 3.01 Mbit`。

**在途、下個 session 撿得到的**：
- fuzzer 的 90 分鐘長跑紀錄（79 分鐘、1.05 億次執行、corpus 31→76、零 crash）留在
  **08-13 那個 session 的 scratchpad**，本 session 沒有再跑，**檔案應已消失**。
  要數字就重跑：`./build-fuzz/bin/fuzz_sflow <corpus> -max_total_time=5400 -timeout=5`。
- `build-fuzz/` 已在 .gitignore，重建指令在 `tests/fuzz/fuzz_sflow.cpp` 檔頭。


<!-- from ndtwin-state-2026-08-11.md lines 1164-1190 (2026-08-13) -->
## 5. 建議下一個 session 先對照程式碼確認的（動手之前）

**⚠️ 這一節 2026-08-13 盤點＋live 輪後更新（基準線、head、環境狀態換新）。前提：
本輪基線剛全綠（C++ 565/74、local CI 6/6 見 §0e 末），沒人動碼就不用重跑。**

1. **環境現況（⚠️ 不是收乾淨的）** — live 輪跑完 **Mininet 可能還開著**：
   `pgrep -ax simple_switch_g`（若= 10 就是還開著；**s2/s3/s9 有 pipeline、其餘七台空**，
   見 §0e 續段末的逐台實測；`-cx` 因 15 字元上限恆回 0，別用）。
   kernel/proxy 仍停（`pgrep -ax ndtwin_kernel` 空）。
   要乾淨環境就 `sudo mn -c`。live 測試前不必重起——直接用現成的 10 台。
   `tc qdisc show | grep -c netem`（live 輪沒注 netem，預期 0）。
2. **簡報產物都在** — `ls ~/Desktop/"NDTwin Slide material"/`：應有
   `NDTwin-progress-report-draft-v1.pptx`、`DRAFT-v1-NOTES.md`、template、S-review、
   `generator/`（build_deck.py + qa_deck.py 兩檔）。
3. **head 沒動、無第二寫者** — `git log --oneline -3`（head 應= `d810b8d`、全是已知 commit）、
   `git status --short`（只該有 `.vscode/settings.json`；`commit.patch` 已刪）、
   `git fetch origin && git log --oneline -1 origin/main`（仍應= `8b61cdc`）。
   08-13 晚真的撞過第二寫者，見 [[two-writers-one-worktree]]。
4. **要改 deck 才做** — 生成用的 venv 在舊 session 的 scratchpad、**已消失**。重建：
   `python3 -m venv /tmp/deckenv && /tmp/deckenv/bin/pip install python-pptx defusedxml lxml`，
   然後 `/tmp/deckenv/bin/python build_deck.py out.pptx` ＋ `qa_deck.py out.pptx`。
   ⚠️ 機器**沒有 Node（pptxgenjs 不可用）、沒有 LibreOffice（不能渲染像素 QA）**，
   別浪費時間試。詳見 [[slide-deck-generator-python-pptx]]。
5. **若有人動過碼才重跑基線** — `bash tools/test_workflow/local_ci.sh`（預期 6/6，約 100 秒；
   p4cov 基準：覆蓋率 `0.851852`、未覆蓋 `[414..421]`）。Python 走 unittest 不是 pytest，
   **要看 `Ran N` 不是只看 `OK`**（`Ran 9`／`Ran 64`）。


<!-- from ndtwin-state-2026-08-11.md lines 1191-1213 (2026-08-13) -->
## 文件索引

**這個 session 實際讀過、可以負責任描述的：**

- `doc/2026-08-11_phase7_power_mechanism_design.md` — 三個設計決定、已知殘餘、**Live 驗收結果**（我寫的）
- `doc/2026-07-27_p4_bmv2_support_plan.md` — Phase 0–8 的規格；Phase 7/8 段落我這次改過
- `doc/2026-08-10_p4_manual_test_runbook.md` — P4 啟動順序、`mnexec` 打流量、sFlow 取樣率、判準
- `tools/test_workflow/stack.sh` / `l1_unit_tests.sh` — 起停順序、測試收集規則
- `p4_proxy/reference/README.md` — 五個手動診斷腳本（我寫的）
- `doc/2026-07-29_HANDOFF.md` — 只讀了「刻意延後的技術債」那節（shell injection 範圍）

**知道存在但這次沒打開的**（只列檔名，不臆測內容）：
`doc/2026-08-10_ovs_manual_test_runbook.md`、`doc/2026-07-30_full_test_runbook.md`、`doc/2026-07-27_testing_workflow.md`、
`doc/2026-01-02_ndt_api.md`（只讀了 §6/§7/§8 和端點清單）、`doc/2026-07-28_test_coverage_gaps.md`（只讀了開頭和
§4.6 被 subagent 改過的部分）、`doc/2026-07-29_environment_gotchas.md`、`doc/2026-07-29_p4_status_and_test_guide.md`、
`doc/audit/` 底下各檔。

**2026-08-11 那次的成果**（保留，未變動）：OVS runbook 首次實跑完成、47 條 HIGH 發現全部裁決、
Tier 1 七條全修、Energy-Saving-App 三個 bug 修好但 **`9facb78` 刻意不推**
（見 [[energy-saving-app-power-bug-fix]]）、MCP `ai-tools` server 建好。

---


<!-- from ndtwin-state-2026-08-11.md lines 200-229 (2026-08-14) -->
## 0f. 2026-08-14（C8 之後：甲類第一輪裁決＋teardown reap＋跨 repo 盤點）

head **`b9a5bea`**，全推上 `p4`。工作樹只有無關的 `.vscode/settings.json`。

**⚠️ 機器在 2026-08-14 10:35 重開機過**（Adam 說「不小心關機」）。所有 bmv2、Mininet、
kernel/proxy、netem、veth 全部消失，`/tmp` 無殘留。**關機無條件殺掉所有 orphan**
（orphan 只是被 init 收養的普通行程），只有 systemd 開機起的 `ovs-vswitchd` 在跑（無 bridge）。
所以 §0e 續段記的「s2/s3/s9 有 pipeline」**已作廢**，現在是全空、要 live 得請 Adam 重起 Mininet。

**Adam 這輪裁決（甲類 8 題問了 4 題）**：
| 題 | 裁決 |
|---|---|
| OVS stale rule | **只留紀錄，不動程式**（理由：刪規則會把單向故障下還能走的路變成死路） |
| 指令拼接 / shell injection | **維持現狀不修**（內部系統、簡報已誠實列為已知風險） |
| completion handle（驗收 #7） | **先讓我查範圍再決定** ← ⏳ **我還沒做,這是欠他的** |
| manifest 生命週期 | 他反問「為什麼不直接修產生孤兒的問題」→ 逼出更好的修法，**已做完** |

**✅ teardown reap 已完成（`b9a5bea`）**：`reap_manifest_switches()` 在刪 manifest 之前
照它收掉還活著的 switch，殺前讀 `/proc/<pid>/cmdline` 確認是 bmv2（pid 會回收）。
12 條新測試（`test_readopt.py` 35→**47**）、**mutation 6/6 全殺（實測非預測）**。
🔴 **但我在 grill 時把它標成「有 demo 風險」是錯的**——啟動時本來就有
`pkill -f simple_switch_grpc`，孤兒擋不住下一輪。它是衛生不是風險緩解。
細節與更正見 [[p4-orphan-switches-and-manifest-lifetime]]。

**簡報**：template Page 33 那句「bmv2 接受未取得 mastership 的 pipeline push」已改寫成我方
真肇因＋在備註加了完整的更正故事與方法論亮點。**`build_deck.py` 與 v1 pptx 都沒動**
（Adam 明講「改 template 就好，不要直接改簡報」）。

**甲類還有 4 題沒問**：`src_ip` 型別、bmv2+OVS 並存、sudoers tc parent、§1h/§1k 搬遷。


<!-- from ndtwin-state-2026-08-11.md lines 230-295 (2026-08-14) -->
## 0g. 2026-08-14 深夜（跨元件串接輪：8 元件矩陣完成）

head **`1a35b50`**（矩陣文件 `doc/2026-08-14_cross-component-integration-matrix.md`——
**細節全在那份，這裡只記指標**）。Adam 起 Mininet 後離開，其餘全 agent 自跑。

- **建得起來 10/10**；live 通了：Web-GUI（CORS ✓、烤 localhost ✓）、NSR（zip 落檔實證）、
  Visualizer（JavaFX 在 :0 畫出 14 節點＋即時 flow）、TE-App（lock 生命週期 ✓；**互動式，
  要 `printf '2\n10\n' |` 餵**）、request_manager :8002、kernel 註冊腿（App ID 發到 2）。
- **卡 root 的**：energy_saving_app 與 simulation_platform_manager **main() 自己 mount NFS、
  失敗即退**，預掛會 busy 反而害死它們 → 唯一配方 `sudo ./binary`（已寫在矩陣文件給 Adam）。
  NFS 基建（server/exports/mount points）7/9 就佈好了，只差 root。
- **NTG×bmv2 = 待完成功能**（Adam 裁定），見 [[ntg-bmv2-support-pending-feature]]。
  P4 流量代打 = mnexec iperf/ping（kernel 同見 3 flow、GUI/NSR/Vis/TE 四端同吃）。
- **TE 遷移在 bmv2 上物理觸發不了**（70% 門檻 vs ~17% 天花板）——要 OVS 輪。
- ~~⚠️ 環境本輪結束時是全開的~~ →（**已過時**：08-15 收官時全收乾淨，見 §5-B 第 1 項的實測值）
- 欠 Adam 的不變：completion handle 範圍調查（§0f）＋甲類 4 題。

**§0g 續（08-15 凌晨，OVS/NTG 輪）**：head **`4178c47`**（`5e7ff3d` OVS 輪＋`4178c47`
log 深掃歸檔 `doc/audit/2026-08-15_integration-log-audit.md`，subagent 兩結論被 live 推翻、
裁決前言在檔頭；採信 6 條=矩陣發現 14-19）。

**§0h（08-15 日間，修復輪＋bmv2 調查）**：head **`c0675a6`**（6 commits `fe6a577..c0675a6`
全推 p4；local CI 6/6、L1 572/572——中途一紅是我新 shell 測試沒印 runner 要的 `Ran N` 行）。
Adam 三令（grill 後裁決：只修我方 repo、NFS 用
chmod 版且**要進 documentation 供報告**、效能=報告+配方不動現役 bmv2）。全部完成：
① **NFS 修復 `fe6a577`**（chmod 取代 chown、export 行 best-effort 誠實訊息、cleanup 先查
再 sudo；7 測試+mutation 4/4；CHANGELOG 條目 0 是給報告的敘事）② stack.sh log 輪替
`.prev`（7 shell 測試+mutant 紅）③ proxy switch-entered 背景重試+誠實警語（4 注入時鐘
測試+mutation 3/3，其中 sleep 順序要事件序才殺得掉）④ **NTG×bmv2 bridge 已寫好**
`p4_proxy/mininet/ntg_bmv2_topo.py`+`flow_bmv2_low.json`（combo 直譯器驗過 import 鏈，
等 Adam sudo 實跑）⑤ **bmv2 效能雙翻案**：現裝是 **-O0+全 logging 的 debug build**
（config.log:7 實錘，p4-guide 預設；logging 巨集讓每次查表做丟棄式格式化，`--log-level`
救不了）＋**「170M 本機實測」是出處錯誤——它是文獻值（SIGSIM-PADS '23），本機從未量過
飽和點**，差點寫進簡報。重建配方 `tools/test_workflow/build_bmv2_fast.sh`（獨立 prefix，
LD_LIBRARY_PATH 陷阱在檔頭）未執行等裁決。報告 `doc/2026-08-15_bmv2-performance-report.md`、
源碼分析歸檔 `doc/audit/2026-08-15_bmv2-source-analysis.md`。template Page 29/33 已補注
出處與 build 條件。教訓重演兩件：mutation 前沒 commit 又害 `git checkout` 洗掉未提交修復
一次；文獻值經記憶轉述變「實測」——引數字先查記憶原文的出處欄。

**§0g 續補（08-15 凌晨 OVS 輪的內文——先前編輯誤插 §0h 造成錯位，內容歸屬 §0g）**：
P4 收掉換 OVS（**NTG 自帶
topo、128 hosts；Ryu 要聽 6653 不是 6633**）。全綠：NTG 305/305 對 5.5GB、kernel 同見
39 flow、**TE 壅塞遷移全鏈到 OVS 實表改寫**（modify 就地改 router 表項）、Visualizer
兩 fabric 都證。**能源管線 live 揭穿 NFS 權限鏈**（kernel chown 敗×all_squash×root app
→ 寫 case 失敗 → flag 卡死永久 skip）；**NSR 一次 connection refused 輪詢執行緒就
無聲永死**（進程活著只產空 zip）。「活著≠在工作」本輪三例（energy flag、NSR、TE 三綠
no-op 風險）。明早清單 7 條在矩陣文件末節。log 深掃 agent 報告：scratchpad
`log-audit-report.md`。教訓：pkill -f 連環自殺兩次（wrapper 含 pattern 字面量，
kill 與 relaunch 必須拆呼叫）；表項查證三個解析假象差點記假 bug。

**§0i（08-15 下午，live 複驗＋NTG×bmv2 結案）**：head **`b5bb21e`**（結案輪 296/303 對
556MB 跨 bmv2、kernel 同見 39 flow；⚠️ 計數器排水到 3 永卡——成功輪也漏 ~1% 完成回呼，
實驗不會真善終、收尾靠 Ctrl-C，量化證據入矩陣）。四個上午修復全 live
複驗（NFS=Energy 管線 0.4 秒決策鏈真關 s9、fabric 10→7 整併全程連通；proxy 重試首次送達；
stale cleanup 零警告；log 輪替生效）。**bmv2-fast 已編裝 `/usr/local/bmv2-fast`**
（out-of-tree configure 被源樹 in-tree config 擋 → clone 法過，Adam 補 install；
腳本已改 clone 法並 commit）。**NTG×bmv2 交付結案**——地雷圖見
[[ntg-bmv2-support-pending-feature]]：**⭐ P4 測試床 offload/TCP 潛伏 bug 已修 `c97d9e2`
（bulk TCP 從拓撲誕生就不通，五週沒炸因為 P4 側只測過 UDP/ICMP——真串接才逼出來的
教科書案例）**；NTG 三缺陷=計數器洩漏+SIGINT 清理死鎖（只能 SIGTERM）、空距離桶
randrange(0) 崩潰（本 fabric 全 pair 落 far）、command_line 不可重入（bridge 裝甲以
no-op logger_config + 崩潰預算解）。**race 教訓：一次一個 actor**（energy 整併 vs NTG
起流互踩）。`ndtwin-lab` root-tmux wrapper 寫好**未 commit**（安全面檔案，分類器擋+
本該 Adam 過目自裝；裝好= agent 全自駕含對 NTG CLI 打字）。矩陣文件「2026-08-15 下午」
節為完整記錄。


<!-- from ndtwin-state-2026-08-11.md lines 1146-1163 (2026-08-14) -->
## 5-A. 【2026-08-14 新增，✅ 已消費——該 session 即 §0g-§0i 三輪】給「跨元件串接測試 session」的先驗證清單

**下一個 session 的任務是把 web-gui / NTG / NSR 等兄弟元件串起來實測一次。**
背景與界線全在 [[cross-repo-component-ecosystem]]，**先讀它再動手**。動手前先確認這五項：

1. **環境是空的** — `pgrep -ax simple_switch_g`（預期 **0**，重開機後全清）、
   `pgrep -ax ndtwin_kernel`（空）、`ss -ltn | grep -E ':(8000|8081|8080|3000|3001)'`（空）。
   ⚠️ **不要用 `pgrep -cx`**（15 字元上限恆回 0）。
2. **兄弟 repo 路徑從 `components.env` 讀，不要憑記憶** —
   `bash -c 'source tools/test_workflow/components.env && echo $WEBGUI_DIR $NTG_DIR $NSR_DIR'`。
   它用「往上找 Energy-Saving-App」定位，不是寫死路徑。
3. **現成入口先跑一次再決定要不要自己寫** — `bash tools/test_workflow/l0_build_check.sh --list`
   會列出 8 個元件；`l0_build_check.sh` 本身就是「全部建一次」。**串接測試缺的是 runtime 不是 build。**
4. **Docker 還活著嗎** — `docker info >/dev/null && echo ok`（2026-08-14 實測可用，29.5.3）。
   Web-GUI 只有 Docker 這條路（機器沒有 node/npm/pnpm）。
   ⚠️ `docker compose up` 會起 postgres 等三個 container，是系統級副作用，**起之前先問 Adam**。
5. **這些 repo 是別人的碼** — 預設**只測不改**。要改先問。


<!-- from ndtwin-state-2026-08-11.md lines 296-344 (2026-08-15) -->
## 0k(08-15 深夜,usage 刷新後:深挖輪+裁決輪+無記憶驗收員)

head **`dde0d63`** 全推 p4。§0j 四件的下場:
- **① 深挖已做**(head `40c52fd`):perf 31,717 樣本=**無單執行緒牆**(四 worker 各 16-36%)、
  cycle 全在資料表示層(GMP ~10%、字串鍵 PHV 查表 ~9%、malloc churn ~9-12%,無函式 >5%)
  =configure 已榨完;700M 丟包仍 ~99% 在第一台 switch input buffer。
- **③ 併入①完成**。**② 功能輪全綠**(pipeline/routes/12 對 ping/twin_audit 零矛盾/thrift
  counter/sFlow 鏈活)。~~功能輪揪出「sFlow clone 取樣硬頂 ~0.8/s」~~ → **❌ 深夜全案撤回
  (`0590e00`):取樣自始健康(規格 1/256)。「cap」=量測通道誤認——P4 egress 的 clone
  分支在 `count()` 前就 return(註解明寫 do not count the copy),`counter[255]` 數的是
  punt(LLDP 5s 間隔),所以時間性定額、與流量無關。三層判別實驗定案:wire 19.5 dgram/s
  +kernel 每秒 5-7 量子(皆=規格)vs counter 0.44/s(離群=誤認層)。mainDev 的 kernel
  估計自始正確、三旗標嫌疑解除、「Δ[255]/Δ[1] 比率法」無效(有效=tcpdump :6343 或
  kernel 量子法)。教訓=[[reproducible-is-not-mechanism]] 字面重演:兩窗完美重現只證明
  穩定量著某個東西;翻案靠三層獨立通道對同一事件,不是更多重複。**
- **④ 完成**:completion handle **結案=不需要做**(async FlowDispatcher 已被 1a7d815
  同步化移除+kernel 自 Phase 2 `7856efc` 就解析 200+error-body;joint seam 有
  `test_RoutingStrategies.cpp:202` 一字不差釘著;HANDOFF :574 與 §1f 已標結案,`d2179a2`)。

**裁決輪(兩張表單全答)**:NTG 三條正式回報(稿=`doc/2026-08-15_ntg-upstream-report-draft.md`,
`dde0d63`)、NSR/TE 不報;clone cap 下輪查根因;**tc parent 規則要加**(與我建議相反)——
✅ Adam 已裝(08-15 深夜,`sudo -n -l` 實證兩條 parent 規則生效;之後注入用 `tc qdisc add dev sX-ethY parent 5:1 handle 10: netem …` 不再繞 mnexec)。裝機時 visudo 順帶抓到 `ndtwin-lab` sudoers 檔 0644 非 0440(仍生效,修正指令已給);
src_ip 維持整數;雙 fabric 維持現狀(他確認過我能全自駕切換就不做 switch 子指令);
§1h/§1k 已搬 `doc/audit/2026-07-31_handoff-verdicts-1h-1k.md`(`dde0d63`)。

**§0k 續**:~~仲裁(`192eaaf`)的兩軌影響模型~~ 隨撤回一併作廢(上條)。仲裁過程留下的
真源碼事實仍在:kernel 估計器=天真 ×256(`FlowLinkUsageCollector.cpp:1674`)+零閘門
(`:1701`);量子=3.01Mb。DeepSeek 複判用 v4-pro(`effort` 參數有,開 max)、**Muse Spark
1.2 已復活**(Adam 給新 token、billing 通了;contributor 模式 Adam 裁決可用「本來就是
開源專案」;effort 檔位叫 `xhigh` 不是 max;MCP wrapper 拒 contributor→直接 curl 打
api.meta.ai,key 在 ~/.config/muse_spark/token)。

**⭐ 無記憶驗收員(Adam 主動要的,防記憶偏見)**:opus subagent、worktree 隔離
(=auto-memory 不注入)、知識檢疫(只准官方手冊+--help+系統行為,禁 doc/audit/HANDOFF/
git 考古)、90 分鐘框、環境唯一 actor。**發稿時還在跑**——結果回來要:轉述給 Adam+
餵 DeepSeek 複判(ai-tools 的 deepseek_query,吃原始證據當外部法官)。Gemini 裁定跳過
(機器無整合,現裝=測新工具)。它的發現若與我們認知衝突,**它對的機率不低**——
那正是它存在的目的。

**✅ 驗收輪結果(08-15 深夜全部完成,`fe07ed5`)**:驗收員 29 分鐘、11 PASS/2 FAIL/2 WARN,
報告與三判官審計已入 repo(`doc/audit/2026-08-15_fresh-acceptance-report.md`+
`_acceptance-judgments.md`——**可行動清單在 judgments 檔末節**:3c 最後一跳歸因 bug
(機制已定位,受害面=get_graph_data per-edge,**不是** Energy app——Fable 判官源碼反駁)、
3h CPU/mem=`10+hash(ip)%50` 佔位、手冊端點數 errata(實 ~40 vs 文 29)、src_ip 是
LE 重讀整數(DeepSeek 抓的,併甲類題)、NTG banner 已修(`fe07ed5`)。補測排序:並發
對帳>寫入路徑>多速率>故障矩陣。判官分層實證兩勝:驗收員量子推翻 orchestrator 的
clone cap;有源碼的判官推翻兩個 text-only 判官的共享盲點。`.claude/agents/fable-judge.md`
已入 repo(session 中建的定義不熱載,下 session 才可用)。**


<!-- from ndtwin-state-2026-08-11.md lines 345-371 (2026-08-15) -->
## 0j(08-15 傍晚,吞吐基線 session:§5-B 第 1 項完成)

head **`5d2c038`**(`4b339f2` override seam+`5d2c038` 實測數字),全推 p4。**全程零 Adam
參與**(wrapper v2 已裝——state 寫 v1 是舊的,他收官後補灌了;full-stack 權限實證夠用)。

**A/B 飽和實測完成,數字在 `doc/2026-08-15_bmv2-performance-report.md`「本機飽和實測」節
+template Page 29(已更新)**:stock=40M/24.2M TCP/3.6k pps;fast=460-530M/431M TCP/
50.8k pps=**12-18×**;170M 文獻值兩顆 build 都不描述。機制三實錘:pps 天花板(64B=1400B
同 pps)、丟在第一台 switch input buffer(介面計數器看不見——counter 對帳的地雷)、
on-path 三台各 165% CPU。⚠️ 差點又犯 arithmetic-fits:第一次 pidstat 全 0.5% 是「server
未釋放、負載沒跑」的假象,localize 腳本(ip -s link 前後快照)才拿到真值。

**seam=`p4_proxy/mininet/bmv2_binary_override` 檔**(一行絕對路徑;absent=stock 原樣、
壞路徑大聲拒絕、LD_LIBRARY_PATH 自動帶 `../lib`);14 tests、mutation 8/8 實殺(M2 要
「相對路徑真的在 cwd 可解析」才殺得掉——executable 檢查會遮蔽天真寫法)。**限制已記錄**:
override 下 ndtwin-p4-power 的 power-ON 會拒絕(argv 帶 env-prefix、helper 無 shell exec),
power-off 不受影響。**override 檔已刪、預設回 stock**;fast build 只過冒煙(pipeline/route/
12 對 ping),**沒跑 L1/CI**。

**環境:全空已驗**(bmv2 0、mininet 0、8000/8081 空)。工作樹多了 `scratch/`(Adam 的
審閱快照:兩個 topo 檔+diff.txt,16:35 建——同 patch.diff 性質,別動)。

**usage 中斷收尾,剩給下輪**:①效能報告的 py-spy/perf 深挖(fast build 只到 53% 利用率
就 24% loss@700M——結構層在哪還沒證)②fast build 跑完整 L1 ③round 2 的 localize CPU
證據補齊(round 1 有)④§5-B 第 3/4 項(upstream 回報包裁決、completion handle+甲類 4 題)。
**⑤ 已做(08-15 加班):公開手冊條目草稿** `doc/2026-08-15_bmv2-performance-build-public-manual-draft.md`(commit `32a8831`,英文正文+內部前言);投遞前 Adam 要:刪內部前言、補 SIGSIM-PADS '23 確切篇名、與兩條 errata(6653、ntg-env python)一起給 patty。


<!-- from ndtwin-state-2026-08-11.md lines 1131-1145 (2026-08-15) -->
## 5-B. 【2026-08-15 收官】✅ **已消費且全數被後續節取代——只留指標,別照它動手**

該 session 已跑完(即 §0j/§0k 的基線與深挖輪)。**本節原有內容已全部過期,其中三處是
會害人的錯誤前提**,故收攏成指標:
- ~~head `941bf68`~~ / ~~「裝的 wrapper 還是 v1」~~ / ~~upstream 第 3 項「NTG 計數器洩漏」~~
  → 三者皆已不成立。現行 head 見檔頭與 §5-F;**wrapper 實裝已是 v2**(2026-08-17 實測
  usage 行含 `ovs-topo-start`);**「計數器洩漏」08-16 改判為不存在**
  (=fixed 流維持性重啟尾巴),見 [[ntg-bmv2-support-pending-feature]]。
- clone 取樣「硬頂」的完整撤回始末 → **權威記錄在 §0k**(`0590e00`,三層判別實驗)。
  本節原本另抄一份,已刪以免兩處漂移。
- bmv2 吞吐基線、completion handle → 皆已完成/結案(見 §0j-§0k 與 §3)。
- **唯一仍未了的**:`tools/test_workflow/ndtwin-lab` 在 repo **仍未 commit**
  (2026-08-17 實測仍是 `??`)——安全面檔案,Adam 過目後自己 commit。
- 接手工作請看 **§5-F(最新)**,不是本節。


<!-- from ndtwin-state-2026-08-11.md lines 932-1038 (2026-08-16) -->
## 5-E. 【2026-08-16 下午】寫入路徑補測完成(判官 #2 關閉;head `630562d`)

**Adam 兩裁決(表單)**:首選=寫入路徑補測 ✅、之後**照建議序自動接續**(寫入→clone
重現→投遞包→其餘),不逐項回問。3c chip 已因 app 重啟自然失效(dismiss 回報 id 不存在)。

**輪次結果(報告=`doc/audit/2026-08-16_write-path-live-retest.md`,兩 commit
`459acbb` 修復+測試、`630562d` 歸檔,均已推 p4)**:
- **三端點證明誠實**:W1-W7 矩陣、獨立通道(thrift/gRPC read/veth+ping/paths)。
  亮點:W2 fallback 換 port live 首證;W5 真流量 modify **hitless**、delete 黑洞
  39 丟包≡8.1s 窗口、twin paths 逐步跟動(12→11→12);W7 SIGSTOP 寫入 5.004s 誠實
  error+並行 poller 最慢 2.4ms(1a7d815 的 threadpool 半邊 live 補證)+逾時寫入
  未事後落表(觀察值)。
- **三定罪三修(mutation 7/7、fabric #2 live 複驗)**:①bmv2 對 delete-不存在回
  UNKNOWN 非 NOT_FOUND→冪等分支死碼→改目標狀態消歧([[bmv2-unknown-status-vocabulary]]
  **新條目,第三例成形**)②非-strict `/stats/flowentry/delete` 缺失→kernel
  priority=-1 預設(deleteAnEntry 預設值+IntentTranslator 唯一 delete)在 P4 模式
  404→雙路由同 handler、空 match 拒絕(不做 OpenFlow 全清)③畸形 body 500→400
  (共享 `_flowentry_body`)。
- **基準線**:`test_p4_client_writes.py` 64→**70**、新檔 `test_flowentry_endpoints.py`
  **6**;L1 全綠(C++ 579 ctest/直跑一致)。環境兩度起收,終態 0/0 已驗。
- 尚未測(報告誠實列出):並發寫入風暴、priority 語意、非 IPv4、kernel 端到端
  delete(TE/Energy 驅動)。

**⭐ clone 疊加輪也完成(head `2d271e0` 全推;報告
`doc/audit/2026-08-16_clone-stacking-raw-repro.md`)**:五相 raw 重現全中(對照組
釘死觸發點=pipeline commit 非重啟;1→2→3 疊加;我方排除)＋兩更正(「DELETE 回
NOT_FOUND」是推論、實錄=UNKNOWN 空 details=bmv2 字彙第 4 例;「API 清不掉孤兒」被
**phase E 推翻**=簿記持有時 DELETE 銷毀整群含孤兒)＋**settle pair 修復
`79e4f69`**(註冊後再 DELETE+INSERT,任何路徑收斂單 replica;tests 20→23、mutation
4/4、live heal 驗證=probe 疊 2→plain stack start→1 node)。**操作規則降級**:
proxy 重啟必連 fabric=防禦縱深非必要。probe 晉升 `p4_proxy/reference/clone_stack_probe.py`。
上游材料 upstream-grade,**包裝=Q4 等 Adam**(session 尾表單問)。
⚠️ 工作樹多兩檔=Adam 14:55 導出的審閱快照(`diff.txt`=630562d、`diff_459acbb.txt`),
與 patch.diff 同性質別動;他當時在機器旁。

**⭐ 接續序③投遞包也定稿(head `990373a` 全推)**:`doc/2026-08-16_delivery-package/`
四檔(README 給 Adam+ntg-report+bmv2-manual-entry+docs-errata)。SIGSIM 篇名已查證
補齊=**Gong Chen/Zheng Hu/Dong Jin "Enhancing Fidelity of P4-Based Network Emulation
with a Lightweight Virtual Time System" SIGSIM-PADS '23, DOI 10.1145/3573900.3591120**
(170 Mbps 已核對原文 p.4=simple_switch_grpc 16-switch linear;**>64 台 fidelity 崩壞
也出自本文 Fig.4**,[[bmv2-scale-ceiling-and-sflow-sample-math]] 的出處欄可補);
端點 errata 升級為實數 **41**(dispatcher 字面 route 去重)。轉交=Adam 動作。
接續序四項全完成。**尾段兩裁決(表單)**:Q4=**單獨投 p4lang**(issue 稿已寫
`doc/2026-08-16_p4lang-clone-stacking-issue-draft.md`,英文正文+內部前言,等 Adam
過目自貼)、下一步=**續跑多速率點對帳**(非收工)。

**⭐ 多速率輪完成(判官補測序第三項關閉)**:6 點 1M-48M 單流 veth 對帳,24 格
23 PASS、**估計器跨速率線性無漂移**;唯一 FAIL 格(12M h1→s1 1.264)三路旁證+
150s 針對性重測(0.940 全過)裁定=**量測通道噪聲**——機制教訓:usage 欄位是
「last-1s 樣本數×256」無平滑,2s 輪詢只看到一半秒數 → 對帳容差要用
c_eff=c×coverage(實測 coverage=0.51 證實);48M 輕度超載新觀察=丟包沿路徑分散
(非首台全吃,那是重度飽和模式)、twin 仍守約。報告=
`doc/audit/2026-08-16_multi-rate-reconciliation.md`(head **`cbdb503`** 全推,
含 issue 稿;L1 全綠 C++ 579 於 settle 修復之上複跑)。記帳來源對映實錘:
h1→s1=s1 input、s1→s5=s5 input、s5→s2=s2 input、s2→h2=s2 output(後兩者每窗
twin 同值=同樣本集餵兩本帳)。

**⭐ 故障矩陣輪也完成(Adam 表單=續跑;報告=`doc/audit/2026-08-16_fault-matrix.md`)
——判官補測序四項全關**。目錄三型+五延伸型態,**系統零缺陷**(twin 各型態全誠實:
B2 完全隔離 paths 12→6 撤回、B5' SIGKILL 8 邊全判死+全繞 s8 零損失、B3 flap×3
無 wedge);**N-4 的 THEORY ONLY 被否決**=凍結 switch 靠 LLDP watchdog 15s 判死
(process-table 謊言無關),faults.txt expect=still→moving+test_faults.sh 佇列
同步改(60/60 綠)。faults.sh **首役四 harness 發現**:①FAULTS_KILL 裸 sudo kill
無授權→無聲 not-injected(header 已補 mnexec 逃生門)②criteria PATHS_URL 預設
:8080,P4 要 export :8081 否則法定人數靜默剩兩通道(faults.sh header 已補)③本
topo veth 無 htb、root 形式合法④**同一 kill 陷阱 20 分鐘內咬了我自己的 stage3**
(B4/B5 無聲未注入,靠 sudo 錯誤行抓回,stage4 重做;教訓=手動注入後必須斷言
/proc State)。時間常數量測:單故障 30s 內收斂、組合故障 ~40-60s;kill 的邊判死
比 freeze 快——**機制歸因(liveness 立即 vs beacon 逐鏈逾時)是推論未驗**,報告
原文標「記錄不定論」,引用時別當定論。

**尾段 Adam 再裁「跑二跟三」=src_ip 覆核+C11 soak 並行**:
- **⭐ src_ip LE 覆核完成(head `4939f9f`,`doc/2026-08-16_src-ip-endianness-review.md`)**:
  「維持整數」裁決成立但前提升級=**LE 重讀整數是三消費端雙向依賴的既成契約**
  (GUI formatters.ts 反轉渲染、TE :333 htonl 重建迴寫、NSR 透傳;kernel 內部網路序
  刻意+api 文件早已載)。改=零增益三 repo 協調。附帶抓到:**TE 的 priority/
  idle_timeout 被 P4 route_flow 靜默忽略→遷移規則永久不老化**(replace-vs-add 族,
  記錄待裁未修)。
- **⭐ C11 soak 完成結案(head `54b4a4e`,`doc/audit/2026-08-16_c11-soak-drift.md`)**:
  3h 三流穩態、18/18 十分鐘窗全 PASS(比值 0.977-1.021、平均 0.9988、容差 2.9%
  用 c_eff);**漂移統計不顯著**(+0.60% 全程 < 1 SE);**RSS 無洩漏簽名**(proxy
  +1.4MB、kernel +1.7MB/3h,無加速);誠實邊界=3h 排除不了更慢的洩漏,過夜輪
  工具已備。環境已收 0/0。**判官補測序四項+R-5 至此全清,本 repo 結構化補測
  清單空了**;殘餘候選只剩 demo 腳本(要 Adam)與 upstream merge(裁定 9/03 後)、
  TE idle_timeout 靜默忽略(記錄待裁)。

**session 收官(Adam 表單=收工)**。下個 session 接手時:head `54b4a4e`、環境 0/0、
工作樹=四項已知殘留+Adam 的三個審閱導出(diff.txt/diff_459acbb.txt/patch.diff);
**欠 Adam 動作**=13 commit 過目、投遞包轉交(NTG+patty)、p4lang issue 貼文;
**待他裁**=TE idle_timeout、demo 腳本時機;9/03 後=upstream merge。

**動手前驗證五項(2026-08-16 夜版,取代 §5-D 的四項)**:
1. 環境:`pgrep -ax simple_switch_g`+`pgrep -ax ndtwin_kernel`+
   `ss -ltn | grep -E ':(8000|8081)'`(預期全空;`-cx` 對 bmv2 恆 0 的坑照舊)。
2. `git log --oneline -3`(head 應 `54b4a4e`)+`git status --short`(應只有
   `.vscode`/`patch.diff`/`diff.txt`/`diff_459acbb.txt`/`scratch/`/`ndtwin-lab`;
   **多了 commit=Adam 過目後動過或投遞包已交,先讀 diff 再動**)。
3. 問 Adam(或看他留言)三件交付的下場:13 commit 審閱、投遞包轉交了沒、
   p4lang issue 貼了沒——貼了要把 issue URL 記回 state。
4. 若要動 clone/寫入路徑:先重讀 `p4_client.py` 的 `write_clone_session`
   docstring(**現在有 settle pair**,序=D,I[,M],D,I)與 `delete_ipv4_route`
   (UNKNOWN 消歧讀回)——舊記憶裡「DELETE-first 治不了孤兒→必須 fabric 重啟」
   已降級,別引用舊版。
5. 測試基準線(2026-08-16 夜):C++ **579**、`test_clone_session.py` **23**、
   `test_p4_client_writes.py` **70**、`test_flowentry_endpoints.py` **6**(新檔)、
   `test_faults.sh` **60**;L1 以 `l1_unit_tests.sh` 實跑為準。


<!-- from ndtwin-state-2026-08-11.md lines 1039-1086 (2026-08-16) -->
## 5-D. 【2026-08-16 午 session-close】並發對帳輪收官(**5-E 進行中,本節候選序已被 Adam 裁決取代**)

**head `bb9aa7e` 全推 p4**(本輪 4 commits):`e86cb4d` 3c 修復(parser 從未讀 type-1
output port+egress 帳本只付 host 邊;7 測試 mutation 7/7)、`f5a7688` clone session
DELETE-first(20 測試 mutation 3/3+操作規則)、`8fee5bf` 對帳報告+NTG 稿更正+矩陣橫幅、
`bb9aa7e` NTG 稿定稿+3h synthetic 標註。
**環境 0/0 已收**(stack down+topo-stop+cleanup 實測);L1 全綠(**C++ 579**=572+7、
ctest/直跑一致;`test_clone_session.py` 18→**20**)。
⚠️ **3c 修復 chip(task_77da611f,上上輪發的)已陳舊**:chip 從未被點,3c 由本輪
親修完成(`e86cb4d`)——**Adam 畫面上若還有那顆 chip,點下去=重複修,直接 dismiss**。

**本輪四個結論(細節全在 `doc/audit/2026-08-16_concurrent-flow-reconciliation.md`)**:
1. **判官頭號缺口關閉**:並發 13-21 流下,有取樣者的邊 twin/veth 總誤差 +0.8~8.7%
   (三輪),3c 修後 sw→host 總比 1.068、與鄰邊逐位互證(transit 守恆)。
2. **3f 定案**:三輪 576 polls 零重複 5-tuple;59-vs-10=ACK 方向流×2+滯留窗
   p90≈13-14s/max≈17s;t+0 矛盾消解。per-flow 警語:last_sec 並發正偏 +29~38%、
   **timeslot 欄位是 hold-last 不可積分**。
3. **⭐ 新 bug 抓到並圍堵**:[[proxy-restart-warm-fabric-multiplies-telemetry]]——
   proxy 重啟×warm fabric=全域遙測×N;**操作規則:proxy 重啟必須連 fabric 重啟**。
   上游材料(PI/bmv2 簿記脫鉤)**待 raw-client 第三方重現**後才可投。
4. **❌ NTG「計數器洩漏」改判並已定稿(`bb9aa7e`)**:卡 3=fixed 流維持性重啟尾巴
   (收尾預算=interval+fixed_duration)。Adam 裁決「先針對性重測再定稿」→ 已做:
   45s kill 風暴(process-death+refused)183/183 全走完成路徑、counter 排空、善終;
   SIGINT 12s 內乾淨退場。三個缺陷子主張全不重現 → **第 1 條定稿 docs/UX 回報**
   (重啟尾巴無文件+等待訊息不透明),#2/#3 不變,**投遞包已可定稿**。
   同 commit:3h 佔位已照裁決文件明標 synthetic(api doc §12/13/21,公式對過源碼)。

**動手前驗證四項**:①環境 `pgrep -ax simple_switch_g`+`pgrep -ax ndtwin_kernel`+
`ss -ltn | grep -E ':(8000|8081)'`(預期全空)②`git log --oneline -3`(head 應
`bb9aa7e`)+`git status --short`(應只有 .vscode/patch.diff/scratch/ndtwin-lab 四項)
③`ls p4_proxy/mininet/bmv2_binary_override`(應不存在)④若跑 live:**fresh fabric
才有單 replica**,驗法 thrift `mirroring_get 250`+`mc_dump`(配方 requirements.txt);
kernel 側新歸因碼在 `FlowLinkUsageCollector.cpp`(`creditHostBoundEgressEdges` 與
type-1 分支的 `outputPort = ntohl(data[index + 8])`),proxy 側在 `p4_client.py`
`write_clone_session`(DELETE→INSERT→MODIFY 序)——動這兩區前先重讀 docstring。
⚠️ 監看類 shell 迴圈用 `pgrep -f "poll_al[l].sh"` bracket 技巧,否則自匹配永不結束
([[process-liveness-checks-lie-in-two-ways]] 第三式,本輪掛了 8h44m 被 Adam 截圖抓到)。
⚠️ Mininet 只隔離網路 namespace、**PID 空間全 host 共用**:mnexec 進 h2 跑 pkill
一樣殺全場([[destructive-shell-traps]])。

**下一步(⚠️ 排序未經 Adam 確認)**:表單裡他點的選項原文=「重測做完**回來再排**」,
所以寫入路徑補測**不是**已核准的下一步——開工前先用表單重問。候選(我的建議序):
①寫入路徑補測(判官 #2:add/delete/modify_flow_entry 全未測,「silent no-op or
dangerous actuation」)②clone 疊加 raw-client 上游重現(重現成功後的**包裝**也還沒裁:
Q4 他答「explain to me later」,白話說明已寫在對話尾,等他選一包投/單獨投/只歸檔)
③投遞包定稿交付(NTG 三條已定稿+errata 三條+bmv2 手冊條目草稿,見 §0j ⑤)
④多速率點、src_ip LE 覆核、C11 soak、demo 腳本、upstream merge(9/03 後)。


<!-- from ndtwin-state-2026-08-11.md lines 1087-1130 (2026-08-16) -->
## 5-C. 【2026-08-16 凌晨 session-close】先驗證清單與接手工作(**已消費,見 5-D**)

**目前狀態**:head **`fe07ed5`** 全推 p4(本輪 9 commits `4b339f2..fe07ed5`)。環境收官時
0/0 已驗;**唯一殘留**=AppArmor 護體的 tcpdump(pid 43008,殺不掉、無害,
[[apparmor-shields-tcpdump-from-kill]])——Adam 說可能重開機,**在不在要重查**。
工作樹:`.vscode`/`patch.diff`/`scratch/`(皆 Adam 的)+`tools/test_workflow/ndtwin-lab`
(未 commit 等他過目)。**3c 修復 chip(task_77da611f)發給 Adam 了,點沒點未知。**
fable-judge agent 定義已註冊可用(session 尾系統通知實證)。

**動手前驗證五項**:
1. 環境:`pgrep -ax simple_switch_g`+`pgrep -cx ndtwin_kernel`+`ss -ltn | grep -E ':(8000|8081)'`
   (預期全空)+`pgrep -af tcpdump`(43008 在=沒重開機,無害不用管;不在=重開過)。
2. `git log --oneline -3`(head 應 `fe07ed5`)+`git status --short`(應只有上述四檔;
   多了 fix 類 commit=Adam 點了 chip 或另一 session 動過,先讀再動)。
3. `ls p4_proxy/mininet/bmv2_binary_override`(**應不存在**=預設 stock;存在=有人選了
   fast build,查清楚是誰為何)。
4. `grep -c "全案撤回" doc/2026-08-15_bmv2-performance-report.md`(應 ≥1;**clone cap 是
   撤回案**,git 歷史 40c52fd/192eaaf 的中間結論全作廢,誰引用誰錯)。
5. 若要跑 L1/CI 先確認沒人動過碼(§5 第 5 項的舊規則照舊;基準:L1 572+14=586 C++?
   ——未複查,以 `l1_unit_tests.sh` 實跑為準)。

**立即下一步(排序)**:
1. **並發流對帳補測**(三判官頭號):NTG 起流(bridge banner 已印正確指令)時用 veth
   計數器對帳 twin 的 per-flow/per-edge 記帳,並反核 59-vs-10 的 double-counting 疑點
   (judgments 檔 3f 節)。全自駕可跑(wrapper+stack.sh+mnexec)。
2. **3c 最後一跳歸因修復**——先查 chip 派了沒(git log / 問 Adam),沒派就照 chip prompt
   的機制敘述動手(受害面=get_graph_data per-edge,**不是** Energy app)。
3. **投遞包定稿待 Adam**:NTG 三條稿(`doc/2026-08-15_ntg-upstream-report-draft.md`)+
   手冊條目草稿(`doc/2026-08-15_bmv2-performance-build-public-manual-draft.md`,SIGSIM
   篇名待補)+errata 三條(Ryu 6653、ntg-env python、端點數 ~40 vs 文 29)。
4. 3h 裁決(CPU/mem 佔位:做真 vs 標 synthetic)、src_ip LE 整數覆核(DeepSeek 發現,
   甲類題附加前提)、C11 soak、demo 腳本、上游合併(9/03 後)——順序 Adam 定。

**本輪已定案(含理由,詳見 §0k)**:clone cap 撤回(三層判別,counter 不數 clone)、
completion handle 不需要做(async dispatcher 已被 1a7d815 移除+kernel Phase 2 就解析
error body)、NTG 三條正式回報/NSR TE 不報(量化證據最強)、tc parent 已裝(Adam 執行)、
src_ip 維持整數、雙 fabric 維持現狀(agent 可自駕切換,不做 switch 子指令)、
§1h/1k 已歸檔、Muse contributor 可用(Adam:開源專案)。

**索引**:驗收報告=`doc/audit/2026-08-15_fresh-acceptance-report.md`(本 session 產出,
可負責任描述);三判官審計+可行動清單=`doc/audit/2026-08-15_acceptance-judgments.md`
(同上);效能報告含撤回節=`doc/2026-08-15_bmv2-performance-report.md`(同上)。
DeepSeek/Muse 判官原始全文只在已消失的 scratchpad,**關鍵結論已全數載入 judgments 檔**。


<!-- from ndtwin-state-2026-08-11.md lines 681-815 (2026-08-17) -->
## 5-F. 【2026-08-17】Adam 對三件交付的回饋輪＋TE idle_timeout 更正(head `5c4f5f9`)

> 📍 **接手請先跳到檔尾的 §5-H（2026-08-19 交接節，最新）**——它有四段狀態、
> 一段「矛盾與被推翻的前提」、六項先驗證。§5-G（08-17）仍有效但已被 §5-H 取代為入口。
> 本節是 08-17 稍早發生了什麼的紀錄，讀完交接節再回來看細節就好。
> （§5-G 排在 §5-F 之後而非之前，是為了不搬動 130 行；索引與 frontmatter 都指向 §5-G。）

**動手前驗證五項全對**(1 環境 0/0/0、2 head `54b4a4e`+工作樹六項已知殘留+0 未推、
5 基準線 C++ **579/78 suites**、clone_session 23、p4_client_writes 70、
flowentry_endpoints 6、faults `Ran 60`)。查清兩件非異常:`.test_run/logs/kernel.log`
的 18:31→21:32 三小時跑**就是 C11 soak 本身**(`54b4a4e` 21:34 歸檔),不是第二寫者;
全程只有 1 warning+1 error,都是啟動時 `/srv/nfs/sim/2` root-owned 殘留清不掉
=`fe6a577` 的 best-effort 誠實訊息在講話。

**⭐ Adam 四答(表單)**:①13 commit(`e86cb4d`..`54b4a4e`)**看過了、沒問題**
②投遞包**還沒轉交**(檔案原樣,我不動)③p4lang issue **不投了、只歸檔**
④本輪做 TE idle_timeout。

**本輪兩 commit,全推 p4**:
- **`2fa09c2` 歸檔裁決落地**:issue 稿、raw-repro 報告、投遞包 README、probe docstring
  四處同標「不投遞只歸檔」(gh 查證 p4lang 上不存在他名下 issue)。順手修 probe
  docstring 的**自我推翻**:「claim under test」是寫在跑之前的假說,而那次跑推翻了
  其中兩點(DELETE 回的是 **UNKNOWN 空 details 不是 NOT_FOUND**;「API 完全構不到孤兒」
  太寬——phase e 的 DELETE 打在**簿記持有時**會銷毀整群)。假說保留但標明是假說,
  底下補實錄。
- **`5c4f5f9` TE 更正**(報告=`doc/2026-08-16_src-ip-endianness-review.md` 新節):
  ⭐ **原記載「TE 在 P4 模式遷移規則永久、不像 OVS 會 idle 老化」被三處獨立推翻**
  ——(a)TE 活路徑=multi-flow(`migrate_only_one_flow_per_round=False`),body **沒有
  idle_timeout 鍵**且打 modify 端點,kernel `makeModifyJob` 連該欄位都沒有
  (b)唯一會送的死路徑送 **0**,kernel `HttpRoutingStrategyBase.cpp:181` 把 0/-1 都當
  「不送」(c)`intelligent_router.py` 零 timeout 生產點。**今天沒有任何生產者要求老化,
  兩個 fabric 都不老化**。priority 那半邊是真的但形狀不同=**LPM 表結構性無 priority**
  (P4Runtime 只給 ternary/range),真正的不對稱是 OVS「疊加」vs P4「取代單槽」;
  而且 `install_initial_routes()` 每次鏈路 transition 都重寫全部 entry
  (呼叫點=`run_watchdog_pass` 與 `handle_packet_in`;**別寫行號**)→ **遷移會被下次
  flap 靜默還原**。
  真做的代價已量:bmv2 JSON **10 張表全 `support_timeout: false`**→要改 .p4+重編+
  全 fabric 重推+proxy 接 IdleTimeoutNotification(P4Runtime 是通知控制器刪)。
  **Adam 裁決=只更正紀錄不改行為**,理由寫進 `route_flow` docstring 與
  `add_flow_entry`(欄位真正被丟掉的地方)。proxy 單元測試 **Ran 454 OK**。
  附帶只記不報(Adam 裁):TE 死路徑 `:546` 三引數呼叫五參數函式=**開啟即 TypeError**。

**⭐ 環境能力更正**:裝的 `ndtwin-lab` **已是 v2**(usage 行含 `ovs-topo-start`),
§5-B「裝的還是 v1」過時 → **OVS 拓撲我也能自己起**。Adam 本輪問「可以自己開 full
stack 嗎/能用說明書的開機方式嗎」,我答:可以(環境 0/0、我只做靜態工作),但說明書
**兩條 errata 還沒修正**(Ryu 要 6653 非 6633、topo 要 ntg-env python)——因為投遞包
還沒轉交給 patty。**他到本節寫下時尚未真的起 stack**(env 仍 0/0)。

**⭐ 第二段(Adam 五問→四裁決,head `6a6f5e3`,共 8 commit 全推)**:他問 doc 區亂不亂／
audit-be3c242 為何在外面／官方文件還能不能開 OVS／要不要做最終測試說明書／SDD 角度
spec 夠不夠完整。四題全照我的建議裁:
- **`1abd22e` audit-be3c242 搬進 `doc/audit/`**。git 查明它**不是歸檔錯誤**:`1f9e4b4`
  07-30 建立時 `doc/audit/` 還不存在(`ef30fde` 08-13 才生)。**資料夾名不改**(保住
  agy-review 與 commit history 的可 grep 識別字)。7 處引用已改。
- **`3680838` 測試說明書 `doc/2026-08-17_testing-manual.md`=唯一入口**,同 commit 給
  其餘七份加地位橫幅(3 參照／2 現役手動 runbook／2 歷史)。**不做第 8 份競爭權威**。
  順手修 `faults.sh` 檔頭過時警告(tc parent 四條 grant 08-17 複查全在,預設安全形式可用)。
- **`7bbe96f` `doc/README.md` 分類索引**——**不開 expired/、不搬檔**(理由:上次改名 532
  處引用還弄壞外部連結;歷史文件「寫的時候正確」)。
- **`470c19d` SDD 補洞**:端點 41／文件 41(完整)／機器檢查 **30→32**。
  ⭐ **三條新檢查 mutation 3/3 實殺**(改 expect_status 各自紅,未 mutate 的對照仍綠)。
  **順帶抓到兩條從沒綠過的既有檢查**:`modify_nickname` 送 `nickname`、
  `modify_device_name` 送 `device_name`,文件規定 `new_nickname`/`new_name`——kernel
  一直正確回 400,因為 MUTATE 要 `--allow-mutations` 才跑所以沒人看見。**51/51 全綠**。
  ⭐ **加檢查當天就推翻文件一句話**:api doc §39 說 `--no-ai` 下 historical_logging 回
  500,實測(契約檢查＋curl 兩通道)**回 200 與 success 形狀**,已就地更正。
- **`6a6f5e3` 副作用警告**:修好 `modify_device_name` 之後寫入才真的發生 →
  kernel 重寫整個 `setting/…P4_10Switches_4Hosts.json`(edges 排到 nodes 前、鍵序不同,
  **~1300 行 diff 但解析後語意完全相同**)。跑完 `--mutations` 要 `git checkout --` 還原。

**live 輪自駕完成**:我自己 `ndtwin-lab topo-start`+`stack.sh up p4` 起(Adam 沒在跑),
驗完 **環境已收 0/0/0、netem 0** 實測。**L2 綠;L3 與 log 兩層仍紅**(見下方待裁)。

**欠 Adam 的剩兩件**:投遞包轉交(NTG+patty)、demo 腳本時機;9/03 後=upstream merge。
**p4lang issue 已結案(不投)**,別再當待辦。
**⭐ 第三段(Adam「都做」→三項全做完,head `763a90f`)**:
- **`45548c8` agy 積壓盤點＋首輪裁決**(`doc/audit/2026-08-17_agy-review-backlog-triage.md`):
  帳=**已審 115／未審 213**;0202–0328 新格式 91 份含 **98 HIGH／113 MEDIUM**。
  本輪只驗 9 條(**明載覆蓋率**):**已修 3**(0225 `if(false)`→真守衛、0214 return→continue、
  0208 `curl -f`→`--fail-with-body`)、**仍活 2**(見下)、**刻意不修 1**(0227 endPass)、
  **待深查 2**(0207 manifest race、0211 readopt 200 吞部分失敗)。
  ⚠️ HIGH 有**三種排版**,抽取器兩版都漏——下輪以 `VERDICT:` 行為準逐檔開。
- **`763a90f` L3 503 修復**:`status>=500` 一律判 MISSING 是錯的,503=刻意停用的守衛
  (且 stack.sh 恆 `--no-ai`)→ L3 每輪必紅沒人看。改成 exists+註記,500/502/504 照舊紅。
  **live 驗證 exit 0**。
- 🔴 **`763a90f` 抓到真缺陷(本日最重)**:
  **`/ndt/install_flow_entry` 缺 `priority` → 回 400 但規則真的裝上交換機**
  (live 實證:表 5→6 條)。機制=`makeInstallJob` 用 `.value("priority",0)` 不丟例外 →
  **enqueue 出去** → 之後 `updateOpenFlowTables`(`DeviceConfigurationAndPowerManager.cpp:2004`)
  用 `.at("priority")` 丟例外 → 外層 handler 把 200 覆蓋成 400。
  **形狀是本 repo 慣見的反面:做了事卻報失敗**,沒人會去查被拒絕的請求做了什麼。
  邊界實測:delete/modify 缺 priority 都正常;install 缺 actions 會正當失敗。
  **危險區只有一格**。報告=`doc/audit/2026-08-17_install-rejected-but-applied.md`,
  含三個修法選項,**未動手等裁決**。
  發現路徑=L2 綠(51/51)但 log 有 `dispatched install failed`——**佇列式端點只驗
  「誠實地說已排隊」,沒有任何一層看派送結果**。

**⭐ 第四段(Adam「開始收尾」→修 install＋CI 存證＋簡報核對,head `13e53df`)**:
- **`ad49347`+`1b1f941` install 400-but-applied 已修**(Adam 選**選項 1**):
  `updateOpenFlowTables` 的 priority/match/actions 改 `.value()` 對齊 `makeInstallJob`,
  `extractKey` 的 match 同步。**行為變化最小**且正好符合 Web-GUI 已假設的語意。
  新檔 `tests/test_FlowTableCacheOptionalFields.cpp` **6 條**、**mutation 4/4 全殺**。
  ⚠️ **M4 一度存活**=我的 match 測試用 install batch,但 `extractKey` 只被 modify/delete
  呼叫(install 不碰)——測試通過卻沒走到它宣稱的碼,改成 modify+delete 才殺掉。
  **嚴重度判定的關鍵證據**:`Web-GUI/src/pages/SwitchFlowTable.tsx:899` 只在
  `priority > 0` 時才放進 body,且其 `api/index.ts:127` 註解寫「priority optional」
  → **不是理論洞,填 0 就觸發**。
- **local CI 6/6 綠(100s)** 於 `1b1f941`;基準線 **C++ 585/79 suites**(+6)、
  `p4_proxy/tests` 453、`tests/python` 238、shell 7。
  🔴 **CI 抓到兩條我自己弄紅的**(`tests/python/test_contract_spec.py` 的後設測試):
  ①rename 測試釘著舊的 `device_name`(與被我修正的 spec 衝突)②`no_error_path_accepts_a_500`
  擋掉我的 503。**流程教訓:我只跑了 `p4_proxy/tests`,沒跑 `tests/python/`。**
  兩者已修(`13e53df`),503 開特例並加一條測試把特例釘死在單一端點。
- **簡報核對清單**=`~/Desktop/NDTwin Slide material/DECK-CROSSCHECK-2026-08-17.md`
  (**未動 template、未動 deck**)。要點:①Page 31 數字要重跑(template 自己就標「動筆時
  重量」並附指令)②Page 32 文件資產三處過時(檔名無日期前綴、缺 doc/README.md 與新測試
  說明書、兩份已降級歷史)③Page 30 只講 L0–L4,**實際有 L5**④新素材三項(install 缺陷、
  契約 32/41、假 PASS 4→6)⑤**p4lang 不投的裁決不需要動 deck**(template 全文沒提)。

**待裁二項**:①agy 剩餘 ~204 份要不要續審②deck 四項落筆裁定＋像素 QA(與數字重跑一起做)。
~~install 400-but-applied~~ 已修。~~L3 503~~ 已修。原存查:L3 把 **503 當成 MISSING**(`l3_component_check.py` 的 `status >= 500`
一律判「route exists but throws」)——503 是 08-11 刻意加的 disabled-mode 守衛,訊息是
錯的,要不要讓 L3 分辨「壞掉」與「刻意停用」②契約套件的 install/modify **在 kernel 端
PASS、proxy 端失敗**(log 有 `dispatched install/modify failed`),佇列式端點只驗了
「誠實地說已排隊」沒驗派送結果=可觀測性缺口,**歸因未完成、記為觀察不下定論**
③agy-review **已審 115／未審 213**(8/16 mainDev 更正我的 201;嚴格算含 0197 是 213)。
**三輪 triage 不是兩輪**:HANDOFF §2d(0057–0106)、§2e(0107–0127)、
**`doc/audit/2026-07-29_codebase-review/ADJUDICATION_agy-reviews_0157-0201.md`**
(2026-08-11,47 個 HIGH;0197 在檔內零命中,嚴謹算未審)。缺口=0001–0056(56)、
0128–0156(29)、**0202–0328(127,自最後一輪以來的真積壓)**。repo 外無其他紀錄
(8/15 mainDev v3 零命中,不必問)。⚠️ **警語**:§2e 與 ADJUDICATION 是 HIGH 級逐條,
§2d 是從 497 條發現裡篩(不完全等同 HIGH-only)——**別對外說「全部審完」**。
🔴 **我的錯誤根因**:`git grep ... | head -10` 截斷了證據,ADJUDICATION 檔在清單第 5 個
但行級命中先吃光十行。見 [[grep-endpoints-misses-concatenation]] 第三例。


<!-- from ndtwin-state-2026-08-11.md lines 816-931 (2026-08-17) -->
## 5-G. 【2026-08-17 session-close】交接:下一輪=Adam 手動測試＋找實際應用案例

### 1. 目前狀態

head **`13e53df`**,本日 **14 個 commit 全推 p4**,0 未推。**環境 0/0/0 已實測**
(bmv2 0、kernel 0、port 0、netem 0)。**local CI 6/6 綠(100s)於 `1b1f941`**。
工作樹=`.vscode`(無關)＋Adam 的四個審閱導出(`patch.diff`/`patch.txt`/`diff.txt`/
`diff_459acbb.txt`)＋`scratch/`＋未 commit 的 `tools/test_workflow/ndtwin-lab`。
**沒有卡住的東西**——本輪 Adam 交辦的全部收斂,剩的都是等他裁或等他動手。

### 2. 已定案的決定(連理由)

- **p4lang clone 疊加 issue:不投遞、只歸檔**(Adam 08-17,取代 08-16 的「單獨投」)。
  理由未明說;但我方曝險已由 settle pair `79e4f69` 關閉,所以歸檔不留開放迴圈。
  四處已同步標記,`gh` 查證 p4lang 上不存在該 issue。
- **doc/ 不開 expired、不搬檔,改建 `doc/README.md` 分類索引**。理由:上次大規模改名
  (105 檔/532 引用)弄壞過 repo 外連結,而歷史文件「寫的時候正確」不該用現況判它。
- **測試文件單一入口 `doc/2026-08-17_testing-manual.md`,同 commit 把其餘七份標地位**。
  理由:只加入口不標舊的=製造第 8 份競爭權威(TESTING-INVENTORY 的前例)。
- **`install_flow_entry` 缺 priority 的修法取選項 1**(`.value()` 對齊 `makeInstallJob`)。
  理由:報告前三週,行為變化最小,且正好符合 Web-GUI 已假設的語意。**選項 2(驗證搬到
  enqueue 前)語意更正確但改變既有拒絕行為,留著沒做。**
- **L3 的 503 不再判 MISSING**;500/502/504 照舊。理由:503=刻意停用的守衛,而
  `stack.sh` 恆 `--no-ai`,原本每輪必紅=沒人看。
- **SDD 只補真缺口兩條**(historical_logging、intent_translator/text 錯誤路徑);
  group/meter 六條維持 Tier 2 不動。
- **agy TypeError(TE 死路徑)只記我方文件不回報**。理由:被旗標關著、不影響現行行為。

### 3. 尚未解決 / 討論到一半

- **agy 剩餘 ~204 份要不要續審**——未裁。首輪 9 條已裁,方法與接手點寫在
  `doc/audit/2026-08-17_agy-review-backlog-triage.md` 第 4 節。
- **兩條經查證仍活的 agy 發現,未修未裁**:①TFM `updateHosts`/`updateLinks` 的**欄位**
  型別守衛缺一半(要 Ryu 送畸形型別才踩,強健性)②電源端點把 `OpResult` 換成硬編 500
  (每次電源失敗都會,`2abf1e3` 寫的復原指引沒人看得到)。
- **deck 四項落筆裁定＋像素 QA**——Adam 明言延後,未動。核對清單已交(見索引)。
- **投遞包轉交**(NTG 維護者＋patty)——Adam 的動作,未做;所以官網兩條勘誤今天複查**仍錯**。
- **`ndtwin-lab` wrapper 仍未 commit**——等他過目自己 commit(安全面檔案)。
- **⚠️ 矛盾/被推翻但要講明的三條**:
  1. **`ovs-pretest-state-2026-08-11.md` 說「Adam 自己的手動 OVS 輪還沒做」——那正是
     下一輪的任務。** 該檔的「OVS 尚未完整再驗證」結論到今天仍然成立,不要當它過期。
  2. **舊記憶把「proxy 重啟必須連 fabric 重啟」當硬規則的段落全部過時**——settle pair
     `79e4f69` 之後它只是防禦縱深。
  3. **`doc/2026-01-02_ndt_api.md` §39 原說 `--no-ai` 下 historical_logging 回 500,
     實測回 200**,已就地更正;引用該節舊版的推論全部作廢。

### 4. 立即下一步(Adam 指定)

**讓 Adam 親自跑手動測試,並找一個實際應用案例驗整體功能。** 我這邊要準備的是:
① 決定用哪個 fabric(手動 runbook 兩份都在,見索引)②提出實際應用案例候選並讓他選
③起環境的指令備妥,**但起停由誰做要先講定**(wrapper v2 讓我能自駕,但這輪的重點是他手動)。

**應用案例候選(全部在 `doc/2026-08-14_cross-component-integration-matrix.md` 有 live 紀錄)**:
- **能源節費管線**(kernel→NFS→simulator→決策→真的關掉 s9,08-15 實測 0.4 秒決策鏈、
  fabric 10→7 整併全程連通)——端到端最完整、跨最多元件
- **TE 壅塞遷移**(全鏈到 OVS 實表改寫)——⚠️ **bmv2 上物理觸發不了**(70% 門檻 vs
  ~17% 天花板),要 OVS 輪
- **斷鏈 failover**(P4 12.5 秒自癒 vs OVS 291 秒零自癒)——對比最戲劇化
- **killed switch 三態 liveness**——**Adam 08-14 已裁定這是 demo 場景**,與報告直接相關

### 5. 文件索引(區分讀過與只知道檔名)

**本 session 實際讀過、可以負責任描述**:`doc/README.md`(我寫的)、
`doc/2026-08-17_testing-manual.md`(我寫的)、`doc/audit/2026-08-17_agy-review-backlog-triage.md`
(我寫的)、`doc/audit/2026-08-17_install-rejected-but-applied.md`(我寫的)、
`doc/2026-08-16_src-ip-endianness-review.md`、`doc/2026-08-16_delivery-package/`(四檔)、
`doc/audit/2026-08-16_clone-stacking-raw-repro.md`、`doc/audit/README.md`、
`tools/contract_test/`(spec.py / run_contract_test.py / l3_component_check.py / README)、
`tools/test_workflow/`(README / faults.sh / stack.sh / run_layers.sh / local_ci.sh 的用法段)、
`~/Desktop/NDTwin Slide material/DECK-CROSSCHECK-2026-08-17.md`(我寫的)。

**知道存在但這次沒打開**(只列檔名,不臆測內容):
`doc/2026-08-10_p4_manual_test_runbook.md`、`doc/2026-08-10_ovs_manual_test_runbook.md`
(只讀了檔頭)、`doc/2026-07-30_full_test_runbook.md`、`doc/2026-07-27_testing_workflow.md`、
`doc/2026-07-28_test_coverage_gaps.md`、`doc/2026-08-07_testing_tools_overview.md`
(以上五份只讀檔頭以加橫幅)、`doc/2026-07-29_environment_gotchas.md`、
`doc/2026-08-14_cross-component-integration-matrix.md`(只讀檔頭)、
`doc/audit/` 底下絕大多數歷史報告、`.git/agy-reviews/` 的 319 份。

### 6. 建議下一個 session 先驗證(開哪個檔、看什麼)

**動手前驗證六項(2026-08-17 session-close 版;取代先前所有版本)**。
每項都寫「開哪個檔／打哪個指令、看什麼」,不要只跑一次 code review。

1. **環境**:`pgrep -ax simple_switch_g`、`pgrep -ax ndtwin_kernel`、
   `ss -ltn | grep -E ':(8000|8080|8081)'`、`tc qdisc show | grep -c netem`
   (收官時全 0,實測過)。⚠️ `-cx` 對 `simple_switch_grpc` 因 15 字元上限恆回 0,別用。
   **非空不等於髒**:看 `.test_run/logs/kernel.log` 最後一行時間戳與開頭的
   `Topology file:` 判斷是誰在跑、哪個 fabric,再決定要不要碰。**一次一個 actor。**
2. **git**:`git log --oneline -3`(head 應 **`13e53df`**)、`git status --short`
   (應只有 `.vscode` 一個 M,加六個 `??`:`patch.diff`/`patch.txt`/`diff.txt`/
   `diff_459acbb.txt`/`scratch/`/`tools/test_workflow/ndtwin-lab`)。
   **多出 commit=Adam 過目後動過或別的 session 進來了,先讀 diff 再動。**
3. **驗「決定 §2 的 install 修法真的在」**:開
   `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`,搜
   `e.at("priority")` —— **應該一個都搜不到**(全部是 `e.value("priority", 0)`)。
   搜得到就是有人 revert 或 rebase 掉了,那個缺陷會回來(400 卻裝上規則)。
   對照測試:`./build/bin/test_routing_strategy --gtest_filter='FlowTableCacheOptionalFields.*'`
   應 **6 passed**。
4. **驗「決定 §2 的 doc 入口真的在」**:`ls doc/README.md doc/2026-08-17_testing-manual.md`
   都要在;`ls doc/audit/2026-07-30_audit-be3c242/` 應有 11 檔(已從 `doc/` 頂層搬進去)。
   **手動測試要照的是 `doc/2026-08-17_testing-manual.md` §2 的起停指令**,不是舊 runbook
   的檔頭——舊的兩份已加橫幅指向它。
5. **官網那兩條勘誤還是錯的**(2026-08-17 WebFetch 複查):要照官方文件起 OVS 的話,
   Ryu 必須 `--ofp-tcp-listen-port 6653`(文件寫 6633)、topo 要用 ntg-env 的 python
   (文件寫 `sudo ./testbed_topo.py`)。投遞包沒交出去之前這兩條都不會自己好。
6. **測試基準線**(要重跑才算數,別引用數字):C++ **585 / 79 suites**、
   `p4_proxy/tests` **453**、`tests/python` **238**、`tests/shell` 7 支、
   契約 L2 **51/51**(帶 `--mutations`)、`test_faults.sh` `Ran 60`、
   p4 覆蓋率 `0.851852` 未覆蓋集 `[414..421]`。
   一次跑完=`bash tools/test_workflow/local_ci.sh`(6 job,實測 100–560s)。
   ⚠️ **跑過 `--mutations` 之後 `setting/…P4_10Switches_4Hosts.json` 會被 kernel 重寫成
   等價但重排的版本**(~1300 行 diff,內容相同),`git checkout --` 還原即可。
   ⚠️ **Python 兩個目錄兩個直譯器**,動 `tools/contract_test/` 要兩邊都跑,
   見 [[python-tests-need-the-venv-interpreter]]。


<!-- from ndtwin-state-2026-08-11.md lines 1214-1349 (2026-08-19) -->
## 5-H. 【2026-08-19 session-close】交接：下一輪＝簡報視覺化／文獻／future work 分析

> 📍 **這是最新節，取代 §5-G 作為接手入口。** §5-G（08-17）的內容仍然有效但已過時：
> 本節的 head 沒有動，因為**這輪刻意零產品碼修改**。

### 1. 目前狀態

head 仍是 **`04b8933`**，branch `fix/flow-rate-divide-by-zero`，**本輪 0 個 commit**。
產品碼**一行未動**（六輪 live 測試全程遵守報告前凍結）。工作樹只有：
`.vscode/settings.json`（無關）＋ `tools/contract_test/spec.py` ＋ `tools/test_workflow/faults.sh`
（後兩者是 08-18 的兩個測試檔修正，**仍未 commit**）。
環境收官時實測 **0/0/0/0**（kernel 0、bmv2 0、mininet 0、netem 0，ports 全關）。
**沒有卡住的東西。**

**本輪產出（全部未 commit，都在工作樹裡）**：

| 產物 | 內容 |
|---|---|
| `doc/KNOWN-ISSUES.md` | **608 行 / 21 條目**，按「示範會不會踩到」排序。**這是現在唯一的彙總出處** |
| `scratch/phase2/` | DeepSeek 盲寫計畫（`PLAN.md` 698 行）＋執行發現（`FINDINGS.md` 1716 行） |
| `scratch/round4/` | `FINDINGS-round4.md` 1036 行 |
| `scratch/round5/` | `PLAN-deepseek.md` 800、`PLAN-muse.md` 459、`CROSS-COMPARISON.md`、`EXP-human-inform-switch-entered.md` |
| `scratch/round6/` | `FINDINGS-round6.md` **977 行**＋ `logs_ovs_archive/` |
| `doc/audit/2026-08-18_live-full-stack-round/` | 14 檔，含 sFlow 準確度報告與兩輪 `.jsonl.gz` 原始資料 |
| 簡報 template | `/home/adam/Desktop/NDTwin Slide material/NDTwin-slide-template.md` → **v4.2** |

### 2. 已定案的決定（連理由）

- **產品碼報告前凍結，六輪嚴格遵守。** A-1／A-2／A-3 全部用**操作繞法**而不改碼。
  理由：A-1 的修法要碰 `powerOn` 的冪等早退（那個早退是**故意**的），報告前改錯比 bug 本身糟。
- **5-tuple 下發報告後再修。** 理由：三層一致——P4 pipeline 有 `flow_5tuple` 且已接進 pipeline、
  proxy 沒接、**TE app 自己也只送 `ipv4_dst`**（帶著 `# TODO: Change to match 5-tuple in HPE`）。
  沒有消費端今天需要它，而現況是誠實回 400 不是靜默降級。詳見 [[single-flow-precision-gap]]。
- 🔴 **Gemini 3.1 Pro（agy）不用了**（Adam 裁定）。理由：兩次都**做完全部工作才在最後一步失敗**，
  69 分鐘零產出。**以後只開 DeepSeek 和 Muse Spark。** 兩個失敗模式見 [[subagent-operating-constraints]]。
- **Muse Spark 給了 repo 存取權**（我改的）：`~/.local/bin/deepseek-agent` 加 `--provider {deepseek,muse}`、
  MCP 加 `muse_spark_agent_task`。共用同一個工具迴圈而非複製腳本。備份 `.bak-2026-08-19`。**實測跑通。**
- **contributor 變體無限制**（Adam 2026-08-19）。理由：全部開源且已在 GitHub
  （`origin = github.com/ndtwin-lab/NDTwin-Kernel`，`doc/audit/` 137 個 tracked 檔）。
  ⚠️ **這條線上已經有兩次憑假設加守衛、兩次都錯的紀錄。看 `git remote` 再推論什麼是私有的。**
- 🔑 **不要再開「模型寫假設」輪**（見 [[model-hypotheses-saturated]]）。理由：round 5 量到
  **42% 提案是已結案的**，兩個不同模型還獨立提出同樣兩條已 CONFIRMED 的發現。
  改成**覆蓋率驅動**（列舉端點／宣稱過的行為／寫入動詞），round 6 第一次就命中中心宣稱＋5 條新缺陷。

### 3. 尚未解決 / 討論到一半

- 🔴 **B 節的增刪行數表還是 08-16 量的**，而 `04b8933` 之後又有 commit。
  **Page 8／Page 9／B 節要一起重跑 `count_lines.py`。我沒動，Adam 說留給他決定。**
  這是 v4.2 唯一沒處理的大項。
- **LLDP 調參**：已寫成 `doc/KNOWN-ISSUES.md` §D-2 待辦，含實驗設計。**報告後做。**
  關鍵洞見：`LINK_BEACON_TIMEOUT_S` 與 watchdog 間隔**都是從 beacon 間隔衍生**的（改一個動三個），
  但 `kLldpFreshSeconds = 12.0` 是 **C++ 常數**；而且**修正窗口由 30 秒 poll 決定，縮 LLDP 不會改善它**。
  🔑 **決定值不值得的數字是誤判率，不是偵測時間**（偵測時間必然會降）。
  ⚠️ 還有個疑點沒解：註解寫偵測 15–20 秒，**實測 10.7–14 秒**，差 5 秒沒解釋。
- **E-H2 判 INDETERMINATE**：`inform_switch_entered` 能否遮蔽 A-2 的 wedge——
  A-2 在約 50 分鐘、兩次 Ryu 啟動裡都沒發作，無法按需製造。
- **213 / 328 份 agy review 從沒被分類**（98 HIGH + 113 MEDIUM），而那份 triage 文件自承抽取腳本不可靠。
  **這界定了 `KNOWN-ISSUES.md` 能誠實宣稱的完整度上限。**
- **agy 0211 需要重新裁決**（readopt 部分失敗被 200 吞掉），08-17 triage 標為可能與
  「completion handle」結論矛盾並明確指示不要繼承任一答案。
- **未討論**：`doc/KNOWN-ISSUES.md` 等一堆新產物**要不要 commit**。整輪都沒提到。

### 3b. ⚠️ 矛盾與被推翻的前提（不要抹平）

- 🔴 **我在 memory 裡寫錯過兩條，都已修，但下個 session 要知道它們曾經是錯的**：
  ① F-17「失效方向保守（少關機不會誤關）」**錯**——實測有負載時高估 4.0×、**閒置時歸零**，
  而 0.0 落在 Energy-App 的 `LOW_WATER_MARK = 0.40` 之下 → **觸發關機**。兩個方向都有。
  ② A-2 的「`is_enabled` 只有一個寫入者」**錯**——有**三個**（poll／`inform_switch_entered` 經
  `setVertexEnable`／liveness worker 的 `setVertexDisable`）。原因是 `grep 'isEnabled = '` 漏掉 setter。
- **兩條旗標敘述看起來衝突，其實不衝突但直覺是錯的**：A-2 的指紋是特定的 `up=true, en=false`；
  round 6 發現 **`up=false, en=true` 是關機交換機的正常穩態**。
  🔑 **所以「兩個旗標不一致」本身不能當故障訊號**，只有那個特定組合可以。
- **`adminDisabled` 我一度以為是寫了沒人讀的旗標**（那會讓 `DisableSwitch` 至今是靜默 no-op）。
  **錯**——它是在 **serialise 出去的那一刻**套用的（`GraphTypes.hpp:346`、`HttpSession.cpp:567`），
  遮罩式而非守衛式。教訓：搜寫入點與搜讀取點會給出相反的結論。
- **一個未解的環境謎題**：本 session 中途我藏起來的 stash（為了盲寫）**不是我還原的**，
  stash 被消耗、`scratch` mtime 是 09:48。當時同機有另一個 session（PID 13143，`--effort xhigh`），
  Adam 說那是他在用的**架構解釋 agent、只讀程式碼**。**所以還原者仍未確定。** 內容驗證過完整無缺。

### 4. 立即下一步（Adam 指定）

**簡報視覺化 ／ 文獻 ／ future work 三段分析。** 他點名四項並要我補充建議：
① demo 影片 ② sFlow 精準度 box plot（**bmv2 vs ovs**）③ failover 速度 box plot（bmv2 vs ovs）
④ bmv2 規模分析（他自己判斷「我們沒實測對吧？可以用文獻探討」）。

**開工前必讀的資料現況——這決定哪幾張圖畫得出來**：

| 他要的圖 | 現有資料 | 缺什麼 |
|---|---|---|
| sFlow 精準度 box plot | **只有 OVS**：兩輪原始資料在 `doc/audit/2026-08-18_live-full-stack-round/sflow_run{A,B}_*.jsonl.gz`，含可重跑的 `run.py`/`analyse.py` | 🔴 **P4 完全沒量過**。要 bmv2-vs-ovs 對照必須新跑一輪 P4 |
| failover 速度 box plot | round 4：OVS 偵測 14s／恢復 3s；P4 偵測 10.7–14s／恢復 ~5s | 🔴 **n=1~2，畫不出 box plot**。要重複注入多次才有分布 |
| bmv2 規模分析 | **他判斷正確：本機沒實測過規模。** 文獻數字已在 [[bmv2-scale-ceiling-and-sflow-sample-math]]（>64 台劣化、256 台剩 17.5%、`simple_switch_grpc` ~170 Mbps，出處已驗證讀過原文 PDF） | 純文獻即可，但**本機實測的飽和點是另一組數字**（stock ~40 Mbps／fast ~460-530 Mbps），兩者不要混講 |
| demo 影片 | 未討論 | — |

⚠️ **畫任何圖之前先讀 `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md` 的
「這一頁不支持的」那節**，以及簡報 template Page 39（v4.2 已填完）裡那句
**「不要說我們準確到 X%」**——精度是窗長的函數，box plot 的分組軸必須是窗長，否則圖本身會誤導。

### 5. 建議下一個 session 先驗證（開哪個檔、看什麼）

1. **`git status`** — 應該只有 `.vscode/settings.json`＋`spec.py`＋`faults.sh` 三個 modified，
   產品碼 0 改動。**若不符，先查是誰動的再繼續。**
2. **`doc/KNOWN-ISSUES.md` 是否存在且 608 行 / 21 條目** — 它**未 commit**，
   而本 session 一度為了盲寫把它移出 repo 過。不見了就從
   `scratch/{phase2,round4,round6}/FINDINGS*.md` 重建。
3. **`~/.local/bin/deepseek-agent` 是否還有 `--provider`**：
   `grep -n 'PROVIDERS\|--provider' ~/.local/bin/deepseek-agent`。
   以及 MCP 是否還有 `muse_spark_agent_task`（工具表裡找）。備份是 `.bak-2026-08-19`。
4. **簡報 template 是否 v4.2、Page 39 是否已填**：
   `grep -n '版本.*v4\.2\|Page 39' "/home/adam/Desktop/NDTwin Slide material/NDTwin-slide-template.md"`。
5. **`scratch/round6/FINDINGS-round6.md` 977 行是否在** — round 6 的全部證據只在那裡。
6. **memory 的 F-17 更正是否在**：
   `grep -n '2026-08-19 更正' live-round-2026-08-18-two-passes.md`。
   若不在，代表記憶被別的 session 覆寫過。

### 6. 這個 session 實際讀過、可以負責任描述的檔

`src/ndt_core/power_management/{P4PowerStrategy,OVSPowerStrategy}.cpp`（全讀）、
`src/ndt_core/routing_management/{HttpRoutingStrategyBase,Controller,FlowDispatcher,FlowRoutingManager,P4RoutingStrategy}.cpp`（全讀）、
`include/ndt_core/routing_management/FlowJob.hpp`（全讀）、
`p4_proxy/p4_src/ndtwin_switch.p4`（表定義與 apply 區塊）、
`p4_proxy/proxy_agent/topology_manager.py`（LLDP 常數與 `unsupported_match_fields`）、
`intelligent_router.py`（`get_switch`/`get_link` 那段）、
`ryu/controller/controller.py:124-140`（雙埠綁定）、
`Energy-Saving-App/src/app/energy_saving_app.cpp:905-935`（關機決策）、
`~/.local/bin/deepseek-agent`（改過）、`~/.local/share/mcp-servers/ai_tools_server.py`（改過）、
`tools/git-hooks/post-commit:183-195`。

**知道存在但這次沒打開的**（只列檔名，不臆測內容）：
`scratch/round5/PLAN-deepseek.md` 與 `PLAN-muse.md` 的**內文**（只讀了實驗標題清單）、
`scratch/round6/FINDINGS-round6.md`（只讀了 agent 的回報摘要，**沒有打開 977 行本文**）、
`scratch/phase2/DEFECT-INVENTORY.md`（~870 行，subagent 產出，只讀回報）、
`doc/2026-08-13_advanced-testing-research/REPORT.md`、`doc/2026-01-02_ndt_api.md`。

---


<!-- from ndtwin-state-2026-08-11.md lines 1350-1438 (2026-08-19) -->
## 5-I. 【2026-08-19 深夜 pre-compact】簡報視覺化輪 ＋ 四輪新實測（取代 §5-H）

> 📍 **這是最新節,取代 §5-H 作為接手入口。** §5-H 的「立即下一步」已全部執行完。
> ⚠️ **本輪與前六輪不同:產品碼動了,而且是刻意的、Adam 逐項核准的。**

### 1. 目前狀態

head **`cc249c8`**,branch `fix/flow-rate-divide-by-zero`,**本輪 4 個 commit 全部已 push 到 `p4`**:

| commit | 內容 |
|---|---|
| `2d19e09` | 兩個測試檔修正(`spec.py` 的 -1 sentinel、`faults.sh` 的 5s→75s settle) |
| `b6b75fa` | `doc/KNOWN-ISSUES.md` ＋ 08-18 audit 輪 ＋ `ndtwin-lab` ＋ **`.gitignore` 加 `scratch/`** |
| `213d209` | P4 遙測精度、291 秒重新裁定、baseline failover、API 延遲、OVS/128 補到 n=10 |
| `cc249c8` | **host-count seam(產品碼)** ＋ P4/128 failover n=10 |

工作樹只剩 `.vscode/settings.json`(無關,而且那個 diff 是**刪掉** excludes,看起來是誤刪,沒動它)。
環境收官 **0 bmv2 / 0 mininet / 0 bridges / 0 kernel**。

🔴 **`scratch/` 現在被 gitignore 了(它有 3.3 GB)**,但 round4/5/6/phase2 的 findings 文件
(共 700 KB)也因此變成「未追蹤又被 ignore」= **沒有備份**。要不要搬進 `doc/audit/` 未裁決。

### 2. 本輪的實測(全部 raw data 已 commit,圖從資料重算)

| 量測 | 結果 | 出處 |
|---|---|---|
| **P4 遙測精度** | 合成的與原生的**一樣無偏**(中位數 0.97–1.02),散布在理論地板內。stock 20M ＋ fast 200M | `doc/audit/2026-08-19_p4-sflow-accuracy/` |
| **291 秒歸屬** | **推翻**,見 [[a-fix-changes-reachability]] | `doc/audit/2026-08-19_failover-provenance/` |
| **baseline failover** | **180.75 s × 3,從不重繞** | 同上 `raw/` |
| **OVS/128 補到 n=10** | 47.0–56.4 s,平均 **51.75**(原 n=3 平均 50.06,估計撐住了) | 同上 `raw_ovs128_n10/` |
| **P4/128 failover** | **16.59 s (n=10)**,對 OVS 差 **3.12× 零重疊** | 同上 `raw_p4_128/` |
| **API 延遲 vs baseline** | **沒有回歸**(11.99 vs 13.02 ms) | `doc/audit/2026-08-19_api-latency-vs-baseline/` |
| **開機時間** | P4 拓撲 22 s / 控制平面 **11 s**;OVS **73 s(含 60 s 寫死 sleep)** | `intelligent_router.py:473` |

🔑 **本輪最有份量的一條**:「資料面是三項裡最小的(1.13×)」**只在 4 台上成立**。
128 台時 OVS 慢 3.29×、P4 只慢 1.21×。見 [[p4-128-hosts-four-hardcoded-lists]]。

⚠️ **P4 遙測精度那輪跑在 4-host cell、OVS 那輪在 128-host**。我查證過交換機核心相同
(都 10 台、都 32 條交換機間邊)且取樣精度只由樣本數決定,但 **Adam 指出這與被作廢的舊表
是同一個形狀**,而現在 128-host P4 已經能跑了——**應該重跑在 128 上把這個不對稱去掉**。

### 3. Adam 本輪的裁決(全部已寫進 template v4.4)

- 🔴 **第 2 節「Baseline defects fixed」延後到下下次報告**——還沒跟學長姐對帳,
  而今天正好有一條(`034da18`)歸因被實測推翻。
- 🔴 **第 3 節「使用技術」拆解**:技術棧→開場、方法論→測試節。**節次要重編(還沒做)**。
- 🔴 **「實機測試 / Results on real hardware」用詞全部改掉**——沒有實體設備,全是 Mininet/bmv2。
- 🔴 **291 秒不進簡報**;`034da18` 移到 Page 19 穩健性頁(已寫入)。
- ✅ **產品碼的 host-count seam 可以推**,前提是先驗預設 4-host 路徑(已驗,已推)。
- ✅ 繪圖用專用 venv `<slide material>/.plotvenv`(**不要污染 `p4_proxy/venv`**)。
- ✅ **簡報由 Adam 自己的 cowork session 產生**,我只交 template ＋ 圖 ＋ 資料。

### 4. 🔴 已知的缺口(Adam 在 pre-compact 當下點出,尚未修)

1. **`page36_failover-raster.png` 沒有涵蓋 P4/128。** 我在 `failover_cells()` 加了
   `p4_128` 分支,但 `fig_failover_raster()` **有自己一份 inline 的 key 判斷**,沒同步改。
2. **`page39_per-hop-consistency.png` 的 P4 側只有 2 跳**,因為它吃的是 4-host cell 的
   sFlow 資料。128-host 上重量就會變 4 跳,與 OVS 對齊。
3. **`page36_failover-decomposition.png` 需要重新設計**:它現在用
   `OVS/4 ÷ P4/4 = 1.15×` 當「資料面」項,而 128 台上是 3.12×——**單一數字已經不誠實**。
4. **節次重編沒做**(第 2 節延後 ＋ 第 3 節拆解之後,Outline 頁碼與節封面編號要重算)。
5. **Adam 問的「What was written down 那一頁」我不確定指哪一頁**,沒回答。
6. **demo 錄影的操作教學** Adam 要,還沒寫。

### 5. 其他未消化的

- **DeepSeek / Muse 的 template 複審 v2** 在 `scratch/*-template-review-v2.md`
  (DeepSeek 446+136 行、Muse 145+150 行)。已消化的:Page 24 漏改(真的,已修)、
  Page 19 沒補第三條(真的,已補)、Page 15 引用標錯(真的,已修)、
  `LockManager::renew` 缺 TTL 檢查(真的,已補進 Page 44)。
  **未驗證的**:Page 40 說第三方檢查的「1 個真 bug」從沒被修;Muse 的另外五條程式碼層提案。
- ⚠️ **v1 的兩個 agent 讀不到 template**(路徑有空格,不在允許根目錄),它們審的是 repo。
  v2 已把 template 複製到 `scratch/slide-material-copy/` 解決。

### 6. 這個 session 實際讀過 / 改過的檔

**改過(產品碼)**:`p4_proxy/mininet/p4_testbed_topo.py`(host 接線＋`_host_count_override`＋ARP)、
`p4_proxy/mininet/ntg_bmv2_topo.py`(ARP 迴圈)、`p4_proxy/proxy_agent/main.py`(`add_host` 迴圈)。
**新增**:`tools/test_workflow/derive_p4_topology_json.py`、
`doc/audit/2026-08-19_{p4-sflow-accuracy,failover-provenance,api-latency-vs-baseline}/`。
**讀過**:`intelligent_router.py`(`on_link_delete`、`install_all_pair_paths`、`hub.sleep(60)`)、
`28b8b13:src/main.cpp`(2 個 cin prompt)、`LockManager.hpp:123-137`、
`ndtwin_switch.p4`(表容量、取樣分支)、`/usr/local/sbin/ndtwin-lab`(`BRIDGE=` 那行)、
`doc/2026-07-29_p4_status_and_test_guide.md:94-95`。
**簡報側**:`NDTwin-slide-template.md` 大改(v4.2→**v4.4**,1194 行)、
`2026-08-19_visualisation-references-futurework-analysis.md`(新建)、8 張圖在 `figures/`。

---

