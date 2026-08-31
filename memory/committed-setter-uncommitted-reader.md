---
name: committed-setter-uncommitted-reader
description: NDTWIN_CLONE_DISABLE：setter 和文件都已提交、reader 從來沒有——grep 得到、讀起來像接好的，實際是 no-op；比「完全不存在」更危險
metadata: 
  node_type: memory
  type: project
  originSessionId: ead7700c-55b2-4730-a1f9-4bdd2b99ee33
  modified: 2026-08-20T10:10:25.626Z
---

2026-08-20 實測。`NDTWIN_CLONE_DISABLE` 這個旗標**看起來是接好的，實際沒有任何程式碼讀它**。

**現況（全部驗過）：**

```
grep -rln NDTWIN_CLONE_DISABLE --exclude-dir=.git .
  doc/audit/2026-08-20_sampling-rate-and-cpu/FIGURES.md
  doc/audit/2026-08-20_sampling-rate-and-cpu/REPORT.md
  doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh          ← 設定它的那一行
  doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py
  doc/audit/2026-08-20_sampling-rate-and-cpu/analyse_matrix.py

grep -rn 'environ.get("NDTWIN_CLONE_DISABLE")' .    → 零個 reader
git log --all -S NDTWIN_CLONE_DISABLE              → 3 個 commit（都是上面那些檔）
```

🔑 **committed 的 setter ＋ committed 的文件 ＋ 零個 reader。**

reader 是每次 A/B 臨時手貼進 `p4_proxy/proxy_agent/p4_client.py`、用完還原的東西,
**從來沒進過版控**。我在 2026-08-20 16:30 親眼驗過它在 `p4_client.py:374`,
一小時後同一個檔已經是 clean 的。

**Why 這比「完全不存在」更危險:** 任何人 grep 都會找到 `matrix.sh` 裡的
`env NDTWIN_CLONE_DISABLE=1 ... stack.sh up p4`,再讀到 REPORT.md 描述它的行為,
然後**合理地**推論旗標是接好的。我和另一個 session 先後都這樣推論過。
帶了它跑會拿到一格「開著取樣卻被標成零點」的資料 —— `mnone` 那格的失敗模式
(實測 553.5 樣本/秒,而 1/64 是 556.1,它是 1/64 的複製品戴著零點標籤)。
這是 [[existence-is-not-wiring]] 最惡劣的變體:連文件都在幫忙誤導。

**How to apply:**
- 看到環境變數旗標,**先找 reader 再找 setter**。`grep` 到呼叫點不算數。
- 「clone session 在不在」可從編譯出的 `ndtwin_switch.json` 讀
  (`clone_ingress_pkt_to_egress`,參數 `0x000000fa` = 250 = SAMPLE_SESSION),
  但那是**必要非充分**:pipeline 有 clone op ≠ proxy runtime 真的裝了 session。
  唯一完整的驗證是**跑流量、確認 twin 讀到 0**。
- 🔴 **對「未提交的工作區狀態」給的建議有保存期限。** 我根據當時存在的手貼掛勾
  建議別人「直接帶 `NDTWIN_CLONE_DISABLE=1`」,給的當下正確、對方要用時已經過期。
  這種建議一定要標注「此刻為真,且它未進版控」。

相關:[[existence-is-not-wiring]]、[[ndt-one-command-lab-lifecycle]]、
[[no-in-repo-callers-is-not-dead-code]](同一枚硬幣的另一面)。

---

## 2026-08-20 深夜補：掛勾的原文與 apply/revert 紀律（另一個 session 實際用過）

上面說「reader 是手貼的、從來沒進版控」——**所以它的原文必須留在這裡，否則下次要零點的人得重新推導。** 貼在 `p4_proxy/proxy_agent/p4_client.py` 的 `write_clone_session()` **docstring 之後、`def build(update_type):` 之前**（貼在 docstring 前會讓 docstring 失效）：

```python
        # >>> NDTWIN_ZERO_POINT_HOOK -- TEMPORARY, MUST NOT BE COMMITTED <<<
        import os as _os
        if _os.environ.get("NDTWIN_CLONE_DISABLE") == "1":
            print("[p4_client] refusing to program clone session %s on device %s"
                  % (session_id, self.device_id), flush=True)
            return
        # <<< NDTWIN_ZERO_POINT_HOOK >>>
```

⚠️ `p4_client.py` **沒有 import `os`**，所以要 `import os as _os` 在區塊內。

**兩個相反方向的失敗，所以 apply 和 revert 都要自我驗證：**
- **忘了貼** → 零點是假的（`mnone` 的失敗模式重演）
- **忘了還原** → 一個「設了就靜默關掉全部遙測」的開關留在工作樹

實作方式（2026-08-20 用的）：apply 後驗「mark 在、檔案編得過、`git diff` 看得到改動」；
revert 後**對帳 git 而不是對帳自己的字串替換**——檔案必須與 HEAD 完全一致。

🔑 **但這兩個驗證都擋不住「貼錯地方」。** 唯一完整的驗證仍然是**跑流量、確認 twin 讀到 0**
（實測：617 Mbit/s 在跑、32 條邊全讀 0）。掛勾在不在 ≠ 它有沒有生效。

**還有一個前提**：只在 **cold fabric** 上有效。warm fabric 上前一代 proxy 留下的孤兒 PRE group
會繼續 cloning，掛勾貼了也沒用——那正是 `mnone` 出事的原因。見 [[ab-control-deleted-nothing]]。

---

## 🪞 2026-08-21:找到並修好了**完全相反**的那一面

`NDTWIN_RYU_TOPO_FILE`(`intelligent_router.py:36-38`)是 **committed reader、零個自動 setter**
—— 跟 `NDTWIN_CLONE_DISABLE`(committed setter、零個 reader)剛好對稱。全 repo 唯一的
`export` 是 08-17 報告裡**一行手打的**(`REPORT.md:182`)。

代價:`ndt up ovs4` 建 4 台 fabric,Ryu 卻照預設的 **128 台模型**算路由 →
**每一對主機 100% 遺失**,而 kernel 的圖、Ryu 的 `/v1.0/topology/hosts`、
`ndt` 自己的 `model matches fabric` **三者全部顯示正確**。

實測(移掉 setter 當變異對照):

| | 有 setter | 移掉 |
|---|---|---|
| `all_destination_paths` | **902 bytes** | **1,110,528 bytes** |
| 出現的主機 | `10.0.0.1-4` | 128 台 |
| `h1 -> 10.0.0.2` | 通 | **100% loss** |

🔑 **兩個方向的教訓是同一句:一個環境變數只有「setter 和 reader 都在版控裡、而且真的被
啟動路徑執行到」才算存在。** 只有一半的時候,它的行為是「有時候對」,而那比壞掉更難查。

修法:`up_ovs` 把它設成與 `TOPO_OVS` 同一個檔(commit `91229f5` 之前的 `f70e95a` 一輪),
並加了一條**會真的送封包**的斷言 —— 因為兩邊的拓樸視圖都是對的,結構性檢查抓不到。
見 [[ndt-one-command-lab-lifecycle]]。
