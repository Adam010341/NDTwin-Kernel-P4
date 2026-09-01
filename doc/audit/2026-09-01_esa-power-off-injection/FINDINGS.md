# ESA 關機路徑注入輪 — 2026-09-01

[Co-developed with claude code -- Adam]

**受測物**：Energy-Saving-App（`/home/adam/Energy-Saving-App`，**另一個 repo**）的
`setSwitchesPowerState()`。本輪**沒有修改 ESA 任何一行**，也沒有 push。

**起因**：`開機手冊` session 在出貨用 P4 demo VM 上量到 ESA 14 個端點裡 13 個通，
缺的 `/ndt/disable_switch` 追下去是**零呼叫點的死碼**（詳見本輪回覆與
`doc/2026-08-07_testing_tools_overview.md:226`）。追的過程中讀到活的那條路上有個沒人擋的洞，
Adam 裁示出貨前實跑驗證。

---

## 一、宣稱

> kernel 對 `/ndt/set_switches_power_state` 回非 2xx 時，ESA 的**關機**路徑察覺不到：
> 狀態碼在 `energy_saving_app.cpp:247` 被丟掉，而且**不像開機側**有
> `wait_until_powered_on_switches_are_up()` 與它的 `if (!waiting_result) return;` 把關，
> 關機側沒有任何下游驗證。

---

## 二、跑的是不是出貨的那份碼（Phase 0）

driver 是**重編**的，不是出貨的 binary，所以這一格是閘門不是註腳：
若機器碼不同，底下每一臂測的都是別的東西。

| | |
|---|---|
| 出貨 binary | `energy_saving_app`，sha256 `0c746a61938bedc4eee2e30dc53e3e6c20e9c158cfe10d3e25c2c713a6ec996d`，build 2026-08-22 13:08:20 |
| 本輪 driver | sha256 `1779eab73a64f82e2623c0a1d4f626480c105f034b641187693aa1c7d8035f8a` |

把兩個 binary 裡受測函式的指令流抽出來、正規化掉位址之後**逐位元組比對**：

| 符號 | 指令數 | 結果 |
|---|---|---|
| `setSwitchesPowerState(...)` | 954 | ✅ **完全相同** |
| `set_switches_power_state(uint64_t, bool)` | 267 | ✅ **完全相同** |
| `install_modify_delete_flow_entries(...)` | 778 | ✅ **完全相同** |

⇒ 受測的三個函式，本輪跑的與出貨 binary 裡的是**同一份機器碼**。

**driver 做了什麼**：`#include` 出貨的 `src/app/energy_saving_app.cpp`（逐字，未改），
用前處理器把它的 `main` 改名以便換上自己的進入點；所有 header 都在改名**之前**先引入，
所以改名進不到任何 header。要 `#include` 而不是連結，是因為那個函式讀的三個狀態
（`caseID2SwitchesDpidToPowerOff` / `...PowerOn` / `dpid2IP`，`energy_saving_app.cpp:48-50`）
宣告為 `static`，外部 TU 叫不出它們的名字——**在不改出貨原始碼的前提下，這是唯一的入口**。

**沒有跑到的**：出貨的 `energy_saving_app` **binary 本身**，以及
`setSwitchesPowerState` 上游的決策邏輯（挑哪個 case、關哪幾台）。本輪從
`setSwitchesPowerState` 進入，帶著那段邏輯會產生的狀態。受測的回覆處理**整個都在**
`setSwitchesPowerState` 與它呼叫的 `http.cpp` 函式裡，兩者都是出貨原始碼，走真的 TCP socket。

---

## 三、五臂

注入載具是一支 stub kernel（`stub_kernel.py`），聽 127.0.0.1:8000。
它**只對一個 target 套用注入**，其它一律 200——一臂如果整個安靜下來，不能用「stub 掛了」解釋。
404 / 500 的 body 抄自真 kernel 實際會送的內容（`handleNotFound` → `{"error":"Not Found"}`），
避免 body 形狀變成混淆因子。

| 臂 | 注入 | 用途 |
|---|---|---|
| `control` | 全部 200 | 對照組 |
| `inject404` | 關機端點 → 404 | 注入 |
| `inject500` | 關機端點 → 500 | 注入（證明不是 404 專屬） |
| `injectrules` | **流表端點** → 404 | 同一個函式裡**另一個**沒被檢查的寫入（見 §5） |
| `guard` | 全部 200 | **鑑別力對照**：叫 app 等一台 graph 永遠不會回報 up 的交換機 |

### 注入有沒有真的發生（Phase 2）

「app 沒報錯」與「app 根本沒送出請求」會產生**同一種安靜**。所以每一臂都去讀 stub 自己的
請求記錄，斷言請求真的到了、也真的被回了注入的那個碼：

```
✓ control    : 2 power-OFF POSTs, all answered 200
✓ inject404  : 2 power-OFF POSTs, all answered 404
✓ inject500  : 2 power-OFF POSTs, all answered 500
✓ injectrules: 2 flow-entry POSTs all answered 404, and 2 power-OFF POSTs still went out
✓ guard      : 1 power-ON POST, 0 power-OFF POSTs (360 requests total, so the stub was alive)
```

🔑 **這一格自己抓到過一個錯，值得記下來**：guard 那臂的期望我一開始寫成
「0 個 `set_switches_power_state` POST」，結果紅了——實際有 1 個。原因是**開機迴圈
（`:201`）跑在等待之前**，所以那是一個 `action=on`。斷言於是改成分辨 `action=on` 與
`action=off`，這才是那一臂真正在宣稱的事（**沒有走到關機迴圈**）。
如果當初把期望寫鬆一點（「至少 0 個」之類），這個錯就會無聲通過。

---

## 四、結果

### 4.1 五臂的輸出計數

| 臂 | 輸出行數 | `Power On/Off Task Complete` | 函式正常返回 | error/warning/critical 行 |
|---|---|---|---|---|
| `control` | 21 | 1 | ✔ | **0** |
| `inject404` | 21 | 1 | ✔ | **0** |
| `inject500` | 21 | 1 | ✔ | **0** |
| `injectrules` | 21 | 1 | ✔ | **0** |
| `guard` | 728 | **0** | ✔ | **1** ← 對照組，見 §6 |

### 4.2 「兩台都關掉了」與「兩道關機命令都被回 404」的**全部差異**

```diff
16c16
< [info] [http.cpp:138 set_switches_power_state] Code: 200, Body: {"result":"ok"}
---
> [info] [http.cpp:138 set_switches_power_state] Code: 404, Body: {"error":"Not Found"}
19c19
< [info] [http.cpp:138 set_switches_power_state] Code: 200, Body: {"result":"ok"}
---
> [info] [http.cpp:138 set_switches_power_state] Code: 404, Body: {"error":"Not Found"}
```

**21 行裡差 2 行，兩行都是 `[info]`。** 沒有 error、沒有 warning，
`Power On/Off Task Complete` 照印，函式照樣正常返回。500 那臂完全同型。

⇒ **宣稱成立。** 一個看 log 等級或看完成訊息的操作者，分不出「省了電」與「一台都沒關」。

### 4.3 🔴 更嚴重的那一臂：改路失敗，照樣斷電

`injectrules` 把**流表端點**（`install_flow_entries_modify_...`）打成 404 ——
那是「把流量從即將關掉的交換機上導開」的那一步，發生在斷電**之前**。

```diff
10c10
< [info] [http.cpp:258 install_modify_delete_flow_entries] Code: 200, Body: {"result":"ok"}
---
> [info] [http.cpp:258 install_modify_delete_flow_entries] Code: 404, Body: {"error":"Not Found"}
13c13
< [info] [http.cpp:258 install_modify_delete_flow_entries] Code: 200, Body: {"result":"ok"}
---
> [info] [http.cpp:258 install_modify_delete_flow_entries] Code: 404, Body: {"error":"Not Found"}
```

stub 的請求記錄顯示，**兩道改路都被拒絕之後，兩道關機命令照樣送出去了**：

```
seq 2  POST /ndt/install_flow_entries_modify_...   -> 404
seq 3  POST /ndt/install_flow_entries_modify_...   -> 404
seq 4  POST /ndt/set_switches_power_state?ip=2.0.0.10&action=off  -> 200
seq 5  POST /ndt/set_switches_power_state?ip=1.0.0.10&action=off  -> 200
```

同樣是 21 行、1 個完成訊息、**0 個 error/warning**。

⇒ 這一臂的後果**比原本那個宣稱更重**：原本是「以為省了電、其實沒關」（帳面錯，網路沒事）；
這一臂是「**改路沒生效，但交換機還是被關掉了**」——流量本來要被導到別條路上，
而那個導流從沒裝上去。**這個會斷線，不只是帳面錯。**
（⚠️ 「會斷線」是從呼叫順序推的，本輪**沒有量真的流量**，見 §7。）

---

## 五、對照——這個 codebase 不是「從來不檢查」

同一個 codebase 在別處**都有**檢查狀態碼：

| 位置 | 檢查 |
|---|---|
| `http.cpp:321, 351, 379, 407, 437, 473` | **六個讀取端點**：`if (code != 200 \|\| body.is_null())` → 記 ERROR、回空 |
| `energy_saving_app.cpp:528` | 送模擬請求：`if (res.result_int() >= 400)` → WARN `Simulation Request NOT Accepted` |
| `energy_saving_app.cpp:952` | `if (!acquire_lock())` → 退避重試 |

沒有檢查的，是 `setSwitchesPowerState` 裡**四個真的會改變網路的寫入呼叫**：

| 位置 | 呼叫 | 回傳 |
|---|---|---|
| `energy_saving_app.cpp:201` | `set_switches_power_state(ip, true)` | `std::optional<uint32_t>`，**丟掉** |
| `energy_saving_app.cpp:225` | `install_modify_delete_flow_entries(...)` | `std::optional<uint32_t>`，**丟掉** |
| `energy_saving_app.cpp:241` | `install_modify_delete_flow_entries(...)` | `std::optional<uint32_t>`，**丟掉** |
| `energy_saving_app.cpp:247` | `set_switches_power_state(ip, false)` | `std::optional<uint32_t>`，**丟掉** |

⇒ 這不是「這個 codebase 不檢查」，是**恰好在會動到實體世界的那四個呼叫上不檢查**。

開機側之所以擋得住，靠的**也不是狀態碼**——是
`wait_until_powered_on_switches_are_up()` 去**看孿生體的圖**確認交換機真的起來了
（`energy_saving_app.cpp:206-211`），失敗就 `return`。那是比檢查回傳碼更好的檢查，
**只是關機側一個都沒有。**

---

## 六、鑑別力對照：這個讀數印得出「app 發現了」嗎

上面四臂的讀數都是「安靜」。**安靜有兩種成因**：受測物真的沒察覺，或者這個 driver
不管發生什麼都安靜。分不開的話，整輪等於零鑑別力。

`guard` 那臂就是為了分開它們：**stub 全部回 200，唯一的改動是叫 app 去等一台
graph 永遠不會回報 up 的交換機。** 結果：

```
[warning] [energy_saving_app.cpp:177 wait_until_powered_on_switches_are_up]
          Timeout waiting for powered-on switches to become up
DRIVER-RETURN: shipped setSwitchesPowerState returned normally
```

- 輪詢 360 秒、728 行輸出、**1 個 warning**
- **`Power On/Off Task Complete` 沒有印**
- stub 記錄：1 個 `action=on`、**0 個 `action=off`** ⇒ 確實在走到關機迴圈之前就 `return` 了

⇒ **這個讀數會說話。** 開機側出事時它印 warning、吞掉完成訊息；
關機側出事時它一個字都不改。**兩者的差別在受測物，不在儀器。**

---

## 七、本輪**沒有**證明的事

逐條列出來，因為這些是下一輪的入口，不是可以順口帶過的但書。

1. **沒有跑出貨的 `energy_saving_app` binary**。跑的是重編的 driver；
   §2 證明的是「受測的三個函式機器碼相同」，**不是**「整支程式行為相同」。
   （原本想連 binary 一起跑：需要 `unshare` 建 user+mount namespace 來繞開
   `main()` 裡那個 `mount -t nfs`，**被權限分類器擋下**。要做這一版得先開權限。）
2. **沒有量真實流量**。§4.3 說「會斷線」是從呼叫順序推的——
   改路被拒 ⇒ 新路徑沒裝上 ⇒ 舊路徑上的交換機被關掉。**沒有跑封包去證實。**
3. **沒有測上游的決策邏輯**（挑哪個 case、關哪幾台）。本輪從
   `setSwitchesPowerState` 進入，帶著那段邏輯會產生的狀態。
4. **沒有測真 kernel 的回應**。用的是 stub；404/500 的 body 抄自真 kernel 的
   `handleNotFound` 與例外分支，但真 kernel 在什麼情況下**會**回非 2xx，本輪沒查。
5. **沒有動 ESA 一行碼，也沒有 push。** 這一輪是驗證，不是修法。

---

## 八、建議（決定權在 Adam）

出貨頁列著這顆 VM 帶了 Energy-Saving-App。「帶了」與「它接得上這顆 kernel」是兩個宣稱，
**第二個現在有證據支持**（14 個端點 13 個存在，缺的那個是死碼）。
但「接得上」與「失敗時看得出來」是**第三個**宣稱，而它現在是**否**。

按代價由小到大：

| | 動作 | 代價 |
|---|---|---|
| A | **什麼都不改，出貨頁只講「帶了 ESA」**，不宣稱節能功能經過驗證 | 零 |
| B | 在 `:225`/`:241`/`:247` 接住回傳碼，非 2xx 就記 WARN | ESA 三行 |
| C | B 再加上：**改路失敗就不要斷電**（`:225`/`:241` 失敗即 `return`） | ESA 少數行，但改變行為 |
| D | 關機側比照開機側，回去看孿生體的圖確認真的關掉了 | 較大 |

🔴 **B 與 C 都要動 ESA**，而 ESA 是**另一個 repo**、Adam 交代過超出負責範圍、
`fix/power-decision-per-group` 那條分支也還壓著沒推。**本輪沒有做任何一項。**

---

## 附：重跑

```
cd doc/audit/2026-09-01_esa-power-off-injection
./run.sh              # 全部五臂（guard 那臂要 6 分鐘，因為出貨的等待預算是 360 秒）
./run.sh inject404    # 單一臂
./run.sh checks       # 只重跑判讀，用磁碟上已有的 log
```

重建 driver（8.4 MB，**故意不進版控**；`sym.*.asm` 與 `Graph.json` 同樣不進，
本目錄有一份 `.gitignore` 擋著它們——但 repo 根目錄的 `.gitignore:5` 把 `.gitignore` 本身
列為忽略，所以那份檔**是本機的、clone 不會帶到**）：

```
ESA=/home/adam/Energy-Saving-App
g++ -std=c++23 -I$ESA/include -Wall \
  $ESA/src/utils/Logger.cpp $ESA/src/app/http.cpp $ESA/src/common/types.cpp driver.cpp \
  -o driver -lpthread -lboost_system -lboost_thread -lspdlog -lfmt \
  -DSPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_TRACE
```

⚠️ Phase 0 會拿重建出來的 driver 跟 `$ESA/energy_saving_app` 比機器碼。
**那顆出貨 binary 若被重建過，比對的基準就換了**——重跑時先確認它的 sha256 還是
`0c746a61…`，不是的話 Phase 0 的「相同」講的是另一件事。
