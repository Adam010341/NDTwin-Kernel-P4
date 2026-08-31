---
name: python-tests-need-the-venv-interpreter
description: "Run p4_proxy tests with p4_proxy/venv/bin/python3 -- the conda python3 on PATH lacks grpc/networkx, so unittest prints OK (skipped=18) and a broken suite looks green. This hid an 11-test regression for two commits"
metadata: 
  node_type: memory
  type: project
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-28T12:09:05.292Z
---

Always run the `p4_proxy` Python tests as:

```
cd /home/adam/Desktop/NDTwin-Kernel/p4_proxy
PYTHONPATH=. venv/bin/python3 -m unittest tests.test_<name>
```

The `python3` first on PATH is `/home/adam/miniconda3` and has neither `grpc` nor `networkx`. With
it, `test_clone_session` prints **`OK (skipped=18)`** and `test_lldp_beacon` fails at import. The
venv has both but **no pytest**, so `-m pytest` fails there while `-m unittest` works — the two
interpreters fail in opposite directions, which is why trying the other one "to see" is misleading.

Also: `python3 -m unittest tests/test_x` (slash) reports `FAILED (errors=1)` for every file. It
needs `tests.test_x`. That looks exactly like ten broken suites.

**Why it matters, not just how:** `fee2110` gave every unary gRPC call a deadline and broke all
eleven grpc-dependent tests in `test_clone_session.py`, whose own `RecordingStub` took
`Write(self, request)` with no `timeout`. I ran the suite after that commit, read a green line, and
shipped it. Two commits later the venv interpreter showed `FAILED (errors=11)`.

Two lessons, and the second is the transferable one:

- A test double narrower than the interface it stands in for turns a **correct** production change
  into a test failure. I had already fixed this exact stub in `test_p4_client_writes.py` in the same
  commit and never grepped for a second one. See [[existence-is-not-wiring]] — same reflex, inverted:
  grep for *other* instances of a thing you just fixed.
- **A skipped test reports as a passing test.** This is [[replace-vs-add-bug-shape]]'s sibling,
  shape 2 on the review checklist: empty conflated with success. When a run says `OK`, check the
  skip count, and check *why* things skipped before believing the OK.

Related: [[mutation-gate-for-tests]], [[sanitizer-and-ci-setup-gotchas]].

**第二個坑(2026-08-17,同一族:「跑對直譯器」不等於「跑對範圍」)**:這個 repo 的 Python
測試分在**兩個目錄、兩個直譯器**——`p4_proxy/tests/`(venv)與 `tests/python/`(系統
python3、只准標準庫)。我改完 `tools/contract_test/spec.py` 之後只跑了前者,綠燈,就
commit 了;`tests/python/test_contract_spec.py` 裡有一組**檢查 spec 檔本身**的後設測試,
被 local CI 抓紅兩條。
**How to apply**:動 `tools/contract_test/` 底下任何東西,兩個目錄都要跑,或直接
`bash tools/test_workflow/l1_unit_tests.sh`(它兩個都跑,且會印每檔的 `Ran N`)。
教訓的普遍形式:**先問「這個改動的測試住在哪幾個地方」,不要問「我跑的那個綠了嗎」。**

## 🔴 08-27 更正：**venv 的直譯器就是 conda 的直譯器**——不要刪 miniconda3

上面那句「conda 的 python3 缺 grpc/networkx」講的是**套件**，很容易被讀成「venv 用的是另一顆
python，跟 conda 無關」。**不是。**

```
p4_proxy/venv/bin/python3 -> /home/adam/miniconda3/bin/python3   （symlink）
which python3              → /home/adam/miniconda3/bin/python3
~/.bashrc                   conda init ×6
~/miniconda3/envs/          ntg-env  ryu-env  te-env
```

差別**只在 `site-packages`**：venv 有自己的一份（含 grpc/networkx），直譯器二進位是共用的。

⇒ 🔴 **刪掉 `~/miniconda3` 會同時弄壞 `p4_proxy/venv`、PATH 上的 `python3`、以及三個 env。**
我在清 2.9 GB 磁碟時把它列進「安全可刪的 2.1 GB」，**是那個 symlink 擋下來的**。

🔑 可轉移的形式：**「A 有而 B 沒有」不代表 A 與 B 是兩個獨立的東西。**
判定一個目錄能不能刪，要找的是**指進去的 symlink 與 PATH 條目**，不是「誰有哪些套件」。
`ls -la <venv>/bin/python*` 是十秒的檢查，而錯誤的代價是弄壞兩個正在跑實驗的 session。

## 🔴 08-28 第三面，最刺的一面：**錯的環境會讓缺陷本身不重現**

同樣的 symlink 結構，這次是繪圖：

```
.plotvenv/bin/python3   → miniconda3/bin/python3.13   matplotlib 3.11.1  ← 文件指定的
miniconda3/bin/python3  → miniconda3/bin/python3.13   matplotlib 3.10.8  ← 我們自己裝的
```

**同一顆 binary，對「有沒有裝 matplotlib」給相反答案。** 到這裡都還是上一節那條。

🔴 **新的是這個**：把**修正前**那張圖在兩個版本上各畫一次（`54551bc` 修的是圖被下緣切掉）：

| | 下緣留白 | 末列墨水 | |
|---|---|---|---|
| pre-fix on **3.11.1**（文件指定的） | **0 px** | **0.1411** | ✅ 缺陷重現 |
| pre-fix on **3.10.8**（另一顆） | 11 px | 0.0000 | 🔴 **缺陷不存在** |

⇒ **拿錯的直譯器去複驗那個修正，會得到「本來就沒壞、這修正沒必要」——而複驗者每一步都做對了。**

🔑 **可轉移的形式**：環境改變的不只是「工具跑不跑得起來」（那是上一節），
而是**「缺陷存不存在」**。⇒ **「我重現不出來」在你把環境釘回產生它的那一個之前，
對那個缺陷不構成任何證據。** 這是 [[the-clean-version-is-the-one-to-recheck]] 的鏡像面：
那條講「乾淨的版本才是要回頭查的」，這條講**乾淨可能是環境給的**。

**修法（`e76d5c4`）：預設拒絕，不是警告。** 腳本開頭斷言 `matplotlib.__version__`，
不符就 `sys.exit` 並印出 want／got／當前 `sys.executable`／該用哪條路徑。
逃生門留 `DECK_ALLOW_MPL_MISMATCH=1`，因為那個 venv 是單點故障——
**但走逃生門必須是一個決定，不能是預設。** 四關都驗過**含看著它失敗**
（[[mutation-gate-for-tests]]）：對的版本 exit 0 且雜湊等於既有產物、
錯的版本 exit 1 且**在產出任何檔案之前**就擋下、覆寫旗標可用、改動本身不改變圖。

📌 **另一半教訓：為什麼兩個人都沒找到那個 venv。** 它埋在兩層有空格的目錄底下、
**沒 activate 過就不在任何 PATH 上** ⇒ `which`／`compgen -c`／列舉 conda env 全部看不到。
**而路徑一直寫在那支腳本的檔頭第 18 行。** 我列舉了機制（conda env、PATH），
**沒有讀那支腳本自己說它要什麼**——我讀了前 12 行就停了，答案在往下 6 行。
⇒ **問「這支腳本要什麼」比問「這台機器有什麼」便宜一個數量級。**
