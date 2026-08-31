---
name: slide-deck-generator-python-pptx
description: 簡報生成器與 QA 腳本的耐久位置、venv 重建指令；這台機器沒有 Node 也沒有 LibreOffice——pptx 一律 python-pptx、QA 只能幾何檢查
metadata: 
  node_type: memory
  type: project
  originSessionId: 299a1af7-1589-4412-9bfa-344937719a81
  modified: 2026-08-31T03:54:03.385Z
---

2026-08-13 深夜，簡報 v1（38 頁）從 `NDTwin-slide-template.md` 生成時建立的工具鏈。

- **生成器**：`~/Desktop/NDTwin Slide material/generator/build_deck.py`——全部頁面內容、
  講者備註、版面都在裡面；**改 v2 就是改它重跑，不要從頭重建**。同資料夾 `qa_deck.py`
  是幾何 QA（座標越界／CJK 字寬溢出估算／文字框互疊）。
- **環境限制（實測，別再踩）**：機器**沒有 Node**（`node: command not found`，pptxgenjs
  不可用）也**沒有 LibreOffice**（`soffice` 不存在，不能渲染 PDF 做像素 QA）。
  重建：`python3 -m venv <dir> && <dir>/bin/pip install python-pptx defusedxml lxml`；
  pptx skill 的 `validate.py` 用同一個 venv 跑（v1 驗證 PASS）。
- **產出**：`build_deck.py out.pptx`；成品與 `DRAFT-v1-NOTES.md`（4 個落筆裁定）同資料夾。
  **Adam 裁定前，deck 的 s22④／s20⑤／s16「11 個」／s28「11+」四處不要動。**
- ⚠️ **v1 凍結期間，內容更正一律改 `NDTwin-slide-template.md`，不要動 `build_deck.py`
  也不要重新產 pptx。** Adam 2026-08-14 明講：「選項一，但改 template 就好了，不要直接改簡報。」
  理由（我的理解）：他還沒逐頁過目 v1，此時重產會讓他審的版本一直在變；template 是內容的
  真實來源，更正記在那裡，等他給完回饋再一次性做 v2。
  **所以「發現簡報有錯」的正確動作是改 template ＋ 告訴他，不是重跑生成器。**
- 幾何 QA 第一輪就抓到 3 個真版面問題（標籤壓標題、兩頁 caption 被 bullets 框蓋）——
  但它估不出字型渲染差異，[[new-tools-are-the-first-thing-under-test]] 照樣適用：
  Adam 開檔人工過版面前不算定稿。
- python-pptx 移植備忘：dash 枚舉在 `pptx.enum.dml`（不是 `enum.line`）；CJK 要在 rPr
  補 `a:ea`/`a:cs` typeface，只設 `font.name` 只蓋到 latin。

相關：[[ndtwin-current-state]]。

---

## 2026-08-19:live 的產生器原本只存在於 Claude session 沙箱裡,已救出

🔴 **`build_deck.js`(126 KB)、`NDTwin_deck.pptx`(1.37 MB,42 頁)、`count_lines.py`、
`line_counts.json` 當時只在
`~/.config/Claude/local-agent-mode-sessions/740b7c88.../outputs/`**——那是綁 session id 的目錄。
2026-08-19 已複製到 `~/Desktop/NDTwin Slide material/generator/` 與該資料夾根目錄。

⚠️ **`build_deck.js` 需要 Node,而這台機器沒有 Node**(本檔上面那條仍然成立),
所以**簡報在這台機器上重建不出來**。Adam 2026-08-19 裁定:**簡報由他自己的
cowork session 產生**,我只交 template ＋ 圖 ＋ 資料。

**這也解開了 §5-H 留的那個待辦**:「B 節/Page 8/Page 9 要重跑 `count_lines.py`」
之所以一直沒做,是因為**那支腳本在沙箱裡**。現在在 `generator/` 了,做得了。

**繪圖工具鏈(2026-08-19 新建)**:這台機器原本**沒有 matplotlib**。
專用 venv 在 `~/Desktop/NDTwin Slide material/.plotvenv`
(`python3 -m venv` ＋ `pip install matplotlib`,裝到 3.11.1)。
⚠️ **不要裝進 `p4_proxy/venv`**——那支是 proxy 在用的。
產生器 `doc/audit/2026-08-19_p4-sflow-accuracy/plot_figures.py`,
輸出到 `<slide material>/figures/`,**8 張圖全部從已 commit 的原始資料重算**
(failover 那幾張每次重畫都重新解析 raw ping log,所以圖與報告不可能漂移)。

⚠️ **08-25 更新：8/27 版換了工具鏈與正本位置**。正本＝`~/Desktop/NDTwin slide material 827/
NDTwin-slide-template-827.md`（E6：template 是唯一事實來源、Adam 會直接編輯、動工前先讀最新版）；
產生器改 **JS（pptxgen＋generator/deck_style.js）**，本機無 Node、**產檔由 cowork session 做**；
繪圖 venv 在舊資料夾 `.plotvenv`（別裝進 p4_proxy/venv）。舊資料夾（8/20 版）只當素材庫；
我 08-25 誤把 v5 草稿寫進舊資料夾、已併入 827 模板 v1.5 並留指標殘檔。

🔴 **08-25 再更正兩處失效路徑**：舊資料夾已改名 **`NDTwin Slide material 820`**（不是
`NDTwin Slide material`）；🔴 **「`.plotvenv` 已不存在、全機沒有任何 matplotlib」是錯的（08-28 更正）**——`.plotvenv` **還在**，Python 3.13.13 ＋ matplotlib **3.11.1**，路徑是
`~/Desktop/NDTwin slide material/NDTwin Slide material 820/.plotvenv/bin/python3`。🔑 **它埋在兩層底下**（`NDTwin slide material/` 裡面還有一層 `NDTwin Slide material 820/`），而且**沒有被 activate 過就不在任何 PATH 上** ⇒ `compgen -c`／`which`／列舉 conda env 全都找不到它。**`plot_deck_903_round2.py` 的檔頭一直寫著這條路徑。** 以下原文保留供對照：（conda 三個 env
皆無）。可行配方：`ryu-env 的 python -m venv <scratchpad>/plotvenv && pip install matplotlib`
（有網路、約 1 分鐘、matplotlib 3.7.5 on py3.8）。畫圖腳本放 repo 的 `doc/audit/<輪次>/`、
輸出直接寫進 `NDTwin slide material 827/figures/`。

## 📌 9/03 那副圖到底在哪（08-28 定位，免得那天重新考古）

**不在 repo 裡**（repo 從來沒有 commit 過任何 PNG，而且不是 `.gitignore` 擋的）。在：

```
~/Desktop/NDTwin slide material/NDTwin slide material 903/figures/
    page_bandwidth-ceiling.png        page_M_cost-and-benefit.png
    page_Q_assumed-denominator.png    page_Q_gate-after-fix.png
    _superseded/  ← 09:12 那版，M panel 蓋著已經過期的 PRE-FLIGHT 戳章
```
四張現行＋兩張已取代＝六張，對得上 `54551bc` 那句 "all six outputs"。

⚠️ **審查員搜遍 repo、所有分支、`git log --all --diff-filter=A -- '*.png'` 得到「一張都沒有」，
就下了「沒有產物」的結論。** 🔑 **他把「我搜過的範圍」當成了「存在的範圍」。**

✅ **圖是可重現的**：我用 `.plotvenv` 跑 `plot_deck_903_round2.py`，
產出與那個目錄裡的 **sha256 逐 byte 相同**（`92e843b2…` / `96fe15af…`）
⇒ 腳本＋committed 資料就足以重建，不必保存 PNG。

🔴 **腳本現在會擋錯版本**（`e76d5c4`）：不是 matplotlib **3.11.1** 就 `sys.exit` 並印出
當前 `sys.executable`＋該用的路徑。逃生門 `DECK_ALLOW_MPL_MISMATCH=1`。
理由不是潔癖——**修正前的裁切缺陷在 3.10.8 上根本不重現**（0px→11px），見
[[benchmark-must-name-the-binary-it-measured]]。

## 🆕 08-30 深夜：903 模板 v0.1 已起草（auditor）

`NDTwin slide material 903/NDTwin-slide-template-903.md`——照 E6：**Adam 唯一編輯者、
產檔歸 cowork session**。骨架＝三節 27 頁（§1 手冊線主菜／§2 效能研究四 page 圖＋二 fig 圖／
§3 工程與下一步）；規約沿用 827 §A/§E 全文（路徑寫在檔頭）。
~~🔴 p.25 投稿計畫頁整頁凍結~~ → **08-30 更深夜 v0.2（reviewer 線、Adam 明令）＝凍結依
自身條件解除**（LINE 已發、教授回「缺乏創新性、無研究價值」）：p.26 改「Worth writing up?」
請教頁（場地名不上台面）、＋p.22 普查記分板＋fig4 spread（不可略）、
study/FINDINGS commit 更新 `b2cd6b5`；**v0.3/v0.4＝加 fig5 矩陣＋fig6 十二數一軸＋fig7 aggregate 兩平面（換掉 p.20 表格頁）
＋fig8 已知≠規範圖解**（`make_survey_figs.py` 在 repo study-figs 目錄、已 commit `408d31b` 08-31；
風格沿 make_figs.py 家族、fig5 欄合計 assert 護欄、fig8 曾被 Adam 打回
「很丑」→引文主角＋等寬盒版過關）→ 31 頁；詳 [[bmv2-literature-review-2026-08-28]] 檔尾。

## 🏁 08-30 Adam 裁「新版面文法」＝以後所有 deck 照用（常設，不只 903）

對照 qec 週報範例後裁定「以後就照這個格式」：字少、「標籤 → 值」的列、kicker（≤6 詞片語）
取代副標句。規格全文＝827 模板 §E3a；五頁版型範例＝`903/NDTwin_style-examples.pptx`＋
`generator/build_examples.js`；helper＝`deck_style.js`。裁定原文與四條產檔地雷（含
🔴「副標句轉 kicker 時，`in our sample` 這類限定詞要跟著數字走、不可獨立成句被砍」）
記在 903 模板 §E-delta-1。落地者＝並行 session（08-30 深夜），此處僅指標。
🔲 待 Adam：827 deck p.32 的承諾①②原文（我不猜）；🔲 自動落點：§6.7/NTG/T-8/T-10/
有流量輪結果（B3 表列了每項落到哪頁）。fig1–4 素材新位置＝repo
`doc/2026-08-29_bmv2-performance-study-figs/`（7ca06e0）。

## 🆕 08-30 深夜：乾淨圖裁決已執行（Adam 附範例圖）

四張 903 圖重渲＝**圖上只留置中標題＋一行參數**（新 helper `_title_clean`）；副標散文、
footer、stamp、判決卡片、ECMP 註記**全搬到 903 template 新開的 §G**（REQUIRED 標記＝
必須隨頁出現的防誤讀句）。腳本改動 repo `ad2fe42`＋label 修正；舊圖в `_superseded/
*_pre-cleanfig-0830.png`。⚠️ sibling 腳本的 tracked-source guard 會查 raw 檔與 audit-raw
一致——本地 raw 缺檔時 `git show audit-raw:<path> >` 取回正本即可。Q gate 數據改印 stdout。

## 🏁 08-31：「可從 committed 腳本 byte-exact 重建」現在成立了——連同它先前為什麼不成立

**先前那條警語有結論、沒有原因**，所以收不掉。原因是：`make_figs.py`（產 fig1–4）
**只存在於 `doc/2026-08-29_europ4-poster-abstract/`，而該目錄在 `.git/info/exclude:25`**
⇒ 一次全新 clone 拿不到它，而論文照樣印著那四張圖。
（fig5–8 的 `make_survey_figs.py` 08-31 已進版控 `408d31b`，所以那句話**當時只對後四張成立**。）

**已修**：`make_figs.py` 逐位元副本抽進 `doc/2026-08-29_bmv2-performance-study-figs/`
（`3661525`，`cmp` 驗過），同目錄 `README-generators.md` 記兩支腳本的分工與此沿革。

🔑 **通則（同 `DERIVATIONS.md`）**：**「不進版控」的鎖是對投稿內容下的，不是對可重建性下的。**
生成腳本／算式／機器規格＝量測 provenance ⇒ 抽進版控；稿件與場次名留在鎖裡。
混為一談會兩頭落空——**鎖沒守住該守的，反而弄丟了該留的**。
