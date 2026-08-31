---
name: install-manual-clean-room-test
description: "🔴 乾淨 VM 實測官網安裝手冊。**08-28 已結案**：v10 兩臂都失敗（tty 是幌子，17→0 證明變數生效而結果不變），成因是 p4-guide 的 patch 對 behavioral-model HEAD 過期；v8 乾淨室通過（2h01m、BMv2 1.15.5-fdd3b893、p4c 1.2.5.16）；`NDTwin-Kernel-P4` 已由 Adam 轉公開；外部模型抓到我 harness 結構上看不到的 cwd 陷阱鏈；快照 `v8-installed` 與 `test_section6.sh` 已就緒未跑"
metadata:
  node_type: memory
  type: project
  originSessionId: 50445b3c-51cd-4c3b-9364-d120dd6a72ff
  modified: 2026-08-31T11:32:55.566Z
---

## 🏁 08-30 這條線整個往前推了一大段 —— 先看這裡，細節在 repo

**§1–§5、§6.0–§6.7、以及「裝完能不能跑」全部第一次實際執行過。** 正本一律在
`doc/audit/2026-08-28_manual-verification-coverage/`：`FINDINGS-sections-1-5.md`、
`FINDINGS-section6-and-T2.md`、`FINDINGS-T3-user-manual.md`、`FINDINGS-T5-fixes.md`；
harness 在同目錄 `vm/`（**跑之前就 commit**，這次做對了）；raw 在 `audit-raw` 分支。

| 發現 | 一句話 | 狀態 |
|---|---|---|
| **M-1** | §1 只要求「Ubuntu 24.04 LTS」不說 Desktop 版，全篇用 `~/Desktop` **13 次卻從不建它** | **未修，Adam 待裁** |
| M-2 | §6.1 說安裝器建 6 個元件，24.04+v8 實際只建 3 個（gRPC 走 apt） | 未修，輕微 |
| **M-3** | 手冊叫你 grep `ECONNREFUSED`，軟體實際印 `Connection refused` | **T-5 已修** |
| **M-4** | User Manual Terminal 3 **停在三個手冊沒寫的互動提問**（答案是 1,1,2） | **T-5 已修**（改印旗標形式） |
| M-5 | 「等 ~60 秒」實測 80／85／80 秒 | **T-5 已修**（改成等訊息） |

🔑 **M-1 最毒的不是 `cd` 失敗，是下一行 `git clone` 成功**——clone 進 `$HOME`、
`rm -rf build` 在家目錄跑、最後 cmake 才報一個指向 repo 的錯，**距離真因五步**。
而且**它被 §2.6 那個「預期會失敗」的 callout 蓋住了**：同一個 `cd` 在 server 上因**兩個**
獨立原因失敗，同訊息同 rc，讀者照 callout 判斷「預期」就走過去了。

✅ **好消息（給教授那場 demo）**：`f00d69f` 的三個拒絕**逐字命中**；§6.1 的
`1.15.5-fdd3b893` / `1.2.5.16` 與頁面記錄**完全相同**；**照手冊裝完的 fabric 會轉發**
（links 32／paths 12／pingall 12/12 零丟包／discovery <5 s）。

⚠️ **T2-1 曾被我報成「fabric 不能通」，已撤回**——那是三個儀器缺陷疊出來的（`kill -0` 對
root 行程回 EPERM、`( … ) &` 的 `$!` 是 subshell 導致孤兒 proxy 佔住 8081、反向的 grep
樣式）。**兩個自己的讀數不一致時，那是關於儀器的發現，除非另有證明。**

📌 **T-6（Developer Manual `NDTwin Kernel API.md`）仍未開始**；§6.7（fast BMv2 build）
與 128-host 也**未跑**——上面所有數字都是 4-host。

---

2026-08-27。教授指定的交付:**下週交出 NDTwin P4 support 的完整官網文件,而且必須測試過
能正常下載那個領先公開 main 580 commit 的新版**。受測文件是我們自己改的
(`~/NDTwin-Website`,分支 `docs/p4-bmv2-environment`,`e71d1f9` 把 OS 下限提到 24.04)。

逐字輸出 `/mnt/win/ndtwin-vm/install-test.log`;報告 `~/Desktop/ndtwin-install-test-RESULTS.md`。

## 🔴🔴 08-28 **「v10 失敗」不是待證，是作廢**——產生它的那一輪對這個問題零資訊

> ✅ **後續：對照實驗已於同日跑完，本節的「兩個方向都沒有證據」已被取代。**
> **兩臂都失敗，成因是 patch 過期**（見檔尾「08-28 結案」第 1、2 節）。
> 本節保留，因為它記錄的是**為什麼那一輪必須作廢**——那個推理今天仍然成立。


**08-28 更正（`開機手冊`）。下面那一整段的前提是錯的，兩層都錯：**

**第一層——我引用的「3.5 分鐘正常建置中」是錯的讀數。**
那一輪實際跑了 **1 小時 43 分**（23:17→01:00），rc=0，而 bmv2 **沒有建**。
3.5 分鐘是它「當時看起來還健康」的一個中途時間點，**我把中途狀態當成了結果**。
🔑 又一次偏向比較好講的版本（見 [[the-clean-version-is-the-one-to-recheck]]）：
「重現跑得好好的」比「跑了一小時 43 分產出半套安裝」乾淨太多，而錯的方向永遠是這一邊。

**第二層——那一輪整個作廢，不算任何一臂。** log 裡機制自己指名了：

```
Found directory /home/tester/behavioral-model.  Assuming desired version ... already installed.
p4lang/behavioral-model install: 0 sec
```

⇒ 它看到 23:00 那輪留下的目錄就**跳過整個 bmv2 建置**然後 rc=0 收工。
**這正是預註冊裡混淆因子 #3 照字面發作**（「23:00 之後的 VM 已被動過，不能當任何一臂的起點」）。
⇒ **「v10 裝不起來」與「v10 裝得起來」兩個方向都沒有證據**，不是「證據較弱」。

## ✅ 但那一輪換到一個**獨立於 A/B**、現在就成立的事實

> **v10 對已存在的目錄靜默跳過，並且回傳 0。**

⇒ **使用者第一次失敗後重跑，會拿到一個宣稱成功的半套安裝**（rc=0、`p4c-bm2-ss` 在、
`simple_switch_grpc` 不在）。**不管 tty 那個對照怎麼落，這條都成立**，而且它是文件要寫的東西。
🔑 這是 [[failures-that-report-success]] 的第 13 型，也是「rc 是關於最後一個指令的」最乾淨的例子。

---

### 以下為 08-27 深夜原始記載，前提已被上面推翻，保留以供對照

兩次唯一找到的差別是他自己的執行方式：

```
setsid … < /dev/null          ⇒  沒有 stdin、沒有 controlling tty
dpkg-preconfigure: unable to re-open stdin:
debconf: unable to initialize frontend: Dialog … falling back to Teletype
```

⇒ 🔴 **「v10 在 24.04 上失敗」可能是「我卸離執行」的性質，不是 v10 的性質。**
**真實使用者在終端機裡跑不會處於那個狀態。**

⚠️ **而它已經被寫進官網文件並 commit（`8e36eab`，未 push）。**
⇒ **審查員裁決：文件那句暫停，等有 tty／無 tty 的對照跑完再定稿。**
**兩次不同結果本身不是結論**——一次成功換一次失敗，仍然不知道成因。

🔑 **這一整段的教訓比 v10 本身重要：**
**一個為了「讓它活過 ssh 斷線」而做的環境調整，改變了被測物的行為，並且差一步就變成對外文件裡的事實。**
與本檔下面那條「格式要求偷渡事實宣稱」是同一天的兩個實例：
**兩次都是我們的『怎麼跑』被寫成了它的『是什麼』。**

### 同一輪另外三個被收回的推論（全部是「間接指標取代直接查證」）

| 他當時說的 | 實際 |
|---|---|
| 「log 兩分鐘沒長 ⇒ 它 wedged」 | **輸出是分塊寫入的**，3.5 分鐘已超過 1065 行，cmake/gmake/z3 全在動 |
| 「早期失敗，磁碟沒動，不會有半個 object tree」 | 那 10 分鐘已 clone z3、建 libbpf、裝 89.8 MB |
| 「證據在磁碟上不會跑掉」 | 🔴 **`/tmp` 被清空了**（見下） |

### 🔴 `/tmp/p4guide.log` 被開機清空，不可恢復

```
/usr/lib/tmpfiles.d/tmp.conf:   D /tmp 1777 root root 30d
```
**大寫 `D` ＝開機時清空目錄內容**，與後面的 `30d` 年齡參數無關（小寫 `d` 才只按年齡清）。

⇒ 交接腳本真正的缺陷不是「失敗時也交接」，是**把不可恢復的動作（關機）放在證據保存之前，
而它保存證據的位置恰好活不過那個動作**。兩個錯誤單獨都不致命，合起來刪掉了診斷資料。

> 🔑 **通則（`開機手冊` 補完的後半句）**：
> **交接動作不能早於證據保存——而且「已保存」要驗證到「那個位置能活過交接動作」為止。**
> **「證據是安全的」本身就是一個需要驗證的宣稱，而它幾乎從來沒被驗證過。**

**⇒ 實務**：VM 內的證據寫 `~/`（活得過重開機）並**立刻 copy 出 VM**，不要留在 `/tmp`。

---

## ⚠️ 以下這節寫於 23:xx，其「v10 失敗」的部分已被上面那節降級為待證

## 🔴 08-27 23:xx：**B 段（§6.1）實測失敗，而失敗的原因是我們自己的修正**

乾淨 VM 照新版手冊走 §6.1 ⇒ **`install-p4dev-v10.sh` 跑 10 分鐘後 rc=1，
`simple_switch_grpc` 與 `p4c-bm2-ss` 兩個都沒裝上**，連帶 §6.2 `p4c rc=127`。

**選到 v10 的正是 `54c3c7a` 第四項改的規則**（「列目錄取最大版號」）。
舊規則是「跑指南指名的那支」，而指南只指名 v6/v7/v8 ⇒ **舊規則會選 v8，也就是 7 月裝成功的那支**。
⇒ **我們的修正把 §6.1 從「你不知道自己裝了哪一版」變成「你裝不起來」——比原缺陷嚴重。**

🔑 **而那個修正自己的「可驗證判準」擋不住它**：判準是 `head -40` 確認腳本檔頭有列 24.04，
而 **v10 第 34 行逐字寫著 `VERSION_ID in 22.04 24.04 25.10`**。**判準通過，安裝仍失敗。**
⇒ 見 [[verify-the-purpose-not-the-mechanism]]：**驗的是規則的機械動作，不是規則的結果。**

### 裁決（審查員）：**B —— 真的去跑一次 v8**

- §6.1 改回**指名 v8**，並寫死「**repo 有 v2–v10；v10 在 24.04 實測失敗（2026-08-27）。
  不要因為版號較大就改用它**」（`8e36eab`，本機 commit **未 push**）
- 判準改**釘在產物上**：`simple_switch_grpc` 與 `p4c-bm2-ss` 存不存在，**不看安裝器的 rc**
- 🔴 **必須真的跑一輪 v8（2–4 小時）**：教授的驗收條件逐字是「測試過能夠正常下載並安裝」，
  而 **§6.1 是這份文件裡唯一沒有乾淨室證據的一節**

### 🔑 我（審查員）在這裡犯的錯，值得單獨記

我要求「在同一行寫死『**2026-08-27 實測**』與 v8 裝出來的版本字串」。
**但今晚實測的是 v10 失敗，沒有人測過 v8。** 照我的字面寫，
就會**在要給外部讀者看的文件上，替一個沒跑過的安裝標今天的日期**。

`開機手冊` **拒絕照寫並說明理由**，改成兩個日期分開、各自標來源、明說 v8 自 **07-13** 起未重驗。

> 🔑 **一個「格式」要求可以偷渡一個「事實」宣稱。**
> 我下的是格式規定（日期寫在同一行），而它**預設了一個我沒查證的事實**（v8 今天被測過）。
> 執行的人照做，就等於替我背書。**不照做並說明為什麼，是這條指令鏈上唯一擋得住它的地方。**

⇒ 對應 [[disclosure-is-not-downgrading]]：我自己註冊的判準要對**每一個**宣稱各跑一遍，
**包括我自己下的指令裡隱含的那些**。

### `開機手冊` 留下的可引用句（已寫進官網文件正文）

> **A script declaring support is not evidence that it installs.**
> Whichever script you run, the check that decides whether it worked is not its exit status
> but whether the two binaries below exist afterwards.

## ✅ 08-27 16:5x:四項文字修正已進 repo(`54c3c7a`,**本機 commit,沒 push**)

三個擋人缺陷 + §6.1 選版規則都改好了。⚠️ **改完還沒在乾淨 VM 重跑驗收** ——
`--no-use-pep517` 與 `python3-venv` 兩項的修法本身在同一輪已逐條實測過,
但**「照新版文件從頭走一遍」還沒做**。下次開 VM 要從 `fresh` 快照重跑,不要從 `ovs-complete`。

## 🔴 三個會擋住使用者的缺陷(全部實測,全部有已驗證的修法)

**一、§2.3 `pip install ryu --no-use-pep517` 直接失敗,而且失敗得很安靜。**

```
ERROR: Disabling PEP 517 processing is invalid: project specifies a
       build backend of setuptools.build_meta in pyproject.toml
```

**Ryu 根本沒裝上。** 危險的是它**不明顯**:那節五道指令,**其餘四道照樣 rc=0**
(它們裝的是 eventlet/greenlet/dnspython),而 §2.4 的驗證
`pip list | grep -E "eventlet|greenlet|dnspython|ryu"` 會印出**四行裡的三行**。
**修法:刪掉 `--no-use-pep517`。** 裸的 `pip install ryu` 在 pip 23.3.2 / Python 3.8 一次成功,
裝到 ryu-4.34,而且四個版本**與文件列的預期輸出逐字相符**。

**二、§3.1 的 apt 會停下來等人 —— 是 `iperf3` 不是 wireshark。**

下載完 173 MB 之後卡在 `Start Iperf3 as a daemon automatically? [yes/no]`。
`-y` 不涵蓋 debconf。腳本化會**吊死並握住 dpkg 鎖**,後面每一步都做不了。
**修法:`sudo DEBIAN_FRONTEND=noninteractive apt install -y ...`**,一次通過。

**三、§6.3 `python3 -m venv` 失敗 —— `python3-venv` 不在文件的任何 apt 清單裡。**

```
The virtual environment was not created successfully because ensurepip is not
available. ... apt install python3.12-venv
```

**只有乾淨環境會現形**(開發機上這套件早就在了)。修法:加進 §3.2 的 apt 清單。
補上之後 §6.3 一次過:protobuf **3.20.3** / p4runtime 1.4.1 / grpcio 1.83.0。

## 🔴 兩個交付前的前提(非文件錯字,是狀態問題)

**四、§4.1 叫人 clone 的網址給的不是這份文件描述的產品。**
`https://github.com/ndtwin-lab/NDTwin-Kernel.git` 可匿名讀(HTTP 200 實測),但**落後 580 個
commit、沒有 P4 proxy**。新版在私有的 `ndtwin-lab/NDTwin-Kernel-P4`。
⇒ **程式碼公開之前,這份文件不可能通過教授的驗收條件。**
Adam 08-27 裁定:**把 `NDTwin-Kernel-P4` 轉公開**,「發佈那步我到時候再處理」。
本次測試用 `git bundle` 代替(`fix/flow-rate-divide-by-zero` @ `059a92c`),其餘每步都測透了。

**五、網站給人貼的 `intelligent_router.py` 落後 repo 1360 行**(724 vs 2084)。
文件叫你**貼舊的那份來跑**、**clone repo 來建 kernel** ⇒ 兩代混用。
(先前紀錄是 588 行;缺口在擴大。)

🔑 **08-27 追查:根因是「順序」不是「內容」,而且不能靠重產 snippet 修掉。**

- 安裝手冊 **§2.6(貼)排在 §4.1(clone)之前** ⇒ 讀者手工造一份,clone 下來又有一份同名檔;
  使用手冊用**裸檔名** `ryu-manager intelligent_router.py`(相對 CWD)⇒ 跑的是手貼那份。
  VM-Linux 頁還是**第三個身分** `intelligent_router_static_topo.py`(絕對路徑)。
  ⇒ **文件從來沒有指向 repo 裡的那份。** §2.6 移到 §4.1 之後就整類消失。
- 🔴 **重產 snippet 是危險的修法**:§2.6.3 叫讀者設 `is_mininet` ——
  **網站那份真的生效**(L32 賦值、L278 使用),**repo 那份 L602 在 module 層無條件覆寫回
  `True`** ⇒ 同一句指示在兩份上答案相反。repo 自己的註解就寫「EDITING THIS LINE DOES
  NOTHING」,是有人標註但刻意沒修(刪掉會改實體測試床的啟動時序)。
  ⇒ **修 drift 之前要先決定那一行留不留**,否則等於把假旋鈕寫進官網。

🔑 這是 [[committed-setter-uncommitted-reader]] 的第三面:**兩個 setter,後面那個贏**,
而**文件記載的是前面那個**。也是 [[replace-vs-add-bug-shape]] 的問法反過來用 ——
不是「舊資料什麼時候消失」,是「**我寫的值什麼時候被蓋掉**」。

## 🔑 §6.1「指南會指名當前的腳本」不成立

文件說「Do not pin a script version — the guide names the current one」。實測 p4-guide:
它指向的 `bin/README-install-troubleshooting.md` **只出現 v6/v7/v8**(v8 在第 142 行的範例裡),
而 repo 實際有到 **v10**,主 `README.md` **一支都沒指名**。
⇒ 照字面走會裝到 **v8**。v8 與 v10 都支援 24.04,所以不是裝不起來,是**你不知道自己裝了哪一版**。

**已改寫成不會腐爛的規則**(`54c3c7a`):`ls bin/install-p4dev-v*.sh` 取版號最大的,
再 `head -40` 確認它自己的檔頭有列 24.04。🔑 **關鍵是第二步不是第一步** ——
版號大不保證支援你的 OS,檔頭那行才是可驗證的判準。
`/mnt/win/ndtwin-vm/run_p4guide.sh` 已改成跑這個新規則(而不是寫死 v8),
因為**文件改了,要測的就是改後的文件**。

## ✅ 文件做對的地方(要留著,不要在改版時弄丟)

- **§6.6 是整份最有價值的預警**:新 clone 的 `bmv2_binary_override` 指向你沒有的
  `/usr/local/bmv2-fast/...`,而拓樸腳本**拒絕啟動而不是安靜退回 stock**。那個情況真的發生了。
- **§2.1 的 conda TOS 補充是準確且必要的**(實測真的被擋)。小瑕疵:它排在 `conda create` 之後。
- **§4.2 逐字可行**:cmake 23.9 s、`ninja -j2` **88/88 / 7 分 6 秒**、binary 11,830,480 bytes。
  順帶驗證了 §6.1 自己的宣稱 **`ldd build/bin/ndtwin_kernel | grep /usr/local` 是空的** ✅。
- §2.2 **沒有先 `apt update` 也成立**(cloud image 索引夠新);§3.2 Boost **1.83.0.1ubuntu2**
  滿足 ≥1.83;§3.3 OVS **3.3.9**、`mn --test pingall` **0% dropped**。

## 🔑 勘誤三條的最終裁定(`doc/2026-08-16_delivery-package/docs-errata.md`)

✅ **08-27 已執行(`5c91ff7`)**:第 1 條撤回,第 2 條補上「哪一支」的表,第 3 條註明重數。
🔑 **而且它已經擴散了兩處,兩處都會照著行動** —— 整合矩陣的發現 11、
以及 bmv2 草稿前言裡「**跟這條一起送給 patty**」的待辦。**只刪原始那條不夠。**

| # | 內容 | 裁定 |
|---|---|---|
| 1 | 「Ryu 要聽 6653,文件寫 6633」 | 🔴 **錯的,已刪**(08-21 三臂實測) |
| 2 | 「`sudo ./testbed_topo.py` 用錯直譯器」 | ✅ **仍有效,且正確指名了 NTG 頁** |
| 3 | 「端點實際 41 條、文件列 29」 | ✅ **08-27 重數仍是 41**,跨 580 commit 沒變 |

🔑 **第 2 條要補一句,否則維護者會修錯檔案 —— 有兩支同名的 `testbed_topo.py`:**

| | 行數 | 額外 import | 系統 python3 |
|---|---:|---|---|
| 安裝手冊 §5 給的(`assets/snippet/`) | 240 | 無 | ✅ **跑得動**(實測 3.12.3 全部 import 成功) |
| NTG 自己的(User Manual 的 NTG 頁) | 250 | `from network_traffic_generator import command_line` | ❌ 要 ntg-env |

## 可重用的測試床配方(不用動分割區)

**磁碟**:VM 映像放 Windows 那顆 NTFS(`/dev/nvme0n1p3`,89 GB 可用)。**不要縮分割區** ——
實體排列是 `[EFI][MSR][Windows 374.7G][Ubuntu 100G][修復]`,**Windows 在 Ubuntu 前面**,
所以「擴大 `/`」需要把 100 GB 檔案系統整個左移,是 GParted 最危險的操作。

```bash
sudo mount -t ntfs3 -o uid=$(id -u),gid=$(id -g),windows_names /dev/nvme0n1p3 /mnt/win
```
⚠️ Windows 用快速啟動/休眠關機時只能唯讀掛載。**三個檢查都要做**:`mount | grep ro`、
`df -h`、**`touch` 實際寫一個檔**(宣稱 rw 卻寫不進去是會發生的)。

工具:`qemu-system-x86_64 8.2.2` + `/dev/kvm` + `cloud-localds` **本機都已經有,不用裝**。
腳本在 `/mnt/win/ndtwin-vm/`:`vm.sh`(start/stop/snap/restore)、`wait_ssh.sh`、
`step.sh`(逐條記錄指令/輸出/rc/耗時)。快照:`fresh` / `after-deps` / **`ovs-complete`**。

## ⚠️ 三個方法論陷阱(這輪實際踩到的)

1. **exit code 在 `ssh -tt` 下不可信**:apt 收尾會 `E: Setting in Stop via TCSAFLUSH ...
   tcsetattr` 而回 **144**,但套件全裝好了。**一律用 `dpkg -s` / 實際輸出驗收。**
2. **但 `-tt` 必須留著** —— 沒有 pty 的話 debconf 自動退回非互動模式,
   **iperf3 那個提問就永遠不會現形**。忠實度比乾淨的 exit code 重要。
3. **`grep -c` 計數為 0 時 exit status 是 1** —— 我寫
   `n=$(... grep -cE "^(ninja|cc1plus)$" || echo 1)`,於是「零個編譯行程」被翻譯成「有一個」,
   等待迴圈永不 break,**白等 20 分鐘、P4 安裝一步沒跑**。同族見
   [[failures-that-report-success]]。

相關:[[ndtwin-official-docs-site]]、[[ndtwin-website-repo-and-build]]、
[[vm-on-this-machine-is-invisible-to-ndt-status]]。

## 🔴 08-27 夜：**「未照新版重跑」的原因不是忘了，是權限分類器**

17:54 交接之後，開機手冊 session 的**下一個開 VM 的工具呼叫直接失敗**：

```
claude-sonnet-5[1m] is temporarily unavailable, so auto mode cannot
determine the safety of Bash right now.
```

⇒ **17:55 → 21:22 那 3.5 小時 VM 一次都沒開過。** 我掃 `/proc` 只看到一顆閒置的
`claude-cowork-vm`（8/25 起、0.3% CPU），**那個觀察證明的是「沒開始」不是「已完成」**——
兩者的 `/proc` 讀數一模一樣。

## 🔑 這份工作要分兩段排，因為兩半的 CPU 帳完全不同

| | 內容 | CPU |
|---|---|---|
| **A 段（§1–§5）** | apt、下載、pip、`ninja -j2` 建 kernel | **輕**，多半是網路 I/O；只有一段 **7 分鐘**的 4 vCPU 編譯 |
| **B 段（§6.1）** | p4-guide 從原始碼建 PI + bmv2 + p4c | 🔴 **2–4 小時飽和，而且負載在期間內大幅擺盪** |

🔑 **三個擋人缺陷全在 A 段**（§2.3 ryu 旗標／§3.1 iperf3 debconf／§3.2 python3-venv）。
⇒ **A 段可以與別人的實驗並行，B 段不行。**
⚠️ **擺盪比穩定高負載更難處理**——穩定負載可以當成臂的一個條件，擺盪讓量測不可重現。

映像在 **`/mnt/win/ndtwin-vm/disk.qcow2`**（`/mnt/win` 有 83 GB），
**與 `/` 上的 kernel build 是不同檔案系統，不共用空間**。

## 本輪的價值不是「三個修法會不會動」

前三項的修法在 08-27 各自**單獨實測過**。本輪要答的是
**「照新版從頭走一遍，會不會冒出第四個問題」**。

⚠️ **§4.1 永遠測不到**：clone 網址指向**落後 580 commit** 的公開 repo ⇒ 只能用 `git bundle` 代替。
**Adam 08-27 裁定：記成已知缺陷，不動公開 repo。** 報告要明寫那一步是**替代而非驗證**。

📌 §2.1b 的 `conda create` 失敗**已排除，不是文件缺陷**（下載 IncompleteRead，重試即過）。
但那次失敗的形狀進了 [[failures-that-report-success]]（**四格中第四格是推論、尚未量測**）。

---

# ✅ 08-28 結案：v10 的失敗有機制、v8 通過乾淨室、repo 已公開

**08-27 那節「在途狀態」已全部解決，整節刪除。以下是結論。**

## 1. tty 對照跑完 —— **預註冊第 3 列（兩臂都失敗），而 tty 是個幌子**

| | NOTTY | TTY |
|---|---|---|
| 注入斷言 | `controlling_tty: NO`、`tty` 為 `?` | `controlling_tty: YES`、`/dev/pts/0` |
| 牆鐘 | 13 分 | 16 分 |
| 產物 | 三個全缺 | 三個全缺 |
| 死在哪 | `patch -p1` → `Hunk #1 FAILED` | **同一行** |
| **debconf tty 抱怨** | **17** | **0** |

🔑 **最有力的一格是「17 → 0」**：變數**確實生效**（抱怨全消失），**而結果完全沒變**。
⇒ 不是「操作沒作用所以看不出差別」，是**操作有作用、且與結果無關**。
⇒ **08-27 那個「可能是我卸離執行造成的」懷疑，被我自己的實驗否證。**

**我在跑臂 2 之前寫下的預測（同一個 patch 步驟、三個產物全缺、牆鐘同量級）三項全中**，
依據是機制（`patch(1)` 不讀 `/dev/tty`）而不是外插。

## 2. 🔑 真正的成因：**p4-guide 的 patch 對 behavioral-model HEAD 過期**（時間相依）

安裝器把 `behavioral-model` clone 在**移動中的 HEAD**（`INSTALL_BEHAVIORAL_MODEL_SOURCE_VERSION`
預設為空 ⇒ 不釘），拿到 `fdd3b893`（2026-08-24）。**behavioral-model 加了 SPDX 授權標頭**，
`install_deps.sh` 開頭改變，patch 的上下文對不上。

`patch -p1 --dry-run`（逐個記 rc，對 HEAD `fdd3b893`）：

| patch | 誰用 | rc |
|---|---|---|
| `behavioral-model-support-fedora.patch` | **v10** | **1** |
| `behavioral-model-support-venv-thrift-0.22.0.patch` | **v10** | **1** |
| `behavioral-model-adjust-ubuntu-packges.patch` | **v8** | **0** |
| `behavioral-model-support-venv-2026-apr.patch` | **v8** | **0** |

⇒ **不是 24.04、不是機器、不是 tty、不是 behavioral-model 本身。**
⇒ **v8 今天能用不是 v8 的性質**，是它那兩個 patch**剛好還套得上**。同一類故障隨時會輪到 v8。

## 3. ✅ v8 乾淨室通過（2026-08-28）

同一個 `ab-base` 快照、同一個釘住的 p4-guide `a2f9f8c5`、tty 臂、**臂內無暫停**。

- 10:42:21 → 12:43:19（**2 小時 1 分**），12 GB 磁碟
- `simple_switch_grpc` **PRESENT** `1.15.5-fdd3b893`、`p4c-bm2-ss` **PRESENT** `1.2.5.16`
- **驗到目的不只是機制**：`p4c-bm2-ss` 實際把最小 `v1model` 程式編成 **4114 bytes** 的 BMv2 JSON

🔑 **版本字串裡的 `fdd3b893` 把機制釘死**：那就是 v10 patch 套不上的那個 commit
⇒ **v8 從完全相同的上游原始碼建成** ⇒ **同一個輸入、不同的處理、其中一個成功**，
比任何 A/B 都乾淨，因為**版本字串直接證明了輸入相同**，不需要假設。

📌 **08-27 被審查員擋下的那句「v8 於某日實測」現在成立**——因為真的跑了，不是因為格式需要它。

## 4. 🔴 交付真正的阻礙（已解決）：**整個 §6 對照著讀的人跑不起來**

§4.1 叫讀者 clone 公開的 `ndtwin-lab/NDTwin-Kernel`，而 §6.2–§6.7 用到的
**每一個 P4 檔案那個 repo 都沒有**（`p4_proxy/` 整個、兩個 P4 拓撲 JSON、
§6.4 要改的兩個設定欄位 **0/2**）。失敗形狀是最壞的：§6.2 的 `mkdir -p` 會在錯的 repo
裡開心地建空目錄，讀者以為在前進；§6.4 的 `AppConfig.hpp` **會存在**（§4.2 的 cmake 產生），
讀者找不到那兩個欄位，最自然的結論是「我版本拿錯」而不是「這 repo 沒有 P4」。

**Adam 裁定：公開 `NDTwin-Kernel-P4`。已完成——他自己執行的。**
`main` 分支由我建立（`git push p4 HEAD:refs/heads/main`），他改預設分支並轉 Public。

⚠️ 見 [[local-git-refs-cannot-tell-you-what-is-public]]：**三個 session 同一天各自對
「這是不是公開的」下了錯誤斷言**，而那是 `gh repo view --json visibility` 一行能查的事。

## 5. 🔴 外部模型只讀文件，抓到我結構上看不到的東西

DeepSeek + Muse Spark 各只讀手冊、不執行，共 21 條，**收斂的 5 條全部成立**，我推翻 2 條。
最重要的是一條**四步驟工作目錄陷阱鏈**（§4.2 `cd build` → §5、§6.1 沒有 cd → §6.4 `rm -rf build`）。
**我的 harness 每條指令都帶絕對路徑或自己 cd，所以結構上永遠踩不到。**
詳見 [[harness-cd-hides-working-directory-defects]]。

## 6. 交付範圍比原本以為的大

安裝手冊只是 12 份文件之一。**還有一份獨立的 User Manual**
（`NDTwin User Manual/NDTwin Kernel/Operate an Emulated (Software) Network/`），
32 處提到 P4，講「裝完之後怎麼啟動 P4 fabric」，**安裝手冊的結尾就指向它**。

它的品質其實不錯（已寫「用 manifest 確認不要只看訊息」、「等數字停止變動」）。
**08-28 對過原始碼，可查證的宣稱全部正確**：
manifest `/tmp/ndtwin_p4_switches.json`（`p4_testbed_topo.py:28`）、
proxy 8081（`main.py:356`）、gRPC 50051 起、16256 = 128×127、
**288 條邊與拓撲 JSON 完全相符**（138 節點）。
🔴 **但它從來沒有被端到端執行過。**

## 7. 現成可用的東西（不要重做）

- 快照 **`v8-installed`**（`/mnt/win/ndtwin-vm/disk.qcow2`）＝ §6.1 已完成的狀態
  ⇒ **測 §6.2 起不必再花兩小時重裝工具鏈**
- **`/mnt/win/ndtwin-vm/test_section6.sh`** ——§6.0–§6.6 的測試腳本，語法檢查過、**尚未執行**。
  🔑 它刻意**在同一個 shell 裡保留步驟間的工作目錄繼承**，因為那正是我原本測不到的那類缺陷。
- `ab_prepare_base.sh`／`ab_arm.sh`（含注入斷言與五條混淆因子）、
  `vm.sh`（含 `exclusive_cpu` 守衛與 `VM_DRY_RUN`）

## 8. 手冊的改動（`~/NDTwin-Website`，分支 `docs/p4-bmv2-environment`，**本機 commit 未 push**）

`4c42108` §4.1 兩個 repo 的選擇 ＋ 新增 §6.0 一秒的 `ls` 檢查
`b41b9e4` 工作目錄鏈 ＋ conda 初始化 ＋ TOS 順序 ＋ OVS 驗證改成驗 daemon ＋ 6.7 補 clone ＋ 佔位符解掉
`39a8462` §6.1 寫入 v8 的實測結果


---

# 🏁 08-28 下午：§6 全過、使用者手冊首次實跑、而 §6.6 是錯的

## 9. 🔴 §6.6 的指示照做起不了 fabric（交付級，已修 `f00d69f`）

原文：「沒建 performance build 就**把那行註解掉**」＋「第一個非註解行勝出，所以註解掉會**選 PATH 裡的 stock**」。
**兩句都錯。** 不是用讀的，是在乾淨 v8 上**直接呼叫 `resolve_bmv2_launcher()`** 四種狀態各跑一次：

| 檔案狀態 | 實際 |
|---|---|
| 出廠（`bmv2-fast`，不存在） | REFUSES `names no executable` |
| **註解掉**（§6.6 教的） | **REFUSES** `has no directive line` |
| **刪檔**（§6.6 教的） | **REFUSES** `no bmv2 binary override at …` |
| 寫 `/usr/local/bin/simple_switch_grpc` | **STARTS** |

🔑 **程式自己的錯誤訊息就寫著答案**：「Commenting the line out **used to** re-select the stock
build silently; **it now refuses**」——**手冊停在 `used to` 那一版**。
⇒ 可操作：**看到「舊行為 vs 新行為」的錯誤訊息，先去查有沒有文件還停在舊版。**
⚠️ `/usr/local/bmv2-fast/` 在 stock 安裝後**不存在**、stock binary **存在** ⇒ **每個沒自建 fast build 的讀者都會踩**。
同一句錯誤**複製到使用者手冊 pre-flight 第 4 條**，兩個引用點一起改。

## 10. ✅ 使用者手冊 P4 啟動段：首次 end-to-end，**全部成立**（4-host）

`2 → 12 → 12 → 12`，收斂在 **12 ＝ 4×3**，與文件一致。
🔑 **第一個樣本真的是 2 不是 12** ⇒ 手冊那句「不要把第一個大值當作完成」**有實測支持了**。
kernel 起得來、`:8000` 回 200、log 看得到 10 台 switch `inform_switch_entered`。
🏁 **128-host 已補測（08-28 傍晚）：16256 完全吻合。**
📌 **而我先前「4 vCPU 跑不動所以不測」的理由是錯的**——兩種 fabric 都是**同樣 10 台 bmv2**，
變的是 netns 數與路徑集合大小；**VM loadavg 只有 0.33**。
🔑 **成本被歸給了看起來變大的那個量詞（host），而不是真正驅動它的那個（switch）。**

### 🔴 收斂軌跡才是這輪最有價值的東西

| t | paths |
|---:|---:|
| +1 s | 155 |
| +4 s | 11424 |
| **+8 s** | **16224** ← **差 32，是最終值的 99.8%** |
| +11 s | 16256 |
| +15 s | 16256（不動了） |

**16224 大、穩、而且錯。** 只取樣一次的人在 +8 s 會開 kernel，
拿到**永久少 32 條路徑**的分身，**而且沒有任何 log 會講**。
⇒ 手冊原本就警告「不要把第一個大值當完成」，**現在那句話底下有實測了**，已寫進手冊（`d6f62f3`）。
📌 mainDev 事前警告「kernel 側（`calFlowPathByQueried` 那一族）不一定撐得住 1355 倍」——
他要我「把收斂時間當讀數而不是等待」的建議是對的，**這張表就是因此才存在的**。

🔴 **但他那個歸因本身不成立，而查證方式值得記**：他警告我跑的是 1 Hz 的 `a40e04ce`。
實際上 ①**我在 VM 裡跑，kernel 是 VM 自己從公開 `main`（`20cd80b`）現編的**，
②**更決定性：輪詢期間 kernel 根本沒起來**（`run.log` 第 23–29 行是輪詢，第 35 行才 T3，
kernel 第一行 log `07:59:47` 在輪詢之後）。
⇒ **`all_destination_paths` 是 proxy 算的**（`ryu_topology.py:191 render_destination_paths`
從 proxy 自己的圖算全對路徑；kernel 的 `fetchAllDestinationPaths` 只是**消費**）
⇒ **`kFlowPathRecomputeInterval` 在 `FlowLinkUsageCollector` 裡，和這條曲線無關。**
（仍查了：`2f57ba5` 是 `20cd80b` 的祖先、`.hpp:51` 就是 `seconds(1)`，**VM 那顆也是 1 Hz**——
不適用不等於不用查。）
🔑 **他的推論形狀＝「用這台機器上那個位置的東西，推另一台機器上跑的是什麼」**，
和他早上「查 PATH 的 binary 而 fabric 跑 `/usr/local/bmv2-fast/`」同型。

🆕 **儀器補強（他抓到的）**：「計數第一次停止變化」**單一空洞就誤判**——
一次卡住的 poll 剛好跨過真正的變化，讀起來和收斂一模一樣。已加 `maxgap`／`errs`，
並用**重播測試**證明抓得到（餵一組卡 15 秒的樣本：舊統計量說「21s 乾淨收斂」，
新統計量說「最長間隔 15s ＝ 3s 節奏的 5 倍，不可信」）。
🔑 **「它不再變了」和「我不再看了」產生同一個讀數。**

## 11. 🪞 兩個「儀器壞了被讀成受測物壞了」

1. **`mininet/clean.py:69` 會 `rm -f /tmp/*.log`** ⇒ 我的 `/tmp/t1.log` 被**受測物自己刪掉**，
   行程握著 fd 繼續寫。我看到 180 次 `No such file` 讀成「T1 起不來」，
   **而 fabric 從頭到尾好好的**（manifest 在、10 台 switch 在聽）。詳見 [[evidence-must-outlive-the-handoff]]。
2. **proxy 存活**看起來像手冊的關機步驟有問題 —— **不是**。
   pid 檔記到 **wrapper（4064）**，真正 serve 的是**子行程 4066**；直接對 4066 送 SIGINT 它就退了
   ⇒ **真人按 Ctrl+C 會成功，錯的是我的自動化**。
   🔑 **「照文件做」與「用腳本模擬照文件做」不是同一件事**：Ctrl+C 打的是整個前景 process group。
   （仍加了一條「確認 8081 released」的檢查，因為殘留的 proxy 會讓下一輪對著死掉的 fabric 講話。）

## 12. ⚠️ 我自己的量測指令又被自己的 argv 污染

`ssh '... ps -eo args= | grep -c "[s]imple_switch_grpc"'` 回報 2/2/3，**全是假的**——
`ps` 看得到那條 ssh shell，而它的 argv 裡就有那個字串。**bracket 只保護 grep 自己的 argv。**
改成 **scp 一個腳本檔進去跑**才拿到真值（0/0/0，proxy 1）。見 [[put-measurement-commands-in-script-files]]。

## 13. 現況

- 網站**五個** commit 本機未 push：`4c42108` `b41b9e4` `39a8462` `f00d69f` `a37e08b`
- ~~🔴 這台機器沒裝 hugo ⇒ 改動無法在本地 render 驗證。~~
  **🔻 08-28 更正：這句已經是假的。** `~/.local/bin/hugo` = v0.165.0 **extended**、在 PATH 上，
  `hugo` 對網站 repo 跑得出 126 頁 exit 0（見 [[ndtwin-website-repo-and-build]]）。
  ⇒ **本地 render 驗證是做得到的，沒有人做而已。**
  - 🔴 **這個更正有下游**：我當時「避開 Docsy `alert` shortcode、改用手冊既有的 blockquote」，
    **理由是「沒法本地驗」——理由沒了，規避還留在手冊裡**。要嘛驗一次 `alert`、要嘛明講是風格選擇。
  - ⚠️ **仍然為真的只有這句**：**排版還是沒有任何人真的看過一眼。** 工具在、人沒做。
- `vm.sh` 現在有 **7200 s 自帶期限的 watchdog**（三條路徑都實測），抄自 mainDev 的
  「清理不能依賴父行程活著」。

---

# 📋 08-28 晚：手冊驗證覆蓋清單（已驗／未驗／驗不了）

📌 **前提更正**：Adam 已裁「**那個我要等全部測試完再公開**」⇒ **24 顆 commit 留在本機是決定不是阻塞**，
不要列成待辦、不要找繞法、不要再問權限。**時間壓力因此解除，品質優先於速度。**
🔑 可轉移：**「某人沒回應」與「某人已決定」在待辦清單上長得一樣**，而前者要追、後者追了是噪音。

## ✅ 已驗
§4.1（未認證 clone、`main`、`20cd80b`）／§6.0／§4.2（ninja 90/90）／§6.1（v8 乾淨室 2h01m，
判準是兩個 binary 存在不是 rc）／§6.2（JSON 75,852 B 真的 parse）／§6.3（`import p4.v1.p4runtime_pb2`）／
§6.4／§6.5／**§6.6（四種檔案狀態各跑一次真 resolver）**／**cwd 鏈**／
**使用者手冊 P4 段 4-host ＋ 128-host 全程**（12 與 16256）／手冊自己的 `pgrep` 警告（10 vs 0）／
排版（hugo 0.154.5、126 頁 exit 0）

## ⚠️ 未驗（做得到，沒做）
🔴 **最該補：§2.1–§2.7、§3.1–§3.3、§5 改版後從未重跑。**
`b41b9e4` 改了 §2.1 conda init／§2.5 Ctrl-C／§3.3 `systemctl is-active`／§5 全路徑，
**而我的 §6 測試是從 `v8-installed` 起跑的——那顆快照裡 §1–§5 是照舊版文字做出來的。**
⇒ **這是唯一「文件被改過而改動從未端到端驗證」的一項**，要從 `fresh` 快照重跑。

其餘：§6.7（optional fast build，數小時）／**P4 段的 Generating Traffic**（只驗到端點回 200，
**沒真的送 iperf3、沒確認流出現** ⇒ 「端點活著」≠「功能對」）／使用者手冊的 **OVS 三終端機段**（整段沒跑）／
§2.6 snippet 落後 1360 行（要先定 canonical，重產是危險修法）

## 🆕 08-29：Generating Traffic 改判準後**已驗**（從「未驗」那欄移出來）

原本只驗到 `/ndt/get_detected_flow_data` 回 **200** ⇒ 那不是那個宣稱。
改成**在 body 裡找到那條流**（對照 baseline 實測是 `200 / 2 bytes / []`）：
**偵測是對的**，兩個方向 5 秒內出現、歸屬正確、`path` 是 `10.0.0.1 → s1 → 10.0.0.2`。
**但手冊的驗收句兩支都叫通過，而且時序讓讀者走不到有訊息的那一支** ⇒ 已修 `f17d2c5`（未推）。
完整經過與三個結果見 [[api-flow-list-inflated-by-idle-timeout]] 檔尾，
正本 `doc/audit/2026-08-28_manual-verification-coverage/GENERATING-TRAFFIC.md`。

⚠️ **一個未控制的偏差，如實記著**：那一輪用的是 mainDev 留下的 fabric，
跑 `/usr/local/bmv2-fast/bin/simple_switch_grpc`（§6.7 的**選配**建置），
**不是手冊主線裝的 stock binary**。對「API 會不會回報一條流」不太可能是關鍵，但**沒有控制**。

📌 §1–§5 的重跑腳本已寫好、語法檢查過、§2.6 的 sed 乾跑驗過（只動一行、還能 parse），
`fresh` snapshot 用 `qemu-img snapshot -l` 確認存在（**沒有開機**）：
`/mnt/win/ndtwin-vm/{guest,test}_sections_1_5.sh`。
🔑 driver 會**先斷言那真的是 fresh**（conda/mn/ovs/cmake 全不在）才往下走——
錯的 snapshot 會給出一個全綠但什麼都沒回答的結果。
🔑 而且它推的是**網站的** `assets/snippet/*.py`，不是 repo 那份——
§2.6 叫讀者貼的是網站那份，而**以前每個 harness 都讀 repo 那份**（見本檔的 harness/reader 分裂）。

## 🚫 驗不了（附理由——這欄最容易靜默消失）
硬體頁（需要 HPE 實體交換機，我只能查它引用的檔存不存在，查了，在公開分支上）／
VM-Linux 頁（需巢狀 VM，**且不提 P4** 故不在本次範圍）／
**實際瀏覽器外觀**（能 render 能驗結構，不能在不同寬度下真的看 ⇒ 「語法對」≠「好看」）／
時間宣稱在別台機器（15 s 收斂、2h01m 都是這台的讀數）／教授的驗收標準（人的判斷）

## 🔴 08-29 22:5x — **`/mnt/win` 目前沒有掛載，本檔所有 `/mnt/win/...` 路徑當下都構不到**

`8/29 auditor` 實測（不是推論）：

```
mountpoint -q /mnt/win     -> NOT a mountpoint
ls /mnt/win/ndtwin-vm/     -> No such file or directory
```

⇒ 本檔至少八處引用 `/mnt/win/ndtwin-vm/...`（`:15` log、`:221` `run_p4guide.sh`、`:266` `vm.sh`／`wait_ssh.sh`、
`:307` `disk.qcow2`、`:412` 快照 `v8-installed`、`:414` `test_section6.sh`、`:562` `{guest,test}_sections_1_5.sh`），
**這些在重新掛載之前全部指向不存在的路徑**。

**掛回來的指令本檔 `:260` 就有**：
```bash
sudo mount -t ntfs3 -o uid=$(id -u),gid=$(id -g),windows_names /dev/nvme0n1p3 /mnt/win
```

⚠️ **強度**：我只驗到「現在沒掛載、路徑構不到」。**我沒有驗證磁碟內容還在、也沒有實際掛回來過** ——
「掛回去就會找到」是推論，不要當結論。

🔑 **為什麼這條值得寫**：`ndtwin-current-state.md` 的 §14-12 把
`{guest,test}_sections_1_5.sh` 記成「**腳本寫好、未跑**」＝聽起來是「隨時可以開跑」的狀態，
但**沒有人講過它們住在一顆平常不掛載的 Windows 磁碟上**。
⇒ 這是 [[evidence-must-outlive-the-handoff]] 的同型：**那兩支腳本從來沒有 commit 進 repo**，
交接檔自己也標了「在 repo 外、未 commit ⇒ 是待辦不是歸宿」。
**下一手要跑 §1–§5，第一步是掛磁碟＋把腳本 commit 進 repo，不是直接跑。**

⚠️ 若掛回來發現腳本不見了：**不要憑記憶重寫然後當成同一份**。
交接檔說那兩支「語法檢查過、§2.6 的 sed 乾跑驗過」——重寫的**沒有那個身分**，要重寫必須宣告是新的並重新乾跑。

## 🏁 2026-08-30：§6（P4/BMv2）整段首次跑完，而且「裝完真的會動」

`開機手冊` 執行，01:17–03:53，起點是 §1–§5 replay 結束時的快照
（＝**讀者走到 §6 時真正所在的那台機器**）。正本＝
`doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-section6-and-T2.md`，
raw 在 `audit-raw`（`66697f6` / `924a7b9` / `4b6306b`）。

| 階段 | 步數 | 非零離開 | 結果 |
|---|---|---|---|
| §6.0–§6.1（**2 h 14 m**，手冊說 1–2 h） | 10 | 0 | pass |
| §6.2–§6.6 | 21 | 0 | pass |
| T-2 把系統跑起來 | — | — | ✅ **fabric 會轉發**：12/12 pingall、paths=12、links=32 |

- ✅ **§6.6（`f00d69f`）第一次被執行驗證**，三句拒絕訊息**逐字吻合**。
  🔑 它自己指出：三支拒絕全過**不構成證據**（一個什麼都拒絕的守衛也全過），
  放行那一支是由 T-2「fabric 真的起得來」補上的。
- ⚠️ **M-2**：§6.1 說安裝器會建 `grpc/`、`PI/`、`behavioral-model/`、`p4c/`，實測 **3/6**
  （v8 的 gRPC 走 apt）。後果小，但照著清單檢查的讀者會找不到。

### 🔴 三個「讀者照做會踩到」的文件缺陷（教授那場的直接風險）
- **M-4**（最該先修）：User Manual 的 **Terminal 3 會反問三個問題**（環境／拓樸／AI，這條流程答 **1,1,2**），
  而頁面只印指令＋截圖、**完全沒提**。更糟：頁面叫你 export `OPENAI_API_KEY` 說可「跳過檢查」，
  讀者會以為不會被問——**實際上是提示在決定**。
  🔑 **只有把 kernel 跑在 pty 底下才看得到**；headless 會變成 usage 訊息，結論會寫成「需要旗標」。
- **M-3**：手冊 `:239` 叫人 grep **`ECONNREFUSED`**，而軟體**從來不印這個字**
  （實際是 `Connection refused` / `[Errno 111]`）。⚠️ **它的第一輪就因此在十台交換機全不通時印 PASS。**
- **M-5**：頁面說等 ~60 s，實測 **~80 s**（單機單次）。

### 🔴 P-1 — proxy 的第二個實例「先把事情做完，才發現自己是多餘的」
`server.py:104` 先跑 **lifespan startup**（連交換機、**寫轉發規則**、開 LLDP），
`server.py:178` 才綁 port 失敗。⇒ **順序是反的**：第二個實例在得知自己拿不到 8081 之前，
**已經把規則寫進交換機**。`curl :8081` 問「活著嗎」回 yes——**回答的是第一個實例**。
✅ **五個安裝的 uvicorn（0.49.0/0.51.0/0.52.1）排序全一樣**，含 proxy 真正用的 `p4_proxy/venv`
⇒ **不是版本問題，守衛必須放在 `uvicorn.run()` 之前**（`main.py:356`），
放在綁 port 的錯誤處理裡來不及。
⚠️ 原報告寫「行程會繼續活著」**是高估**：所有執行緒都是 daemon 且主程式 `sys.exit`，
行程不會賴著，那 29 行是關機競爭。**發現成立，那句話要改。**

### 還沒做的（不要當成做完）
§6.7 fast build **沒跑** ⇒ **binary 沒被指認**（[[benchmark-must-name-the-binary-it-measured]]）；
128-host 沒測（VM 只有 4 vCPU，以上全是 4-host）；
**Developer Manual 的 `NDTwin Kernel API.md` 還沒打開**（判定最高風險）；
NSR／Simulation Platform 兩頁有指令可跑但沒跑；整機輪沒開。
🔑 **scope 更正**：User Manual 12 md／Developer Manual 9 md 裡，**5 和 3 是 `_index.md` 空殼**
⇒ 真正的面是 **7 + 6 = 13 頁**。

---

## 🔴 08-30 夜：**乾淨室 VM 的 CPU 比任何讀者的機器都舊 —— 這是整套 VM 計畫的界**

**先讀這條再看任何 VM 結果。** NTG 的 entry point 在 guest 裡掛掉，訊息是

```
RuntimeError: NumPy was built with baseline optimizations: (X86_V2)
but your machine doesn't support: (X86_V2).
```

實測兩側：

| | `sse4_2` | `popcnt` | `ssse3` | `sse4_1` |
|---|---|---|---|---|
| guest（`QEMU Virtual CPU version 2.5+`，即預設 `qemu64`） | ✗ | ✗ | ✗ | ✗ |
| host | ✓ | ✓ | ✓ | ✓ |

⇒ **PyPI 的 NumPy wheel 以 x86-64-v2 為基準，所以 `import pandas` 在這個 guest 裡永遠不會成功**，跟 NTG 或手冊寫什麼無關。

🔑 **「NTG 一 import 就崩」會是對軟體的偽發現。** 那個閘門當初被寫成 `N/A` 並註明「乾淨拒絕還是崩潰要讀 log，不是這個閘門分辨得了的」，所以它在有人去看之前不會被讀成缺陷 —— **這是預先寫好判讀規則救回來的，不是靠當下警覺。**

**界的範圍（不要讀寬也不要讀窄）**：既有結果**全部不作廢** —— §1–§6.7、NSR 與 NTG 的**安裝**旅程都是 `apt`／`git`／`pip`／`cmake`／shell，不需要 v2。但**任何 numpy 形狀的 runtime 在這把尺構不到的範圍外**。

**修法**＝`vm/vm.sh` 加 `-cpu host`（KVM 不可用就 `max`）。**08-30 夜刻意沒改**：在工作夜尾聲動一個三個 session 共用、且已產出 commit 結果的儀器，是讓人搞不清「哪個結果來自哪把尺」的標準做法。auditor 裁「准，但在輪界執行」：改之前後的結果要分得開、`vm.sh` 檔頭註明變更日期與理由、之後每份 harness meta 記錄 guest CPU model、**改完 NTG 的 runtime 閘要重測**（它從構不到變構得到）。⇒ **改完之後回來把這一節補一句「界已移除自 <日期>」。**

## 🔴 08-30 夜 Adam 裁：**§4.1 不改字** —— 不要「順手修好」那個 404

實測：手冊叫讀者 clone 的**九個** repo，未認證只有 `NDTwin-Kernel-P4` 回 404，其餘八個 public。用讀者真正會跑的操作複驗過（`git ls-remote` → `remote: Repository not found.`；🔑 **API 的 404 與 `ls-remote` 不是同一支儀器** —— 前者「私有」與「不存在」不分，後者就是 `git clone` 的第一個呼叫）。而 §4.1 用**粗體推薦**它：「If you are not sure, clone the P4 one.」

**兩個現行裁決相撞，沒有人做錯**：repo 依 Adam 裁轉私有（過審後再議），手冊線同日升到「可公開等級」。

**Adam 選：repo 維持私有 ＋ 手冊延後發表 ＋ §4.1 不改字、不加誠實句。**「可公開等級」是**品質線不是發表排程**。⇒ 下一個 session 看到那個 404 **不要去修頁面** —— 發表時點將來另裁，屆時 §4.1 與 repo 公開狀態一起重看。正本 `doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-publishable-bar-blocker.md`。

## 🏁 08-30 夜實測收穫（正本全在 `doc/audit/2026-08-28_manual-verification-coverage/`）

- **§6.7 fast build 逐字可用，15 分鐘**（4 vCPU；**手冊完全沒寫時間**，值得補）。debug 安裝 byte-identical ⇒ 分離前綴的承諾成立。手冊叫讀者去 `config.log` 找的 `CXXFLAGS=-O0 -g` **真的在那裡**。
- 🔑 **note 2 的機制被手冊指認錯了**：危險條件**全部成立**（soname 相同、debug 在 ldconfig 快取、fast 不在），混用**仍然沒發生** —— 因為 binary 自帶 `RUNPATH: [/usr/local/bmv2-fast/lib]`，loader 先搜它。**保護來自 build 的性質，不是操作者的紀律**，而手冊歸給了操作者。兩個方向都有害：忘記設變數的人被告知在量混合物（其實沒有）；哪天 build 掉了 rpath，這條建議無聲變成命脈。⇒ 見 [[benchmark-must-name-the-binary-it-measured]]。
- ⚠️ **手冊自己的驗證法（`/proc/<pid>/maps`）在 §6.7 那個位置做不到** —— 要活的 switch，switch 要 fabric。**note 3（對 fast binary 重跑功能測試）沒做**，那是讀者最會跳過也最跳不起的一條。
- **文件缺陷的兩個形狀，各一張票不是各四張**（auditor 裁）：①**PEP 668** 四個位置全壞（NSR 安裝×1、NTG 安裝×2、NTG 使用×1），而**沒有一頁的 Requirements 提到虛擬環境**，Kernel 手冊又強制 24.04。②**`cd` 家族**四例一形，票名就叫「**一條從別處看是對的路徑，印在讀者不在的地方，然後安靜地失敗**」（M-1／NSR 安裝／SimPlatform S-2 與 S-3；S-2 最乾淨：註解寫「From the source root of Energy-Saving-App」正上方就是 `cd Energy-Saving-App`）。**毒性都不在 `cd` 失敗，在下一行成功。**
- **NSR 本身零缺陷**：四個失敗全部歸因到指令；照做之後它啟動、讀設定、檢查前置、指名 host 與 port、乾淨退出。
- ⚠️ **範圍會比派工大**：NSR「1 頁 6 塊」實為**兩頁九塊**、SimPlatform「1 塊」實為**安裝頁 9 塊＋使用頁 1 塊**。派到「某一頁」時先確認讀者的旅程有幾頁。

---

# 🔴 08-31 更正：`/mnt/win` 那一節的修法會害人，**不要照它跑**

本檔 08-29 那節說「`/mnt/win` 沒掛載，掛回來的指令在 `:260`」。**前半對、後半是陷阱。**
實測（08-31）：**同一顆 `nvme0n1p3` 已經由 udisks2 以 rw 掛在 `/media/adam/Windows-SSD`**
（`mount | grep Windows-SSD` ⇒ `ntfs3 (rw,nosuid,nodev,relatime,uid=1000,…)`）。

⇒ **照 `:260` 那行再 `sudo mount … /mnt/win` 是把同一個 block device 掛第二次。** 要那個路徑就
`mount --bind /media/adam/Windows-SSD /mnt/win`，不要重掛。

✅ **而且東西一直都在**：`disk.qcow2`、`vm.sh`、`ndtwin-kernel.bundle`、12 個快照、
`guest_*.sh` / `test_*.sh` 全部健在，在 `/media/adam/Windows-SSD/ndtwin-vm/`。
🔑 **`grep -l '/mnt/win' *.sh` 零命中——沒有任何腳本寫死那個路徑**（都用 `$DIR`）。
⇒ 08-29 那節的警告**只影響文件裡的引用，不影響腳本可用性**，它把嚴重性寫高了。

🔑 可轉移：**「路徑構不到」有兩種成因——沒掛載，或掛在別的地方**，而我當時只查了前者
（`mountpoint -q /mnt/win` 回 false 就下結論）。`lsblk -o NAME,MOUNTPOINT` 一行就能分辨。

## 🔴 `vm.sh` 的 watchdog 預設值比真實跑程還短

`vm.sh:19` 註解寫 *"a section test is ~15 min, a full v8 install was ~45"* 所以訂 `MAX_SECONDS=7200`。
**那個 45 分鐘是錯的**：本檔自己記著 v8 乾淨室 **2 h 01 m**（08-28）、§6.0–§6.1 **2 h 14 m**（08-30）。
⇒ **預設的兩小時會在 §6.1 中途 ACPI 關機**。長跑要帶 `VM_MAX_SECONDS=28800`。
🔑 註解裡的數字沒有跟著同一份檔案裡的實測走——**同一個檔案內部的自相矛盾**，
與 [[cited-line-numbers-are-not-evidence]]「一次正確的量測會無聲過期」同型。

# 🏁 08-31：P4/BMv2 demo VM 已做出來（正本在 repo，成品不在）

🔴 **這一節下面兩批數字被 08-31 傍晚推翻過兩次，只有這張表是現行值：**

| | 值 |
|---|---|
| 檔名 | `NDTwin-P4-demo.ova` |
| bytes | **2,757,157,888** |
| md5 | `b56c588275f13651fc343639f13a6ec7` |
| sha256 | `af1d373093b6493c56f40d5e2740d4c7c2d2db642189a9689196ad1d5d853ee4` |
| 打包者 | **ovftool 5.1.0（不是我手寫的描述子）** |
| 宣告 | `<Name>NDTwin-P4-demo`、**`vmx-14`**、4 vCPU / 6144 MB / SATA-AHCI / E1000 |
| 放在哪 | **只在 `nslab:/home/nslab/NDTwin-P4-demo.ova`**（mode 600）——最後一版在那台產生，沒有回傳本機 |
| 裡面的源碼 | `ndtwin-lab/NDTwin-Kernel-P4` **`main` @ `20cd80b6`（2026-08-28 10:46:57）**，`.git` 已刪，commit 記在 guest 的 `PROVENANCE.txt` |
| 驗收 | **T-2 已在這顆上重跑**：AHCI 開機（`/dev/sda1`）、10 switches、12 paths、**0% dropped (12/12)**，PASS/FAIL 清單與先前各版逐行相同 |

**被推翻的三批（不要再引用）**：
① 手寫描述子那版 2,592,010,240 B / sha256 `4965d003…` —— **VMware 匯不進去**，見下面「ovftool」那節。
①b `c832c91a…` / 2,513,469,440 B —— 洗乾淨了但仍是手寫描述子，**同樣匯不進去**；🔴 **它就是現在 Drive 上那顆**。
①c `b7f0f7fb…` / 2,757,157,888 B —— 匯得進去，但宣告 **`vmx-99`**（不存在的硬體版本）且 VM 名字叫 **`x`**。
② 我曾記載源碼是 `fix/flow-rate-divide-by-zero` @ `059a92c`（08-27）—— **分支與 commit 都錯**。
`059a92c` 是 `ndtwin-kernel.bundle` 的 head，也就是源碼經過的**通道**；我把它當成 image 的**內容**。
image 的工作樹比它新三天。⇒ **要記錄 X 裡面有什麼就去讀 X，不要讀那個指向 X 的東西**
（同日第二次同型，另一次見下面「網站上那顆」）。

放在 **`/media/adam/Windows-SSD/ndtwin-vm/`**，08-31 已由 Adam 上傳 Drive
（file id `1x7XhKiU7SQUclg4sOGRbDZ_1iy7mp-em`，🔴 **他選了「任何人都可以看」**——
而裡面是 PRIVATE repo 的完整源碼；他說會自己注意權限）。
建置腳本與完整驗收表在 repo：`doc/audit/2026-08-31_p4-demo-vm/`
（commit `2acccef`＋`68a588f`＋`09a6a15`＋`3acd4de`）。

不是重裝的——是拿 `post-s6.7-nsr-ntg` 快照（§1–§6.7 都跑過、T-2 驗過會轉發）壓平、清乾淨、打包。
內容：Ubuntu 24.04.4、`p4c-bm2-ss` 1.2.5.16、BMv2 `1.15.5-fdd3b893`（stock ＋ §6.7 fast build）、
kernel、`p4_proxy`、Ryu（conda `ryu-env`）、Mininet、OVS。帳號 `tester`/`tester`（**安裝屬於它**）、
`ndtwin`/`ndtwin`、root `ndtwin`。硬體宣告 4 vCPU / 6144 MB / SATA-AHCI / E1000。

**驗收跑了四輪**，每輪都 32 links / 12 paths / **pingall 12/12**，最後一輪是**從 `.ova` 解出來的磁碟**。
🔴 **第三輪整輪失敗（0 links、100% dropped），而那不是砍東西砍壞的**——是上一輪的孤兒 proxy
還佔著 `:8081`，P-1 守衛正確拒絕啟動第二個。**「砍完再跑一次」是唯一分得出「砍得安全」與
「我砍壞了」的動作，而這一輪兩個答案都出現過。**

🔑 **安裝被綁死在 `/home/tester`**：`p4_proxy/venv` 有 11 個 console script 寫死絕對路徑、
conda 在 `/home/tester/miniconda3` ⇒ **整棵樹搬不走**，`ndtwin` 只能是「額外的登入」。

⚠️ **`simple_switch_CLI` 被我砍 `p4dev-python-venv` 砍壞過又修好**：binding 本體在
`/usr/local/bmv2-fast/lib/python3.12/site-packages`（installed prefix，沒被刪），
缺的只是 system interpreter 的路徑與 `thrift` ⇒ 一個 `.pth` ＋ `apt install python3-thrift` 修好，
**而且比原狀更好**（原本要先 source `p4setup.bash`）。🔑 **「工具在但 import 不到」是三態裡最糟的
那個，因為它看起來是裝好的。**

## 🏁 08-31 深夜：Drive 上那顆已經量過了——衝突解掉，答案比兩邊都糟

**用未認證 `curl` 打 `1x7XhKiU7SQUclg4sOGRbDZ_1iy7mp-em` 的下載頁**（不帶任何 cookie／帳號）：
回得出檔名與大小 → **① 它是公開的**（限制存取會回登入導向，不會回下載確認頁）；
**② 它是 `NDTwin-P4-demo.ova`「2.3G」＝ `c832c91a…` 那版**，也就是**手寫描述子、VMware 匯不進去**的那一顆。

⇒ **到目前為止每一次下載，抓到的都是匯不進去的檔。** 要換的是 `nslab:/home/nslab/NDTwin-P4-demo.ova`
（`af1d3730…`）。同一招也量了官方那顆：`NDTwin.ova`「17G」，也是公開的。
🔑 **這一招就是本專案「公開與否只能打公開 URL 驗」的可執行形式**——不需要第二個帳號，
不帶認證去打就是最強的證據；我先前寫「我沒有查，因為那要用另一個帳號」是**把它想得太難**。

<details><summary>（歷史）當時記下的衝突，保留是因為它示範了「兩份紀錄不打架、只是講不同檔案」</summary>

⚠️ **這一節不是結論，是一個未解決的衝突。** 兩邊我都沒有親自驗過 Drive 的權限設定。

| 來源 | 說法 |
|---|---|
| **本檔上一節**（08-31 稍早寫的） | `NDTwin-P4-demo.ova`（**2,757,157,888 B**、sha `b7f0f7fb…`）已由 Adam 上傳 Drive，file id `1x7XhKiU7SQUclg4sOGRbDZ_1iy7mp-em`，**「任何人都可以看」** |
| **開機手冊線 08-31 傍晚轉述的 Adam 裁決** | **「先不公開，寫草稿就好」**；Drive 連結設**「限制」**、只加那位有 ovftool 的人，目的是**驗匯入不是發佈**；官網草稿的 P4 那列**刻意沒有連結** |

🔑 **兩者不必然矛盾，因為檔案不是同一個**：今天傳上 nslab 的是**洗過的**版本
（**2,513,469,440 B**、sha `c832c91a…`，`.git` 整包刪掉重打包）。**大小與雜湊都不同。**
⇒ 可能是「早先那顆已經公開、後來這顆改成不公開」，也可能是早先那筆紀錄已被取代。

🔴 **但沒被排除的那一支是要緊的**：若 `1x7XhKiU…` 現在仍是「任何人都可以看」，
**那是一個 PRIVATE repo 的完整源碼對外可讀**。
⇒ **查法只有一種算數：用未認證／無關帳號打那個 Drive 連結**（同本專案「公開與否只能打公開
URL 驗」）。**我沒有查，因為那要用 Adam 的瀏覽器身分或另一個帳號。**

</details>

## 🏁 08-31：已公開那顆 17.9 GB（`NDTwin-Testbed-20260831`）已被查過了

開機手冊線在 nslab 上下載＋開機盤點（`.git` 那一題**只能開機跑 `git rev-list`**——
掃 raw 位元組找 packfile 樣本會是**假陰性**，因為樣本取自另一個 repo）：

- 🟢 **乾淨**：七個 repo **全部 0 個投稿包物件**，**每個對照組都非零**（2736/728/167/103/90/81/7）；
  `NDTwin-Kernel` 的 tip 是 **2026-01-29**，早投稿工作七個月。
- 🔴 **它為什麼 17.9 GB**：`df`／`du` 說實際只有 **30 GB**，而已配置區塊是 **70.6 GB**
  ⇒ **約 40 GB 是刪掉但沒 discard 的區塊，佔成品 57%**。出貨前少跑一次 `fstrim`，
  代價是每個使用者多下載 8 GB。**不是安全問題，是使用者付了不必要的下載。**

⇒ **這兩件事各出一次，成了一份出貨清單**（auditor 裁「開一張票寫『加 fstrim』，
下一次會漏掉別的東西」）：**`doc/2026-08-31_vm-image-shipping-checklist.md`**，
已進 `doc/README.md` 索引。三項＝`.git` 歷史（**問物件庫不問工作樹、帶陽性對照、禁 `| head -N`**）／
`fstrim`／**成品大小 vs 檔案系統用量對帳**（第三項是第二項的**驗收**不是重複——`fstrim` 回 0
不代表區塊真的釋放）。**第 0 步在清單之前：先問「它到底需要什麼」，不必洗的東西也不必驗它洗乾淨了。**

## 🔴 網站上那顆 demo VM 是誰、我怎麼判斷錯的

我曾說它是「P4 之前的、二月那顆」。**方法錯了：我拿指標的證據去斷言檔案。**
頁面的元件清單是**頁面**寫的、`1efc7b1 Update vm image link`（xxxPatty, 2026-02-13）是
**連結**最後被改的時間——兩者都不是檔案。

實測（抓下載的前 1 MB，OVA 規格把 descriptor 放在 tar 第一個成員）：

| | |
|---|---|
| Drive 提供 | `NDTwin.ova`，**17,900,278,784 bytes** |
| last-modified | **2026-08-31 11:29:12 CST** |
| 內部名稱 | `NDTwin-Testbed-20260831` |
| 產生者 | **`VMware ovftool 5.0.0 (build-25296333)`，同日 11:18:39 CST** |
| 硬體 | 16 vCPU / 16384 MB / `vmx-21` / 磁碟在 **SCSI lsilogic** / E1000 ＋ floppy 1.47 MB ＋ ISO 99.9 MB |

⇒ **公開映像在我建 VM 的幾小時前被換掉，而網站不需要任何改動就發生了**——連結是 Drive file ID，
換內容不換 ID，頁面一個字都不用動。**Adam 確認那顆不含 P4**，所以我這顆補的是缺口不是重工。
⇒ 也證明**這個專案裡有人有 ovftool 5.0.0 而且當天早上在用**——那是驗 VMware 最短的路。

## 🏁 08-31 傍晚：ovftool 拿到了，而它抓到前面每一種方法都放行的東西

Adam 自己在 nslab 上下載了 **ovftool 5.1.0 (build-25410048)**，路徑
`/home/nslab/ovftool-dist/ovftool/ovftool`。它免費（要 Broadcom 帳號，Adam 自己註冊），
**zip 版解開就跑、不需要 root、不需要核心模組** ⇒ 這是唯一能在沒有 root 的機器上驗 VMware 的路。

🔴 **`ovftool --verifyOnly` 不檢查磁碟雜湊。** 兩個陰性對照都被它放行：

| 受測物 | `--verifyOnly` |
|---|---|
| 完整檔 | exit 0 |
| **截斷成 200 MB** | **exit 0** |
| **磁碟中間翻一個 byte** | **exit 0** |

⇒ 它只解析描述子。**只跑它就宣稱「VMware 驗過了」是假的**，而那正是我原本打算做的。
真正會檢查的是**轉換**（`ovftool x.ova out.vmx`，也就是使用者匯入時走的路）。

🔴 **而手寫描述子那版轉換失敗**：`Error: SHA digest of file …-disk1.vmdk does not match manifest`。
manifest 本身是對的——我從同一顆 `.ova` 解出來用 `sha256sum` 重算，**兩個雜湊逐字相符**。
是 ovftool 算出來的摘要跟標準工具不同（未追出機制；推測與 streamOptimized 的結束標記有關，
**未驗證**）。加 `--skipManifestCheck` 就 `Completed successfully` ⇒ **描述子與磁碟都好，壞的只有那份手寫 manifest。**

✅ **修法：用 ovftool 自己重打包**（`.ova → .vmx → .ova`），手寫描述子這整類風險一次消掉。
重建版：`The manifest validates` → `Completed successfully`；**陰性對照翻一個 byte → exit 1
且出現一模一樣的錯誤** ⇒ 這道檢查有鑑別力。硬體全數保留（4 vCPU / 6144 MB / SATA AHCI / **E1000**）。
重建後的磁碟**實際開機驗過**（nslab，SSH 起來、三個 P4 binary 都在、`.git` 0、投稿關鍵字 0、
`PROVENANCE.txt` 在、8.1 G used）。

🔑 **教訓有兩層，第二層比較貴：**
① 名字叫 verify 的東西不一定在 verify ⇒ **每個閘門都要 force-red 過才算數**。
② **我原本的計畫是「跑 `--verifyOnly`，過了就回報 VMware 驗過」** —— 那份計畫在對照跑出來之前
看起來完全合理。**是對照而不是懷疑救了這件事。**

📌 舊記載保留供對帳：VirtualBox 的 OVF parser 曾對手寫版回報 `Interpreting … OK.`、dry-run rc=0、
零不合規警告——**而那顆 VMware 匯不進去。第二個獨立實作通過，不代表第三個會通過。**

## 🆕 08-31：§6.1 有了**第二個平台**的資料點（不是同條件重跑）

`test` session 在新機器 `nslab` 的 qemu VM 裡跑完 §3.1＋§3.2＋`install-p4dev-v8.sh`。
**全過**，正本＝guest 的 `~/install-p4.log` / `~/install-deps.log`
（`ssh -J nslab -p 2222 ndt@127.0.0.1`；機器與進法見 [[nslab-remote-dev-machine]]）。

| | 硬體 | 牆鐘 | behavioral-model | 最小 v1model JSON |
|---|---|---|---|---|
| 手冊寫的 | — | 1–2 h | — | — |
| 08-28 乾淨室 | 4 vCPU | **2 h 01 m** | `fdd3b893` | 4114 B |
| 08-31 nslab VM | 16 vCPU（宿主 28 核/31 GiB） | **38 m 41 s** | `583e76e4` | 4122 B |

**三件可直接進手冊的事：**

1. 🔑 **時間估計取決於核數與記憶體，不是一個區間。** 3.1× 的差距全在硬體。
2. 🔑 **v8 自己是記憶體感知的**——`install-p4dev-v8.sh:981` 是 `MAX_PARALLEL_JOBS=\`max_parallel_jobs 2048\``，
   取 min(核數, 可用記憶體÷2 GB)。⇒ **不需要教讀者手動限制 `-j`**，也不要覆寫它。
3. ✅ **v8 的兩個 patch 現在跨兩顆不同的 behavioral-model commit 都成立**（`fdd3b893`／`583e76e4`），
   而 v10 的兩個在 08-30 仍 rc=1。⇒ §6.1「指名 v8」的建議比原本更硬。

🔴 **兩個偏差，不要把這輪當同條件重跑：**
- **上游版本不同**：preflight 在 08-30 16:12 量到 `fdd3b893`，**上游 08-30 22:06 推了新 commit**，
  建置實際吃到 `583e76e4`。⇒ **`1.15.5-fdd3b893` 已不是今天預設會拿到的字串**；
  安裝器不釘 behavioral-model，這條會一直發生（見 [[cited-line-numbers-are-not-evidence]] 檔尾）。
- **M-1 是繞過不是通過**：cloud-init 先建了 `~/Desktop`。
  （獨立資料點：08-30 查過 server8 的裸機帳號，`~/Desktop` **本來就存在** ⇒ **M-1 在實體機上不必然發作**，
  VM 上的發現不要直接外推到「所有 Ubuntu Server」。）

✅ **真乾淨的部分**：全新 cloud image、零前輪殘留；腳本在 p4 階段有硬檢查——
`behavioral-model`/`p4c`/`PI`/`grpc` 任一存在就**拒絕開跑**（就是 08-27 那個「跳過已存在元件然後回 0」
的半安裝陷阱）。驗收釘產物不釘 rc，並多驗一步「真的編得出 JSON」。

## 🏁 08-31 傍晚：官網那顆 17.9 GB 的兩個問題都答完了

**在 nslab 上下載 17,900,278,784 B 全額**（`CURL_EXIT=0`、`file` 確認是 tar 不是 HTML 導頁），
解出 vmdk、轉 qcow2、**把它唯讀掛成我自己那顆 P4 demo VM 的第二顆硬碟**來查。
🔑 **沒有開它**——開它會讓三個未知數同時變成承重牆（sshd 開不開、從哪個控制器開機、
**第一次開機會往我正要檢查的磁碟寫什麼**）。唯讀掛載三個都不存在。

### ① 為什麼 17.9 GB

| | |
|---|---|
| `df`／`du`（一致） | **30 GB** |
| 已配置區塊＝OVF `populatedSize` | **70,573,555,712（70.6 GB）** |
| 差額 | 🔴 **約 40 GB＝刪掉但沒 discard 的區塊，佔成品 57%** |

`streamOptimized` 已壓縮 ⇒ **不是壓縮沒開，是內容裡有 70 GB**。真實那 30 GB：
`/home/ndtwin` 13 G（`.local` 7.3 G、miniconda3 2.8 G、snap 625 M、.vscode 445 M）、
`/var` 7.4 G（snapd 4.7 G、docker 1.6 G、journal 603 M）、`/usr` 5.5 G、
**六個專案的源碼只佔 673 M**。⇒ 出貨前少跑一次 `fstrim`，代價是每個使用者多下載 8 GB。

### ② 🟢 它**沒有**帶投稿包

七個 repo 全部 0 個關鍵字物件，**而且每個的物件總數都非零**（2736／728／167／103／90／81／7）
⇒ 那七個 0 有鑑別力。檔案系統層面 0 路徑 0 內容。
**獨立的第二支柱**：`Desktop/NDTwin-Kernel` 的 tip 是 `4b9234c4`，**2026-01-29**——比投稿工作早七個月，
remote 是公開的 `ndtwin-lab/NDTwin-Kernel`（投稿 commit 打公開 API 回 **422**、對照組回 **200**）。

⚠️ **不能用掃 raw 位元組那招查它**：那組 packfile 樣本取自 `NDTwin-Kernel-P4`，這顆裝的是
`NDTwin-Kernel`，packfile 不同 ⇒ **零命中會是假陰性**。詳見
[[packaging-a-filesystem-ships-the-invisible]]。

## 🔴 08-31：我這顆 `.ova` 曾經裝著 EuroP4 投稿包（已修）

整段的正本在 repo `doc/audit/2026-08-31_p4-demo-vm/README.md`（`09a6a15`），
可重用的教訓抽在 [[packaging-a-filesystem-ships-the-invisible]]。
這裡只留跟這條線相關的三句：

- 污染**不是**走 `ndtwin-kernel.bundle` 進去的（那顆查過乾淨、tip 08-27 早於投稿工作）
  ⇒ **走的是一條我沒有記錄的通道**，在我記載的那次傳輸之後。
- 洗法＝刪掉全部三個 `.git`（剩 0）＋`fstrim`＋填零＋`fstrim`，
  驗收＝**對照組 12/12 找得到、成品 11/11 消失**。
- **T-2 在成品上報 `failures: 1`（twin 14 ≠ 10），我沒有假設那是舊有的**——
  同一 driver 跑在「未刪 `.git`」的 image 上，**完整 PASS/FAIL 清單逐行相同**（含 `M-3` 的 proxy 項）
  ⇒ 與刪除無關。**這是唯一分得出「我砍壞了」與「本來就這樣」的動作。**

## 🔴 08-31 深夜：**兩顆 demo VM 誰都不是誰的超集**

Adam 問「舊的有 tools 嗎？有的話新的也要有」。逐一量過（舊的是唯讀掛磁碟數 `.git`，
新的是 `PROVENANCE.txt` 與 clone 記錄）：

| repo | 官方 17.9 GB（`/home/ndtwin/Desktop`） | P4 版（`/home/tester/…`） |
|---|---|---|
| NDTwin-Kernel | ✅ `4b9234c4` 2026-01-29 | ✅ **NDTwin-Kernel-P4** `20cd80b6` 08-28 |
| Network-Traffic-Generator | ✅ | ✅ |
| Network-State-Recorder | ❌ | ✅ |
| Energy-Saving-App | ✅ | ❌ →（08-31 補上） |
| Traffic-Engineering-App | ✅ | ❌ →（同上） |
| Network-Traffic-Visualizer | ✅ `cdd816b` | ❌ →（同上） |
| Simulation-Platform-Manager | ✅ | ❌ →（同上） |

🔑 **舊的六個 app、新的三個，而且各有對方沒有的。** 我原本在官網草稿寫
「P4 版＝標準版＋P4」——**錯的，而且是照頁面文字寫、沒照成品寫**（同日第三次同型）。
草稿已更正（`NDTwin-Website` `a24eedb`，本機未推）。

**Adam 裁「要能跑」**（不是「跟舊的一樣」）⇒ 四個都 clone 進去、裝相依、建起來、各啟一次。
建置與啟動的細節全在 [[cross-repo-component-ecosystem]]，這裡只記結論：
**六個執行體全部建得起來也啟得起來**，其中 ESA 與 SPM 要 root。

## 🔴 08-31：一次唯讀稽核，把官網的下載連結關掉一天

為了查投稿包，17:00 在 nslab 上把官方那顆 17.9 GB 整個抓了一次。21:38 要再抓時
Google Drive 回 **`Quota exceeded`**（三次嘗試各存下同一張 2009 B 的 HTML，`curl` 都回 0）。

✅ **鑑別力來自對照**：同一時刻對**同兩個 file id** 發 4 KB `range` 請求，都回 `206` ＋ tar magic
⇒ 檔在、連結對、權限仍公開，**被擋的只有大量傳輸**。沒有這個對照我會讀成「檔不見了」。

⇒ **稽核不是免費的，而且成本落在沒有訂購它的人身上**：那天之後約 24 小時，
任何照官網下載頁點連結的人都拿不到檔。**下次要整份下載一個公開 artifact 之前，先問
「這會不會把它的配額用掉」**，並且優先用 range 請求做能用 range 回答的問題。
