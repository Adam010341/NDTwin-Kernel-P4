# 審查員複審：chaos harness 的行動面與 oracle

**2026-08-28。複審對象**：`01_action-surface_deepseek.md`（DeepSeek）、`02_oracle_muse.md`（Muse Spark）。
**兩份都值得用。下面是必須先修的兩個缺陷，和一個關於這類產出的通則。**

---

## 🔴 必修一：INV-01 的獨立檢查**永遠回報「行程不見了」**

Muse 寫的獨立路徑是：

```
P4: `pgrep -a simple_switch_grpc` or gRPC port LISTEN + proxy /p4/switch_state probe_ok
```

**`pgrep -a simple_switch_grpc` 恆不匹配。** 實測（fabric 正在跑、11 台交換機）：

```
$ pgrep -a simple_switch_grpc
pgrep: pattern that searches for process name longer than 15 characters
       will result in zero matches
$ pgrep -cf 'simple_switch_g[r]pc'
11
$ cat /proc/<pid>/comm
simple_switch_g          ← 截斷到 15 字元
```

`-a` 只改輸出格式，**不含 `-f`** ⇒ 比對的是 `comm`，而 `comm` 上限 15 字元、
`simple_switch_grpc` 有 18 個。**新版 pgrep 會警告，但警告在 stderr 且 rc 非零**——
腳本看到的仍然是「沒有匹配」。

⇒ **後果最壞的位置**：這是**最重要的那條不變量**（power state 的 anti-lying 檢查）的**獨立路徑**，
而它會在**每一次**檢查回報違規 ⇒ **100% 偽陽性**，而且長得像「系統壞了」。

**修法**：`pgrep -cf 'simple_switch_g[r]pc'`（`-f` 比對整條命令列，bracket 防自我匹配）。
⚠️ **不要改成 `pgrep -xf`**——`-x` 配 `-f` 要求整條命令列完全相等，對任何帶參數的行程恆假。

---

## 🔴 必修二：INV-08 的單調性宣稱**對正確行為會發火**

> `get_average_link_usage` must be non-decreasing as busy links increase;
> if it drops when busy links increase, denominator bug.

**這是錯的。** 那個端點取的是**忙碌鏈路的平均**（F-17）。
**在一個平均值上加入一個低於現值的樣本，平均值會下降**——那是算術，不是缺陷。

⇒ 一條新鏈路以低於當前均值的速率變忙 ⇒ 均值下降 ⇒ **這條不變量在完全正確的系統上發火。**

🔑 **反諷之處值得記**：這條不變量是為了偵測「分母算錯」而寫的，
而**它自己用了一個錯的分母模型**。

**修法**：要偵測 F-17，正確的比較是
**「端點回報的值」對「自己用 `isUsable` 邊重算的均值（分母含閒置邊）」**——
Muse 在 INV-04 裡已經寫對了這個做法。**INV-08 這半條刪掉，指向 INV-04。**

---

## ✅ 兩份的優點（不要在修上面兩條時弄丟）

- **每條不變量都指名了獨立路徑**，而且 INV-06 明文寫 **"Do NOT check HTTP codes"**——
  對一個有「回報成功但沒動作」前科的系統，這是正確的起手式
- 🔑 **飽和標記貫穿全文**：INV-04 把 `link_bandwidth_usage_bps` 標成
  **🔴 BOUNDED … beyond bound they are DECORATIVE**、INV-02 標了邊數在拓樸大小飽和。
  **這正是同一天 `mainDev` 在自己的階梯偵測器上學到的（`busy` 頂到 1.000）**，
  而 Muse 是**獨立**寫出來的
- INV-07 把 N-1（wall-clock 殭屍）接上一個**具體可執行的動作**（注入 NTP step）——
  那條假設至今未驗，這是第一個能驗它的設計
- DeepSeek 的行動面**每條都附 `檔案:行號`**，並自己驗證了兩條先前發現
  （「400 但仍安裝」在 `priority` 那格已修、但可用非法 match 值重新製造；
  `installOne` 的無條件 `push_back` 仍在）。
  它獨立指出的 shell 注入我**逐項複驗四個環節後全部成立**，已升級 KNOWN-ISSUES B-2b（`9b69e74`）

---

## 🔑 通則：**這類產出擅長「該檢查什麼」，不擅長「在這個環境裡什麼會壞」**

兩個必修缺陷是同一種東西：**結構正確，而環境特定的陷阱照樣踩進去。**

- `pgrep` 的 comm 截斷 —— 我們**兩週前付過這個學費**，它是我記憶裡那條的第一項
- 「平均值單調」—— 需要知道**這個端點的分母只含忙碌鏈路**，那寫在 F-17 裡

⇒ **它們讀得到 repo，讀不到我們踩過的坑。**
**分工因此是清楚的：讓它們產生結構與覆蓋面，由我們補環境特定的判準。**
⚠️ **反過來不行**——不要拿它們的產出直接跑，**尤其是「獨立路徑」那一欄**，
那正是最需要環境知識、也最容易靜默失效的地方。

📌 附帶：Muse 自己標了「Chinese term searches 執行了但不完整、213 個 review 未分類」——
**它主動聲明覆蓋邊界，這比多找到幾條有用。**

[Co-developed with claude code -- Adam]
