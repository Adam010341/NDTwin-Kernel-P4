# W7：`ndt apps start te` 一秒內死於 `EOFError`

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W7（夜巡修法規劃員）。
修的人：夜巡「修法 agent」session，worktree `wt-integrate`（分支 `integrate/2026-09-03-auditor-merge`）。
日期：2026-09-04。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論

`app_spawn` 用 `( … ) &` 起 app，而**非同步指令的 stdin 被 bash 重導成 `/dev/null`**，
於是 `Traffic-engineering-App.py:599` 開機就呼叫的 `input()` 立刻拿到 EOF、丟 `EOFError`，
行程在 `app_spawn` 的 `sleep 1` 之內就死了，`ndt` 正確地回 rc=1。
修法：`app_spawn` 加一個**可選**的 `APP_STDIN`，用 **herestring** 掛在同一個 `exec` 上；
`te` 分支餵 `2\n5\n`（週期模式＋app 自己的預設秒數）。**其他四個 app 的行為一個 byte 都沒動。**

## 2. 🔴 對工單根因的一條更正（這條改變了「有沒有替代手段」）

工單 §W7 寫「`:3516` **stdin 完全沒有處理**，子 shell 繼承 `ndt` 自己的 fd 0」。
**繼承那半是錯的。** bash 對**非同步指令**（`cmd &`）在 job control 關閉時
（也就是所有腳本情境）一律把 fd 0 重導成 `/dev/null`，**除非那個指令自己帶了重導向**；
掛在**呼叫端**的重導向不算。

我實測（2026-09-04，`readlink /proc/self/fd/0`，同一個 `( cd … && exec setsid nohup … ) &` 形狀）：

| 情境 | 子行程的 fd 0 |
|---|---|
| 函式呼叫端帶 `< feed.txt` | `/dev/null` |
| 完全不帶重導向 | `/dev/null` |
| 腳本自己的 stdin 是一個真的檔案 | `/dev/null` |
| `exec` 上掛 herestring | `pipe:[…]`（＝真的餵到了） |

**後果比工單寫的更強**：不是「非互動情境下是 EOF」，而是**任何情境下都是 EOF**——
使用者在終端機前面手打 `ndt apps start te` 再手動輸入 `2`，那個 `2` 也永遠到不了 app。
**這個 bug 沒有 workaround**，餵料只能從非同步指令的內部發生。這也是修法必須是
herestring／而不是任何掛在外面的重導向的理由。

## 3. 缺陷本體

| 位置 | 內容 |
|---|---|
| `tools/test_workflow/ndt:3516`（修法前） | `( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 ) &` |
| 同上 `:3520-3525` | `sleep 1` 之後 `kill -0` 失敗 ⇒ `err "$name exited immediately"`、rc 1 |
| 同上 `:3651-3653`（修法前） | `te)` 分支，`app_spawn te "$TE_APP_DIR" "$TE_PY" Traffic-engineering-App.py` |
| `~/Traffic-Engineering-App/Traffic-engineering-App.py:595-612` | `ask_mode()`，`input()` 在 `:599`（模式）與 `:605`（秒數） |
| 同上 `:586-592` / `:623-625` | `enter_listener()` 的第三個 `input()`（`:589`），**只有 mode 1 會啟動那條執行緒** |

BEFORE（今晚整機測試留下的實測，`.test_run/logs/app_te.log` 尾端，工單 §W7 逐字引用）：

```
Enter 1 or 2 [default 1]: Traceback (most recent call last):
  ...
  File ".../Traffic-engineering-App.py", line 599, in ask_mode
    choice = input("Enter 1 or 2 [default 1]: ").strip() or "1"
EOFError: EOF when reading a line
```

🟠 這一段是**別人（今晚 auditor／整機測試）跑出來的**，我沒有重跑 live。

## 4. 為什麼只能改 `ndt` 這一側

Adam 2026-09-04 裁：**七個外部 app 的 repo 只讀不改**。
而那個檔沒有任何非互動路徑（`grep isatty／argparse／environ／getenv` 全部零命中，704 行）
⇒ **餵 stdin 是唯一的槓桿**。

## 5. 修法

`tools/test_workflow/ndt`，兩處：

1. `app_spawn`：`APP_STDIN` 非空才走帶 herestring 的那一行，否則**原字面不動**。
2. `te)` 分支：`APP_STDIN=$'2\n5\n'`。

### 為什麼是 herestring，不是 wrapper、也不是管線

| 候選 | 結論 | 證據 |
|---|---|---|
| `bash -c "…"`／`script -c "…"` wrapper | 🔴 **壞** | `pid_is_app`（`:2797`）比的是 **argv 的元素**；wrapper 把 `Traffic-engineering-App.py` 埋進某個元素的**中間**，`apps status` 會對一個明明活著的行程印 `not-running`。閘門 M2 實測抓到 |
| 管線 `printf … \| ( … ) &` | ⚠️ **沒有壞**（工單預測它會壞，**預測是錯的**） | job control 關閉時 bash 不給管線自己的行程群組 ⇒ 子 shell 不是群組首領 ⇒ `setsid(1)` 原地 exec 不 fork ⇒ `pgid == sid == pid` 仍成立、`$!` 就是程式本身。實測 51 checks 全綠，**留成閘門的 C4 對照組** |
| 管線移進子 shell 內部 | 🔴 **壞** | 子 shell 不能再 exec，它 fork 出 app 並活著當它的父行程；`$!` 指到一個穿著 `ndt` argv 的 shell ⇒ 就是 2026-08-20 那個「pidfile 裡不是程式」的失敗。閘門 M3 實測抓到 |
| ✅ herestring 掛在 `exec` 上 | **不壞** | 重導向由子 shell 在 `exec` **之前**做完，argv、pid 鏈、`pgid==pid==sid` 判斷全部不變 |

⇒ 選 herestring 的理由**不是**「管線會壞」，是 `app_spawn` 自己的設計註解那條：
`$!` 必須由眼前的 exec 鏈保證指到程式本身，而不是由「管線最後一個元素」這條規則保證。
**閘門把這件事寫成 C4 對照組，就是為了不讓後人把這份文件讀成「管線壞掉」。**

### 為什麼餵 `2\n5\n` 而且到此為止

那個檔一共 3 個 `input()`。選 **2**（週期執行）之後 `:605` 讀秒數，
而 `enter_listener` 那條執行緒**只有 mode 1 才啟動**（`:623-625`）
⇒ 行程餘生不再讀 stdin，兩行餵料是完整的。
選 mode 1 的話 `:589` 的執行緒吃到 EOF、catch 之後結束——**app 活著、看起來成功、Enter 觸發從此是死的**。
`5` 是 **app 自己的預設**（`:603` `te_interval = 5.0`，prompt 寫 `[default 5]`）：
餵一個與預設不同的值等於在 launcher 裡偷改 app 的行為。
🟠 auditor 今晚手動驗過的是 `printf '2\n2\n' | …`（**管線**形式、秒數 2）。
**這一格（5 還是 2）留給 Adam**，改一個字元即可。

## 6. 測試與看紅

測試進既有的 `tests/shell/test_ndt_apps_liveness.sh`（新的第 6 節，51 checks），
不開新檔——它已經 `source "$NDT"`、已有安全 fixture 慣例。
新增 `NDT_UNDER_TEST` 支援一行（沿用 `test_apps_stop_kills_the_group.sh:49` 的慣例，
未設時行為與原本完全相同），讓閘門可以只動副本、**永不寫 `tools/test_workflow/ndt`**。

### 看紅（逐字）

把修法拿掉（＝閘門的 M1，未修的 launcher）之後：

```
app_spawn stdin (W7: te died of EOFError one second in)
  FAILED   app_spawn feeds APP_STDIN to the program
             expected: 2/5
             actual:   EOF/EOF
  ok       a fed app is still its own session leader
  ...
Ran 51 checks, 1 failed
```

`EOF/EOF` 就是 app 死掉時拿到的東西：fixture 分別記錄「read 失敗（EOF）」與「read 到空行（EMPTY）」，
所以它同時也擋得住「乾脆全部餵空字串」那種修法（那會讀成 `EMPTY/EOF`）。

### 🔴 兩個 fixture 設計上的錯誤（我自己踩到，寫下來給下一個人）

1. **第一版 fixture 用絕對路徑起腳本，M2（wrapper）SURVIVED。**
   `pid_is_app` 收 `*/"$sig"`，而 wrapper 的 `-c` 字串結尾若是 `…/Traffic-engineering-App.py`
   **剛好滿足那個 glob**。真的 launcher 是用**裸檔名**從 app 自己的目錄起的，
   結尾會是 `python Traffic-engineering-App.py`（前面是空白不是斜線）⇒ 不匹配。
   **fixture 不照抄 launcher 的 argv 形狀，就看不到 launcher 會有的 bug。** 已改成裸檔名。
2. **第一版控制組斷言「不餵料時程式拿到呼叫端的 stdin」，紅了**——見 §2，
   那個假設本身是錯的。正確的控制組是 `EOF/EOF`（＝修法前的行為）。

## 7. 閘門

`tests/shell/mutate_te_launcher_stdin.sh`（**不用 build**，bash 而已，不佔 build lock）。
log：`scratch/overnight-2026-09-04/fix/W7-gate.log`。

```
mutation gate: 9 mutations, 0 survived
baseline byte-identical: yes (tools/test_workflow/ndt)
```

5 個變異（M1 缺陷本身、M2 wrapper、M3 內部管線、M4 mode 1、M5 餵所有 app）
＋4 個對照（C1 `-n`↔`! -z`、C2 註解改寫、C3 重導向順序、**C4 外部管線**）。

**沒有放進來的變異**：`>>` → `>`。它已經是
`tests/shell/mutate_apps_stop_kills_the_group.sh` 的 M6，而那支的兩個 anchor
（`    ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 ) &` 與 `>>"$log" 2>&1 ) &`）
在我這次修改之後**仍然各命中一次**——`APP_STDIN` 那條分支結尾是 `<<<"$APP_STDIN" ) &`，
不會撞到它們。**這是刻意設計的**：修法的 else 分支保留原字面（只多了縮排），
所以既有閘門一個都不用改。

## 8. 可達性口徑

🟠 **產線走得到，今晚實測 rc=1**，log 裡有逐字 traceback（別人跑的，我沒複驗）。
**這是這批單裡唯一一個「使用者照手冊做就會撞到」的**：`ndt apps start te` 是手冊教的用法。
⚠️ **修法本身（herestring／mode 2）我沒有跑過 live**——lab 今晚有別的角色在用，我沒碰。
AFTER 的證據是 shell 測試（51 checks）與閘門（9/9），**不是 live**。
建議整機測試結束、lab 空了之後照 R1 登記再做一次
`ndt apps start te` ⇒ rc=0、`ndt apps status` 顯示 running、log 出現 mode 2 的週期輸出。

## 9. 沒修的同型

- **其餘四個 app 沒有查**有沒有一樣的開機 `input()`。`APP_STDIN` 這個接縫已經備好，
  哪一支需要就在它的分支上加一行；但**我沒有讀那四個 repo 的原始碼**，不宣稱它們沒事。
- **`pid_is_app` 的 `*/"$sig"` glob 沒有錨在元素開頭**（§6-1）。它不是這張單的缺陷
  ——真的 launcher 走不到——但它是「一個 wrapper 可以騙過身分檢查」的形狀。
  **沒改**：改它會動到 `:2765-2771` 那段明文寫死的取捨，那是另一張單。
- `apps_trim` 依賴的 O_APPEND（`:3953-3955`）沒有動，`>>` 兩條分支都保留。

## 10. 給 Adam 的一格

`te` 的週期秒數餵 **5**（app 自己的預設，本次選這個）還是 **2**（auditor 今晚手動驗的值）？
