# 量測輪的收官清單

（2026-08-31 建立。起草端的對應物是 [2026-08-31_prereg-inheritance-checklist.md](2026-08-31_prereg-inheritance-checklist.md)；
**那一份在開輪前讀，這一份在收輪時讀**。分成兩份是刻意的：收輪的人不會去開「起草」清單。）

[Co-developed with claude code -- Adam]

## 為什麼需要這份清單

`tools/githooks/pre-commit` 會擋「raw 出現在工作分支」，`:32` 是
`[[ "$branch" == "audit-raw" ]] && exit 0`。**它只能擋錯的目的地，不能檢查對的目的地發生過。**

⇒ **一輪如果從頭到尾就沒 commit 過它的 raw，repo 裡沒有任何機制會出聲。**
hook 只在你 commit 的那一刻才有機會說話，而**「缺席」不觸發任何事件**——
忘記歸檔的那一輪，正好就是永遠不會讓 hook 執行到的那一輪。
（這是「保護的失效時機與它要防的事件重合」的又一個實例。）

2026-08-31 普查的結果：**15 輪的 raw 不在任何 object store，合計 533.2 MiB，
而且沒有一輪宣稱過相反的事。缺口是沉默不是假話。**
沒有事件可以掛，就得自己排一個——**這份清單就是那個「自己排的事件」。**

## 收官時逐項做

### 1. raw 已落 audit-raw，而且寫下 sha

- [ ] 本輪所有 `raw*` 目錄的檔案都在 `audit-raw` 上。
      🔴 **是所有 `raw*`，不是 `raw/`**——一輪可以有 `raw_n`／`raw_h`／`raw_gil`
      （`.gitignore:60` 的 pathspec 之所以是 `raw*` 就是為此）。漏掉會少算，而且少算的方向
      正好讓你以為做完了。
- [ ] 在本輪的 README／報告裡寫下 **commit sha ＋ 檔數**，例如
      「raw N 檔落 `audit-raw <sha>`」。**這句話之後會被人引用，所以它要可驗證。**
- [ ] **驗內容不驗 rc**：至少抽一個檔
      ```bash
      git cat-file blob "audit-raw:<path>" | sha256sum
      sha256sum <path>          # 兩個要一樣
      ```
      `git cat-file -e` 只證明物件存在，不證明它是你以為的那份。

普查指令（確認自己這輪是乾淨的，也可以拿來掃全部）在
[KNOWN-ISSUES.md](KNOWN-ISSUES.md) §G「raw 歸檔的守衛是單向的」那條，可直接貼。

### 2. 還在跑的東西不要歸檔

- [ ] 落檔前確認本輪的檔案**已經沒有人在寫**：
      ```bash
      find doc/audit/<round>/ -type d -name 'raw*' -exec find {} -type f -mmin -10 \; 
      ```
      有輸出就**先不要歸檔**。
      🔴 **把一個正在被 append 的 log 的半截快照存成「該輪的證據」，比不存更糟**：
      它會產生一個看起來完整、實際上是任意時點截斷的物件，**而且沒有任何欄位會顯示它是半截的**。

### 3. 別的輪次對你的依賴，要寫成 path＋sha

- [ ] 如果本輪的閘門／對帳**讀別輪的存檔**（force-green 餵已知良品、逐格對帳…），
      把**確切 path 與 sha 寫進預註冊**，不要只寫輪次名。
      🔑 **理由是實例**：`2026-08-31_sampling-ceiling-after-merge` 的 §6 與
      `gates_e.sh:264` 的 `RATIO_GOOD_CELL:-t008_poll` 都寫「08-25 D 輪的格子」，
      但那些 cell 其實在 **`2026-08-20_sampling-rate-and-cpu/raw/`**
      （`round.env:23` 的 `PRIOR` 才是真正解析的地方）。
      **輪次名對不上檔案位置，而依賴只活在腳本裡**——這正是本清單第 1 項要防的病的另一面。

### 4. 歸檔的方式（這台機器上）

- [ ] 用 plumbing，**不要** `git worktree add /tmp/rawwt audit-raw`：
      ```bash
      TIP=$(git rev-parse refs/heads/audit-raw); IDX=/tmp/ar.index; rm -f "$IDX"
      GIT_INDEX_FILE="$IDX" git read-tree "$TIP"
      GIT_INDEX_FILE="$IDX" git add -f --pathspec-from-file=<清單檔>
      TREE=$(GIT_INDEX_FILE="$IDX" git write-tree)
      NEW=$(git commit-tree "$TREE" -p "$TIP" -F <訊息檔>)
      git update-ref refs/heads/audit-raw "$NEW" "$TIP"   # 帶舊值＝compare-and-swap
      rm -f "$IDX"
      ```
      🔴 **理由不是方便**：`audit-raw` 攤開超過 500 MiB，而這台機器上
      **`rm` 不會還你空間**（VM 的 `virtiofsd` 按住已刪除的檔案，見 §G）⇒
      **「先展開再刪掉」是一個會單向消耗磁碟的動作**。
      plumbing 也不動工作區與 HEAD——共用 worktree 上有別的 session 在工作。
- [ ] **一輪一個 commit**，訊息寫該輪、檔數、以及查得到的話「為什麼當初沒進去」。
- [ ] 提交前掃憑證形狀（`BEGIN .* PRIVATE KEY`／`api[_-]?key[=:]`／`password[=:]`／
      `Bearer <20+>`／`ssh-rsa AAAA`）與可疑檔名（`*key*`／`*token*`／`*secret*`／`*.pem`／`id_*`）。
- [ ] **不要 `git push`**：公開與否只能打公開 URL 驗，push 是 Adam 的裁決。

### 5. 收乾淨

- [ ] `ndt release`，並在 `.test_run/lab.handoff` 寫清楚 fabric 留不留、為什麼。
- [ ] `ndt apps orphans` 回 0。**2026-09-07 起它的 rc 不只回答行程了**（G-12／W16-1），
      判準跟著改，五個碼互斥、看到哪一個就做哪一件事：

      | rc | 意思 | 你要做的 |
      |---|---|---|
      | 0 | 行程乾淨，網路上也沒東西 | 過 |
      | 1 | 有沒人追蹤的 app **行程**還在跑 | `ndt apps stop <name>` |
      | 2 | 某一條存活通道**看不到** | 查那一條，別當成 0 |
      | 4 | 行程都走了，**網路上還有東西**（窗內的流表規則／還握著的鎖） | 規則照它印的 `delete_flow_entry` 手動刪；鎖等 TTL 自己過 |
      | 5 | 行程都走了，**殘留查不了**（kernel 沒起來／讀不到流表／這個平面分不了窗） | **不是「乾淨」**。P4 平面永遠是 5——它的流表統計沒有時間軸 |

      🔴 **`|| exit 1` 這種寫法會在 P4 上永遠失敗**。把 orphans 當閘門的腳本要改成
      看得懂 4 與 5，或至少把 5 記進報告而不是當成通過。
- [ ] `ndt status --check` 的 `residue` 那一列**抄進報告**（2026-09-07 起有這一列）。
      `none` 才算問過了；`NOT CHECKED` 是沒問到，**不是乾淨**。
- [ ] `ndt status` 的 `knob baseline` 與 `tree vs round` 兩列**抄進報告**（I-3）。
      `p4_proxy/mininet/host_count_override` 還原＝**寫回**開工那個值，
      **不是 `git checkout --`**（那會給你 HEAD＝128）。`porcelain` 行數不是還原證據：
      2026-09-05 那次它從 22 掉到 21，而機器正好離開了基準。
- [ ] 本輪結論對帳舊結果：**推翻／更新／可對比哪一個**，三選一寫進報告。

### 6. 回報義務清償盤點（**常設**，不是特例）

**母體＝預註冊裡每一條「必須回報」的條款**，逐條回答「**回報在哪裡／檔案:行**」。
答不出來的就是**一筆未清償**。要涵蓋：註冊的假說與其結局區間、
任何寫成「不論結果往哪個方向都要報」／「兩個都要報」的、次要觀察、
控制組（陽性／陰性／發送端／負載閘）**有沒有發火**、中止條款**有沒有被觸發**、
註冊為「X 收案後再算」的、以及**對後續輪次寫下了後果的**。

🔴 **母體要用「條款」，不要用「關鍵詞」。** 08-31 首次執行時，
第一條漏報是靠 grep 一個**逐字字串**發現的——**那招在措辭被改寫時就失效**，
而三條漏報裡有兩條**沒有任何可 grep 的特徵字**。

🔑 **為什麼這件事非得做成清單**（08-31 同日兩例的共同形狀）：

| 例 | 漏掉的東西 | 方向 |
|---|---|---|
| ② AMENDMENT-1 §7.4 第 1 項 | 「fast 側可重現」；判準達成、後果條款也觸發 | **對我們有利** |
| ③ 的 `/proc/net/snmp` 收端讀出 | 每臂都採了，卻改引一個已知有問題的跨輪值 | **對我們有利** |

> **兩次都是漏掉對自己有利的證據 ⇒「忘記報」跟「想不想報」無關。
> 所以防它的不是誠實，是清單。**

**產出**＝一張表（輪／條款出處 `file:line`／註冊原文短引／是否清償／回報處 `file:line`／
未清償時資料本來會說什麼）。**在不同措辭或不同檔案下清償的要標出來**——
那正是「走條款不走關鍵詞」才抓得到的一類。

## 記帳的地方

- 缺口普查與成本數字：[KNOWN-ISSUES.md](KNOWN-ISSUES.md) §G。
- `audit-raw` 分支自身的說明：`git show audit-raw:README.md`。
