# Overnight review 2026-08-12 — INDEX

主導 session：Fable（orchestrator，只分工不動手）。Base：`5d53cf0` @ `fix/flow-rate-divide-by-zero`。
Adam 開好 bmv2 環境後離場；本檔隨每份 agent 結果即時更新。

> **搬遷註記（2026-08-13）**：這個資料夾原本在 `~/Documents/NDTwin documentation/`，已搬進 repo。
> **兩份刻意留在原處，不在這個資料夾裡**（Adam 裁決）：
> - `S-slide-review.md` — 審查對象是 `~/Desktop/NDTwin-slide-template.md`，那份不在 repo。
> - `DRAFT-message-to-patty.md` — 給真人的私信草稿，Adam 自己寄。
>
> 下文提到這兩個檔名的地方（S 那列、上游合併那列等），要去
> `~/Documents/NDTwin documentation/Overnight review 2026-08-12/` 找。

## 環境確認（orchestrator 開場親測，Adam 離開前）

- HEAD `5d53cf0` ✅
- bmv2 switch 10 台、Mininet host 4 個、topo 腳本 pid 178866 活著 ✅
- netem 殘留 0 ✅
- stack 未起時 h1→h2 ping 100% loss（**預期**：無 controller 即無 table entries）
- `stack.sh up p4` + `wait`：10/10 up+enabled、40 edges、1 秒收斂 ✅
- stack 起後 h1(178914)→h2(10.0.0.2) ping 10/10、0% loss、RTT ~3.1ms ✅ —— **資料面端到端驗證通過**
- 注意：stack.sh 顯示 kernel API 在 **:8000**（runbook/記憶裡多處寫 :8080，值得 B4 核對）

## Agents

| # | 任務 | 檔案 | 狀態 |
|---|---|---|---|
| A | Live runbook 全輪（bmv2，獨佔 live 環境） | A-live-runbook.md | ✅ 完成（P0 0 / P1 3 / P2 5；**readopt 清表缺陷**見下） |
| B1 | 今日 commits 審查（b0a7bdc..5d53cf0）+ 開場五驗 | B1-commit-review.md | ✅ 完成（16 commits 全審，零 P0/P1） |
| B2 | 文件腐爛掃描（今日動過的 doc/註解，逐引用開檔驗證） | B2-doc-rot.md | ✅ 完成（2 P1 / 4 P2） |
| B3 | 測試品質 / mutation（今日新測試，全套無 filter） | B3-test-mutation.md | ✅ 完成（7/7 mutant 殺、零假測試；+1 P1 事故見下） |
| B4 | Runbook vs code 掃雷（純讀，Adam 早上照跑前除雷） | B4-runbook-vs-code.md | ✅ 完成（3 P0 / 8 P1） |

| C | **OVS live runbook 全輪**（第二輪，Adam 離場後 agent 跑） | C-live-ovs-runbook.md | ✅ 完成（1057 行；🔴 P0×1、P1×5、P2×2；runbook §4/§5/§7 各項全中） |
| S | **Slide template 補充審查**（fbd8140→5d53cf0 差距） | S-slide-review.md | ✅ 完成（差距實為 69 commits；9 條新 A2 裁定） |

B1–B4、S 各自 worktree（明寫 reset 到 5d53cf0）；A、C 在主樹但禁改檔案。全部 opus。

**OVS 輪環境交接（orchestrator 驗證）**：mn -c 後零孤兒 → Ryu（216679，:8080/:6633/:6653）→ Adam 開 Mininet（testbed_topo.py，10 bridges/4 hosts）→ Enter 起 kernel（242000，:8000）→ wait 10/10、edges=288 → h1→h2 ping 10/10、0% loss、RTT ~0.15ms。
**Adam 指示（離場前）**：OVS 輪跑完後開始修 tonight 找到的 bug；不清楚的等他回來問；slide template 審查結果跟他匯報（瑣碎不報）。

## 修復階段（2026-08-13 凌晨～早上，orchestrator 親自執行，Adam 核准）

全部已 push（`5d53cf0..d2a609a`，6 個 commit），每條新測試都經 mutation gate 紅過：

| commit | 修了什麼 | 驗證 |
|---|---|---|
| `034da18` | **C 的 P0**：Ryu 單向斷鏈黑洞——BFS 只走雙向都存在的邊＋兩處 mid-walk 防護＋修正 on_link_delete 註解過度宣稱 | 3 條新測試（AST 抽取式）；全 mutant：雙拔=errors 2、單拔=failures 1——兩道守衛各自承重 |
| `b966f45` | **B3 的 P1**：LiveSwitchTest 改硬 gate（`NDTWIN_LIVE_SWITCH_OPT_IN=1`），可達性不再等於同意 | 兩面驗證：無變數硬 skip；有變數停在下一道安全前置 |
| `a72a168` | **A 的 P1**：readopt——非 primary 就 502 `step:mastership`**不碰 switch**；attempted>0 且 accepted=0 → 502 `step:routes`；回傳加 `routes_attempted` | 4 條新測試；兩 mutant 各殺各的；root cause 是 log 四行實錘（Election id already exists → push 照過 → 三筆 Not primary → success） |
| `a7158c8` | B1 的 note：curl helper 認得捆綁式 `-sSf`＋meta test | mutant 紅過；C++ 全套 547/69 綠 |
| `f6492a6` | 文件批次：runbook §6h 換 tc netem 塊＋歷史 banner、「還沒修」×2 改已修、11s→15-20s、sFlow 描述 P4 化、§9 加 32afeb9/readopt 症狀列、孤兒 §5b 刪除、§5g 改 symbol 錨、兩個舊路徑、README 機制句、gotchas 加 htb 條目 | 各項皆對程式碼或 live 證據覆核 |
| `d2a609a` | 防呆工具：stack.sh `up ovs` 拒絕在 Mininet 活著時重啟 Ryu（`--force` 可越過）；`qdisc_snapshot.sh` save/diff 快照工具 | 19 個 shell 檢查全綠；guard mutant 紅 3 項；既有 test_wait_for_port 迴歸綠 |

**Adam 已裁決（2026-08-13 grill 輪，全部答完）**：

| 題目 | 裁決 |
|---|---|
| readopt 強制接管健康 switch | **不做，永久關閉**。現在的行為（壞了能救、健康不誤傷）就是完成態 |
| `src_ip` 回整數 | **維持整數不改碼**，定調為「怪癖」；簡報可口頭當「無聲不一致」的例子，不進 bug 頁 |
| bmv2 非 primary 清表 | **下次開環境做 10 分鐘乾淨對照實驗**；坐實才考慮回報上游 |
| 上游合併 | **先問 patty**（草稿見 `DRAFT-message-to-patty.md`，Adam 自己寄）；**並行**做技術分析（U agent 跑中） |
| repo 轉公開 | **不轉**。CI 改本機跑——已做成 `tools/test_workflow/local_ci.sh` |
| 他自己的手動 OVS 輪 | 要做，他自己排時間（也是 demo 手感） |
| Tier 2 那 14 條 | 下個 session 花 30 分鐘**重分級（只分級不修）** |
| 三週排程 | 照下方骨架走，**twin 測謊器排 W2 當 demo 壓軸** |
| twin 測謊器範圍 | **連通性對帳**（對 twin 宣稱 active 的 flow 抽樣驗封包真的在動），介面預留路徑對帳；不做全欄位對帳（sFlow 取樣誤差會讓告警變雜訊） |
| 測謊器住哪 | **獨立工具 `tools/twin_audit/`**，不進 production；好處是 OVS/P4 兩條路都適用，呼應雙資料面敘事 |
| 今晚這輪進不進簡報 | **(b) 不加專頁**——發現併進既有 bug／功能頁，來源不提。方法論頁與測試資產頁可無聲吸收新數字 |
| 兩個 P0 怎麼歸類 | **照 A2 規則分開放**：單向斷鏈黑洞 → **bug 頁**（缺陷在前人的 `intelligent_router.py`，與 `2c81b26` 同源，沿用「既有 Ryu 控制程式的缺陷」註記）；readopt 清表 → **功能／穩健性頁**（在 Adam 自己的 proxy 碼裡，同 OpResult 先例） |

### 給 slide template 的更新指示（W1 第一件事，餵 cowork 前套用）

1. **B 節四個數字**：commit 202→**271+**、gtest 426→**547**、Python 337+101→**524**（393＋131）、`tests/` 33→**43** 檔。A3.1 的三條量測指令仍準確，不動。
2. **Phase 狀態三格**：Phase 7 **已完成**；Phase 8 的表格格子與它自己的章節矛盾（章節四條劃掉三條）；Page 33 未完成清單三格全錯。
3. **新增一頁**：第 1 節加「Phase 7 電源管理」（目前完全沒有頁面，最大結構缺口）。**不加**「隔夜驗證輪」頁（Q14 裁決）。
4. **A2 裁定表 +10 條**：S 報告的 9 條（6 條列入／`916d330` 拆半）＋**單向斷鏈黑洞列入**（前人 Ryu 程式碼，比照 `2c81b26`）。**readopt 清表明確標排除**，改放功能頁。
5. **兩個誤判陷阱加註**：`57346f6` 是**產品自帶的** Intent Translator 用 OpenAI，不是 A1.3 禁的 AI 協作流程；`3292653` 的 message 與 Page 18 ④ 對 graph 行為矛盾，動筆前擇一。
6. **D 節出處表補 repo 外路徑**：`doc/audit/overnight-review-2026-08-12/`（Page 28 的 failover 數據、Page 30 的取樣誤差地板都在這）。不補的話生成 agent 找不到素材會自己編。
7. **Page 28 現在填得起來**：bmv2 斷鏈 ping gap **16.63s** 自癒、復原 **hitless（0 loss）**、偵測 2 筆零假訊、38/40 edge、路徑 `1 6 10 7 4`；OVS 對照 **52.42s**、偵測 +42.6s。Page 30 可寫理論地板：誤差 = 196√(1/c)、bmv2 >64 台 fidelity 崩壞、`simple_switch_grpc` ~170 Mbps 天花板。

## U — 上游 `8b61cdc` 分析 ✅（詳見 `U-upstream-8b61cdc-analysis.md`，500 行）

**「Add sharding」只有約 40% 是 sharding。** 其餘：新增 **sFlow sample type 5 parser（132 行、
無邊界檢查）**、**三個 thread 被 `// TODO` 停用**、`touchEdgeFlow` 的 map 更新被註解掉、
`::close(m_sockfd)` 從 `stop()` 被刪、新增一個 metric、以及**第 5 個檔案**（`setting/` JSON 的
LAG port 重編號——之前的合併測試沒顯示，因為它乾淨合併）。**sharding 本身反而最沒爭議**
（1024 shard、`FlowKeyHash & 1023`、相同 key 必落同片、API 透明、純為吞吐）。

**她的書面意圖只有兩個字**（commit message 無 body、無註解、`git grep -il shard` 零文件）——
所以問她是**必要**不是禮貌。

**三個要注意的**：
1. **我們有兩個 commit 修了她也修的同一個 bug**（`1542f1e` lock-before-lookup race、`c127a53`
   封包率算法），各自獨立、實作不同——我們的有測試，她的是 inline。
2. **最尖銳的衝突可能是我們的錯**：`hopsCounter == 0` 時她**歸零** rate、我們**保留**；
   而我們自己的樹不一致（`Immediately` 路徑已經歸零），我們自己 `109690d` 的推論反而支持她。
   → **值得當成我們這側的疑似缺陷單獨查**。
3. **最危險 hunk #15**：~70 行純縮排包著一個 token 的修正；解成「take theirs」會靜默 revert
   `c127a53` 與 `31b357a` 的 SIGFPE 守衛（分支名稱的由來），而且我們自己的 commit 註記說
   這裡的退化**測試抓不到**。

hunk 分類 9 clean / 5 機械 / **7 語意**；衝突數 U 與 `merge-tree` 皆算 12（08-12 那次算 10，
演算法差異——別把 10 當精確值）。**未驗證**：`getTopKFlowInfoJson` 的遞迴 `shared_lock`
我們有沒有另外修過（U 說她順手修了）——這是我們自己樹的自查項。

## 本機 CI（取代 GitHub Actions）

`tools/test_workflow/local_ci.sh` — 一個指令跑完 workflow 的五件事（GCC build+direct+ctest、
Python L1、ASan+UBSan、TSan 含 `setarch -R`、clang 建置），**不 fail-fast**（一次知道全部壞在哪），
任一紅則 exit 1。9 個 driver 測試（含兩個 mutant 驗證失敗真的會傳遞到 exit code）。
**在 `afe0717` 上實測 5/5 全綠。**

> 它誕生後一小時內抓到我自己的兩個錯：新測試 import networkx 違反 `tests/python` 的
> 「標準庫 only」約定（用系統 python3 跑）、三個新 shell 測試的摘要格式不合 runner 解析的
> `Ran N`。兩個都是「driver 測試全綠但真跑紅」——accept path 要真的走過。

## 研究報告的落地（2026-08-13 下午，Adam 授權「直接開始準備測試」）

研究報告在 `doc/audit/advanced-testing-research-2026-08-13/REPORT.md`
（684 行）。**抽驗它的事實宣稱全部吻合**（31 個 fixture、p4testgen 已裝、`handlePacket` 簽名、
venv 缺 hypothesis/ptf/scapy），可信。已落地兩條最高 CP 的：

### R-4 P4Testgen 覆蓋閘門 ✅（`bc904f8`）
**獨立複驗報告的核心數字**：0.851852（46/54），未覆蓋的 8 個節點正是 `:414-421` 的 clone
取樣段——與報告完全一致。做成 `tools/test_workflow/p4_coverage_gate.sh`：
- **只在 `.p4` 的 hash 變了才真跑**（未變 14ms），所以能安全當 local_ci 的第六個 job
- **盯的是未覆蓋清單的「形狀」不只是數字**：清單變長＝新增了自動測試永遠碰不到的程式碼 → 擋下來要求 `--update-baseline` 明確裁決
- p4c 沒裝就 skip 不 fail
- 15 個 stub 驅動檢查 ＋ 真跑驗證；兩個 mutant 各殺 3 / 8 個檢查
- **「符號執行原理上碰不到 sFlow 取樣路徑」已寫進 `doc/p4_bmv2_support_plan.md`**——這是
  「live 才抓得到」這個經驗事實的**機制層級解釋**

### R-1 sFlow libFuzzer harness ✅（`a3bfa40`）
`tests/fuzz/fuzz_sflow.cpp`＋CMake `-DFUZZING=ON`（clang-only、零安裝、預設不建）。
**基線：90 秒 26138 runs、21 個新 corpus unit、零發現。**

**兩個 negative control 都跑了**（沒看過它失敗就不算交付）：
| mutant | 結果 |
|---|---|
| 拿掉真 bounds check（`SFlowType.hpp:366` 的 throw） | **立刻抓到 SEGV**，指 `FlowLinkUsageCollector.cpp:1214` → `SFlowType.hpp:368` ✅ |
| 拿掉前置的 sampleCount 上限檢查 | **不 crash**（正確：內層仍有防護），但 **287 exec/s → 6 exec/s，慢 48 倍** |

第二個是意外收穫：那個上限檢查**承重的是資源耗盡不是記憶體安全**，而 libFuzzer 預設
`-timeout=1200` 抓不到這類——要抓 DoS 面得下 `-timeout=5`。

**一個我自己的假陽性已記錄在 harness 註解裡**：第一版對**每個**輸入（含正常 fixture）都在
exit 時 heap-use-after-free。那是 harness 不是 parser——`~FlowLinkUsageCollector` 呼叫
`stop()` 會碰 logger，而 static destruction 期間 spdlog registry 可能已消失。查證
production 沒有這個形狀（`main.cpp:331` 區域變數、`:425` 明確 stop），所以最後一個
collector 刻意不析構。

**尚未做的**（報告的 R-2/R-3/R-5）：R-2 L5 故障注入層要 live 環境才能真驗（與 W2 的
twin 測謊器合併——注入與對帳是同一件事的兩面）；R-3 Hypothesis 需裝 `hypothesis==6.165.5`；
R-5 soak 需長時 live。

## 三週排程（報告 ~2026-09-03，Adam 核准骨架）

- **W1（本週）**：slide template 照 `S-slide-review.md` 更新 → 餵 cowork 出初版；Tier 2 重分級（30 分）；patty 訊息寄出 ＋ 收 U agent 分析；Adam 自己的手動 OVS 輪（兼 demo 手感）。
- **W2**：live 複驗輪（F0 繞路、F1 readopt gate、P4 側單向故障、bmv2 非 primary 對照實驗、qdisc 快照串上）——這輪數據直接填 Page 28/32；**twin 測謊器 MVP**（demo 壓軸）。
- **W3**：彩排、收尾、buffer。
- **報告後**：sFlow fuzzer、mastership 微套件、上游合併（若 patty 回覆指向「等她告一段落」）。
**測試數新 canonical**：C++ **547/69**、Python **524**（393＋131）。

## 發現彙整（隨收隨寫）

### B2 文件腐爛掃描 ✅（詳見 B2-doc-rot.md，241 行）

**指定三項全過**：5d53cf0 的 VLAN symbol 引用（`calFlowPathByQueried`、`packKey`）真實存在、grep 錨點恰好一中；3a312e3 的 `/p4/readopt/{dpid}` 端點真的註冊在 api_routes.py:161、proxy :8081，可直接貼上用；c4505e9 twin-liveness 文件與程式碼一致（`kLldpFreshSeconds = 12.0` 精確吻合）。

**P1 ×2（都是 3fc42ed 搬腳本沒同步文件，早上順手修）**：
1. `doc/p4_bmv2_support_plan.md:398` 說 `dump_table.py` 在專案根目錄 → 實際已在 `p4_proxy/reference/`
2. `doc/test_coverage_gaps.md:430` 指 `p4_proxy/test_10_routes.py` → 實際已在 `reference/` 底下

**P2 ×4（結論對、機制描述錯/過時）**：README 的「NO TESTS RAN 算失敗」對它點名的 runner 不成立（`l1_unit_tests.sh:194-197` 不加 FAILURES；另一個 runner :322-324 才有）；phase7 文件三個 `計劃 §` 引用全偏（正確為 §507/511/537）；`--ignore-unparsed` 已完全不再傳，該節自相矛盾；`printf`-into-stdin 脆弱性已不存在（stack.sh:606 改用 CLI flags）。

**澄清（不是腐爛）**：twin-liveness 在兩份文件一寫已修一寫未修——**兩者都對**（修的是 proxy 側；kernel 的 `TopologyAndFlowMonitor.cpp:565` 仍無條件 `isUp = true`）。port 全部乾淨：kernel `:8000`、proxy `:8081`，殘存的 8080 都是明標歷史脈絡——**記憶裡的「:8080」是過時的，該修記憶不是修 repo**。

**其餘**：~19 處行號漂移（宣稱仍成立，含 `HttpSession.cpp:1080→1120`、`IntentTranslator.cpp:227→310` 的「唯一呼叫點」重驗為真）、3 個過時測試數、1 個死連結、1 個超出 30 行檔案的行號範圍。

### A Live runbook 全輪 ✅（詳見 A-live-runbook.md，718 行）

**🔴 P1 新缺陷（今晚最大條）：`POST /p4/readopt/{dpid}` 對健康 switch 會清空整張表、裝回 0 條路由、回 `"status":"success"`。** s1 實測 4 rules→0、h1 四方向全不通、60 秒無自癒，kernel 卻仍報 `sw up 10 en 10`；在**未受污染的 s6** 上對照重現 → 通用缺陷、非 s1 特例。更糟：3a312e3 的 502 訊息**正是教操作者跑這個指令救援**。已驗證的恢復手段＝重啟 proxy。（三個靜態 agent 都驗過這端點「存在、接線正確、可貼上」——壞的是行為。live-runs-find-what-tests-cannot 再 +1。）

**今日 commit 的 live 驗證**：32afeb9 ✅（dpid `0a` 從 `/v1.0/topology/switches` 消失；10 Hz × 678 筆取樣**零 up-blip**，用 commit 自己的方法）；949fcba ✅（關機 135 秒 → power-on **1.50 秒**，無繼承 backoff）；3a312e3 / eace67c **未觸發**（全程沒遇到 502），誠實記為**未驗證**而非已驗證。

**Failover 端到端 ✅（最有價值的一段）**：斷 `s6-eth3↔s9-eth2`（對端自己從 topo 推導，沒抄 runbook 例子）：2 筆 down 零假訊、38/40、規則 `OUTPUT:3→4`、reroute `1 6 10 7 4`、**ping 停 16.63 秒後自癒**、復原 **hitless（0 遺失）**、零 netem 殘留。s10 電源循環後驗證有載真流量。

**s1 污染事件收案**：A 的三個 proxy-down 窗口全記錄（storm 窗口 23:02:40–23:09:02）；s1 packet storm 歸因 B3 的外部寫入——同樣的 kill 在乾淨 proxy 上 **102 秒重現不出來**（對照實驗）。「proxy 非預期下線？」疑點同步收案：窗口皆 A 自己的操作。s1 交接時已恢復健康。

**環境交接**：Mininet（178866）＋4 host 未動、repo byte-identical（HEAD 5d53cf0）、零 netem 殘留、ports free；全程未用 ifconfig / mn -c / pkill。orphan pid 198120（s10 helper 重生、reparent 到 systemd）→ **orchestrator 已用 `ndtwin-p4-power off s10` 清掉（rc=0）**，殘餘 9 台皆 Mininet 原生、exit 即亡。

### C Live OVS/Ryu 輪 ✅（詳見 C-live-ovs-runbook.md，1057 行）

**🔴🔴 P0（兩輪之最）：單向鏈路故障 → Ryu 路由重算永久崩潰 → 流量無限期黑洞。** 機制：LLDP 單向死 → Ryu 只發一個 `EventLinkDelete` → DiGraph 不對稱成**穩態** → `intelligent_router.py:582` 的 BFS 查反向邊 `KeyError` → 整輪重算中止 → OpenFlow 規則永不更新。實測 **291 秒 100% 丟包、零自癒**（netem 移除瞬間恢復），同時 twin 回報 `edges_up=287/288`、該 flow「以 9–15 Mbps 流動」——twin 說謊的鐵證。**同一崩潰在正常啟動時也觸發過一次**（`KeyError: 1`，被 LLDP 自癒掩蓋）。程式註解 :807-809 自己寫下了被違反的假設（「the paired event removes the other」——單向故障時配對事件永遠不來）。→ **修復中（F0）**。

**其他重點**：雙向斷鏈對照組全綠（偵測 +42.6s、ping gap **52.42s** vs P4 輪 16.63s、恢復 hitless）；電源輪（runbook 未涵蓋）off +0.34s / on +3.4s hitless，**但 power cycle 會永久遺失 sFlow/fail-mode 設定（P1，OVSPowerStrategy 重建 bridge 不還原 sFlow）**——C 已手動還原 s7；§5j flow 閃爍重現並補獨立 ground truth（twin 給 0/1/2 三種答案時 ping 序號證明 0% loss）；§6i 窗口 A 第三次重現（14.3s）。

**殺 controller phase 刻意未做**（正確判斷）：runbook 的精確程序就是「不要重啟 Ryu」，而整組 down→up 在 Mininet 不可重建的當晚等價於 wedge 觸發條件；改測錯誤路徑 8 項全對。

**方法論收穫（要進記憶）**：交接單教的 `tc qdisc add dev X root netem` 會**靜默替換掉 Mininet TCLink 的 htb**（shaping 消失、NOPASSWD 還原不回、「netem 殘留 0」檢查看不見）；C 改用非破壞性 `parent 5:1` 掛法。P4 輪的 Mininet 已 mn -c 銷毀，該側損傷已隨 namespace 蒸發，但 runbook/記憶裡的示範指令要改。

### B1 今日 commits 審查 ✅（詳見 B1-commit-review.md）

**範圍實為 16 個 commit（不是 10），全審、零跳過。無 P0、無 P1——今天的工全部貨真價實。**

**開場五驗全過**：option 字串一字不差 `grpc.use_local_subchannel_pool`（在 grpc 1.82.1 C-core 二進位裡找到原文）值為 1；`connected_switch_dpids()` 端到端接通（定義→handler→`render_switches` 真的迭代該參數）；`--fail-with-body` 在 `P4PowerStrategy.cpp:82`、無裸 `-f`；**上游仍只領先 28b8b13 一個 commit**；C++ baseline 546/68/0 skip 精確吻合。

**測試數帳目破案（重要，要更新記憶）**：Python 實際是 **517 ran / 3 skipped / 0 failed**，不是 385。385 = caa6d5b 寫文件時只算 `p4_proxy/tests`（不含 `tests/python/` 的 128）、又早於 32afeb9 的 +4；389−4=385 帳目精確吻合。3 個 skip 全數有下落（2 = gitignored p4info 在 worktree 缺、主樹有；1 = 宣告 opt-in 的 live test）。**今後 canonical：C++ 546/68 + Python 517。**

**它還主動跑了 commit 宣稱的 mutation，三條全部成立**：revert 成 `-f` 只殺新 curl 測試（545/546）；移除或拼錯 gRPC option 各殺 3 條新測試中的 2 條；還原 `switches.keys()` 殺 2 條。也證實了前提——grpc 連 `grpc.total_nonsense_option_xyz` 都安靜吞掉。

**唯一 message↔diff 不符（note 級）**：`3fc42ed` 的理由句「NO TESTS RAN 在該 runner 算失敗」不成立（`l1_unit_tests.sh:194-197` 那個 glob 不加 FAILURES；會加的 :322-324 管的是另一個目錄）——**與 B2 對 README 的 P2 發現獨立互證，同一根因，一次修兩處**。決策本身仍正確（靠 `rc != 0` 路徑）。

**三個小 note**：eace67c 的 token helpers 漏了一處捆綁的 `-f`（`curl --fail-with-body -sSf`——`-sSf` 裡的 f 還在）；3a312e3 的測試仍斷言在措辭上（本意是釘屬性）；既有潛伏——`add_switch` 對已存在 dpid 會安靜丟棄替換的 client（目前不可達；`readopt_switch` 正確地直接賦值繞過它）。

### B3 測試品質 / mutation ✅（詳見 B3-test-mutation.md）

**7/7 mutant 全殺、每個都先寫預測再跑、全套無 filter、預測全中——今天的新測試沒有一條是假的。** M1 `--fail-with-body`→`-f`、M2 `connected_switch_dpids()`→`switches.keys()`、M3 拔掉 gRPC options、M4 拼錯 option、M5 revert 502 訊息、M6 三態→truthiness、M7 在模擬無 protobuf 的直譯器下拔 `@skipUnless`（恰好 3 個 error、全是 WriteDeadlineTest——把 f3759ae 的宣稱重現到個位數）。

**兩個佐證**：M1 顯示既有的順序測試在 `-f` 下**仍綠**——即今天之前整套 546 曾與這個 bug 和平共處，新的 token 測試是唯一防線（「live 抓得到、測試抓不到」再添一例）；M2 顯示 `test_ryu_topology.py` 全部 32 條在壞實作下仍綠，證明把守衛放在 endpoint 層是承重的、不是冗餘。

**⚠️ P1 事故（B3 自己申報，已控制）**：M6 期間 `test_p4_client.py::LiveSwitchTest` 守衛失效，**真的對 live switch 1 推了 pipeline config、2 條 route、clone session 250**。兩個獨立成因疊加：:8081 的 proxy 當時沒人聽（非 B3 所為——**已收案**：A 的時間線記錄了全部三個 proxy-down 窗口，皆 A 自己的操作，無「非預期下線」）＋ B3 複製進 worktree 的 json 滿足了最後一道守衛。已封鎖（刪 json、測試回 skip、baseline 回 517/1），主樹零寫入。**耐久發現：`NDTWIN_L1_OPT_IN` 只是給 harness 的提示，真實語意是「proxy 不在就直連 live switch」——fabric 開著、proxy 停著的任何普通 L1 跑測都會安靜重配一台 switch。** A 已被通知，s1 相關觀察需用此脈絡裁決。

**其他**：baseline 獨立算出 517（與 B1 同結論、先於我的更正抵達）；78be6b6 無測試因此變弱（被刪成員無讀者，結構上不可 mutation）；5d53cf0 的 grep 錨點準確（現在 1 中、在 :2542——恰是文件說 2534 會爛掉的那種漂移）。未跑清單在報告 §6。

### B4 Runbook vs code 掃雷 ✅（詳見 B4-runbook-vs-code.md）

**🔴 P0 ×3，全在 §6h（斷鏈路節）——早上跑 runbook 前必修**：
1. **§6h 的操作步驟（L692）是 `ifconfig down`，判準（L855）卻是 `tc netem` 版的**。runbook 自己在 L764-803 證明過 ifconfig down 會讓整台 switch 停轉、ping 永不恢復，而 L855 又說「永不恢復＝failover 壞了」——由上往下照跑**保證得出假的「failover 壞掉」結論**。修法：把 §6h L683-695 換成 L810-816 已驗證的 tc netem 塊。
2. §6h 說 `reroutable_down_endpoints()`「還沒修」——**其實已修**（`topology_manager.py:451-455` 有反向檢查，`test_link_watchdog.py:816` 鎖 `{(5,4),(10,1)}`）。照舊文件會白查一輪。
3. §6h L729-731 的 root cause 過時：`install_initial_routes()` 有 **3** 個 production 呼叫點（`:941` discovery、`:813` readopt、`:1312` link transition），不是 1 個；定義在 `:665` 不是 `:655`。

**🟡 P1 精選**（其餘見報告）：sFlow「ingest healthy」的描述三處全錯（INFO 只在 `rx > 0` 才印，且 P4 **沒有 counter sample**、idle 時 grep 是零行＋約 60 秒會出現一個沒被文件提到的 WARN）；L5「Phase 7 還不存在」已過時（Phase 7 全完成）；§6b「約 11 秒」不可能（`LINK_BEACON_TIMEOUT_S = 15`，實際 15–20s）；§5g 行號漂移最危險的一處——`HttpSession.cpp:1734-1739` 實際在 `:1811-1814`，而 `:1773` 有一段**長得一模一樣**的 `if (e.dstDpid == dpid)` 屬於別的端點，照舊行號會讀錯段；§9 缺 32afeb9 的新症狀（死 switch 現在是從清單**消失**：`switches` < 10，不是 `enabled` < 10）；L1015-1026 有一段孤兒 §5b 與正牌 §5b 矛盾。

**✅ 乾淨、不用重查**：全部 6 個路徑存在；3fc42ed 搬走的 5 個腳本 runbook 完全沒引用（零影響）；port 佈局 kernel **8000** / proxy **8081** / **Ryu 8080** 全對；9 個端點在註冊處逐一驗過、方法一致；10/4/40/12/32、1/256 取樣、2s TTL、TTL 59、path_len 7 全吻合；power 值域 33466–147622 mW 逐 dpid 重算 byte-exact；「ping 有沒有停」判準句三處都在。

**方法論註記**：全檔**唯一**存活的引用是 §6e——它就是用 symbol 不用行號的那處（5d53cf0 自己的修法）。行號引用五處全漂。

**流程註記**：worktree 陷阱又中了一次——B2 的 worktree 開在上游 `8b61cdc`（沒有 tests/），靠 prompt 裡的 reset 指令救回。這條要進 session-close 的記憶更新。

### S Slide template 補充審查 ✅（詳見 S-slide-review.md，~300 行；template 未改，等 Adam 裁決）

**差距實為 69 commits**（fbd8140..5d53cf0），不是估的十幾個——素材量大一個量級。

**B 節四數字全過期**：commit 202→**271**、gtest 426→**546**、Python 337+101→**517**、`tests/` 33→**43** 檔。A3.1 的三條量測指令仍準（grep 數與實跑逐位吻合），不用動。**Phase 格三處錯**：Phase 7 已完成（plan:480）；Phase 8 自己的章節 :515-523 四條劃掉三條但表格 :25 仍寫「未做」；Page 33 未完成清單三格全錯。

**建議新增 2 頁**：① Phase 7 電源管理（目前簡報**完全沒有**這頁，最大結構缺口）；② 第二輪獨立審查（55 條全中零誤判，比 Page 31 的第一輪大一級）。

**A2 裁定表建議 +9 條**（全部 `git show 28b8b13:` 驗過原文）：6 條列入 bug 頁——`f21d7a0` 缺欄位殺 kernel、`57346f6` OpenAI key 進 log、`cbb504a` 丟 boost::edge found 旗標、`5054249` VLAN 欄位名不符（未引爆地雷）、`59dc5d3` 十台共用一個插座、`ee7233b` 功能五層同時是死的；`916d330` 拆半（power 半 baseline、OpResult 半照 8c25dbc 先例排除）。六條全符合 Page 14「無聲」主題。

**兩個會讓簡報 agent 出錯的陷阱**：`57346f6` 是**產品自己的** Intent Translator 用 OpenAI，不是 A1.3 禁的 AI 協作——不加註會被誤砍；`3292653` 的 message 與 Page 18 ④ 對 graph 行為互相矛盾，動筆前須擇一。

**Page 28 現在就填得起來**（16.63s 自癒、hitless、38/40、路徑 1 6 10 7 4）但素材在 repo 外（本資料夾），**D 節出處表只列 repo 內路徑——不補位置，簡報 agent 找不到會編**。**⛔ readopt 相關（3a312e3/eace67c）在缺陷修掉前不要上台。**

## 給 Adam 的早晨清單

-2. **⛔⛔ 早上不要在 Mininet 活著時直接 `stack.sh up ovs`**——那會重啟 Ryu，而「Mininet 活著＋Ryu 重啟」正是 /stats/flow wedge 的觸發條件（root cause 未證明、無解法）。要重起 stack：先 exit Mininet → `stack.sh up ovs` → 在它停下等 Enter 時再開 Mininet。詳見 C 報告收尾節。
-1. **⛔ readopt 在修好前視為危險品**：`POST /p4/readopt/{dpid}` 會把健康 switch 清成 0 條路由還回報 success（A 在 s1、s6 兩台重現）。**不要對任何 switch 跑它**；3a312e3 的 502 訊息會把你引導到它——那段指引在缺陷修掉前等於陷阱。中招後的救援＝重啟 proxy。修這條時記得補「readopt 後驗 rule 數非零」的測試。
0. **⛔ 跑 runbook 前先修 §6h**：它的斷鏈路步驟是 `ifconfig down`（L692）、判準卻是 tc netem 版（L855），照跑保證得出假的「failover 壞了」。把 L683-695 換成 L810-816 的 tc netem 塊。同節「reroutable_down_endpoints 還沒修」也是舊的——已修。
1. 先讀本檔「發現彙整」，再看各 agent 檔的 TL;DR（都在檔案開頭）。
2. Mininet 整晚沒動的話：exit CLI 後跑 `pgrep -ax simple_switch_g` 查 orphan（A 的報告會有基線 pid 清單可比對）。
3. 兩個 P1 文件路徑修正（見 B2 節，一行改一處，低風險）。
4. 記憶更新：kernel API 是 `:8000` 不是 `:8080`（B2/B4 對程式碼證實：kernel 8000 / proxy 8081 / Ryu 8080）；Python 測試數 canonical 改為 **517**（385 是 caa6d5b 的過時帳面，B1 已溯源）。
5. 小修候選：eace67c 漏網的 `curl --fail-with-body -sSf`（捆綁 `-f` 還在，token helpers 處）；`3fc42ed` 理由句與 README 的「NO TESTS RAN」機制描述（B1+B2 互證，同根因）。
6. **P1 待修：`LiveSwitchTest` 的 opt-in 守衛是「proxy 不在就直連 live switch」**——fabric 開著時跑普通 L1 測試（proxy 恰好停著）就會安靜重配 switch。昨晚實際發生過一次（s1 被推了 pipeline/2 routes/clone session 250，已控制）。修法方向：把 opt-in 改成顯式環境變數硬 gate，缺席一律 skip。看 A 的報告時記得 s1 有這個污染事件的脈絡。
7. **餵 template 給 cowork 之前**：先照 S-slide-review.md 更新 template（B 節數字、Phase 三格、A2 +9 條、D 節補 repo 外素材路徑、兩個誤判陷阱加註）；readopt 相關素材先不要上台。
8. **下次開環境的 live 複驗清單**：
   - OVS 輪：`034da18` 的繞路（單端 netem，期望 canary 自癒而非 291 秒黑洞）＋啟動期不再出現 `route reinstall failed`/KeyError。
   - P4 輪：對健康 switch 打 readopt → 期望 502 `step:"mastership"` 且 **rule 數不變**（清表不再發生）；power-cycle 後 readopt 照常成功。
   - **P4 側單向故障是未測空白**（proxy watchdog 對單向 beacon 消失的行為）——單端 netem 一次就知道。
   - 新工具串上：故障輪前後 `qdisc_snapshot.sh save/diff`。
9. 研究 session（進階測試）prompt 在本資料夾 `RESEARCH-PROMPT-advanced-testing.md`——貼到有 web 的新 session 跑，報告會自己落檔，跑完跟接手的 session 說一聲即可。

## Housekeeping（未動，留給 Adam 裁決）

- repo 根目錄有未追蹤散落物：`cbb504a.patch`、`commit.diff`、`commit_diff.txt`、`diff.patch`、`diff_caa6d5b.patch`、`head.txt`——今天 3fc42ed 才把手跑診斷搬離 root，這幾個又出現了。
- `.vscode/settings.json` 有未 commit 修改。
