# 🏁 htb 假陰性的機制已定位——它不是量測誤差，是**指令從未執行**

**懸案**＝`2026-08-30_ovs-flowcount-control/FINDINGS.md:134-136`：
「`sudo -n tc -s qdisc show | grep -c htb` 兩次讀 0 … **讀 0 的機制未定位**（待 T-4 窗外
live 釘死——只用唯讀指令）」。
**觸發**＝08-31 回報義務盤點（`77_`）發現 ③ 的 `tc -s qdisc` 讀出從未成功；我循線釘死。

## 證據一：raw 裡沒有 qdisc 資料，只有一行 sudo 錯誤

```
$ 對 audit-raw 逐檔檢查 doc/audit/2026-08-28_flow-count-capacity/raw/**/tcqdisc_*.txt
共 31 檔，其中 31 檔內容是 sudo 錯誤          ← 全數
$ git show audit-raw:…/n16_a/tcqdisc_before.txt
sudo: a password is required
```
OvS 輪（`2026-08-30_ovs-flowcount-control/raw/**/tcqdisc_*.txt`）**同樣的一行**。
🔑 **`2>&1` 把錯誤寫進了「資料」檔**，於是檔案存在、非空、看起來像有輸出。

## 證據二：現場重現那條斷言（08-31，唯讀，單次）

```
$ out=$(sudo -n tc -s qdisc show 2>/dev/null); echo $?   →  1      # sudo 拒絕
$ echo ${#out}                                           →  0      # stdout 全空
$ sudo -n tc -s qdisc show 2>/dev/null | grep -c htb      →  0      # 斷言讀到的就是這個 0
```

⇒ **機制＝`sudo -n tc` 需要密碼（免密碼白名單不含這條形式）⇒ 指令未執行 ⇒ stdout 為空
⇒ `grep -c htb` 忠實地數出 0。** 讀到的 0 **不是「沒有 htb」，是「沒有輸出」**。

## 為什麼它能活過兩輪

1. **`2>&1` 把診斷訊息變成資料**——檔案非空，肉眼掃過去像有東西。
2. **`grep -c` 對「空輸入」與「有輸入但無匹配」給出同一個答案 `0`**
   ——又一個[[failures-that-report-success]]家族的「兩種原因、同一個輸出」。
3. **結構缺陷（FINDINGS 已自記）**：expect-0 那側有 die-gate，**expect->0 這側只有 echo**
   ——**有訊息的那一側沒有閘門**。
4. ⇒ 三者疊起來：**一個從未執行的斷言，看起來像一個執行了並回報陰性的斷言。**

## 這條記在案的「未定位」現在可以結案

- OvS 輪的結論**不受影響**（帽存在已由三重獨立證據支撐：08-28 jitter 輪直接讀到 htb、
  本輪 0.96 G 的 goodput 簽名、patch 落在同名異 repo 檔＝shaping 從未被移除）。
- 但**那兩次讀 0 從此不得再被描述為「量測」**——它是儀器未執行。
- 🔴 **同一支指令在兩輪都失效**（③ 08-28、OvS 08-30），且第二輪**重新註冊了同一條斷言**
  而沒有先驗它能不能跑 ⇒ [[injections-must-assert-their-own-success]] 的第八式：
  **註冊一條斷言之前，先讓它對「已知為真」的情況成功一次**（本例＝在有 htb 的 fabric 上
  先跑出非零計數，再把它寫進 prereg）。

## 修法（給下一輪，不改已收案的結論）

```bash
# 壞：兩種原因給同一個 0
n=$(sudo -n tc -s qdisc show | grep -c htb)

# 好：先斷言指令本身成功，再談內容
out=$(sudo -n tc -s qdisc show 2>/tmp/tc.err) || { echo "ABORT: tc 未執行: $(cat /tmp/tc.err)"; exit 3; }
[ -n "$out" ] || { echo "ABORT: tc 成功但無輸出"; exit 3; }
n=$(printf '%s' "$out" | grep -c htb)
```
🔑 **通則**：**任何「數出 0」的斷言，都要先證明它的輸入存在。**

[Co-developed with claude code -- Adam]
