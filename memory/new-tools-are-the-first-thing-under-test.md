---
name: new-tools-are-the-first-thing-under-test
description: 新測試工具第一次對真環境跑時，找到的幾乎都是工具自己的缺陷——它們的單元測試把整個世界 stub 掉了，所以第一次 live 跑要當成「測這個工具」而不是「用它測系統」
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3631e0c3-4043-413e-9a04-715ef6600218
  modified: 2026-08-13T14:22:03.228Z
---

2026-08-13 一天內同一個形狀出現三次。

**L5 故障注入 harness 第一次實戰，找出三個缺陷，全在工具裡**：
1. 對帳工具的 counter 檢查是**被動觀察**（sample→sleep→sample）→ 閒置網路上永遠判「爭議」，
   harness 因此拒絕注入。先前看起來正常只是因為當時剛好有背景流量在跑。
2. harness 呼叫判準模組時**沒傳 host PID** → 所有探測跑在主機的 root namespace，
   ping 打不到目標、counter 讀的是主機網卡（rx 139 萬且持續成長）。
3. 還原指令 `del … root netem` **多一個 token** → 不符 sudoers 的精確參數列表 → 要密碼 →
   注入被允許、還原被拒、故障留在原地。

**`local_ci.sh` 上線一小時內抓到我自己兩個錯**：新測試 import 了 `tests/python/` 不准用的
第三方套件、三個新 shell 測試的摘要格式不合 runner 解析的 `Ran N`。

**twin 測謊器有一個概念層級的缺陷，而且是我 prompt 造成的**：我寫「三個通道交叉驗證」卻
沒說哪些是證人——它把「控制平面宣稱有路徑」跟 ping、counter 平等投票，等於讓被告當陪審員。
實測後果：主機斷線時判「爭議、exit 0」，**在它被造出來要抓的那個案例上會失效**。

**Why**：新工具的單元測試必然 stub 掉外部世界（那正是它們能跑得快的原因），
所以**工具與世界的介面**——sudo 授權的精確形式、namespace、pid 解析、有沒有背景流量——
是測試結構上看不到的地方，而那裡正是工具最容易錯的地方。

**How to apply**：
- 新工具第一次 live 跑，**預期它會失敗，而且預期是工具的錯**。排時間，不要排在關鍵路徑上。
- 交付前問：這個工具的判準**依賴環境的什麼假設**？（有流量？在正確的 namespace？sudo 形式對？）
  每一條都是 stub 看不到的。
- 「工具找到系統的 bug」與「工具自己壞了」在輸出上長得一樣——**先假設是後者**，
  用獨立手段（自己 ping 一次、自己 curl 一次）確認環境真的壞了再說。
- 設計 seam 時明確標註**哪些通道是獨立證據、哪些只是轉述被測對象的宣稱**，不要讓它們平等投票。

相關：[[live-runs-find-what-tests-cannot]]（互補的另一面：系統的 bug 也只有 live 抓得到）、
[[smoke-the-accept-path-not-just-refusals]]（同源：拒絕路徑全綠不代表接受路徑會動）、
[[mutation-gate-for-tests]]。

## 2026-08-13:文件引用檢查器,假陽性率 91%

寫了 `docref.py` 掃 `doc/` 的 14 份文件(~11,000 行),把所有機械可驗證的引用
(檔案路徑、行號錨點、反引號識別字、HTTP 端點、commit hash)抓出來核對。

**第一版報 85 條。修掉工具自己的缺陷後剩 33 條。逐條人工查證後只有 8 條為真。**

工具的三個缺陷,每個都是不同的失效方式:

1. **搜尋範圍手寫死** — 只列了幾個原始碼目錄,漏掉 `p4_proxy/tests`、`p4_proxy/p4_src`、
   `p4_proxy/mininet`、`CMakeLists.txt`。
2. **把別人軟體的名字當成本專案符號** — `RemoteController`(Ryu)、`weak_ptr`(stdlib)、
   `Traceback`、`egress_spec`(P4 規格)、`simple_switch_CLI`(bmv2)。
3. **grep 搜的是檔案內容,不是檔名** — 所以每一個「用檔名引用測試」的地方都變成假陽性,
   那 8 個測試檔全都存在。

而且第 9 條是在**寫報告的過程中**才發現是我的誤判:`src/app/http.cpp:269` 真的存在,
在 **Energy-Saving-App** 裡——工具只檢查本 repo,所以把跨 repo 的正確引用報成壞掉。

**做對的一件事:先拿已知答案當對照組。** B2 在 2026-08-12 手工深掃過 4 份文件、報了兩個
具體的定位錯誤;工具兩個都抓到才往下走。沒有那道對照,我不會知道 85 這個數字要打幾折。

**How to apply**:新工具的第一份輸出,在人工複驗完之前**不是發現清單,是待驗證清單**。
先找一組已知答案當對照組;沒有對照組就先做一個。假陽性寫進文件的代價,遠高於慢一輪。

## 2026-08-13:thrift CLI 讀 counter,連我落檔的配方本身都是錯的

C10 要用 `simple_switch_CLI` 第一次對真 bmv2 讀 counter。**我在 commit `75b70c2` 先把配方寫進
`requirements.txt` 註解——`p4_proxy/venv/bin/python "$(command -v simple_switch_CLI)"`——
然後才真跑,一跑就 `ModuleNotFoundError`。** 兩個 stub 看不到的坑:① 裝好的 wrapper 自己的
`sys.path.append` 指向 p4dev venv 的 site-packages,但 `sswitch_CLI`/`runtime_CLI` 只在
`~/P4_Source_Code/behavioral-model/` source 樹;② p4dev venv 自己的 thrift 是壞 namespace
(`cannot import Thrift`)。正解花了三四次嘗試才收斂(proxy venv 的 thrift＋source PYTHONPATH),
`24308a7` 更正。**新面向:這次不是「用工具測系統」找到工具的 bug,是「我寫的操作說明」
本身沒跑過就落檔。** 配方、runbook、README 的指令都算「工具」——寫完先跑一次再 commit,
[[fresh-grep-before-confirmed-quote]] 的操作版(能跑的指令勝過記憶中的指令)。


**2026-08-18 又一例，而且是我自己現寫的量測器。** 為了量「幽靈規則多久發作一次」，
我寫了一支每 10 秒同時抓 kernel 表與 `ovs-ofctl` 真值、比對後記錄分歧的腳本。
**第一次實跑，每一個取樣都報 DIVERGENCE。**

原因不是系統有問題，是我拿**整串格式化字串**去比對，而真值那側經過 `uniq -c` 會補空白、
kernel 那側不會。內容完全相同、空白不同。

**代價比「白跑一輪」更糟**：底下確實藏著一個真的差異（kernel 有 dpid 7、真值沒有，
那是 energy app 正在關 s7 的瞬間），但**被雜訊淹沒到分不出來**。壞掉的量測器不只是沒結果，
它會把真訊號變成不可辨識。

修法與新紀律：兩邊都 parse 成正規化的結構再比對；並且**把「成員差異」與「內容差異」分開計數**
（前者在電源開關時本來就會暫時出現）。修好之後**先在健康狀態下跑一分鐘驗它不誤報**
（12 取樣 12 個 MATCH），才開始正式量。腳本在
`doc/audit/2026-08-18_live-full-stack-round/measure_f5_frequency.sh`。
