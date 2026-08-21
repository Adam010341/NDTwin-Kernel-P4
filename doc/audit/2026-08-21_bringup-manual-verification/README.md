# 開機手冊 §2 的實跑驗證（2026-08-21）

驗證對象：`doc/2026-08-17_testing-manual.md` **§2 開機手冊**（當天寫的初稿）。
方法：從乾淨環境照著手冊寫的順序一路走到底，P4 128 台與 OVS 128 台各一輪，
把每一條宣稱都執行一次。**不符的算手冊的缺陷，不算跑的缺陷。**

跑的環境：`52cba51`，實驗室由 mainDev 於 17:47 釋出後接手，全程單一 actor。

| 檔案 | 是什麼 |
|---|---|
| `TRANSCRIPT.md` | 逐字輸出（含每一步的 rc 與秒數） |
| `verify_bringup_manual.sh` | 產生上面那份的腳本 |
| `which_links_down.sh` | 追查「256 條鏈路 down」的後續實驗 |
| `ovs_graph_snapshot.json` | 那一輪 OVS 的 `/ndt/get_graph_data` 快照，分類的原始資料 |

**為什麼是 script 檔而不是命令列**：`ndt status` 會對 Mininet 的行程標籤、bmv2 的
執行檔名與 `iperf3 -c` 跑 `pgrep`/`ps`。命令列裡出現這些字串會匹配到自己、
汙染它正在讀的計數。script 的 argv 只有它自己的路徑。

---

## 手冊被推翻的三條（都已在原地改正）

### 1. 🔴 `ndt status --check` 在 OVS 上永遠 rc=1，而初稿把它當驗收關卡

初稿 §2.3 寫「`ndt status --check`，exit 非零 = 有東西會讓量測不可信」，並沒有分平面。
實跑：**OVS 一輪剛開完就 rc=1**，而同一輪的跨象限 ping 全通（0% 掉包）。

```
links          288 total, 256 down, 0 admin-disabled
check: 1 problem(s)
  - 256 link(s) are down
```

**沒有停在算術上。** 288 − 32 = 256 而且 128 hosts × 2 = 256，算式吻合——但這個 repo
已經因為「算式吻合就當機制」栽過三次，所以去讀了 kernel 自己的圖，逐條分類：

| 邊 | 數量 | `is_up` | `is_enabled` |
|---|---:|---|---|
| switch ↔ **host**（`dst_dpid=0`，如 `dpid 1:3 → 10.0.0.1`） | **256** | `False` | `False` |
| switch ↔ switch（如 `dpid 1:1 → dpid 5`） | 32 | `True` | `True` |

**down 的 256 條全部是 host 邊，一條不多一條不少。** OVS 平面從不把 host 邊標成 up，
而 P4 平面會（同一天 P4 輪：`288 total, 0 down`）。

⇒ **OVS 沒有一鍵驗收。** 已改成：P4 看 rc=0；OVS 要看「列出來的問題是不是只有這一條」。

### 2. veth 數不是 0

初稿 §2.1 寫「實測 0/0/0/0」。實測**永遠有 4 條 veth**，屬於 Docker
（`ndt-frontend` :3000、`ndt-node-positions-api` :3001、`ndt-postgres` :5433，
加一個 hugo 容器），跟實驗室無關。netem 與 OVS bridge 收乾淨後確實是 0。

### 3. 秒數

| | 初稿 | 實測 |
|---|---|---|
| `ndt up p4 128` | 35–40 s | **33.6 s** |
| `ndt up ovs` | ~25 s | **24.1 s** |
| `ndt down` | 13 s | **13.3 / 13.8 s**（空的實驗室 1.6 s） |

---

## 順手抓到的：兩行會在畫面上自打嘴巴的訊息

`ndt:783` 與 `stack.sh:208` 都印
「the Ryu app sleeps a hard-coded 60s before installing paths, so this takes >60s」。
那個 60 秒**當天稍早已經改成 `NDTWIN_RYU_SETTLE_S`（預設 10）**，訊息沒跟著改。
實測收斂 20 秒、整個 `ndt up ovs` 24.1 秒——**操作員看到的字和碼表差 3 倍**。
已改成印當下真正生效的值。`stack.sh` 的兩處註解（`:163`、`:192`）一併更正。

這是 [committed setter / uncommitted reader] 那一族的第三種形狀：
**碼改了、講這段碼的字沒改**，而字比碼更常被讀。

---

## 手冊宣稱、實跑對上的部分

- `ndt up ovs 16` 依約拒絕，rc=2，訊息指向 `ovs` / `ovs4` / `p4 16` ✅
- `ndt clean` 檢查的正是那五件事，兩個平面收完都印綠色 `clean` ✅
- 跨象限連通性 h1→h64 / h64→h128 / h128→h1，兩個平面各 3/3、0% 掉包 ✅
- 跑的是 fast build（`/usr/local/bmv2-fast/bin/simple_switch_grpc`）✅
- `ndt ntg` 正確回報 `cli` ✅
- P4 的 `--check` rc=0、`288 total, 0 down` ✅
- **Ryu 不帶旗標時 6653 和 6633 兩個都在聽**（`ss` 實證）——與 §2.2 摺疊區那條
  「6633 假警告」的更正一致 ✅

## 沒驗到的

- **`ndt up ovs4`**（4 台）本輪沒跑，時間仍沿用先前紀錄。
- **`ndt apps`** 五個 app 一個都沒起（會改變網路的有兩個，不適合塞進驗證輪）。
- **每台 switch 實際撥哪個 OpenFlow port**：腳本寫成
  `ovs-vsctl get-controller s1 s5 s10`，而該指令最多吃一個參數，所以這一格是空的。
  三臂實測在 `doc/audit/2026-08-21_ryu-topology-scaling/`，本輪只重驗了「兩個埠都在聽」。
- **中斷 teardown**（§2.8 摺疊區）沿用 08-21 稍早的實測，本輪沒重跑。

[Co-developed with claude code -- Adam]
