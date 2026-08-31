---
name: ndtwin-website-repo-and-build
description: NDTwin-Website repo（Hugo+Docsy）已 clone 到 ~/NDTwin-Website；repo 自己的 docker-compose 建置壞掉，可行的本機建置配方＋URL slug 規則＋既有相對連結少一層
metadata: 
  node_type: memory
  type: project
  originSessionId: 576681dc-6a95-4e35-b020-de395c7eea6d
  modified: 2026-08-28T12:15:45.374Z
---

2026-08-21 clone 到 **`~/NDTwin-Website`**（不在 workspace，跟其他兄弟 repo 一樣在 `~/`）。
private repo，`gh` 過得去但**只有 READ 權限**——推不上去，要交付得走 PR 或請 patty 開權限。

## 🏁 2026-08-28 Adam 已裁：**推不上去是刻意的，不要再想辦法繞**

> 「那個我要等全部測試完再公開。」

⇒ **24 顆 commit 留在本機是決定，不是阻塞。** 不要寫成待辦、不要找 PR 以外的推法、
**也不要再問權限**——我（`8/28 auditor`）連問三次才問到這個答案，而它從第一次起就是一個決定。

🔑 **可轉移的形狀：「某人沒有回應」與「某人已經決定」在待辦清單上長得一模一樣**，
而前者要追、後者追了是噪音。⇒ 看到「卡在某人身上」的項目，
**先問「這是未決還是已決」，不要預設是未決。**
📌 附帶後果：手冊驗證**沒有對外截止壓力**，品質優先於速度。
Hugo + Docsy，`baseURL: https://www.ndtwin.org/`，內容在 `content/en/`（51 篇 md）。

## 🏁 2026-08-28：**站台可以 render 了**，而 08-21 那個 docker 配方今天會失敗

⚠️ **先講一個我踩的坑**：我（和審查員）當天都宣稱「**現在沒有任何人能 render 這份文件**」，
而**這個檔案裡就寫著一個實測可行的配方**。我沒有先查舊結果就下結論——
違反 [[check-against-prior-experiments]]，**規則就在我自己的記憶裡**。

🔴 **但查了之後發現：那個配方今天真的壞了，只是壞在別的地方。**
容器內 **DNS 完全不通**（`Could not resolve host: github.com`），
而且 **`--dns 8.8.8.8` 也救不了** ⇒ 不是 resolver 設定，是**容器 egress 被擋**。
（08-21 可行、08-28 不可行，環境變了。）

### ✅ 現在可行的兩條路

**① docker + 掛載 module cache ⇒ 完全不需要網路**（實測 126 頁、exit 0、**1 秒**）
```bash
cd ~/NDTwin-Website && docker run --rm --network none \
  -v "$PWD":/src -v /tmp/out:/out -v "$HOME/.cache/hugo_cache/modules":/tmp/modules \
  -u "$(id -u):$(id -g)" -e HOME=/tmp -e HUGO_ENABLEGITINFO=false \
  --entrypoint sh floryn90/hugo:ext-alpine -c 'cd /src && hugo --destination /out'
```
🔑 **`--network none` 是特性不是將就**：module cache 掛進去之後**根本不需要連外**，
所以它對「容器沒網路」免疫。cache 是 **168 MB**，在 `~/.cache/hugo_cache/modules`。

**② 原生工具鏈**（我 08-28 裝的，全在 `~/.local`，不需要 root）
```bash
export PATH="$HOME/NDTwin-Website/node_modules/.bin:$HOME/.local/node/bin:$HOME/.local/bin:$HOME/.local/go/bin:$PATH"
cd ~/NDTwin-Website && hugo          # 126 頁 exit 0
```
- `~/.local/bin/hugo`（extended 0.165）、`~/.local/go`（1.27）、`~/.local/node`（v24 LTS）
- 🔑 **`node_modules/.bin` 要排在最前面**——repo 用 npm 釘住 `hugo-extended@0.154.5`，
  排前面就會用**它釘的那版**而不是我裝的 0.165（**這才是對的 fidelity**）。
- **需要 Go**：docsy 是 hugo **module** 不是 vendored theme。
- **需要 npm 的 postcss**：Docsy 的 SCSS 走 postcss，缺了會 `POSTCSS: failed to transform`。
- ⚠️ **`go.dev` 在這條網路上只有 266 B/s**（70 MB 要跑三天）。
  `https://mirrors.aliyun.com/golang/` 量到 **12.8 MB/s**；node 同一個 mirror 也快。
  GOPROXY 用 `https://mirrors.aliyun.com/goproxy/,https://goproxy.cn,direct`。

### 🪞 render 驗證本身也有個陷阱
`hugo --quiet` **會把 `ERROR` 一起吞掉**：我第一次跑輸出全空、`public/` 還在（前一次的殘留），
差點讀成「建置成功」。**實際 exit=1，錯誤是 `binary with name "go" not found`。**
⇒ **驗建置要看 exit code，不要看「有沒有噴東西」，也不要看 `public/` 在不在。**

## 🔴 repo 自己的 `docker compose build` 是壞的（這條仍然成立）
`docker compose build` 走 `Dockerfile`（`FROM floryn90/hugo:ext-alpine` + `apk add git`），
**`apk add git` exit 99 失敗**。README 教的 `hugo server` 也不行——這台機器沒 hugo、沒 go、沒 node。

**可行配方**（實測 126 頁零錯誤，約 35 s + 首次抓 module 約 37 s）：

```bash
cd ~/NDTwin-Website && docker run --rm -v "$PWD":/src -v /tmp/out:/out \
  -u "$(id -u):$(id -g)" -e HOME=/tmp -e HUGO_ENABLEGITINFO=false \
  --entrypoint sh floryn90/hugo:ext-alpine -c 'cd /src && hugo --destination /out'
```

三個 flag 缺一不可，各自對應一個真實失敗：
- `-u $(id -u)` — 不加會 `open /src/.hugo_build.lock: permission denied`
- `-e HOME=/tmp` — Go module cache 要可寫的 HOME
- `-e HUGO_ENABLEGITINFO=false` — `hugo.yaml` 開了 `enableGitInfo`，容器裡沒 git
（容器**有**網路也有 go 1.26.5；module 抓得到。`apk` 失敗不是網路問題。）

## URL slug 規則（實測產出反推，不是猜的）
目錄／檔名 → 小寫、空白轉 `-`、**括號直接移除**。
例：`Operate an Emulated (Software) Network` → `operate-an-emulated-software-network`。
heading anchor 去掉 `.` 和 `:`：`### Step 6.6: Check the ...` → `#step-66-check-the-...`。

## ✅ 連結與圖片已全數修好（08-21，分支 `docs/p4-bmv2-environment`）
原本三類壞法：相對連結**少一層**（`../../../` 只退到 `/docs/{manual}/`）、**8 個 `.md`
結尾**的相對連結（Hugo 不改寫＝404）、**2 張圖**指向 `/Users/zhangtingen/Downloads/`
（檔案其實就在同一個 page bundle 的 `images/` 裡，純路徑錯）。
全部換成絕對路徑 `/docs/...`。**新寫的連結一律用絕對路徑**，相對路徑在這個站是陷阱。

⚠️ **壞圖是 2 張不是 5 張**——掃描沒做 URL 解碼會把 3 個中文檔名（`截圖%20...`）誤判成壞的。
檢查連結要 `urllib.parse.unquote` 再比對檔案系統。

**驗證方式（值得重用）**：對**跑起來的 hugo server** 爬 `sitemap.xml`、抓每頁 `<main>`
裡所有 `href`/`src` 逐一 curl。51 頁 / 167 個目標 / 0 壞。
**對自己改的 markdown 做 grep 等於自己給自己打分，證明不了東西。**
腳本：`scratchpad/linkcheck.py`。

## 🔴 兩項刻意沒修（Adam 08-21 裁決「先不改」）
1. **檔名拼字** `Excution`（3 檔）、`Recoder`（2 檔）——改名會變動 ndtwin.org 公開網址。
   要改的話正解是重命名＋front matter 加 Hugo `aliases` 保留舊網址。
2. **內嵌 snippet 落後**：`assets/snippet/intelligent_router.py` **724 行 vs repo 1265 行**
   （repo 有而網站沒有 **588 行**）。沒同步是因為我手上唯一的來源是領先 main 413 個
   commit 的開發分支，貼上去＝公開未發布的改動。**要先指定 canonical 版本。**

## issue（已 close，等 Adam 點頭才重開）
[#43](https://github.com/ndtwin-lab/NDTwin-Website/issues/43) Ubuntu 下限（文件寫 20.04，
kernel 要 24.04：C++23 + Boost 1.83 自 repo 初始 commit `d6f7c01` 就在，**不是 head 造成的**）、
[#44](https://github.com/ndtwin-lab/NDTwin-Website/issues/44) API 端點文件 29 條 vs dispatcher 41 條。
草稿在 `scratchpad/issue-drafts.md`。理由見 [[draft-outward-facing-artifacts-first]]。

## 看「某個 commit 當時的網站」（實測可行）
`git worktree` + 第二個容器跑不同 port，**主 worktree 完全不受影響**（不必 stash、
不必 checkout、分支指標不動）：

```bash
cd ~/NDTwin-Website
git worktree add --detach /tmp/web-at-<sha> <sha>
docker run --rm -p 1314:1314 -v /tmp/web-at-<sha>:/src -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e HUGO_ENABLEGITINFO=false --entrypoint sh floryn90/hugo:ext-alpine \
  -c 'cd /src && hugo server --bind 0.0.0.0 -p 1314 --baseURL http://localhost:1314/ --disableFastRender'
# 收：git worktree remove /tmp/web-at-<sha>
```
容器起來約 10 s（module cache 已在 image 裡）。實測 :1313 顯示新文字、:1314 顯示舊文字，
**同一頁左右對照**。這也是「一頁一 commit」真正好用的地方。

## commit 慣例（Adam 08-21 指定）
**一個頁面的改動＝一個 commit**，方便他逐頁審。用 `git commit -m … -- <path>` 鎖定路徑
（`--` 之後全是 pathspec，`-m` 要寫在前面）。

相關：[[ndtwin-official-docs-site]]、[[cross-repo-component-ecosystem]]、[[ndtwin-current-state]]

## 🔴 2026-08-27:snippet 的缺口從 588 行擴大到 1360 行

實測(`wc -l`):

| | 行數 |
|---|---:|
| `assets/snippet/intelligent_router.py`(安裝手冊 §2.6 叫人貼這份) | **724** |
| repo 的 `intelligent_router.py`(§4.1 叫人 clone 的那個) | **2084** |

⇒ 照文件做的人,**跑的控制器和建 kernel 的原始碼不是同一代**。
`testbed_topo.py` 的缺口小得多(240 vs 257)。

⚠️ 一個反直覺的細節:**網站那份沒有 `is_mininet` 被無條件覆寫的 bug**
(只在第 32 行賦值一次、278 行使用),所以文件叫你設定它**是有效的**。
那個 bug 在**我們 repo 的 2084 行版本裡**。舊版不一定比較糟。

完整測試 [[install-manual-clean-room-test]]。
