# opus-judge report on fix/p4proxy-requirements-0925 @ 55cebe6c and candidate 7cc50b42

# 審查報告：p4_proxy requirements 對齊 `55cebe6c` 與 protobuf 5.29.6 候選 `7cc50b42`

## 裁決

- **`55cebe6c`（對齊）：MERGE AFTER FIXES**
  - 10 行 pin 我逐項對主 venv 的 dist-info 親查：9 行完全相符，googleapis-common-protos 一行刻意不同，理由成立。兩套測試的證據紮實。
  - 但 header 的核心宣稱「每個直接依賴都 pin 到主 venv 的版本」被 starlette 推翻（#1），同檔還有一句舊註解和新 header 互相矛盾（#2）。
  - 兩項都不需要 live。#1 若改成 pin，要照檔案自己的規矩重建 fresh venv，重跑兩套測試加逐條比對。
  - 功能面：兩個 starlette 版本下測試都全綠，所以就算先併也不會壞東西。錯的是這個 commit 本來要修的那件事，也就是「檔案描述了實跑環境」。
- **`7cc50b42`（候選）：可以進 live 試跑，不可併**
  - 離線證據夠強：
    - committed 工具在全新的 3.12 venv 上從零跑過，4 個 descriptor 逐位元組相同。
    - 3 次重生的 8 個產物雜湊一致。
    - 1744 個 test id 的判決相同。
  - 擋住併入的有四件事：
    - 候選字樣會原封進 trunk（#6）。
    - 既有 venv 的遷移和回滾沒有步驟（#7）。
    - gRPC stub 和實際連線那條路徑，離線測試完全沒碰到（#8）。
    - CI 還沒在 GitHub 上跑過。

## 發現

### 55cebe6c

**1.【中】starlette 是直接依賴，卻沒有 pin（推翻 header 宣稱）**
- 位置：`p4_proxy/requirements.txt:9` 寫 "Every direct dependency is pinned…"；`:14-16` 把 starlette 列為 transitive。
- 證據：
  - `p4_proxy/proxy_agent/api_routes.py:3` 是 `from starlette.concurrency import run_in_threadpool`。
  - `tests/test_multicast_group.py:41`、`tests/test_table_entry_route.py:47` 都 import `starlette.requests`。
  - 主 venv 是 `starlette-1.3.1.dist-info`；fresh venv 解出 1.7.0（`venv_create_aligned.p4req-62f76cf5-wt.log:28`）。
  - `check_pins` 抓不到這個問題，因為它只檢查檔案裡已經有的行。
- 修法：加 `starlette==1.3.1`，註明是直接 import。fastapi 0.139.2 只要求 `>=0.46.0`，主 venv 就是這個組合。然後重建 fresh venv，重跑兩套、verdict diff、check_pins。次選是改 header 措辭，把 starlette 排除在「每個直接依賴」之外。

**2.【低】同一個檔案前後矛盾**
- `:29-30` 還寫著 "/home/adam/p4dev-python-venv, the interpreter they pass under"。
- 實際上 `l1_unit_tests.sh:311` 先試 `"$P4_PROXY_PY"`，而 `components.env:45` 把它預設成 `p4_proxy/venv`。
- 修法：改寫這一句。

**3.【低】推論被寫成事實進了 commit**
- requirements 的 `:18-20` 和 ci.yml 新註解都寫著 "what the user manual's P4 path gives its users"。SUMMARY §3 自己把這點標成 INFERRED，並沒有去讀手冊。
- ci.yml 註解的另一半 "the development machine's 3.13 is what the local gates run"，我照 l1 腳本加 components.env 核過，成立。
- 留在 3.12 的決定本身合理。

**4.【低，證據】幾個寫成 OBSERVED 的宣稱沒有存檔**
- 主 venv 前後指紋 `f30dfcae…`：整個 logs 目錄 grep 不到。
- 主 venv 的 `pip check` 原文：沒存。
- build 複製的雜湊：`d54ff552` 哪裡都 grep 不到；`0b19d789` 只出現在別輪的 log。
- 「1.73.0 是 pip 自己解出來的」：aligned venv 建立時草稿已經寫死 1.73.0，看不到解析過程。
- 「p4runtime 1.5.0 是 PyPI 最新」：`pip index versions` 的輸出沒存。
- 各個「diff 0 行」：只存了 TSV，比對結果只印到終端機。唯一存檔的 `compare_main_vs_pb5_upb.v2…log` 還是剪過的：宣稱 98 行 diff，只留 2 行，而腳本本身會印到 60 行。

**5.【資訊】新的 pin 比對檢查**
- 有鑑別力。舊檔 RED 共 6 行：1 行是真的不符（p4runtime 1.4.1≠1.5.0），另外 5 行是 floor，依它的定義算紅。新檔 GREEN：9 行相符、1 行宣告的不符。
- 它只放在 gitignored 的 `scratch/.../scripts-p4req/`（`.gitignore:46`），不在 commit 裡，CI 和別台機器都不會碰到，也就不會被它弄壞。輸入是 freeze 檔路徑，沒有寫死主 venv。
- 代價是它沒有持續防護，檔案還是可能再漂掉。
- 它的 GREEN 有一部分是構造出來的：pin 就是從同一份 freeze 抄的，所以它證明的是「抄對了」；「測過」要靠 fresh venv 的測試結果。
- 它不檢查 Python 版本宣稱，也不檢查「有 import 卻沒列」。若要升成閘門：`$P4_PROXY_PY` 不存在時要 SKIP，並加上 import 覆蓋檢查。
- googleapis-common-protos 1.73.0：**合理**。
  - 我讀了 `googleapis_common_protos-1.75.0.dist-info/METADATA`，裡面是 `Requires-Dist: protobuf<8.0.0,>=4.25.8`。所以主 venv 依 metadata 確實不一致，`pip check` 會報。
  - 它實際上能跑，是因為 1.75.0 的 `google/rpc/status_pb2.py` 是 `# Protobuf Python Version: 4.25.3` 的 `_builder` 寫法，3.20.x 就有這個 API。
  - pip 不會從檔案裝出一組宣告衝突的套件，所以檔案不可能完全等於主 venv。pin 1.73.0 再用 fresh venv 跑出同一組判決，是正確做法。

### 7cc50b42

**6.【高，擋併】候選字樣會進 trunk**
- requirements 開頭寫 "CANDIDATE … NOT merged … NOT yet run live"，ci.yml 寫 "(CANDIDATE branch cand/p4proxy-protobuf5-0925)"。
- 修法：併之前改寫成事後的敘述，附上 live 結果和日期。

**7.【高，維運】既有 venv 的遷移和回滾沒有步驟**
- 往前：對既有 venv 只跑 `pip install -r`，protobuf 會升到 5.29.6，但 p4runtime 已經是 1.5.0、不會重裝，舊 gencode 就留在原地，下次起 proxy 會在 import 時 TypeError。stack.sh/ndt 的「create it:」提示只在直譯器不存在時才印，救不到這種情況。
- 往回：重生後的模組是 `# Protobuf Python Version: 5.29.0`，並且 `from google.protobuf import runtime_version`（venv-cand 的 `p4/v1/p4runtime_pb2.py:5,9,12`）；3.20.3 沒有這個模組。就地降回 3.20.3 會讓 import 失敗，而工具的「3.x 什麼都不做」分支不會把舊碼裝回來。
- 另外，一併下去，主 venv（live 在用）又會和檔案不符，直到遷移完成為止。
- 修法：先寫好遷移步驟。建議新建一個 venv 再切換，不要就地升級，並選在沒有 live 的時段做。回滾步驟是 `pip install --force-reinstall --no-deps p4runtime==1.5.0`，或整個重建 venv。

**8.【中】離線測試沒碰到實際的 gRPC 路徑**
- identity 檢查只比對 4 個 `_pb2` 的 FileDescriptorProto。
- 4 個 `_pb2_grpc.py` 是 grpcio-tools 1.71.2 產生的（帶 `GRPC_GENERATED_VERSION = '1.71.2'` 和 `_registered_method=True`），只驗了「能 import」。
- 唯一會打真 gRPC 的 `tests.test_p4_client.LiveSwitchTest…`，在 6 個 p4_proxy TSV 裡全部是 skip（都在第 710 行）。
- 所以「1744 個測試逐條相同」證明的是 mock／fake 層面等價，不是實際傳輸等價。

**9.【中】live 試跑不是單一變數**
- venv-cand 和主 venv 的差別除了 protobuf 和 backend（python→upb），還多了 grpcio-tools 和 setuptools，另有 12 個 transitive 套件版本不同，例如 starlette 1.3.1→1.7.0。
- live 通過代表整組可用；live 失敗就無法直接歸因到 protobuf。

**10.【中低】供應鏈與維護**
- runtime venv 多了 grpcio-tools（含原生 protoc）和沒 pin 的 setuptools，這兩個只有安裝時才需要。
- grpcio-tools 1.71.2 限制 protobuf<6，以後要升到 6.x 就得連它一起動。
- 沒有 hash pin。
- 改寫 site-packages 後，這 8 個檔和 wheel 的 RECORD 對不上，完整性掃描會把它們當成被竄改。
- `copyfile` 逐檔覆寫，不是原子操作。
- 寫完後的驗收若失敗只會 `return 1`，已經替換的檔案不會還原。
- 可以考慮的替代方案：把重生碼 vendor 進 repo。好處是可以 review，也不需要第三道安裝指令。

**11.【低】prefix 防線沒有要求一定是 venv**
- 系統 python（`sys.prefix=/usr`）遇到裝在 `/usr/local/...` 的 p4 會放行。
- 這是為了讓 CI 的 setup-python（不是 venv）能跑而刻意放寬的，文件寫明即可。

**12.【低】工具有幾條路徑從沒執行過**
- 沒跑過的：3.x 什麼都不做、缺 grpcio-tools 回 rc=2、不在 prefix 內就拒絕、寫到一半中斷。
- mutant 只截掉比對端的最後一個 byte。它證明的是「比對失敗就什麼都不寫」，沒有證明真實的 schema 漂移會被抓到。

**13.【低】安裝點沒有全部更新**
- `doc/audit/2026-08-28_manual-verification-coverage/vm/guest_section6_p2.sh:81` 和 `doc/audit/2026-09-02_manual-usertest/run-04-sonnet/tester-files/tester-scripts/s6_2to6_setup.sh:26` 也照這個檔安裝，沒有接上重生步驟。
- SUMMARY §3 拿來支持 3.12 決定的，正是這批 VM／tester 腳本。

**14.【正面】route C 本身站得住**
- 用 wheel 內嵌的 `serialized_pb` 當 schema 來源，不必下載 .proto。
- `_VERIFY` 檢查 import 的實際路徑；舊模組在 upb 上本來就 import 不了，所以不可能「拿舊模組比對過關」。
- 逐位元組相同確實有呈現：
  - `venv_create_cand312.p4req-7cc50b42.log:9-12, 23-26`：committed 工具在全新 venv 上從零跑。
  - 3.13 上有 red/green 和 committed rerun 兩份 log。
  - 實驗路線另有 `bytes_equal=True proto_equal=True`。

### 公開 repo（D）

**15.** 兩個 diff 都沒有秘密、token、IP，新增行裡也沒有 `/home/adam` 路徑；同檔既有的 `/home/adam/...` 是 context，本來就在。

**16.** 候選字樣（#6）不能進公開的預設分支。p4／lab 都是公開遠端，要拿到 CI 結果就得推候選分支，推了等於公開一套還沒過 live 的安裝流程。有 CANDIDATE 標示可以接受，但要是刻意的決定。

**17.** `55cebe6c` 可以推。唯一的判斷題：requirements.txt 現在把公開讀者指向 `doc/audit/2026-09-25_p4proxy-requirements/`，那張票寫著「兩個 high 的 dependabot 警告先不關」。票在 62f76cf5 就已經進 trunk，所以不是新揭露，只是更容易找到。

## SUMMARY 各判定的分類

| 判定 | 分類 | 缺什麼／依據 |
|---|---|---|
| §0-1 每個直接依賴都用 `==` 釘在主 venv 的版本 | **CONTRADICTED** | #1 |
| §0-1／§2.3 fresh venv 與主 venv 同 commit 逐條相同（1557 OK skip=1；187 OK） | SUPPORTED | 計數、rc、首行親查；TSV 1557 id／1556 ok／唯一 skip 同 id 同行；diff 我沒重跑 |
| §0-1 3.12.3 也跑過、數字一樣 | SUPPORTED（僅計數） | 沒做逐條比對 |
| §0-2／§3 CI 維持 3.12 | SUPPORTED（決策）；「就是使用者的直譯器」UNDER-EVIDENCED | #3 |
| §0-3／§4.2 只換 requirements 沒過 | SUPPORTED | traceback 鏈逐行吻合；49 個全在 test_preflight（44 FAIL＋5 ERROR） |
| §4.2 p4runtime 1.5.0 是 PyPI 最新 | UNDER-EVIDENCED | `pip index versions` 輸出沒存 |
| §4.2 grpcio 不依賴 protobuf | SUPPORTED | grpcio METADATA 只在 extra 才拉 grpcio-tools |
| §0-4 路線 B、C 離線逐條相同 | SUPPORTED | pb5_pyimpl／pb5_regen 的 TSV |
| §0-5／§5.1 切換 venv 只要 `export P4_PROXY_PY` | **UNTESTED** | §5.2 自己承認；§0-5 沒附這個但書 |
| §5.1 unset 後 proxy 自動重啟、§5.3 venv 可以整包搬 | **UNTESTED** | 讀碼推論 |
| §0-6 主 venv 全程只讀、指紋相同 | UNDER-EVIDENCED | 沒有 log |
| §1 主 venv 事實（版本、套件、backend） | SUPPORTED | pyvenv.cfg、dist-info、log 標頭 |
| §1 主 venv pip check 不一致 | SUPPORTED | METADATA 親查；pip check 原文沒存 |
| §1 主 venv 安裝史（依 dist-info mtime） | UNDER-EVIDENCED | 沒有 log |
| §1 build 複製雜湊與主 checkout 相同 | UNDER-EVIDENCED | #4 |
| §1 首跑紅燈的歸因 | SUPPORTED | 82＋2，缺 build 的訊息出現 95 次 |
| §2.1 diff +43／−8；§4.3 +234／−26、工具 188 行 | SUPPORTED | 我逐行數過 |
| §2.1 1.73.0 是 pip 解出的最新版 | UNDER-EVIDENCED | 版本衝突本身 SUPPORTED |
| §2.2 建立指令、pip check 乾淨、dry-run 零安裝 | SUPPORTED | 「pip 26.0.1」沒有 log |
| §2.4 check_pins 紅轉綠 | SUPPORTED | 有效範圍見 #5 |
| §4.3 red/green | SUPPORTED（依 log） | 驅動腳本和指紋算法沒存；step 0 只留 TypeError 最後一行 |
| §4.3 descriptor 逐位元組相同 | SUPPORTED | 限 4 個 `_pb2`，不含 `_pb2_grpc` |
| §4.3 8 個產物雜湊一致（決定性） | SUPPORTED | 同一台機器，3.12 與 3.13 |
| §4.1／§4.3 venv-cand「照檔頭三道指令新建」 | 大致 SUPPORTED | 見下方說明 |
| §4.3 gate anchors 116/116、wedge guard 10 checks、「唯一 grep 提示字串的測試」 | SUPPORTED | 我 grep tests/ 也找不到其他斷言 |
| §4.4、§4.5-2 | 推論（報告已標） | — |
| §4.5-4 force-reinstall 會把舊碼裝回 | 推論 | 沒執行 |
| §4.5-6 本機 3.12 照候選流程全綠 | SUPPORTED | 但不是 CI 的流程：CI 會先升 pip、用非 venv 直譯器、跑 l1 腳本 |

venv-cand 那一列的細節：第三道指令是在 red/green 驅動裡，用未提交版工具（`d7efa3f4`）跑的，中間還夾了一次 mutant。committed 工具在 venv-cand 上只跑過 already current；從零重生只在 cand312 跑過。不過產物雜湊和 committed 工具的輸出相同，所以 venv-cand 可以放心拿去 live。

## 併入 7cc50b42 前，live 必須驗的項目

1. **起跑前**：worktree 和 `scratch/venv-cand` 還在；shell 裡沒有 `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION`。§5.3 建議順便比較路線 B，這個變數一旦殘留，upb 試跑會靜默變成 python backend。
2. **確認切換真的生效**：§5.1 的 `p4_proxy.cmd` 和 `ps` 只證明直譯器路徑。
   - 要再唯讀查 `/proc/<proxy pid>/maps`，確認 map 到 `…/venv-cand/…/google/_upb/_message*.so`。
   - 並確認 `/proc/<pid>/environ` 裡沒有上面那個變數。
3. **live 01、06 各跑一次**，逐列對照最近一次主 venv 的 baseline。proxy log 要看到：
   - pipeline push、clone session、初始路由寫入；
   - LLDP（走 StreamChannel）、counter 讀取；
   - 錯誤路徑的訊息，例如 "INSERT said ALREADY_EXISTS"（走 `google.rpc.Status`＋`Any` 解包）。
   - 不能出現 TypeError、RuntimeError 或版本檢查錯誤。
4. **若 claim 允許**：在 venv-cand 下開 `NDTWIN_LIVE_SWITCH_OPT_IN=1` 跑 LiveSwitchTest。這是唯一會用重生後的 stub 打真 bmv2 的測試。
5. **資源對比**：proxy 的 CPU／RSS 和規則安裝時間，對 baseline 比。
6. **收尾**：`unset P4_PROXY_PY`，確認 proxy 重啟回主 venv。
7. **結論範圍**：06 的 convert／preflight 仍然跑在主 venv 上（`drive_exercise.py:93`）。5.29.6 下的 preflight 只有經 ndt 的 app_preflight 才覆蓋到，結論要照這個範圍寫。
8. **live 以外還要做**：
   - 改寫候選字樣（#6）；
   - rebase 到修好後的 55cebe6c；
   - 推分支，讓 CI 在 GitHub 綠一次；
   - 寫好遷移和回滾步驟（#7）；
   - 更新 repo 外的使用手冊。

## 報告沒跑、我會跑的測試

1. 對三組 TSV 跑 `diff` 並存檔；empty-HOME 和 py312／cand312 也做逐條比對。
2. 對 `scripts-p4req/SHA256SUMS` 跑 `sha256sum -c`；補存 red/green 驅動、schema identity 腳本和指紋腳本。
3. import 覆蓋檢查：proxy、tests、p4_exercise 的第三方 import 對照 requirements（會抓到 starlette）。
4. 用 `P4_PROXY_PY=venv-py312` 和 `venv-cand312` 跑 `l1_unit_tests.sh` 本身。CI 跑的是這支腳本，不是直接的 unittest 指令。
5. 工具的負面路徑、真實擾動 FileDescriptorSet 的 mutant，以及回滾路徑。
6. 跨 backend 的傳輸內容比對：把代表性的 WriteRequest 用 `SerializeToString(deterministic=True)` 在兩個 venv 各序列化一次，比 bytes。
7. 存下 `pip index versions`，以及拿掉 googleapis pin 之後的 `--dry-run`。

## 報告內部不一致

1. requirements.txt 內部：header 說 p4_proxy/venv 是測試環境、每個直接依賴都 pin 了；`:29-30` 說 p4dev-python-venv 才是測試直譯器；`:14-16` 又把直接依賴 starlette 列為 transitive。
2. SUMMARY 說「所有 log 第一行都是完整 sha 加直譯器」。suite log 全部符合，但以下幾份不是：
   - `regen_tool_red_green…-wt.log`：只有短 sha。
   - `venv_create_cand…-wt.log`：沒有直譯器。
   - 另外，所有 3.13 venv 的 realpath 都是同一支 miniconda binary，真正能分辨 venv 的是括號裡的 venv 路徑加上 freeze。
3. §3 拿 VM／tester 腳本當 3.12 的依據，§4.3 卻只數「三處」安裝點（#13）。
4. `scripts-p4req/regen_p4runtime_pb2.py`（`49301e8b`）是實驗版，不是 committed 版（`66fb47b0`），也不是建 venv-cand 用的未提交版（`d7efa3f4`）。同名很容易被誤認成候選工具的存檔。
5. `run_suites.sh` v2 的註解提到「複製出來的 venv」，SUMMARY 通篇沒有交代是哪一個。報告裡的 venv 都有新建的 log，所以應不受影響。
6. v2 比對 log 是剪過的，不是 raw。
7. 數字對帳全部對得上：+43／−8、+234／−26、1557＋187＝1744、4＋80＝82＋2、44＋5＝49、98＝2×49、venv 大小加總約 530M。

## 我親自驗過的 vs 推論

**親自讀檔驗過：**
- 主 venv：dist-info、pyvenv.cfg，以及 METADATA（googleapis、p4runtime、grpcio）。
- 1.75.0 的 gencode 形狀、p4runtime 的 `create_key` 寫法。
- 全部 suite log 的首行、計數、rc、backend。
- TSV：計數和 skip 行。
- route A 的 traceback 鏈。
- check_pins 腳本和兩份 log。
- 各 venv 的建立 log。
- 三次重生的產物雜湊。
- 重生碼的 `runtime_version` import 與 grpc stub 的版本檢查。
- live 切換路徑的讀碼：l1、components.env、stack.sh `:532/:1087`、ndt `:1913/:3284-3286`、drive_exercise `:93/:461-463`、06 拒絕以 root 執行。
- starlette 的直接 import。
- `.gitignore:46`、diff 行數。

**推論，沒驗：**
- upb 的 `serialized_pb` 是從已載入的定義重新序列化。若屬實，identity 比對驗的是實際載入的內容，比對字面常數更強。
- live 行為、切換實際生效、GitHub CI。
- CVE 與 dependabot 相關事實。
- 「最新版」兩則。
- 主 venv 沒被動過。
- TSV 的 diff 為 0：計數與 skip 一致，但我沒執行 diff。

## 相關檔案

- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925/p4_proxy/requirements.txt`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925/p4_proxy/proxy_agent/api_routes.py`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925/tools/test_workflow/l1_unit_tests.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925/reqcand-55cebe6c..7cc50b42.diff`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/venv_create_cand312.p4req-7cc50b42.log`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/regen_tool_red_green.p4req-55cebe6c-wt.log`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/compare_main_vs_pb5_upb.v2.p4req-55cebe6c.log`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925/scratch/venv-cand/lib/python3.13/site-packages/p4/v1/p4runtime_pb2.py`
- `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/lib/python3.13/site-packages/googleapis_common_protos-1.75.0.dist-info/METADATA`