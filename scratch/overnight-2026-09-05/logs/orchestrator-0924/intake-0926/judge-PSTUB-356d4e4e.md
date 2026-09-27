# judge-PSTUB-356d4e4e (fix/probe-suites-stub-0927 @356d4e4e)

## 裁決：MERGE AFTER FIXES

範圍：全程唯讀，沒有執行任何東西，也沒有用 git。
- RULINGS 只讀了 item (a)，當作任務規格。
- `doc/audit/` 底下只讀了被 suite source 的兩個程式檔 `lib_e.sh`、`round.env`，沒有讀任何報告。
- 我抽查的 worktree 內容與 patch 一致：`lib_probe_stub.sh`、`mutate_probe_stubs.sh`、sample_rate suite 全檔一致，其餘五支 suite 的變更段落一致。

路徑前綴：
- `$WT` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927`
- `$LOGS` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`
- 沒寫目錄的 `*.sh` 在 `$WT/tests/shell`；`ndt`、`sudo_surface.sh` 在 `$WT/tools/test_workflow`。

總評：
- 沒找到能到 root 的路徑，數字也全部對得上。
- sample_rate 在「會回答的 OVS」下變紅的問題確實修掉了。
- 擋 merge 的是兩件小事：
  - B1：交付的註解和 SUMMARY 用一個被程式碼推翻的前提，來合理化對裁決的偏離。
  - B2：一條新宣稱已交付的非空洞防線，從來沒看過紅。

---

## BLOCKING（merge 前必修，都很小）

### B1. stub 的字句會改變 ndt 的判讀，也不是 CI 或閘門看到的字句。註解和 SUMMARY 必須改，並揭露這是偏離裁決

**裁決要什麼、stub 給了什麼**
- 【讀】裁決要的是「answering like today's R pass」（RULINGS-0927-suites.md:10）。
- 【讀】R 輪的 sudo 回 `sudo: refused by the nolab shim (a lab command)`（`$LOGS/scripts-pstub-356d4e4e/make_shims.sh:15-21`）。
- 【讀】stub 改回 `sudo: a password is required`（`lib_probe_stub.sh:39-44`）。

**字句會決定判讀**
- 【讀】`ndt_sudo_probe` 的 granted／refused 由字句決定（`sudo_surface.sh:179-182`）：`capture && return 0; ndt_sudo_refused && return 1; return 0`。
- 【讀】`ndt_sudo_refused` 只認五種字句（`sudo_surface.sh:145-154`）。R 輪字句不在其中，所以判 granted；stub 字句在其中，所以判 refused。
- 【讀】lab_handoff 每次 `bash "$NDT" status`（`test_lab_handoff.sh:76,170`）都無條件走到 `ndt_sudo_report`（`ndt:6938-6947`）。它的 allow-list 裡有 `sudo mnexec -a 1 true`，那正是 `sudo_surface.sh:88` 表上的探針，證明這條路有走到。

**同一支 suite 在三個環境走三個分支**【推】
- 改動前的閘門：`all 3 granted`。
- HEAD 加上 stub：`refused` 加 explain 區塊。
- CI：`command -v` 先擋（`sudo_surface.sh:176-177`），得到 `could not be tested`。
- 判定沒變，只是因為 lab_handoff 的檢查只讀 `lab` 區段（`test_lab_handoff.sh:76` 的 sed），sudo grants 那一列在 network health 區段。

**SUMMARY 引的證據測不到這件事**
- 【讀】SUMMARY §1 用「HEAD 在 R／L／L2 三輪逐條相同」證明字句沒差。
- 但 HEAD 三輪都是 suite 自己的 stub 在回答，外層 sudo 收到 0 次（`$LOGS/redfirst_stub.pstub-356d4e4e.log:18,27,36,45,54,64`）。外層字句根本到不了 ndt，所以這個比較測不到字句。

**CI 看到的不是這個字句**【推】
- CI 是 GitHub-hosted ubuntu-24.04（`$WT/.github/workflows/ci.yml:47`），這六支 suite 由 `l1_unit_tests.sh` 跑（ci.yml:97；`$WT/tools/test_workflow/l1_unit_tests.sh:449,464`）。
- runner 的 sudo 免密碼（ci.yml:54-55 非互動使用 sudo），而且沒有裝 OVS、mininet、ndtwin-lab（ci.yml:32-39）。
- 所以 CI 上多數探針根本不會呼叫 sudo（`ndt:6000`、`sudo_surface.sh:176-177`）。會呼叫的 lab_session（`ndt:1377`）拿到的是 `command not found`，不是 `a password is required`。

**要改的文字**
- `lib_probe_stub.sh:1-3`：「the way CI and every gate answer it today」。
- `lib_probe_stub.sh:11-12`：「the one path CI and the gates run」。
- `lib_probe_stub.sh:37-38`：「wording only, never a verdict」。
- 六支 suite 的註解塊，例如 `test_apps_stop_kills_the_group.sh:72-75` 的「cannot change its path」。
- SUMMARY §1。

**建議做法**
- 保留 stub 的字句：它讓 ndt 把拒絕讀成拒絕，R 輪字句反而讓 ndt 讀成 granted。
- 但要寫明這是偏離裁決，以及它對 lab_handoff sudo grants 分支的影響，交 orchestrator 追認。
- 不需要改任何行為。

### B2. closing check 的「PATH 上的 sudo 不是這支 stub」那一行從沒看過紅

- 【讀】這條防線在 `lib_probe_stub.sh:81`。
- 【讀】P1–P7 只從 allow-list 拿掉項目。P8 讓 `PROBE_STUB_LOG` 不存在，在 :78-80 就 return，碰不到 :81（`mutate_probe_stubs.sh:98-125`）。redfirst_p8 只驗 P8 的 escape 條件。
- 【推】刪掉 :81，現有 8 個 mutant 全部仍然 caught。依 CLAUDE.md「測試沒看過紅就不算交付」，SUMMARY §1 宣稱已交付的這條防線其實未交付。
- 【推】它正是 Q2 問的情境的唯一 in-suite 防線：stub 被 PATH 上另一支 sudo 遮住時，呼叫不會被記錄，allow-list 檢查就會空洞地綠。
- 修法：加 P9，在 install 之後把一個含 sudo 的目錄放到 PATH 最前面，closing check 必須紅在 `the sudo on PATH is`。再做 red-first：刪掉 :81 時 P9 必須 SURVIVED。

---

## 逐題

### 1. 每支 suite 是否不管 lab 狀態都走同一條路？

**沒有 sudo 繞過 PATH**
- 【讀】ndt 全部用裸的 `sudo -n`（`ndt:1377, 2970, 2987, 3078, 3082, 3436, 3463, 3478, 4454, 5258, 5271, 6103, 8919, 9026, 9034`）。
- 【讀】`LAB=/usr/local/sbin/ndtwin-lab` 永遠接在 `sudo -n` 後面（`ndt:55`）。sudo_surface 只經 `sudo -n "$@"`（`sudo_surface.sh:130`）。
- 【讀】cell_gate 的 `$LAB` 是 `sudo -n /usr/local/sbin/ndtwin-lab`（`round.env:30`，用在 `lib_e.sh:133-134`）。
- 【讀】以下寫法全部 0 處：`/usr/bin/sudo`、`command -p`、`env -i`、`PATH=` 重設、`$SUDO`、pkexec／su／runuser。範圍涵蓋 `tools/test_workflow`、六支 suite、`lib_e.sh`、`round.env`。
- 【讀】ndt 不改 PATH。子行程會繼承 export 過的 PATH（`lib_probe_stub.sh:61`）：honesty 的 `bash -c`、apps_stop 的 `setsid bash selfgroup.sh`（:498-509）、app_orphans 的 `in_ndt`（:465）。

**stub 在第一個探針之前就裝好了**
- 【讀】三支先 source ndt 的 suite：apps_stop（:69 → :80）、app_orphans（:73 → :84）、sample_rate（:29 → :42）。這沒問題，因為 source ndt 本身不探測：
  - 頂層只有變數設定、source `ports.sh`（表格）、source `sudo_surface.sh`（表格，自述 no side effects：:68, 85-90, 118）、`export TERM`、顏色、`declare -A`（`ndt:51-98, 9655`）。
  - ndt 在 :10658-10660 就 return。
- 【讀】cell_gate 在 :53 裝 stub，之後才 source `round.env`／`lib_e.sh`（:58, :61）。honesty 在 :70、lab_handoff 在 :60 裝，都在任何探針之前。

**stub 看不到或管不到的路徑**
- (a)【讀】honesty 子 shell 裡的 `sudo() { return 1; }` 函數（`test_ndt_honesty.sh:310,377,393`）：不經 PATH、不被記錄，但無害。
- (b)【讀】決定「要不要探」的機器狀態 stub 管不到：
  - `command -v ovs-vsctl`（`ndt:6000`）。
  - `command -v mnexec`、`command -v /usr/local/sbin/ndtwin-lab`（`sudo_surface.sh:176-177, 86-88`）。
  - 真的 `ps`：`ovs_daemon_running`、`bmv2_count`（`ndt:6011-6015, 109-114, 674-681`）。
  - 【推】因此 sample_rate 的路徑仍隨機器改變，判定則相同：
    - 有 live bmv2：走 p4 分支，0 次 sudo。
    - 有 ovs-vswitchd 在跑：走 unknown 分支，4 次 sudo。
    - CI：走 none 分支，0 次 sudo。
  - 所以註解裡的「cannot change its path」不成立。
- (c)【讀】lab_handoff 的完整 `ndt status` 還會讀這些非 sudo 的 lab 面向，stub 和 red-first 都沒有碰：
  - `/dev/tcp` 埠（`ndt:148, 6874-6876`）。
  - `curl :8000`（`ndt:6892-6894, 7078`）。
  - `/tmp/ndtwin_p4_switches.json`（`ndt:57, 6873`）。
  - `/usr/local/sbin/ndtwin-lab` 的 sha（`ndt:2609-2615`，經 6803）。
  - 行程表（`ndt:6764-6788`）。
- (d)【讀】closing check 只驗 `type -P sudo`（`lib_probe_stub.sh:81`），不檢查非特權的 tc／ovs-vsctl stub 有沒有裝上。
- (e)【讀】整輪 356d4e4e 的外層 shim log 是 0 行（`nolab_tripwire.pstub-356d4e4e.log:20`；`scripts-pstub-356d4e4e/tripwire.log` 為空）。也就是這台機器、這次執行，沒有任何呼叫漏到外層 shim。

### 2. closing check 是否非空洞？

- 【讀】NO STUB 分支看過紅（P8：`mutate_probe_stubs.pstub-356d4e4e.log:25`，f970d5b3 那輪 :25 也是）；allow-list 分支看過紅（P1–P7）。`type -P` 分支沒有，見 B2。
- 【推】不夠的地方：它只在頂層 shell、最後一刻檢查 PATH。以下寫法會繞過 stub、不被記錄，closing check 仍然綠：
  - `PATH=/usr/bin:/bin cmd`
  - `(export PATH=…)`
  - `env PATH=…`
- 【讀】目前六支 suite 和它們 source 的程式都沒有這種寫法。
- 【推】外層後援只有兩個，都只抓「走 PATH 的 sudo」：
  - mutate_probe_stubs 的 ESC 紀錄器（`mutate_probe_stubs.sh:33-41, 49-51`）。
  - 閘門的 tripwire。
  - 把 PATH 重設成系統目錄的呼叫會直接到真 sudo，三個紀錄器都看不到。
- 【讀】allow-list 只比對指令的 basename（`lib_probe_stub.sh:63-71`）。

### 3. `sudo: a password is required`、rc 1 是 CI 看到的嗎？

- 見 B1。rc 1 與閘門一致【讀：`make_shims.sh:20`】。字句與閘門不同【讀】，與 CI 也不同【推】。
- 【讀】依字句分支的地方有三處：
  - `sudo_surface.sh:180`（`ndt_sudo_probe`）。
  - `ndt:6095-6096`（`dataplane_ok`）。
  - `ndt:6238`（sflow）。
- 【讀】六支 suite 裡只有 lab_handoff 走到第一處。honesty 把 `ndt_sudo_report` 換成了 stub（`test_ndt_honesty.sh:172`）。
- 【推】cell_gate 會依 pane 長度分支（`lib_e.sh:145-154`），但三種字句都不到 64 字元，走同一支。

### 4. mutate_probe_stubs

- 【讀】P1、P2、P5、P6 拿掉唯一一項；P3、P4、P7 拿掉多項中的一項（`mutate_probe_stubs.sh:98-122`）。
- 【讀】錨點唯一性由 gate 自己強制：count ≠ 1 就算 SURVIVED（:66-67, 74-76）。8 個都 caught，所以每個錨點在它的 suite 裡恰好出現一次。
- 【讀】P4/P7、P6/P8 共用錨點，所以 check_gate_anchors 報 `ok(6)`（`check_gate_anchors.pstub-356d4e4e.log:114`），和 8 個 mutant 相容。
- 「為指名的理由而紅」：
  - 【讀】P5、P6、P8 的 log 直接印出被攔下的呼叫（log:22-25）。
  - 【推】P1–P4、P7 的理由欄是空的（log:18-21, 24），只能推論：同一輪 baseline 綠，唯一差異是 allow-list，且 0 escaped。
  - 【讀】caught 判準（:87-93）只要求 closing check 出現在 FAILED 行，不要求被攔的呼叫就是被拿掉的那一項。
- baseline 的拒絕：
  - 【讀】ESC 的 sudo 真的拒絕（:34-39，exit 1、不 exec）。
  - 【讀】「有 suite 漏到 ESC 就 rc 2」（:49-51）和「P1–P7 漏出 > 0 就 SURVIVED」（:84-86）兩條程式碼存在，但從沒看過它們觸發（UNTESTED）。
- 【讀】ESC 在 PATH 最前面（:41），也不會外洩：P8 的 4 次呼叫落在 ESC（log:25），外層 tripwire 是 0。
- 【推】可攜性：P5、P6、P8 能被 kill，靠的是這台機器真的有 ovs-vswitchd 在跑（`ndt:6001`）。在沒有 OVS daemon 的機器上它們會 SURVIVE。方向是 fail-loud，但 gate 沒寫明這個前提。

### 5. red first

- 【讀】base 在 L2 紅 4 條；HEAD 三輪都是 7 綠，check 逐條相同（`redfirst_stub.pstub-356d4e4e.log:57-64`）。f970d5b3 那輪逐行相同（`redfirst_stub.pstub-f970d5b3.log:57-66`）。
- 【讀】f47f3b45 那輪 stub 沒裝上，HEAD 在 L2 仍紅 4 條（`redfirst_stub.pstub-f47f3b45.log:59-62`）。這是「stub 才是修正因素」的附帶證據。
- 【推】「L2 = live OVS」有一半是真的：假 ps 只加 mininet 主機和 bmv2 列（`make_shims_live.sh:55-58`），沒有 ovs-vswitchd。base 的 L2 紅靠的是這台機器上真的在跑的 ovs-vswitchd。
- 【推】HEAD 的「三輪相同」實際上只變了 ps 列和非特權 ovs-vsctl，沒有變埠、curl、manifest、已安裝的 binary、ovs-vswitchd 在不在。
- 【讀】harness 會不會到 root：從構造上看不會。
  - live sudo 只印罐頭答案、不 exec（`make_shims_live.sh:19-36`）。
  - mnexec／iperf／ping 拒絕（`make_shims.sh:15-21`）。
  - 真 binary 只以一般使用者身分 exec（`make_shims.sh:32-55`）。
  - 開跑前後都拒絕真的 fabric（`redfirst_stub.sh:21,62`）。
  - 這是讀程式碼得到的結論，不是觀測；harness 本身沒有偵測絕對路徑 sudo 的機制。

### 6. tripwire

- 【讀】f970d5b3 那輪記到 4 行 `gates r3 sudo -n ovs-vsctl list-br`（`scripts-pstub-f970d5b3/tripwire.log:1-4`；`nolab_tripwire.pstub-f970d5b3.log:20-27`，rc 1）。
- 【讀】標籤整輪固定（`gates_stub.sh:24`），log 本身無法指出是哪個 gate。
- 【推】歸給 P8 成立，理由：
  - 唯一沒裝 stub 的 sample_rate 執行就是 P8。
  - 4 次正好等於 sample_rate 每跑一次的次數（P6：`4 sudo ovs-vsctl list-br`，log:23）。
  - redfirst 的 base 副本寫進自己的 `NOLAB_LOG`（`redfirst_stub.sh:26`），不會進外層 log。
  - 356d4e4e 加了 ESC 之後，同樣 4 次出現在 ESC，外層降到 0。
- 【讀】pstub2 的 tripwire 是 0（`nolab_tripwire.pstub2-356d4e4e.log:20-21`），但那一輪只涵蓋 redfirst_p8（`gates_stub2.sh:46-52`）。全套閘門的 0 看的是 pstub-356d4e4e。

### 7. 數字

- 【讀】六支 suite 的 check 數在各 suite 的 gate log 和 redfirst 表裡一致，每支都是 base + 1（多的是 closing check）：

  | suite | base | HEAD |
  |---|---|---|
  | apps_stop | 71 | 72 |
  | cell_gate | 12 | 13 |
  | lab_handoff | 18 | 19 |
  | app_orphans | 103 | 104 |
  | honesty | 345 | 346 |
  | sample_rate | 6 | 7 |

- 【讀】mutate_probe_stubs 是 8/0。
- 【讀】各 suite 的 mutation gate 分別是：apps_stop 13/0、cell_gate 6 個 mutant 0 存活、redirection_order 22/0、honesty 67/0、live_cells 35/0（另有 3 個對照與 16 項 fixture 檢查）、sample_rate 3/0。
- 【讀】anchors 121/121（log:136）。
- 沒有內部不一致。
- 【讀】但「每支 suite 都有自己的 mutation gate」只成立於 4 支：
  - 沒有任何 gate 跑 test_lab_handoff。
  - app_orphans 只被 `mutate_redirection_order.sh:43,198-199` 靜態引用。
- 【讀】措辭小瑕疵：SUMMARY 說外層「收到 16／32／8 次 sudo」，但 harness 計的是 sudo|ovs-vsctl|mnexec 三種（`redfirst_stub.sh:58`）。

---

## SUMMARY 各宣稱的判定

| 宣稱 | 判定 |
|---|---|
| 記錄並以 rc 1 拒絕，不捏造 rc 0 | SUPPORTED（sudo 部分；tc stub 見 N5） |
| 「就是 CI 和各閘門今天看到的答案」 | rc：閘門 SUPPORTED；字句：CONTRADICTED |
| 「ndt 只拿 stderr 選措辭，wording only」 | CONTRADICTED（`sudo_surface.sh:179-182`） |
| 「真實字句比 R 輪更接近 CI」 | UNDER-EVIDENCED，反向推論見 B1 |
| 「兩者對判定沒差：HEAD 三輪逐條相同」 | UNDER-EVIDENCED（引用的證據測不到字句） |
| NO STUB 會變紅 | SUPPORTED |
| 「PATH 上的 sudo 不是 stub 也會紅」 | UNTESTED |
| P8 密封、4 escaped、tripwire 0；redfirst_p8 | SUPPORTED |
| base L2 紅、HEAD 三輪相同、各 +1 | SUPPORTED（只涵蓋 sudo 答案和 ps 列） |
| 「沒有呼叫到達 root」 | SUPPORTED（讀程式碼得出，不是觀測） |
| 「外層一次都沒收到，全部被 stub 接走」 | 前半 SUPPORTED；後半在 L 下的 sample_rate 是空真（0 次 sudo）【推】 |
| 「絕對路徑 0 處」 | SUPPORTED（它 source 的程式也是 0） |
| 「Python HTTP 只有 honesty 那一處」 | UNDER-EVIDENCED：lab_handoff 的 `ndt status` 經 curl 讀 :8000（`ndt:6892-6894, 7078`），沒有 stub |
| 註解「a live lab cannot change its path or its verdict」 | path：CONTRADICTED；verdict：只在 harness 變化過的面向上 SUPPORTED |
| baseline 遇漏出以 rc 2 拒絕 | UNTESTED |
| merge-tree 乾淨、與 (b) 無共用檔 | 未驗（不得用 git）；patch 只動 `tests/shell` 的 8 個檔【讀】 |

---

## NOTEs（可排隊）

- **N1** 路徑仍會隨 ps、`command -v`、埠、curl、manifest、`lab_sha` 改變（見 1(b)(c)）。這超出本次裁決範圍，可以和 live-answer 變體一起另立範圍；註解照 B1 修即可。
- **N2** red-first harness 和 P5/P6/P8 都依賴真的 ovs-vswitchd 在跑。建議 gate 開頭先斷言這個前提，或在 gate 內用假 ps 固定它。
- **N3** caught 判準應該要求 FAILED 區塊裡含有被拿掉那一項的正規化字串。
- **N4** 補兩個 red-first：baseline 遇漏出以 rc 2 拒絕；P1–P7 遇漏出 > 0 判 SURVIVED。
- **N5** tc stub 對任何 argv 都回 rc 0（`lib_probe_stub.sh:45-50`），對會改變狀態的形式等於捏造成功。建議只有 `qdisc show` 回 0，其他回 rc 1。註解裡的「CI's answer」也不精確：CI 的 `tc qdisc show` 不是空的，只是沒有 netem【推】。
- **N6** closing check 不檢查 tc／ovs-vsctl 的 stub 是否在 PATH 上。
- **N7** allow-list 以 basename 比對，`sudo -n /任意目錄/ndtwin-lab status` 也會被當成允許。
- **N8** lab_handoff 和 app_orphans 沒有自己的 mutation gate。
- **N9** tripwire 的 `NOLAB_SUITE` 固定，無法歸屬到 gate；`gates_stub.sh:6-7` 寫著 p4hbr3、:24 寫著 r3，都是舊輪殘留（scratch 腳本，不影響交付）。
- **N10** 新加的「找不到 lib」早退只印 FAILED，不印摘要行（例 `test_apps_stop_kills_the_group.sh:78-79`）；同檔 `source "$NDT"` 失敗時會印 `Ran 1 checks, 1 failed`（:69），兩者不一致。

---

## 我會跑、報告沒跑的

1. **字句互換**：同一個 HEAD，把 stub 字句分別換成 R 輪字句和 `sudo: X: command not found`，跑六支 suite，diff lab_handoff 的 `ndt status` 全文和所有 check 行。
2. **P9 加 red-first**（見 B2）。
3. **子 shell PATH 繞過**：做一個 mutant，讓某個探針以 `PATH=/usr/bin:/bin` 執行，把 closing check 抓不到這個限制變成有紀錄的事實。
4. **模擬 CI**：假 ps 把 ovs-vswitchd 拿掉、PATH 裡沒有 ovs-vsctl／mnexec、helper 不存在，跑六支 suite 和 mutate_probe_stubs。預期 P5/P6/P8 會 SURVIVE。
5. **harness 沒變化過的面向**：在隔離容器裡放假的 :8000 graph、假 manifest、假 iperf3 行程、會回 netem 行的 tc stub，看六支 suite 的判定。
6. **CI 那條 lane**：在 HEAD 上跑 `bash tools/test_workflow/l1_unit_tests.sh` 和 `python3 tests/shell/check_test_tmpdirs.py`。
7. **真實 CI 環境**：在 ubuntu-24.04 容器（sudo 免密碼、沒有 OVS／mininet）直接跑六支 suite，看真實字句和實際走到的分支。
8. **base 對 head 逐條比對**：redfirst 現在只比 check 數量，應該逐條 diff base-R 和 head-R 的 check 行。
9. **可歸屬的 tripwire**：每個 gate 設不同的 `NOLAB_SUITE` 重跑 tripwire。

## 相關檔案（絕對路徑）

- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927/tests/shell/lib_probe_stub.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927/tests/shell/mutate_probe_stubs.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927/tests/shell/test_lab_handoff.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927/tools/test_workflow/sudo_surface.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927/tools/test_workflow/ndt`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927/.github/workflows/ci.yml`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_stub.pstub-356d4e4e.log`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_probe_stubs.pstub-356d4e4e.log`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pstub-356d4e4e/make_shims.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pstub-356d4e4e/make_shims_live.sh`

---
Orchestrator 09-27: B1 wording deviation RATIFIED (keep real sudo refusal wording; fix the false comments/SUMMARY); fix round B1+B2+N5+N2+N10; N1,N3,N4,N6-N9 queued.


---

# Round 2 -- scoped re-review of f9c59a44

## 裁決：MERGE（沒有 BLOCKING）

範圍：全程唯讀，沒有執行任何東西，也沒有用 git。
- 讀了：delta patch、SUMMARY §0 與改動過的段落、全部 `*.pstub3-f9c59a44.log`、`redfirst_stubfix.pstub3-f9c59a44.kept/` 的輸出、`scripts-pstub3-f9c59a44/`，以及 worktree 現況。worktree 與 patch 逐處一致。
- d32738b0 的重跑只讀到還沒跑完的部分：
  - `rerun-summary.d32738b0.txt` 只有三個 TRUNK 紅臂，屬於 (b)，與本交付無關。
  - `rerun-test_apps_stop_kills_the_group.d32738b0.log` 只寫到第 38 行，全部 ok，還沒有 rc。
  - 其餘五支 suite、mutate_probe_stubs、anchors、tripwire 行數都還沒出來，這部分我沒有讀到結論。

路徑前綴：
- `$WT` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-probe-stub-0927`
- `$LOGS` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`
- 沒寫目錄的 `*.sh` 在 `$WT/tests/shell`。

---

## 1. 兩個 BLOCKING 都已關閉

### B1：新文字對照 sudo_surface.sh 和 ndt 是準確的
- 【讀】`lib_probe_stub.sh:23-24`「ndt_sudo_probe decides granted / refused BY it … five wordings」，對得上 `sudo_surface.sh:145-154` 的五種字句和 `:179-182` 的判定邏輯。
- 【讀】`lib_probe_stub.sh:20-22` 對 sample_rate 三條分支的描述對得上程式：
  - p4 分支，0 次 sudo（`ndt:676`）。
  - unknown 分支，4 次 sudo（`ndt:674-681, 5999-6005`；P6 看到的就是 4 次）。
  - none 分支，0 次 sudo（`ndt:6001`）。
- 【讀】`lib_probe_stub.sh:31-37` 表格的前兩列已經實際觀測到（`redfirst_stubfix.pstub3-f9c59a44.log:10-21`）：
  - stub 的字句 → `sudo grants refused` 加上三行 REFUSED。
  - R 輪 shim 的字句 → `all 3 granted`。
  - CI 那一列標明是讀程式得出、沒有執行（`sudo_surface.sh:176-177, 199-201`），標示誠實。
- 【讀】舊的三句宣稱在 `tests/shell` 裡已經 grep 不到。
- 殘留的都是小瑕疵，列在 NOTE a、f、g、h。

### B2：P9 為指名的理由被殺，red-first 證明拿掉那一行後只有 P9 存活
- 【讀】`report()` 新增第 4 個參數，要求 closing check 紅的理由必須包含指定字串，否則判 SURVIVED（`mutate_probe_stubs.sh:112-114`）。P9 傳入的是 `the sudo on PATH is`（:162）。
- 【讀】實際結果：`caught … actual: 1 the sudo on PATH is /tmp/…`，0 escaped（`mutate_probe_stubs.pstub3-f9c59a44.log:27`）。這串文字只有 `lib_probe_stub.sh:111` 會產生。
- 【讀】red-first 做法：在 HEAD 的 sandbox 裡，用內容比對（count==1）刪掉那一行。它現在在 :111，是因為表頭變長，從原本的 :81 移下來（`redfirst_stubfix.sh:74-80`）。
- 【讀】red-first 結果：整個 gate `rc 1, 10 mutation(s), 1 survivor(s)`，唯一的 SURVIVED 是 P9「rc 0; the closing check did not go red」（`b2_gate_without_the_line.out:19,25`；`redfirst_stubfix…log:55-58`）。

## 2. N5：tc stub 已拒絕所有會改狀態的 argv，T1 對 tc 部分成立

- 【讀】只有完全等於 `qdisc show` 的呼叫回 rc 0；其他任何 argv 都會記錄並回 rc 1（`lib_probe_stub.sh:76-79`）。帶參數的唯讀形式也會被拒絕，這是保守做法，不是捏造成功。
- 【讀】ndt 只呼叫 `tc qdisc show`（`ndt:5981`）；P7 顯示 lab_handoff 有 13 次，行為不變。
- 【讀】T1 的判定是否 sound：
  - 契約檢查涵蓋：`qdisc show` 必須 rc 0 且無輸出；`qdisc add`／`del` 必須被拒絕；呼叫必須被記錄（`mutate_probe_stubs.sh:171-174`）。
  - HEAD 的 lib 若不符契約，gate 以 rc 2 拒絕（:181-182）。
  - T1 突變把 tc 改成「任何 argv 都回 0」，也就是 356d4e4e 的行為，被抓到（log:31）。
  - 拿 356d4e4e 真正的 lib 做 red-first 也違約（`redfirst_stubfix…log:41-45`）。
- 【推】安全性：契約真的會透過 PATH 執行 `tc qdisc add/del dev ndt-no-such-dev …`。萬一 tc stub 沒裝上，呼叫會落到外層 shim，或落到真的 tc。但這是非特權身分，而且裝置不存在（名稱 15 字元，合法），改不到任何東西。
- 缺口見 NOTE d、e。

## 3. N2：前提拒絕站得住，不會在這台筆電上誤拒；「拒絕而非假 ps」可以接受，但給的理由說過頭了

**判準和 ndt 用的是同一套**
- 【讀】`grep -qx 'simple_switch_g'` 等同 `ndt:111` 的比對；`grep -qx 'ovs-vswitchd'` 等同 `ndt:6013`；`command -v ovs-vsctl` 等同 `ndt:6000`。讀的也是同一支經由 PATH 找到的 `ps`（`mutate_probe_stubs.sh:56-59`）。
- 【推】comm 會截斷成 15 字元，檢查用的正是截斷後的 `simple_switch_g`，和 ndt 一樣。所以相對於 ndt 自己的判斷，不會有誤拒：
  - 只要它拒絕，ndt 必然走到探不到的分支（bmv2 在跑 → p4 分支；沒有 daemon → none 分支），P5／P6／P8 也確實殺不到。
  - 反過來，三項都成立時，ndt 必然會發出那個探針（`ndt:674-681, 5999-6005`）。
- 【推】在這台筆電上，實際會觸發拒絕的只有「有任何 simple_switch_grpc 在跑」，包括別人的 P4 lab 或孤兒 bmv2。拒絕本身正確，代價是 P4 lab 活動期間這個 gate 無法執行。

**red-first 只驗了一個分支**
- 【讀】拒絕發生在任何 suite 或 mutant 之前，並寫明缺的是哪一項（`n2_gate_head_no_ovs.out:1-3`）。
- 【讀】對照組：舊 gate 在假 ps 下，P5、P6、P8 存活，而且沒有任何說明（`n2_gate_base_no_ovs.out:14-19`）。
- 【讀】但只驗了「沒有 ovs-vswitchd」這一支；另外兩支見 NOTE c。

**理由說過頭**
- 【讀】`mutate_probe_stubs.sh:53-54` 的理由是：假 ps 也會被 apps_stop 和 app_orphans 讀到。
- 【讀】ndt 裡只有 `bmv2_count`（:112）和 `ovs_daemon_running`（:6013）讀 `ps -eo comm=` 這個確切形式。
- 【讀】作者自己的 N2 red-first 就把一支只改寫 `-eo comm=` 的假 ps 放在整個 gate 的 PATH 上（`redfirst_stubfix.sh:90-92`），apps_stop 和 app_orphans 的 baseline 照樣全綠，P1、P2 照樣被抓（`n2_gate_base_no_ovs.out:1-11`）。
- 【推】另一條路是只在 P5／P6／P8 那幾次執行（也就是 honesty 和 sample_rate）掛假 ps，apps 那兩支根本不會碰到。給的理由排除不了這條路。
- 【推】即便如此，拒絕本身是可以接受的選擇：它 fail-loud、不會造出假的 kill、也不引入一個自己可能說謊的儀器。

## 4. 其他改動與新破損

- 【讀】N10：六支 suite 找不到 lib 時現在會印 `Ran 1 checks, 1 failed`。lane 的 scorer 從 0/0 變成讀 1/1（`redfirst_stubfix…log:22-40`）。
- 【讀】其餘改動只有註解、tc stub、gate 本身。
- 【讀】pstub3 全部 rc 0，數字都對得上：
  - 六支 suite：72／13／19／104／346／7。
  - mutate_probe_stubs：10 個 mutation、0 存活（P1–P9 加 T1）。
  - 各 suite 自己的 mutation gate：13／6／22／67／35／3。
  - anchors 121/121，其中 mutate_probe_stubs 是 `ok(7)`，等於原本 6 個加上 P9；T1 沒有算在內，見 NOTE e。
  - tripwire 0 行，原始檔也是空的（`scripts-pstub3-f9c59a44/tripwire.log`）。
- 【讀】P1–P4、P7 的理由欄現在會印出來（log:19-25）。
- 【推】重跑的解讀提醒：d32738b0 重跑的 PATH 上沒有 ps／ovs-vsctl 的 shim（`stale/rerun-ab2.frozen.sh:13-15`），前提檢查看的是筆電真實狀態。若 mutate_probe_stubs 回 rc 2 並印出 `refused: …`，那是設計好的拒絕，不是回歸。
- 【讀】TRUNK 紅臂裡 group C 在 test_ndt_honesty 失敗（`stale/rerun-TRUNK_test_l1_shell_scoring.d32738b0.log:91-93`），取到的最後一行是「other-session …」。
- 【推】那是舊的靜態 last-echo 啟發法讀錯（honesty 用 printf 收尾），不是本交付造成的；本交付只在檔頭加了 N10 那一行 echo。其餘五支在 trunk 版 group C 下都是 ok。
- 【讀】SUMMARY §3 說「(b) 新 group C 在合併樹上 96/0」，我手上的材料沒有這份 log，重跑也還沒跑到，所以未驗。

---

## BLOCKING
無。

## NOTE（可排隊）

- **a.** cell_gate 那份註解是從其他 suite 照抄的：它說「Its PATH through ndt is not … ps, command -v, … decide which probes it makes」（`test_cell_gate_suspect_wiring.sh:47-48`）。
  - 【讀】但 cell_gate 不 source ndt，只 source round.env 和 lib_e.sh（:60, :63）。
  - 【讀】它的兩個探針無條件發出（`lib_e.sh:133-134`）。
  - 所以這句對 cell_gate 不成立。它是往保守方向寫錯，不會讓人誤信什麼保證。
  - 另外 honesty 註解說「every sudo it makes is recorded」，但它 fixture 裡自己定義的 `sudo()` 函數（`test_ndt_honesty.sh:312,379,395`）不會被記錄。
- **b.** 見 3：把 `mutate_probe_stubs.sh:53-54` 的理由改準確，或下一輪改成只在 P5／P6／P8 那幾次執行時掛假 ps（也能讓 gate 在 P4 lab 活動時照常跑）。
- **c.** 前提的另外兩支從沒看過紅：「bmv2 在跑」和「PATH 上沒有 ovs-vsctl」。建議補一個會列出 `simple_switch_g` comm 列的假 ps 當 red-first。
  - P4 其實也依賴 ovs-vsctl 這一支，但拒絕訊息只點名 P5／P6／P8。
  - 前提只在開頭檢查一次（:57）；跑到一半才起 bmv2，會以 SURVIVED 的形式出現，雖然會紅但歸因錯誤。
- **d.** 契約裡 sudo 和 ovs-vsctl 的檢查在這個 gate 內沒有鑑別力：
  - ESC 對 `sudo -n true` 回的是一字不差的同一句（`mutate_probe_stubs.sh:36-44`）。
  - 若 `--ovs-refuse` 的 stub 沒裝，呼叫會落到外層 shim 或真的 ovs-vsctl，非特權下同樣會拒絕 `list-br`。
  - 所以 ok 行寫的「sudo and ovs-vsctl refuse」不是由契約證明的。T1 的 tc 部分則成立。
- **e.** 兩個 gate 內部防線沒被 check_gate_anchors 或 red-first 覆蓋：
  - T1 的錨點寫在 inline python 裡，check_gate_anchors 看不到；錨點失配時 T1 會 SURVIVE（會紅），但訊息令人困惑。
  - `report()` 新增的「went red, but not on …」分支（:112-114）從沒看過觸發。
- **f.** 【讀】`lib_probe_stub.sh:29-30` 寫「reads the `lab` section and nothing else」，但 lab_handoff 也讀了 `ndt status` 的 rc（:171-172）。不帶 --check 時 rc 恆為 0（`ndt:7050-7074`），所以結論成立，只是措辭不精確。
- **g.** SUMMARY §5 仍寫「Python HTTP 只有 honesty 那一處」，漏了 lab_handoff 的 `ndt status` 經 curl 讀 :8000（`ndt:6892-6894, 7078`）。lib 的表頭（:19）已經涵蓋 curl :8000。
- **h.** 【讀】`sudo_surface.sh` 自己的註解（:59-61, :117, :137-139）仍說分類器只影響措辭，和同檔 :179-182、以及現在的 `lib_probe_stub.sh:23-24` 矛盾。這是既有問題、不在本次範圍，建議另開 ticket。
- 舊 NOTE N1、N3、N4、N6–N9 依 SUMMARY §5 排隊，照舊。
