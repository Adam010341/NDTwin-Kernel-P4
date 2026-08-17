# NDTwin-Kernel 測試工具總覽

> 📍 **入口不是這裡（2026-08-17）**：「我現在該跑什麼」看
> [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md)。這一份的角色是**參照**——
> 每個工具的完整說明與設計取捨。兩份衝突時以入口那份為準。

## 這份文件回答什麼

這份文件是 NDTwin-Kernel（一個網路數位孿生系統的 C++ 核心）測試工具的總覽，對象是接手的工程師。它回答五個問題：

1. 專案裡有哪些測試層級？以什麼分類軸組織？
2. 每一層抓什麼樣的缺陷、需要什麼前置、怎麼跑、判準是什麼？
3. **每一層結構上看不到什麼？**（最重要的一問——它決定了綠燈能買到多少信心）
4. 為什麼需要這麼多層，而不是一個「跑全部」的腳本？
5. 每個工具取代了什麼不可靠的人工判斷？

急著用的話：層級總表在「分類軸一」開頭，會咬人的東西在「陷阱速查」，缺口在「什麼還沒有被涵蓋」。

這不是工具清單。主要分類軸是專案自己的**八格測試架構**（L0、L1、L1-fuzz、L1.5、L2、L3、L4、L5，外加橫跨 L2/L3 的 property testing）加上判定標準層；第二個分類軸是跨層級的閘門機制型態。文件內容只根據專案中實際存在的文件與工具檔頭撰寫；凡是材料不足以支撐的地方，文件會明說「不在材料範圍內」，而不是猜測。

**刻意不寫檔案清單、也不寫測試數字。** 這兩者都會在三天內腐爛：fault 目錄現在 3 型、TODO 列了 3 型、還有更多要加；L6 尚未存在；`2026-07-27_p4_bmv2_support_plan.md` 的 Phase 3 還沒開始。`7eddd68`（"Stop baking test counts into three testing docs"）是刻意把數字從文件裡拿掉的 commit，本文件延續那個決定：**凡是會變的量，給你數它的指令，不給你數字。**

## 設計主題：把「看起來還好」換成 pass/fail 閘門

這個專案的測試工具有一個反覆出現的主題：**把「看起來還好」換成明確的 pass/fail 閘門**。幾乎每個工具的存在理由都可以用這句話解釋：

- `check_logs.py` 取代「捲一遍 log 看有沒有怪東西」——它對任何未允許的 error/warning 直接判失敗。
- `warning_allowlist.txt` 讓「新出現的 warning」無法藏在既有 warning 裡——任何沒列出來的就失敗。
- `baseline_diff_allowlist.txt` 逼每個「P4 做不到這個」都必須寫成文字——任何沒被允許的差異都失敗。
- `compare_baseline.py` 用「已知良好的 OVS 行為」當 P4 的規格，取代「肉眼看 P4 輸出覺得差不多就當作可以」。
- `components.py` 用實測取代「把七個元件全部啟動再用肉眼檢查」。
- L1 把 gtest 跑兩種方式，取代「單一測試跑法全綠就當作沒問題」。
- mutation testing 要求「親眼看測試失敗過」才算出貨，取代「測試有跑、有綠燈就當作有效」。
- `local_ci.sh` 取代「憑記憶把六個 job 的旗標打對」——`setarch -R` 那一行寫下來三天後還是被重新發現了一次。
- `p4_coverage_gate.sh` 取代「覆蓋率大概還可以」——它盯的是**未覆蓋清單的形狀**，不是數字。
- `fuzz_sflow` 取代「我想得到的畸形封包都寫成測試了」——手寫案例只涵蓋有人想到的畸形。
- `twin_audit.py` 取代「儀表板說健康就是健康」——所有儀表板數字都來自同一個 ingest，它們一起錯的時候會很有自信。
- `faults.sh` 取代「這個 bug 修好了」——修好而沒留下故障**類型**的 bug，只被防守到下一次回歸為止。
- `qdisc_snapshot.sh` 取代「netem 殘留為 0 就等於環境乾淨」——那個檢查看不見 htb 被換掉。

為什麼需要這麼多層？因為不同的失敗模式出現在不同階段，而且每一層的成本不同。L0/L1/L1.5/property testing 只要幾分鐘、不需要 Mininet 或執行中的 kernel，所以可以在每次改動後跑；L2/L3 需要 running stack，回答 API 契約與影響範圍；L4 需要完整 stack 和流量，回答端到端行為；L5 還要能對介面與行程動手。層與層之間有依賴關係——workflow 文件明確指出啟動順序有依賴關係，順序錯了測不出東西。下層沒過，上層的結果沒有意義；反過來，下層過了也不代表上層會過。

把閘門分層的另一個理由：每一層的失敗有不同的調試成本。L0 失敗表示編譯期就破，L1 失敗表示單元行為錯或跨測試干擾，L1.5 失敗表示 P4 裡多了永遠測不到的程式碼，L2 失敗表示 API 契約破，L3 告訴你誰會受影響，L4 告訴你整個 P4 路徑是否偏離已知良好的 OVS 行為，L5 告訴你已修的缺陷會不會再溜過去。越早的閘門越便宜，所以應該越常跑。

還有第三個理由，是 2026-08-12/13 那一輪才學到的：**有九個 bug 裡的八個來自實跑而不是全綠的測試套件**。L5 與 twin 測謊器就是把「實跑才找得到」的那一類，從偶然變成可以重複執行的程序。純粹往下加測試補不上這個缺口——L1 再多也看不到一條 291 秒沒動的 flow 被儀表板一致地報成健康。

## 分類軸一：測試層級（八格 + 判定標準）

以下是總覽。**「結構上看不到什麼」那一欄是最有價值的一欄**——它決定了下一層為什麼必須存在，也決定了綠燈能買到多少信心。

| 層級 | 回答的問題 | 前置 | 失敗代表 | 結構上看不到什麼 |
|---|---|---|---|---|
| L0 建置檢查 | 每個元件還能不能編譯？ | 無 | 跨 repo 建置破壞 | 任何執行期行為 |
| L1 單元測試 | 單元行為對不對？共享 process 下還對不對？ | 無 Mininet | 行為錯誤或跨測試干擾 | 沒人想到要寫的輸入；跨元件互動 |
| L1-fuzz sFlow 模糊測試 | 解析器對**沒人想到的**畸形封包是否記憶體安全？ | clang + `-DFUZZING=ON` | crash／sanitizer 報告／hang | 解析結果對不對（那是 L1 的事） |
| L1.5 P4 覆蓋閘門 | `.p4` 有沒有新增任何**符號執行永遠到不了**的程式碼？ | p4c／p4testgen（缺席即 skip） | 未覆蓋清單變長 | 取樣／clone 路徑（原理上不可達，見下） |
| L2 API 契約 | kernel 的 `/ndt/*` API 是否遵守契約？ | running stack | API 結構、不變量、錯誤路徑被破壞 | 數值對不對；誰在用這個 endpoint |
| L3 元件契約子集 | 改一個 endpoint，哪些元件會壞？ | running stack | 元件呼叫未實作 endpoint | 執行期真的會不會走到那個呼叫點 |
| L4 端到端 + 差異比對 | P4 路徑與已知良好的 OVS 路徑行為是否一致？ | 完整 stack + 場景流量 | 行為差異未被允許 | rates/counters/timestamps 的**數值** |
| L5 故障注入 | 修好的那個 bug，再發生一次會不會被抓到？ | 完整 stack + root（見陷阱 6） | 故障下的行為不符合目錄的宣告 | 目錄裡沒有的故障類型；速率層級的損害 |
| property testing（跨 L2/L3 旁） | 隨機的 link up/down 序列會不會打破圖的不變量？ | 只要 `p4_proxy/venv` | 不變量被違反 | 真實時序、偵測延遲、封包 |
| twin 測謊器（L5 的判定引擎，也可單用） | twin 說 active 的 flow，封包真的在動嗎？ | running stack + Mininet host PID | 宣稱與證據矛盾 | 速率／利用率（刻意不做）；路徑對帳（保留未實作） |
| 判定標準 | log、行程、資源有沒有異常？ | 每個需要判定的場合 | 未允許的 warning/error 等 | 不會叫的錯誤 |

**怎麼跑（速查；細節與旗標理由在各節）：**

```bash
./run_layers.sh quick                     # L0 + L1，約 2 分鐘，不需要 Mininet
tools/test_workflow/local_ci.sh           # 六個 CI job（含 L1.5），重建四個 build 目錄，數分鐘
tools/test_workflow/p4_coverage_gate.sh   # L1.5 單跑；.p4 沒改時是毫秒級 no-op
./build-fuzz/bin/fuzz_sflow tests/fixtures -max_total_time=60   # L1-fuzz，需先另開 clang build
./run_layers.sh api p4                    # L2 + L3 + log check，需要 running stack
./run_layers.sh baseline ovs / compare / full p4                # L4
tools/test_workflow/faults.sh list        # L5 目錄；run <ID> 才會真的注入
tools/twin_audit/twin_audit.py audit      # twin 測謊器
```

**尚未存在的層級：L6 soak（長時執行 + drift 偵測）。** 目前**沒有**這個工具，本文件寫出來是為了讓缺口可見而不是讓它看起來已被涵蓋。長時間執行才會現形的缺陷（記憶體成長、counter 溢位、twin 與現實的緩慢漂移）目前**沒有任何一層在守**。sFlow 取樣的誤差地板 196·√(1/c) 是決定 drift 門檻的理論下限——在有這個數字支撐的門檻之前，soak 只能報告不能判定。

### L0：建置檢查

**回答的問題：**「每個元件還能不能編譯？」具體來說，它抓的是最常見的跨 repo 破壞：你在 kernel 改了一個 shared header，一週後才發現 Energy-Saving-App 已經編不過了。L0 把這個發現時間從一週縮短到幾分鐘（腳本執行時間為秒到分鐘級）。

**執行時機：** 每次改動後的第一道閘門。不需要 Mininet、不需要執行中的 kernel。可以只跑指定的元件（`./l0_build_check.sh kernel p4`）或全部。

**失敗代表：** 某個元件回報 FAIL，exit code 非零——有跨 repo 的建置破壞。特別值得注意的是第三種狀態 SKIP：toolchain 在這台機器上缺席。SKIP 不算失敗，但會被回報，讓你知道覆蓋範圍縮小了。這是這個專案一貫的設計：覆蓋降低必須可見，不能默默發生。

**為什麼存在：** 取代「等到真的把系統跑起來才發現編不過」。單一 repo 的建置無法發現 shared header 的跨 repo 影響，所以必須把 kernel 的兄弟元件一起編。這個腳本依賴 `components.env` 提供路徑、conda env 與 port 的單一事實來源；`KERNEL_DIR` 由 `components.env` 自己的位置推導，`WORKSPACE_ROOT` 用「找兄弟 repo」的方式發現而不是假設固定深度——這些設計都是為了讓腳本在不同 checkout 下不用改設定就能跑。檔頭也註明這些值是在這台機器上驗證過的，佈局不同時要調整。

### L1：Kernel 單元測試

**回答的問題：** 單元層級的行為是否正確？這層涵蓋 C++ 與 Python 兩半邊。C++ 這邊是 gtest，全部在 `tests/` 下，編成單一執行檔 `test_routing_strategy`。Python 這邊是 `p4_proxy/tests/`（unittest 格式，不是 pytest）——P4 路徑有一半在 Python（sFlow emitter、clone session），C++ suite 碰不到它們。

⚠️ **這裡不再寫測試檔數與 case 數。** 這兩個數字在 2026-08-10 實跑更正過一次，48 小時內又過期了（新增的測試檔就是讓它過期的原因）。要當下的數字，自己數：

```bash
git ls-files 'tests/test_*.cpp' | wc -l          # C++ 測試檔
git ls-files 'p4_proxy/tests/test_*.py' | wc -l  # p4_proxy Python 測試檔
git ls-files 'tests/python/test_*.py' | wc -l    # kernel 端 Python 測試檔
git ls-files 'tests/shell/test_*.sh' | wc -l     # shell 測試檔
grep -rhE '^(TEST|TEST_F|TEST_P)\(' tests --include='*.cpp' | wc -l   # C++ case 數（不需 build）
./build/bin/test_routing_strategy --gtest_list_tests | grep -c '^  '  # C++ case 數（需 build）
```

⚠️ **兩個 Python 測試目錄用的是不同直譯器，這不是巧合而是規格。**

| 目錄 | 直譯器 | 可用什麼 | skip 的意義 |
|---|---|---|---|
| `p4_proxy/tests/` | `p4_proxy/venv/bin/python`（`components.env` 的 `P4_PROXY_PY`；runner 會依序試它、`p4dev-python-venv`、`python3`，挑第一個 import 得到 P4Runtime protobufs 的） | 第三方套件（grpc、networkx、hypothesis…） | 缺 protobufs 或缺編譯好的 p4info 時 skip，回報為 **PROVED LESS**；兩個前置都在卻還 skip 則是 **FAIL** |
| `tests/python/` | **系統 `python3`，只准標準庫** | 標準庫，就這樣 | **任何 skip 都是 FAIL**——這裡的測試不依賴 python3 以外的任何東西，所以沒有 skip 的正當理由 |

2026-08-13 踩過一次：在 `tests/python/` 底下的測試 import 了 networkx，系統 python3 沒有，整個檔案在 import 期就死掉，runner 讀到 `ran=0` 判 FAIL。**要寫依賴第三方套件的測試，它就不屬於 `tests/python/`。** 這條界線是刻意的：`tests/python/` 涵蓋 OVS/Ryu 那半邊與測試工具本身，必須在一台只有裸 python3 的機器上能跑。

⚠️ **shell 測試的摘要格式是硬性介面。** runner 用 `grep -oE '^Ran [0-9]+'` 抓執行數（`l1_unit_tests.sh`），所以每個 `tests/shell/test_*.sh` 結尾必須印：

```
Ran N checks, all passed        # 或 "Ran N checks, M failed"
```

行首不能有空白（樣式錨在 `^Ran`），數字不能省。格式不合會被判 `NO TESTS RAN`，而 `NO TESTS RAN` **計入失敗**——它跟「測試全掛」在 exit code 上沒有差別，因為兩者都沒有證明任何事。

**執行時機：** `./run_layers.sh quick` = L0 + L1，約 2 分鐘，不需要 Mininet。`l1_unit_tests.sh` 會先設定/建置（或 `--no-build` 假設 build 是最新的），然後把 gtest 跑兩種方式。

**L1 最關鍵的設計理由：為什麼要把 gtest 跑兩次。** 兩種執行方式單獨看都會騙人：

- `ctest` 為每個 `TEST_F` 註冊一個獨立的 ctest case，各自在自己的 process 裡用 `--gtest_filter` 執行。這種隔離意味著「只有在多個 suite 共用同一個 process 時才會發生」的問題永遠不會發生，所以 ctest 會報綠。
- 直接執行整個執行檔則把所有 suite 放在同一個 process，跨測試干擾才會現形：static 初始化、singleton、全域註冊表、某個 suite 留下來的狀態。

實測數據（在 `Logger::init` 重複初始化 bug 還存在的時候）：

| 執行方式 | exit | ran | passed | skipped |
|---|---|---|---|---|
| `--gtest_filter=P4RoutingStrategyTest.Install...` | 0 | 1 | 1 | 0 |
| 整個執行檔 | 1 | 12 | 10 | 2 |
| ctest | 100% passed | 12 | 0 failed | — |

注意第一行：在 ctest 底下那些測試是真的跑了、也真的通過。ctest 不是在吞掉失敗，而是它從來沒有製造出會失敗的條件。所以兩種方式都要跑：ctest 的隔離保證每個測試的獨立正確性，直接執行讓跨測試干擾現形。

腳本另外斷言「實際 RUN 的測試數」等於「探索到的測試數」：被 SKIP 的測試不是通過的測試。Python 端的 skip 比照辦理，但有一个額外的陷阱：unittest 把 skip 掉的測試算進 "Ran N tests"（gtest 不會），所以「整個檔案全部 skip」會印出 `Ran 55 tests / OK` 而被誤判為通過。Python 測試若因為 interpreter 真的缺 P4Runtime protobufs 而 skip，那是環境限制而不是測試壞掉，但仍舊會被回報為未通過。

**失敗代表：** 單元行為錯誤、跨測試干擾、或測試被 skip。找出是哪一種，是 L1 之後除錯的起點。

**為什麼存在：** 取代「單一測試跑法全綠就當作沒問題」。L1 也是上面所有層的立足點：API 契約測試假設單元行為正確，端到端比對假設元件行為正確。測試資產方面還有 `tests/python/`（kernel 端與測試工具本身的 Python 測試）、`tests/shell/`、以及 `tests/fixtures/` 的 `.bin`——從真實運作的 OVS + Ryu + Mininet 抓下來的 sFlow 封包，作為 golden fixtures。

### L1-fuzz：sFlow 解析器模糊測試

**回答的問題：** 「沒有人想到要寫成測試的那些畸形封包，解析器擋不擋得住？」`FlowLinkUsageCollector::handlePacket(char*, size_t)` 是這個 process 暴露面最大的輸入口——任何能對 :6343 送 UDP 的東西都到得了它，而且它**已經產生過一次 heap-buffer-overflow**（ASan 抓到，後來用邊界檢查加 17 個手寫畸形案例修掉）。手寫案例涵蓋的是有人想得到的畸形；這一層涵蓋的是想不到的。

**判準是「乾淨拒絕」，不是「沒有聲音」。** 解析器有一條明確的拒絕路徑（`reportMalformedDatagram`），所以任何輸入不是被解析就是被計為畸形。**crash、sanitizer 報告、hang 就是發現**。這一層不對解析結果做任何斷言——它獵的 bug 類別是記憶體安全，「安全但解錯」是 `test_SFlowParsing.cpp` 的職責。

**前置與怎麼跑：** clang only（libFuzzer 隨 clang 出貨，GCC 沒有；`tests/CMakeLists.txt` 對 `FUZZING=ON` + 非 clang 直接 `FATAL_ERROR`）。預設 OFF，要另開一個 build 目錄：

```bash
cmake -S . -B build-fuzz -DCMAKE_BUILD_TYPE=Debug -DFUZZING=ON \
      -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_FLAGS=-Wno-error=deprecated-declarations
cmake --build build-fuzz -j"$(nproc)"
./build-fuzz/bin/fuzz_sflow tests/fixtures -max_total_time=60
```

**seed corpus 就是 L1 的 golden fixtures**（`tests/fixtures` 的 `.bin`，真實抓包，其中數個本來就是畸形的）。這個選擇有實質效果：語料庫從 header 檢查的**另一側**開始，fuzzer 不用先自己學會 sFlow 的 version 欄位該填什麼。

**驗收這個 harness 本身**（呼應下面的 mutation 章節）：把解析器裡的某個邊界檢查註解掉，確認它幾秒內就抓到。**接不到東西的 fuzzer 會永遠綠燈**——這是這一層最容易的自欺方式。

**結構上看不到什麼：** 解析結果對不對。還有兩個實作上的細節值得知道，因為它們是「看起來像發現但不是」的來源：collector 每 512 個輸入回收一次（否則 flow table 累積成長會被 libFuzzer 報成解析器 OOM），而最後一個 collector 是**故意不刪**的（`~FlowLinkUsageCollector` 會呼叫 `stop()` 進而碰 logger，在 static destruction 期間那會撞上已經消失的 spdlog registry，表現為每一個輸入——包括合法輸入——都在結束時 heap-use-after-free）。

### L1.5：P4 覆蓋閘門

**回答的問題：** 「`.p4` 有沒有新增任何符號執行**永遠**到不了的程式碼？」注意問句的形狀：這一層問的不是「覆蓋率夠不夠高」。

**怎麼跑：** `tools/test_workflow/p4_coverage_gate.sh`。p4testgen 隨已安裝的 p4c 出貨，所以不用額外裝東西，而且**不需要 bmv2、不需要 kernel、不需要 Mininet**——只要那個 `.p4` 檔。它對程式做符號執行，回報產生的測試碰得到哪些 IR statement node。

```bash
tools/test_workflow/p4_coverage_gate.sh                    # 閘門（.p4 沒改就跳過）
tools/test_workflow/p4_coverage_gate.sh --force            # 沒改也強制量
tools/test_workflow/p4_coverage_gate.sh --update-baseline  # 接受現況為新基準
```

**判準是未覆蓋清單的形狀，不只是數字。** 基準檔 `p4_coverage_baseline.txt` 記三個欄位：`.p4` 的 `git hash-object`、覆蓋率、以及**未覆蓋的行號清單**。閘門對這個清單雙向比對：

- 清單**變長** → FAIL。有新程式碼落地，而且沒有任何產生出來的測試到得了它。這應該是一個**刻意的決定**（附上 `--update-baseline`），而不是六週後的意外發現。
- 清單**變短** → 不是失敗，印一行 note 提醒你 `--update-baseline`。
- 覆蓋率低於 `MIN_COVERAGE`（預設 0.85）→ p4testgen 自己就會拒絕跑完，FAIL。

**只在 `.p4` 真的變了才量**（比對 `git hash-object` 與基準記的 sha）。完整跑一次要幾分鐘，沒改時是 14ms 等級的 no-op——這正是它可以被安全掛進 `local_ci.sh` 的原因。**人會跳過的檢查不算檢查。**

**p4testgen 缺席是 skip 不是 fail。** 這台機器上有，別台可能沒有 p4c。理由寫在腳本裡：為了一個可選工具缺席就讓整個 run 變紅，是 CI 開始沒人讀的方式。

**結構上看不到什麼——而且這是原理問題，不是待辦事項。** 基準是 85.2%，未覆蓋的是 egress clone 分支上連續的 8 行（為取樣封包組 `packet_in` header 的那一塊）。

原因要講精確，因為講錯很容易：**不是「因為有 clone 所以到不了」，而是因為那個分支條件讀的是 `instance_type`**——這個值只有在 clone 真的發生的那次執行才會被設成 clone 的值，而符號執行引擎是沿著一條路徑走一個封包，不會模擬 clone 的第二次 egress 執行。已用 p4lang/tutorials 當對照組證實：`basic.p4` 沒有 clone，100%；`flowcache/solution` **有** clone 卻也是 100%，因為它的 egress 分支條件讀的是 `egress_port`，那是 solver 可以直接選的值。

所以那 8 行只能靠 **live 驗證**，加上 `test_SFlowEmitterRoundtrip.cpp` 的跨語言 round-trip。清單變短是好消息，變長就是閘門要擋下來的東西。

### L2：Kernel API 契約測試

**回答的問題：** kernel 的 `/ndt/*` HTTP API 是否遵守契約？工作區的每個工具和 app 都只透過這個 API 跟 kernel 講話，所以在這裡驗證，等於驗證它們共同的地基。workflow 文件把 L2 標為「最重要，你現在缺的」一層；`tools/contract_test/` 下的工具就是這層的實作。

**檢查什麼：** 每個 endpoint 三種檢查：

1. **structure**：回應是合法 JSON、欄位正確、型別正確。
2. **invariants**：數值跟 topology 檔一致、彼此一致（例如 10 個 switch、全部 up、路徑非空）。
3. **error path**：壞輸入得到合理的 4xx，而不是 500、也不是假 200。

**工具如何配合：**

- `spec.py`（710 行）定義每個 kernel 註冊的 `/ndt/*` endpoint 的契約。shapes 取自 `doc/2026-01-02_ndt_api.md`，並與 `src/ndt_core/http/HttpSession.cpp` 的 dispatch table 交叉檢查。endpoint 名稱與 method 以 kernel 實際註冊為準，所以有幾個是 `2026-01-02_ndt_api.md` 沒寫到的。method 很重要：kernel 是 (method, target) 一起 match，GET 打到 POST-only endpoint 會落到 404，看起來像 endpoint 不存在。
- `schema.py` 是刻意零依賴的宣告式 schema validator（不用 jsonschema/pydantic），讓契約測試在任何有 python3 的地方都能跑，包括光禿禿的 demo VM。它的存在理由是**精確的失敗訊息**：`nodes[3].is_up: expected bool, got str ('true')` 比「get_graph_data failed」有用得多——後者比肉眼盯 GUI 好不了多少。
- `run_contract_test.py` 是驅動者，對每個 endpoint 跑 structure/invariant/error path 檢查。它是 read-only 檢查，對 running system 安全。用法帶 `--topology` 指定 topology 檔（例如 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`）。
- `selftest_fixtures.py` 用 `doc/2026-01-02_ndt_api.md` 的實際 response 範例當 fixture，**證明 schema 接受 kernel 文件上寫的東西**，不需要跑 kernel。如果 schema 拒絕文件範例，是 schema 錯；在 live system 上除錯之前，先在這裡發現便宜得多。invariant 的 case 還額外檢查每個 invariant 在壞資料上真的會 fire——確保檢查不是空轉、不是 vacuous pass。

**執行時機：** 需要 running stack。`./run_layers.sh api p4` = L2 + L3 + log check。

**失敗代表：** API 的結構、不變量或錯誤路徑被破壞。workflow 文件在 L2 章節有「順手抓到的現有破口」一節，表示建置這一層時確實抓到了既有的 API 問題。

**為什麼存在：** 取代「把 GUI 打開、點一點、看有沒有壞」。因為所有元件都站在同一個 API 上，契約測試是最省錢的槓桿點。同時它讓「改 kernel API」變成有明確後果的動作：改壞了，L2 會先紅。

### L3：元件契約子集

**回答的問題：** L2 問「kernel 的 API 對不對」，L3 問「**哪些元件會壞**」。改完一個 endpoint 之後，不用把七個元件全部啟動再用肉眼檢查，就能知道爆炸半徑。

**工具如何配合：**

- `components.py` 記錄每個工作區元件實際依賴哪些 `/ndt/*` endpoint。它是**實測不是猜的**：把每個元件的 source 拿來 grep `/ndt/` URL 得出來的。`KERNEL_ENDPOINTS` 是 kernel 真正的 dispatch table，從 `HttpSession.cpp` 的 if/else-if chain 逐行抄錄。method 的細節再次重要：kernel 是 (method, target) 一起 match，GET 打到 POST-only 會 404，看起來像 endpoint 不存在。
- `l3_component_check.py` 對每個元件做兩種檢查：
  1. **existence**：它呼叫的每個 endpoint 必須存在。404 代表元件在呼叫 kernel 沒實作的東西。Energy-Saving-App 對 `/ndt/disable_switch` 的呼叫就是這樣被抓到的——不過這個例子後來被更正過，值得完整寫下來，因為它示範了 L3 這種靜態掃描的能力邊界。`components.py` 記錄「app POST 這個 endpoint」是**對的**：**Energy-Saving-App** 的 `src/app/http.cpp:269`（另一個 repo）真的有那段程式碼，而 kernel 真的沒有實作它，L3 也確實印出 MISSING。但那個函式有 **0 個呼叫點**——它是死碼。實際的節能路徑走 `/ndt/set_switches_power_state`（2 個呼叫點，實測回 200）。所以「節能功能從來沒關掉過任何交換機」這個推論是錯的。

  這件事的教訓不是 L3 沒用，而是它回答的問題比看起來窄：**它掃的是「原始碼裡出現過哪些 endpoint」，不是「執行時真的會打哪些 endpoint」。** 前者是後者的超集。要區分兩者需要呼叫圖分析或執行期觀測，不在這一層的能力範圍內。把這個限制寫清楚，比讓下一個人再推論一次同樣的錯誤便宜。
  2. **contract**：對 `spec.py` 有涵蓋的 endpoint，跑 L2 的 structure/invariant 檢查，把失敗歸因到依賴它的元件。

**執行時機：** 需要 running stack；`run_layers.sh api p4` 包含。

**失敗代表：** 有元件在呼叫 kernel 沒實作的 endpoint，或某個 endpoint 的契約破壞會波及哪些元件。它把「改 API 的影響」從模糊的擔憂變成明確的清單。

**為什麼存在：** 取代「全部啟動、肉眼檢查」。「當 kernel 改一個 endpoint 時，可以精確說出哪些元件會壞，而不是把七個都 launch 起來盯著看」——這是 `components.py` 自己寫明的存在理由。

### L4：端到端場景 + OVS/P4 差異比對

**回答的問題：** 整個系統跑起來之後，P4 路徑的行為是否與已知良好的 OVS 路徑一致？這層分兩部分：4-A 固定場景腳本，4-B OVS/P4 差異比對。workflow 文件稱 4-B 是「P4 開發最有效的技巧」。

**4-B 的核心設計（`compare_baseline.py`）：** OVS 路徑是 known-good，所以**用它的行為當 P4 的規格**，而不是替 P4 發明一份規格。naive JSON diffing 在這裡行不通：兩個 topology 真的不同（128 hosts vs 4），rates/counters/timestamps 每秒都在變。所以只比較兩件「無論 data plane 為何都應該相同」的事：

1. **shape**：遞迴的「field path -> type」集合。抓 missing field、type 改變、以及（關鍵）某一邊是空的但另一邊有內容的 list——這正是 P4 stubs 呈現差異的方式。
2. **facts**：per-endpoint 的行為布林。所有 switch 是否 up？flow paths 是否有值？rates 是否非零？tables 是否非空？這些問題的答案必須一致，即使數字不一致。

**`baseline_diff_allowlist.txt`：** 目的是「逼每個『P4 做不到這個』都寫下來」。`compare_baseline.py` 對任何不在清單上的差異都判失敗。每個 P4 落差都必須附理由，不能默默劣化。當 `doc/2026-07-27_p4_bmv2_support_plan.md` 的某個 phase 完成，對應條目就應該刪掉；工具會回報未使用的條目，所以不會累積。

**執行時機：** 需要完整 stack。`./run_layers.sh baseline ovs` 抓 OVS reference；`./run_layers.sh compare` 比對最近一次 P4 capture 與 OVS baseline；`./run_layers.sh full p4` 跑 P4 run 可用的全部層級。stack 的帶起由 `stack.sh` 負責（見「執行編排」一節），場景需要的 readers、traffic、apps 由場景腳本各自啟動。

**失敗代表：** P4 與 OVS 的行為差異（shape 或 facts）沒有被允許。這表示 P4 實作在某個地方偏離了已知良好的行為。

**為什麼存在：** 取代「肉眼看 P4 輸出覺得差不多」。數字永遠不會一樣，但 shape 與 facts 應該一樣；把這個「應該一樣」變成自動化閘門，P4 開發才有穩定的回饋。

### L5：故障注入

**回答的問題：** 「已經修好的那個 bug，同一形狀再發生一次，會不會被抓到？」

**為什麼存在：** 2026-08-12 的靜態＋live 複查連續三次找到同一種形狀——**修好了，但沒有留下對應的故障「類別」**（單向鏈路遺失、mastership 衝突、殺掉 controller）。一個修好而背後沒有故障類型的 bug，只被防守到下一次回歸為止。L5 就是給那些修法一支常設的守衛。

**故障目錄是資料不是程式。** `faults.txt` 一行一個故障型，格式與 `warning_allowlist.txt`、`baseline_diff_allowlist.txt` 同一個形狀（三欄，分隔符是「 | 」空白-直條-空白）：

```
ID | ACTION key=value ... | 這個故障型守的是什麼回歸
```

解析只發生在 `faults.sh` 一個地方。關鍵設計：**故障要落在哪裡不在這個檔案裡**——`--iface` / `--peer-iface` / `--pid` 從命令列來，因為同一個故障型適用於任何鏈路、任何交換機。這就是「加一個故障型 = 加一行」成立的原因。反過來說，**加一個新機制是改程式**，目錄裡出現未知機制會被判 usage error 並明講這件事。

目前只有兩個機制：`link_loss`（netem 丟包，單端或雙端）與 `proc_signal`（對 PID 送訊號）。要當下的故障型數量與內容：

```bash
tools/test_workflow/faults.sh list
```

**每一輪的協定（`run_round`），三條規則都是實際事故換來的：**

1. **qdisc 前後置快照，diff 必須為空——而且這條最後檢查、否決其他一切。** 一輪如果改動了 shaping 樹，那麼它量到的東西已經不是它以為自己注入的那個故障；訊息直接寫 `ROUND VOID ... Discard the result`。
2. **判定來自 `tools/twin_audit/criteria.py`**，不是在這裡另寫一份第二意見。「封包有沒有在動」只有一個事實來源，指控 twin 的工具和弄壞網路的工具共用它。
3. **revert 一定會跑**，包括中途檢查失敗或操作者中斷的時候。留在原地的故障會毒化這台機器上後面每一輪。

完整順序是：qdisc 快照 → `before` 必須是 `moving`（否則什麼都不注入，因為「在一個已經壞掉的網路上跑故障輪證明不了任何事」）→ 注入 → settle → `during` 對照目錄宣告的 `expect` → revert → settle → `after` 必須是 `moving` → qdisc diff。`expect` 只有三個值：`moving` / `still` / `any`；而「前 moving、後 moving、qdisc 乾淨」不是逐條設定的，是入場費。

**失敗代表：** 故障下的實際行為與目錄的宣告不符，或者網路沒有回來，或者這一輪汙染了環境。三者的意義不同，輸出會分開講。

**結構上看不到什麼：**

- **目錄裡沒有的故障類型。** 這是設計上的取捨：故障目錄刻意選擇故障，不像 property testing 那樣隨機探索。TODO 區塊裡有三個已寫下但尚未成為條目的型（非對稱灰色失效、hard controller loss、graceful shutdown），mastership 衝突則明確記為**沒有涵蓋**——它需要第二個 P4Runtime client，也就是第三個機制——「記下來是為了讓缺口保持可見，而不是讓它看起來已被涵蓋」。
- **速率層級的損害。** 見下面 L-3 的說明。
- **同一條目在兩個 data plane 上的答案可能不同。** `L-2`（單向 100% 丟包）在 P4 上 12.5 秒重繞成功，所以 `expect=moving`；同一個注入在 OVS 上黑洞 291 秒零自癒，那裡 `expect=still` 才對。目前條目無法依模式分支，所以那一行編碼的是 P4 的答案，**OVS 輪若在這裡讀到 `still` 應該當成 bug 再現**。

⚠️ **`L-3`（30% 雙向丟包，gray failure）的判定目前不穩定，已知未修。** `criteria.py` 的 ping 通道預設 `TWIN_AUDIT_PING_COUNT=3`，而 `ping` 的 rc==0 只要有一個回應就成立；在 30% 雙向丟包下，某一個方向三個 echo 全掉的機率不可忽略（brief 記錄約 13%，本文件未自行複測），一旦發生就會被讀成「非對稱、有一個方向死了」→ STILL，於是同一個故障輪的判定會隨機在 pass/fail 之間跳。這是取樣數問題，旋鈕（`TWIN_AUDIT_PING_COUNT`）已經存在但目前沒有任何地方設定它。

另外 `L-3` 這條的 `expect=moving` **本身就是發現，不是弱斷言**：它是一個可執行的陳述句，說「連通性檢查在這裡是瞎的」。要抓到灰色失效真正造成的損害需要速率對帳，而那正是 twin_audit 刻意不做的事（見下）。

### twin 測謊器：證據 vs 宣稱

`tools/twin_audit/{twin_audit,criteria}.py` 不屬於任何一層——它是 L5 的判定引擎，也可以單獨對著跑起來的系統用。它獨立於 kernel、獨立於 proxy、不在任何 request path 上，所以**同一份工具對兩個 data plane 都能用**。

**它問的問題：** 對於 twin 宣稱 active 的每一條 flow，去獨立驗證那兩台主機之間封包是不是真的在動。

**founding case：** 2026-08-13 OVS 輪，`get_detected_flow_data` 說某條 flow「flowing at 9-15 Mbps」、`get_graph_data` 說 edges_up 287/288，而那條 flow 已經 291 秒沒有載過任何封包。整個 stack 沒有任何東西發現——因為每一個儀表板數字都源自同一個 sFlow ingest，當 ingest 一直重播一筆陳舊記錄，它們會一致地、很有自信地、全部答錯。

**三通道法定人數。** 三個獨立會壞的觀察通道，`QUORUM = 2`，而且**只要有任何一個異議就是 DISPUTED，永遠不做多數決**——兩票壓過一票不代表那一票錯了，只代表對同一個網路的獨立觀察者之間有矛盾，該去查是哪一個壞了。

| 通道 | 看什麼 | 會被什麼騙 |
|---|---|---|
| `ping` | 資料平面本身，**兩個方向都問** | ICMP 專屬過濾 |
| `paths` | 控制平面自己的答案（`all_destination_paths`） | 陳舊的 twin |
| `counters` | 對端 `/proc/net/dev` 的 rx，**取兩次看成長** | 無關的背景流量 |

⚠️ **證據 vs 宣稱——這是整個工具的重點。** `ping` 與 `counters` 是 EVIDENCE，會投票；`paths` 是 CLAIM，**照跑、照印、但不投票**。理由：`paths` 讀的是控制平面自己的宣稱，而 twin 的信念正是被審計的對象，不是它自己的證人；讓它投票等於讓被告坐上陪審席。這一刀在第一版沒有，實測代價是：2026-08-13 把 h1 的 access link 切斷，ping 說 still、counters 說 still、paths 說 moving，結果判成 DISPUTED、exit 0——**第一版會漏掉自己的 founding case**。

三個設計細節，各自也是踩出來的：

- **一律雙向。** 正向與返向常常走不同交換機（runbook 2026-08-10：6 對主機有 3 對非對稱），所以單一方向證明不了兩台主機能不能通話。「只有一個方向通」被判為 NOT moving，而不是 UNKNOWN——那個非對稱狀態正是上述 P0 的形狀，判成 UNKNOWN 等於在它唯一被設計來抓的案例上解除武裝。
- **看成長，不看絕對值。** 非零的 counter 只證明過去某個時點有封包，那正是那條 291 秒的 flow 混過去的方式。
- **`counters` 會在兩次取樣之間自己送探測封包。** 純被動取樣在閒置鏈路上永遠讀 STILL，造成永久 DISPUTED，害故障輪以「baseline 壞了」為由拒絕注入。中間送封包把它從觀察變成實驗：問題變成「我剛送的封包有沒有到」。它也沒有塌縮成 ping——它數的是**對端的到達**，所以「單向通、回程掉」在這裡是 MOVING 而 ping 是 STILL，非對稱依然看得見。

**⚠️ `PATHS_URL` 預設指向 Ryu 的 :8080。** 跑 P4 模式時必須改指 proxy 的 :8081，否則 `paths` 通道會讀到空的或錯的東西。（它不投票，所以不會直接翻轉判定，但報告會失去最有價值的那一行——宣稱與證據矛盾的那一行。）

**exit code：** 0 沒有矛盾 / 1 至少一條 flow 在說謊或瞎了 / 2 usage 或完全連不上 twin / 3 什麼都判不出來。`criteria.py check` 則是 0 moving、1 still、2 usage、3 inconclusive、4 disputed——選成這樣是為了讓 shell 呼叫者不用解析文字就能分支。

**結構上看不到什麼——而且是刻意的：** **不對帳 rate 與 link utilisation。** 在 1/256 的 sFlow 取樣下誤差地板是 196·√(1/c)，在這個 testbed 產生的計數量級上，「錯的速率」和「誠實取樣的速率」不可分離。在那裡做數值比較只會發出沒有人能處理的警報，而**沒有人能處理的警報會訓練人忽略真正要緊的警報**。路徑對帳（「封包有沒有走 twin 宣稱的那條路」）是下一個要問的問題，它的位置已經在 `criteria.py` 的 `RESERVED_CHECKS` 佔好了，而且是**大聲拒絕**（`NotImplementedError`）而不是安靜回傳 UNKNOWN——一個安靜回傳 UNKNOWN 的保留檢查會在輸出上看起來像已經實作了。

### property testing：橫跨 L2/L3 旁邊的一格

`p4_proxy/tests/test_topology_properties.py`，Hypothesis 的圖狀態機（`RuleBasedStateMachine`），跑在 `p4_proxy/venv` 底下（`hypothesis==6.165.5`，見 `p4_proxy/requirements.txt`）。它是 unittest 相容的，所以 L1 的 Python 半邊會順便跑到它。

**為什麼是這個形狀，而不是顯而易見的那個。** 原始提案是拿 Hypothesis 去驅動**live stack**。那行不通：一條規則（斷鏈路、等偵測、等重繞）要數十秒，而 stateful testing 要跑上百步才划算。那樣做買到的只是少數幾條緩慢的隨機序列——比故障目錄還糟，因為故障目錄至少是**刻意**選擇它的失效。

**價值在圖上。** 這個專案撞過的兩次黑洞缺陷都是圖狀態機的 bug，不是網路的 bug：2026-08-13 的單向失效讓 DiGraph **永久**非對稱（成對的 `EventLinkDelete` 永遠不會來），all-pairs 走訪接著在缺少的反向邊上 KeyError；同樣的非對稱形狀也在一次普通啟動的 LLDP jitter 中出現過。這些在這裡毫秒級就到得了，完全不需要 Mininet。

**規則與不變量：** 規則是 link up、link down 雙向、**link down 單向**——最後那個正是沒有人寫過測試的形狀。承重的不變量是 `recompute_never_raises`，因為 live 缺陷是一個例外而不是一個錯誤答案；其餘不變量釘住「正確答案長什麼樣」，這樣一個用「把例外吞掉」來假裝修好的改動仍然會失敗。

**一個關於不變量強度的教訓寫在檔案裡：** 第一版直接檢查每條規則後的 `dest_paths`，立刻抓到「path 2->1 聲稱有 hop 2->1，但圖上沒有」。那是**測試錯了不是程式錯了**——`dest_paths` 是內部中間值，每個消費者讀之前都會重算，所以「鏈路變動到下一次重算之間的陳舊區間」沒有觀察者。斷言更強的性質會永遠失敗，而且描述的不是任何真實的東西。契約是「使用時一致」，不是「永遠一致」。

**結構上看不到什麼：** 真實時序、偵測延遲、封包。它證明的是圖的代數，不是網路。

### 判定標準層：取代「看有沒有 error」

workflow 文件的判定標準章節處理三件事：log 判定、行程健康度、以及為什麼要量記憶體和 thread。`run_layers.sh` 的 `--traffic` 會加上 telemetry checks。材料中可詳細說明的是 log 判定：

**`check_logs.py`** 直接取代「捲 log 看有沒有怪東西」：

- 任何 error/critical 行失敗，除非明確 allowlist。
- 任何 warning 行失敗，除非 allowlist——所以**新的 warning 無法藏在已經接受的 warning 裡**。
- FORBID pattern 在任何 level 都失敗，針對「severity 比它被記錄的 level 還糟」的訊息。
- allowlist 條目如果從來沒 match 到，會被回報——allowlist 不會腐化。
- `--suggest-allowlist` 可以在既有 log 上 bootstrap。

allowlist 格式是三個欄位，以「 | 」（空白-直條-空白）分隔：`LEVEL | python regex | 為什麼可以接受`。不用裸直條，是為了讓 regex 本身可以包含直條。

**失敗代表：** kernel log 裡出現未允許的 warning/error。這就是「有東西在叫」的明確閘門。

**為什麼存在：** `warning_allowlist.txt` 的檔頭解釋了核心問題：沒有 allowlist 時，「檢查 log 有沒有 warning」只要有超過一小撮 warning 就退化——真正新的 warning 會淹沒在已經決定要與之共存的 warning 裡。allowlist 反轉預設：**任何沒列出來的東西都是失敗**，回歸無法躲在雜訊裡。

（行程健康度、記憶體與 thread 的具體判定工具與標準，在材料中只有 workflow 文件的章節標題與 `--traffic` 的線索；此處不做臆測。）

### 各層如何被編排：兩個驅動，加上手動的那幾件

編排現在是**兩頭**的，弄清楚哪個管哪些，比記住個別指令重要：

| 驅動 | 管什麼 | 面向 |
|---|---|---|
| `run_layers.sh` | L0–L4 | 面向 stack：哪些層在這個環境下跑得起來 |
| `local_ci.sh` | gcc / python / asan / tsan / clang / p4cov | 面向 CI：GitHub workflow 會跑的那幾件，在這台機器上 |
| （手動） | L5 `faults.sh`、`twin_audit.py`、`fuzz_sflow` | 需要人決定注入哪裡、審計哪條 flow、跑多久 |

⚠️ `run_layers.sh` **目前不包含 L5、不包含 twin 測謊器、也不包含 fuzz**；`p4_coverage_gate.sh` 則是掛在 `local_ci.sh` 而不是 `run_layers.sh`。不要假設「跑了 `full` 就等於全部跑過」。

#### `local_ci.sh`：GitHub workflow 的六件，在這裡

```bash
tools/test_workflow/local_ci.sh              # 全部
tools/test_workflow/local_ci.sh gcc asan     # 指名 job
```

**為什麼存在：** GitHub Actions 自 `b0a7bdc` 起額度用罄（八個 check 全部「Failing after 2s」），repo 目前保持 private，所以**CI 就是這台機器上實際跑過的東西**。四個 workflow job 都很好命名也很好搞錯：TSan 沒有 `setarch -R` 會在 main 之前就死、ASan 的 UBSan 那半邊沒有 `abort_on_error` 會印出報告然後 exit 0、clang 需要一個 `-Wno-error`、GCC 那個 job **刻意**同時跑執行檔與 ctest。手動跑「只要有人記得全部這些」就行得通——而 `setarch` 那一行在寫下來三天後（2026-08-13）還是被重新發現了一次。

**不 fail-fast**：一個 job 紅了後面還是照跑，因為本機跑一輪的目的是**一次知道全部壞了什麼**。任一 job 失敗 exit 1；job 名稱打錯 exit 2。

| job | 是什麼 | 關鍵旗標的理由 |
|---|---|---|
| `gcc` | build + 直接執行 + ctest | 兩種都跑；workflow 稱這是它最重要的一行 |
| `python` | 轉呼叫 `l1_unit_tests.sh` | 全 skip 的檔案在那裡是失敗，除非宣告 `NDTWIN_L1_OPT_IN` |
| `asan` | ASan/UBSan build 並執行 | `abort_on_error=1`，否則 UBSan 報告印完照樣 exit 0 |
| `tsan` | TSan build 並執行 | `setarch "$(uname -m)" -R`，見陷阱 3 |
| `clang` | **只 build，不跑測試** | 腐化守衛：clang 曾經根本編不過（GCC 接受的 incomplete type `unique_ptr`），那擋住了整個 fuzzing 計畫 |
| `p4cov` | L1.5 覆蓋閘門 | 不在 GitHub workflow 裡（runner 沒有 p4c）；`.p4` 沒改時是毫秒級 no-op，所以留著幾乎不花錢 |

`local_ci.sh` 會重建四個 build 目錄（`build`、`build-asan`、`build-tsan`、`build-clang`），跑完要數分鐘——**這不是每次改動後的閘門**，那是 `run_layers.sh quick` 的位置。

⚠️ **它鏡射 `.github/workflows/ci.yml`；那個檔案改了，這個檔案要跟著改。** 這是一個沒有工具在守的手動不變量。

#### `run_layers.sh`：面向 stack 的層級組合

`run_layers.sh` 是頂層驅動，依你在做的事選對層級組合：

| 指令 | 執行內容 | 需要什麼 |
|---|---|---|
| `quick` | L0 + L1 | 無 Mininet，約 2 分鐘 |
| `api p4` | L2 + L3 + log check | running stack |
| `api p4 --traffic` | 同上 + telemetry checks | running stack + traffic |
| `baseline ovs` | 抓 OVS reference 給 L4 | OVS stack |
| `compare` | 比對最近一次 P4 capture 與 OVS baseline | 兩份 capture |
| `full p4` | P4 run 可用的全部層級 | 完整 P4 stack |

每層印出自己的判定（verdict）；最後的 summary 是該讀的東西。**任何一層失敗，exit code 非零，所以可以 gate CI。**

為什麼需要這個編排？因為不同工作階段需要不同層級：快速驗證不需要 Mininet；API 檢查需要 running stack；L4 需要先有 baseline。單一指令讓「該跑什麼」變成決定好的事，而不是每次重新判斷。`tools/test_workflow/README.md` 是這些流程腳本的中文說明，可與本文件搭配閱讀。

## 分類軸二：閘門的機制型態（跨層級的共同模式）

如果只看層級，會忽略這個專案真正反覆出現的設計模式。這些模式跨越層級，是理解整套工具如何互相配合的關鍵。

### allowlist 型閘門：新問題不能藏在舊問題裡

`warning_allowlist.txt` 和 `baseline_diff_allowlist.txt` 共享同一套哲學：**不在清單上的東西就是失敗**。兩者的動機相同：「檢查 log 有沒有 warning」這種事，只要 warning 一多就退化；「P4 有一些差異」只要累積起來就會變成常態。allowlist 反轉預設值，讓新的 warning 和新的 P4 差異都必須被明確承認。

兩者還有三個共同的防腐化機制：

- 格式相同：三個欄位，`LEVEL/endpoint | python regex | 為什麼可以接受`，分隔符是「 | 」。
- 未使用的條目會被回報，所以 allowlist 不會因為「以前寫的條目現在沒用了」而默默累積。
- 條目有生命週期：`baseline_diff_allowlist.txt` 的條目在 `doc/2026-07-27_p4_bmv2_support_plan.md` 的 phase 完成後**應該被刪掉**——工具回報未使用條目，讓刪除變成例行公事。

這個機制型態回答的問題是：**如何讓「接受既有問題」和「抓新問題」不衝突**。沒有 allowlist，接受既有問題的方式是「容忍所有 warning」；有了 allowlist，接受既有問題的方式是「逐條寫下理由」。

### 目錄型閘門：把「加一項」壓成「加一行」

同一個「三欄、` | ` 分隔、第三欄寫理由」的形狀，現在有四個實例：`warning_allowlist.txt`、`baseline_diff_allowlist.txt`、`p4_coverage_baseline.txt`（欄位不同但精神一致）、`faults.txt`。前兩個是**允許清單**（不在清單上就失敗），後兩個是**基準／目錄**（清單本身就是規格）。

共同的設計決定值得單獨講，因為它決定了這些檔案會不會腐爛：

- **資料與程式分離。** `faults.txt` 只在 `faults.sh` 一個地方被解析；加一個故障**型**是加一行，加一個**機制**才是改程式，而且用錯的話工具會明講這個區別。同理，`p4_coverage_baseline.txt` 記的是事實，判斷邏輯在腳本裡。
- **參數化的維度不放進檔案。** 故障要落在哪條鏈路、哪個 PID，是命令列參數而不是目錄欄位——否則每多一條鏈路就要多一堆條目，檔案會爆炸然後沒人維護。
- **未使用／已失效的條目會被回報。** allowlist 回報沒 match 到的條目；覆蓋閘門在某行變成可覆蓋時提醒你更新基準。
- **「還沒涵蓋」要寫在檔案裡。** `faults.txt` 的 TODO 區塊列了三個尚未成為條目的型，並明確記下 mastership 衝突**沒有**被涵蓋以及為什麼（需要第三個機制）——「記下來是為了讓缺口保持可見，而不是讓它看起來已被涵蓋」。這比一份看起來完整的目錄誠實得多。

### 以「已知良好」當規格，而不是發明規格

- `compare_baseline.py`：OVS 路徑 known-good，用它的行為當 P4 的規格。
- `components.py`：元件依賴是實測掃出來的，不是猜的；`KERNEL_ENDPOINTS` 從真實 dispatch table 逐行抄錄。
- `spec.py`：shapes 取自 `doc/2026-01-02_ndt_api.md`，並與 `HttpSession.cpp` 交叉檢查；endpoint 以實際註冊為準，所以文件漏寫的也會被涵蓋。

這個模式回答的問題是：**規格從哪裡來**。當文件與程式碼衝突時，以實測或實際註冊為準。它取代的是「相信一份可能過期的文件」或「替 P4 發明一份可能不符合現實的規格」。

### 測試的自我驗證：確保閘門本身有意義

- `selftest_fixtures.py`：證明 schema 接受文件範例；而且 invariant 檢查在壞資料上真的會 fire，不是 vacuous pass。
- L1 的「跑兩次」：兩種執行模式互相補位，避免任何單一模式造成的假綠。
- SKIP 當失敗：被跳過的測試不算通過（Python unittest 還會把 skip 算進 "Ran N tests"，需要特別處理）。
- `NO TESTS RAN` 當失敗：摘要行讀不到就是失敗，不是「大概沒事」。
- fuzz harness 的自我驗收：把某個邊界檢查註解掉，確認它幾秒內就抓到。**接不到東西的 fuzzer 永遠綠燈**。
- `criteria.py` 的保留檢查大聲拒絕：`path_match` 丟 `NotImplementedError`，而不是安靜回傳 UNKNOWN——後者會在輸出上看起來像已經實作了。
- L5 的入場費：每一輪都要求「前 moving、後 moving、qdisc diff 為空」。這三個條件是在驗證**這一輪本身有沒有資格產生結論**，與它想測的故障無關。
- mutation testing（下一節）：最強的一種自我驗證。

這個模式回答的問題是：**怎麼知道測試本身有意義**。沒有自我驗證，綠燈只是「有跑」的證據，不是「行為正確」的證據。

### 獨立通道與法定人數：不要只有一個事實來源

這是 2026-08-13 之後才成形的一個模式，目前只有 `criteria.py` 一個實例，但它的教訓適用於整份工具集：**單一事實來源是一個可以無聲出錯的來源**。那條 flow 的每一個儀表板數字都源自同一個 sFlow ingest，所以它們一致地全部答錯。

對策有三層，缺一不可：

1. **多個會獨立壞掉的通道**——不是多個數字，是多條因果鏈。三個通道各自能被騙，但騙得動它們的東西不一樣。
2. **法定人數，且不做多數決**——任何異議都是 DISPUTED。「兩票壓過一票」會把「有一個觀察者壞了」這個真正的發現變成一個被吞掉的少數意見。
3. **證據與宣稱要分開**——被審計的對象不能當自己的證人。這一刀不做的代價已經量過：第一版會漏掉自己的 founding case。

### 執行編排：讓閘門可重複、可信任

- `components.env`：路徑、conda env、port 的單一事實來源，l0/l1/stack 腳本都 source 它；可以在環境變數覆蓋（例如 `NDT_URL=http://192.168.1.5:8000 ./l0_build_check.sh`）。`KERNEL_DIR` 從檔案自身位置推導，`WORKSPACE_ROOT` 用尋找方式發現——不同 checkout 不需要改設定。
- `stack.sh`：元件有嚴格依賴順序，太早啟動下一個會產生「看起來像 bug 的失敗」。step 3→4 尤其必須等：很多「看起來壞了」其實是「topology 還沒 converge」。腳本涵蓋 1–3 步（control plane、data plane、kernel）加 convergence，因為這幾步必須腳本化才能再現；readers、traffic、apps（steps 4–6）由每個測試場景自己啟動。提供 `up ovs`、`up p4`、`wait`、`status`、`down`、`logs` 等操作。Mininet 需要 root，`up` 會在 sudo 下重新執行 topology；其他步驟以呼叫者身份執行。
- `run_layers.sh`：把常見情況濃縮成單一指令，每層獨立 verdict、最後 summary、exit code gate CI。
- `local_ci.sh`：把「六個 job 的旗標」從記憶變成程式碼。不 fail-fast，因為本機跑一輪要的是一次看完全部。

**seam 是這個模式的共同技法。** 每個會碰到外面世界的腳本都留了替換點，所以流程邏輯本身可以在什麼都沒跑的情況下被測試：`local_ci.sh`、`faults.sh` 被 source 時只定義函式不執行；`faults.sh` 的 `run_tc` / `run_signal` / `settle` / `check_pair` / `qdisc_save` / `qdisc_diff` 全部可覆寫，二進位檔則是環境變數（`FAULTS_TC`、`FAULTS_KILL`、`FAULTS_CRITERIA`…）；`qdisc_snapshot.sh` 是 `QDISC_SNAPSHOT_TC`；`p4_coverage_gate.sh` 是 `P4TESTGEN`；`criteria.py` 把 `run_command` / `http_get_json` / `sleep` / `now` 集中成唯一四個碰外界的函式。`tests/shell/` 底下的測試就是靠這些 seam 驅動真正的流程邏輯——**純 stub、不碰環境、秒級**，所以它們可以在沒有 Mininet、沒有 bmv2 的機器上跑。

這個模式回答的問題是：**怎麼讓測試結果可信**。如果啟動順序錯了、路徑設錯了、topology 還沒 converge，任何測試結果都沒有意義。編排工具把這些變數消掉，讓「跑測試」變成一個決定好的、可重複的程序。

## 以 mutation testing 驗收測試本身

這個專案把 mutation testing 當成測試的驗收閘門，規則是：**一個測試沒有「親眼看它失敗過」就不算交付**。

做法是：對生產程式碼做一個具名的修改（mutation），重新編譯、執行，確認**指名的那個測試**真的失敗，然後還原。每個測試都要附上「把哪一行改成什麼，這個測試就會失敗」的紀錄，包含實際觀察到的失敗輸出。如果找不到任何 mutation 能讓某個測試失敗，那個測試就要被刪掉——因為它證明不了任何事。

實測成效：這個做法在這個 repo 上已經抓出 11 個「會通過但證明不了任何事」的測試。證據文件在 `doc/audit/mutation-evidence-*.md`（要當下的份數：`ls doc/audit/mutation-evidence-*.md | wc -l`）。

三個已知的陷阱：

1. 確認 mutation 有落在檔案裡還不夠，它必須落在**測試真正會走到的那條路上**。
2. 一個 mutation 如果一次弄壞 30 個測試，對其中任何單一個測試都是很弱的證據——要盡量找窄的 mutation。
3. ⚠️ **對 Python 跑 mutation 一定要設 `PYTHONDONTWRITEBYTECODE=1`。** CPython 用 `(mtime, size)` 驗證 `__pycache__`，而一個**等長**的 mutant（把 `>` 改成 `<`、把 `+` 改成 `-`）如果 mtime 的粒度沒跨過去，就會直接沿用舊的 `.pyc`——**mutant 根本沒有被執行**，測試照樣全綠。那個結果跟「測試太弱抓不到」在畫面上一模一樣，而結論完全相反。

   ```bash
   PYTHONDONTWRITEBYTECODE=1 python3 tests/python/test_whatever.py -v
   ```

   這條目前**只記在這裡**，沒有工具在守它——mutation 是手動流程，所以它是一個要靠人記得的不變量。

為什麼存在：前面所有閘門都在檢查產品；mutation testing 是**檢查閘門本身的閘門**。它把「測試有效」從信念變成可驗證的事實，也直接呼應整個專案的主題：不能通過「親眼看到它失敗」這個考驗的測試，就是另一種「看起來還好」。

## 測試資產：形式與誰在跑它

⚠️ **這張表刻意不寫數量**（`7eddd68` 的決定）。要數量，用 L1 節的那組指令。這裡回答的是**形式**與**誰會跑到它**——後者比數量重要，因為「這個目錄下的測試到底有沒有在 CI 裡跑」是實際會出錯的地方。

| 資產 | 形式 | 直譯器／編譯器 | 誰會跑它 |
|---|---|---|---|
| `tests/test_*.cpp` | gtest，編成 `test_routing_strategy` | GCC（`gcc` job）、clang（只 build）、ASan、TSan | ctest **與**直接執行，兩者都要 |
| `p4_proxy/tests/test_*.py` | unittest（**不是** pytest） | `p4_proxy/venv/bin/python`，可用第三方套件 | `l1_unit_tests.sh` |
| `tests/python/test_*.py` | unittest | **系統 `python3`，只准標準庫** | `l1_unit_tests.sh`。⚠️ **沒有**被 ctest 註冊 |
| `tests/shell/test_*.sh` | 純 stub，透過 seam 驅動流程腳本，不碰環境、秒級 | bash | `l1_unit_tests.sh`。⚠️ **沒有**被 ctest 註冊；摘要必須是 `Ran N checks, ...` |
| `tests/fuzz/fuzz_sflow.cpp` | libFuzzer harness | **clang only**，`-DFUZZING=ON`，預設 OFF | 手動；不在任何驅動裡 |
| `tests/fixtures/*.bin` | 真實 OVS + Ryu + Mininet 抓取的 sFlow 封包 | — | L1 的 golden fixtures **兼** fuzz 的 seed corpus |
| `tests/manual/` | **claim-checker**，不是測試：驗證別處註解所依賴的平台事實 | 手動編譯，刻意不進 CMake build | 手動。存在理由是「那個註解裡唯一承重的宣稱，讀者本來無法重現」 |
| `tools/test_workflow/faults.txt` | L5 故障目錄（資料） | — | `faults.sh` |
| `tools/test_workflow/p4_coverage_baseline.txt` | P4 覆蓋基準（資料） | — | `p4_coverage_gate.sh` |
| `doc/audit/mutation-evidence-*.md` | mutation 驗收證據 | — | 人 |

**「沒有被 ctest 註冊」為什麼要標出來：** `tests/CMakeLists.txt` 只註冊 gtest；`tests/python/` 與 `tests/shell/` 只由 `l1_unit_tests.sh` 驅動。所以「跑了 ctest 全綠」**不包含**這兩個目錄——它們是靠 `run_layers.sh quick` 或 `local_ci.sh python` 才會跑到。

## 陷阱速查

每一條都是實測代價換來的，而且每一條都有「看起來像成功／看起來像別的問題」的偽裝。上面各節都有完整脈絡，這裡是可以掃過去的版本。

| # | 陷阱 | 症狀偽裝成什麼 |
|---|---|---|
| 1 | `p4_proxy/tests/` 用 `p4_proxy/venv/bin/python`（可用第三方套件）；`tests/python/` 用**系統 python3、只准標準庫** | 2026-08-13：`tests/python/` 底下有測試 import networkx，import 期就死，runner 讀到 `ran=0` 判 FAIL——看起來像測試寫錯，其實是放錯目錄 |
| 2 | shell 測試摘要必須是 `Ran N checks, ...`，錨在 `^Ran`（行首不能有空白） | 判成 `NO TESTS RAN`，計入失敗——看起來像沒收集到測試 |
| 3 | TSan 一定要 `setarch "$(uname -m)" -R` | main 之前就 `FATAL: ThreadSanitizer: unexpected memory mapping`——看起來像 TSan 壞了 |
| 4 | gtest 要「直接執行」與「ctest」兩種都跑 | ctest 每 case 獨立 process，`SetUpTestSuite` 的失敗被吃掉，讀成「100% tests passed」而其實什麼都沒跑 |
| 5 | mutation 跑 Python 要 `PYTHONDONTWRITEBYTECODE=1` | 等長 mutant 因 pycache 的 `(mtime,size)` 驗證而**根本沒執行**，測試全綠——與「測試太弱」畫面完全相同，結論相反 |
| 6 | 斷鏈路只能 `tc netem`，不能 `ifconfig down`；而且 sudoers 只授權會毀掉 htb 的 `root netem` 形式 | `ifconfig down` 在 bmv2 上是**整台停止轉送**不是斷一條鏈路；安全的 `parent H:D` 形式沒有授權，要透過 `mnexec` 以 uid 0 執行。**revert 的 `qdisc del dev X root` 後面不能多接 `netem`**——sudo 逐字比對參數列，多一個 token 就 fail，故障留在原地 |
| 7 | `PATHS_URL` 預設指向 Ryu :8080 | P4 模式要改指 proxy :8081，否則 `paths` 通道讀到錯的東西（它不投票，但報告會失去最有價值的那一行） |
| 8 | 證據 vs 宣稱：只有獨立實測的通道（ping、counters）投票；讀控制平面宣稱的 `paths` 只報告不投票 | 讓 `paths` 投票會讓 twin 當自己的證人；實測代價是第一版會漏掉自己的 founding case |

## 什麼還沒有被涵蓋

⚠️ **這一節會過期，而且過期的方式是「看起來已經涵蓋了」。** 讀的時候先確認 head 是不是還在寫這份文件的那一版。

**尚未存在的層級：**

1. **L6 soak（長時執行 + drift 偵測）——完全不存在。** 只在長時間執行才會現形的缺陷目前沒有任何一層在守：記憶體成長、counter 溢位、twin 與現實的緩慢漂移。門檻要能定得住，需要以 sFlow 的誤差地板 196·√(1/c) 為理論下限；在那之前 soak 只能報告不能判定。
2. **L5 的機制只有兩個。** `link_loss` 與 `proc_signal`。mastership 衝突（三個「修好但沒有測試類別」之一）需要第二個 P4Runtime client，也就是第三個機制，目前**沒有**。這一點記在 `faults.txt` 裡。

**工具自身的原理限制（不是待辦事項）：**

3. **P4Testgen 原理上碰不到取樣路徑。** 85.2%，未覆蓋的 8 行是 egress clone 分支；原因是**分支條件讀 `instance_type`**（只有 clone 真的發生才會被設），不是「有 clone」——已用 p4lang/tutorials 對照證實（`basic.p4` 無 clone 100%、`flowcache/solution` 有 clone 但條件讀 `egress_port` 也 100%）。那 8 行只能靠 live 驗證與 `test_SFlowEmitterRoundtrip.cpp` 的跨語言 round-trip。
4. **twin 測謊器不對帳速率。** 刻意的：1/256 取樣下誤差地板 196·√(1/c)，錯的速率與誠實取樣的速率不可分離。路徑對帳的位置已在 `RESERVED_CHECKS` 佔好並大聲拒絕。
5. **L4 不比數值**：`compare_baseline.py` 只比較 shape 和 facts，不比 rates/counters/timestamps 的數值——因為這些數值每秒都在變。
6. **L3 掃的是原始碼不是執行期**：`l3_component_check.py` 掃「原始碼裡出現過哪些 endpoint」，那是「執行時真的會打哪些 endpoint」的超集（死碼會被算進去，見 L3 節的實例）。contract 檢查另外只對 `spec.py` 有涵蓋的 endpoint 有效。
7. **fuzz 只問記憶體安全**：不對解析結果做任何斷言，「安全但解錯」是 `test_SFlowParsing.cpp` 的職責。

**已知不穩定，未修：**

8. **L-3 gray failure 的判定會隨機跳。** 30% 雙向丟包下，`ping -c 3` 有不可忽略的機率（brief 記錄約 13%，本文件未自行複測）在某一方向三個 echo 全掉，被讀成「非對稱、一個方向死了」→ STILL，於是同一輪的 pass/fail 隨機。這是取樣數問題；旋鈕 `TWIN_AUDIT_PING_COUNT` 已存在，目前沒有任何地方設定它。
9. **`N-4` 是 THEORY ONLY。** 從未對真的 bmv2 驗證過——這正是它被放進目錄的理由。

**沒有工具在守的手動不變量：**

10. **`local_ci.sh` 鏡射 `.github/workflows/ci.yml`**，兩者的同步靠人。
11. **`p4_coverage_baseline.txt` 的 sha 是工作樹的 hash，不是 HEAD 的**——在髒的工作樹上 `--update-baseline` 會記下一個未提交的狀態。
12. **`PYTHONDONTWRITEBYTECODE=1`**（陷阱 5）只記在文件裡，mutation 是手動流程。

**環境依賴造成的覆蓋缺口：**

13. L0 在 toolchain 缺席時回報 SKIP；`p4_coverage_gate.sh` 在 p4testgen 缺席時 skip；p4_proxy 的 Python 測試在 interpreter 缺 P4Runtime protobufs 時回報 PROVED LESS。三者都不算失敗，但在那些機器上對應的東西**沒有被驗證**。這是這個專案一貫的設計：覆蓋降低必須可見，不能默默發生。
14. **log 檢查目前只有 kernel 的**：`check_logs.py` 檢查的是 NDTwin kernel log；沒有其他元件 log 的同等工具。
15. **`stack.sh` 只保證 1–3 步**：readers、traffic、apps（steps 4–6）由每個測試場景各自啟動，那幾層的啟動再現性不在 `stack.sh` 的保證範圍內。

**本文件材料不足以判斷的：**

16. 判定標準中的行程健康度、記憶體與 thread 測量，只有章節標題與 `--traffic` 會加入 telemetry checks 的線索；具體工具與標準需另外查閱 `doc/2026-07-27_testing_workflow.md`。
17. `tools/test_workflow/README.md` 目前**沒有**提到本文件新增的七件工具（實測 grep 0 次命中），兩份文件的分工需要另外裁決。
