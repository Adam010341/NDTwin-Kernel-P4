# 圖的生成腳本——為什麼兩支都在這裡

| 腳本 | 產出 | 進版控時間 |
|---|---|---|
| `make_figs.py` | **fig1–fig4**（unit ambiguity／perflow monotone／build two working points／literature spread） | **08-31**（本次；先前只存在於被排除的目錄裡） |
| `make_survey_figs.py` | fig5–fig8（reporting matrix／twelve numbers／aggregate two planes／known-but-never-reported） | 08-31（`408d31b`） |

## 為什麼 `make_figs.py` 現在才進來

它原本只存在於 `~/Desktop/NDTwin slide material/paper/abstract/`，而該目錄在
**`.git/info/exclude`**（09-01 起改為：整個投稿包已移出 repo，規則連同對象一起撤掉）。⇒ **一次全新 clone 拿不到它**，
而論文照樣印著 fig1–4。本檔的副本與原檔**逐位元相同**（`cmp` 驗過）。

🔑 **通則（與 `DERIVATIONS.md` 同一條）**：「不進版控」的鎖是**對投稿內容**下的
（稿件、場次名、匿名前的識別），**不是對可重建性**下的。生成腳本、算式、機器規格
屬於量測 provenance ⇒ 抽進版控；投稿內容仍留在鎖裡。混為一談會兩頭落空。

## 對「圖可由 committed 腳本 byte-exact 重建」這句話的更正

該句**先前只對 fig5–8 成立**，fig1–4 的腳本不在版控裡——這是先前記憶中
「暫不成立」那條警語的**原因**（警語有，但沒指出原因）。**自本 commit 起，八張全部成立。**

⚠️ 兩支腳本都自行定位輸出目錄（`os.path.dirname(os.path.abspath(__file__))`），
所以本目錄的 `make_figs.py` 會寫到 `<本目錄>/figs/`，與投稿目錄那份輸出到不同位置、
**內容相同**。直譯器＝`.plotvenv`（matplotlib 3.11.x，腳本內有版本斷言）。
