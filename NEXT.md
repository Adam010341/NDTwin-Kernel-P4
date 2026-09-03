# 交接：`fix/ndt-sudo-surface`（第四件，未開始）

2026-09-03 01:30 寫。[Co-developed with claude code -- Adam]

**分支從這一支（`fix/g7-ndtwin-lab-config`）的頭長出去**——它要動的兩個檔，其中
`tools/test_workflow/ndtwin-lab` 我在 G-7 已經改過。合併順序 auditor 已裁：
**G-9 → G-7 → 這一支**。

**為什麼今晚沒做**：三支已交付的分支各自帶著會紅的變異閘門，這一支要動的是**提權面**，
而且要證明兩個方向（沒權限紅／有權限綠）。在做了四小時之後趕一支安全相關的分支，
換來的是一個「大概有測」的閘門——auditor 的裁決是品質壓過涵蓋率，所以停在這裡。

## 出處

- 來源是手冊線 `ndtwin-kernel-d8` 的 desk check；auditor（`ndtwin-kernel-c4`）轉述給我。
  **要逐行原文直接找 `d8`，不用經過 auditor**（auditor 2026-09-03 明講）。
- 下面的行號與引文是**我自己在 base `6283ff5e` 上讀過**的，不是轉述。

## 病灶一：`ovs_bridge_count` 的吞噬鏈

`tools/test_workflow/ndt:1177`：

```bash
ovs_bridge_count() { sudo -n ovs-vsctl list-br 2>/dev/null | grep -c . || true; }
```

sudo 被拒 → stderr 被 `2>/dev/null` 丟掉 → `grep -c` 對空輸入得 `0` → `|| true` 吃掉非零 rc
⇒ **回 0，與「真的沒有橋」無法區分**。

消費者在 `ndt:647-648`（`up_p4` 的守衛）：

```bash
if topo_session && [[ "$(ovs_bridge_count)" -gt 0 ]]; then
    err "an OVS fabric is running ($(ovs_bridge_count) bridges) under the topo session."
```

⇒ 在沒有 `ovs-vsctl` NOPASSWD 規則的機器上，**守衛永不觸發，`ndt up` 會靜靜拆掉別人正在跑的
OVS fabric**。碼裡的註解說這個行為已經修掉了；在沒有額外規則的機器上它原樣復活。

## 病灶二：`dataplane_ok` 把「沒權限問」翻譯成一句關於資料平面的斷言

`ndt:1203-1208`（檔頭 `:1192` 自己寫著 `0 forwards, 1 does not, 2 could not be tested`）：

```bash
dataplane_ok() {
    local pid; pid="$(host_pid "$1")" || return 2
    [[ -n "$pid" ]] || return 2
    sudo -n mnexec -a "$pid" ping -c 2 -W 2 -q "$2" >/dev/null 2>&1 || return 1
    return 0
}
```

sudo 被拒 → `|| return 1` ⇒ 走「不通」那條，於是 `verify_dataplane`（`:1211-1223`）印出：

```
data plane: h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding
```

**這不是誤報，是把「沒權限問」翻譯成一句關於資料平面的具體斷言。**
誤報會被懷疑；具體的錯誤訊息會被相信，然後有人去 debug 一個不存在的轉發問題。

`ndt:1201` 的註解本身就把假設寫死了：
「mnexec is the form **this machine's** sudoers allows without a password」。

## 修法方向（auditor 已裁，不要重新討論）

**走 `ndtwin-lab`（已經是 root，不必再 sudo，也不擴大提權面），不要擴 sudoers。**
擴 sudoers 是每台機器都要重做一次的修法，且把「使用者忘了設」變成永久的失敗模式。

會動兩個檔：`ndtwin-lab` 加子命令（`ovs-br-count`、`host-ping` 之類）、`ndt` 改呼叫點。

## 驗收條件（auditor 原文，寫進測試）

- 沒有權限時 `dataplane_ok` **必須回 2，不准回 1**。**這是這條案的核心，不是附帶。**
- `ovs_bridge_count` 在**無法查詢**時必須與**真的是 0 座橋**可區分——
  回 0 然後被當成「沒有 OVS」正是缺陷本身。
- 變異閘要能證明兩個方向：把權限拿掉要紅、權限正常要綠。
  模擬「權限被拒」**不要用真的改 sudoers**，用一個會回非零的假 `sudo` shim 放在 PATH 前面即可。

🔴 **不要改 `/etc/sudoers`、不要 `visudo`、不要動已安裝的 `/usr/local/sbin/ndtwin-lab`。**
全部只在 repo 內的副本做。

## 🔴 要寫進那一支的 RATIONALE 的一句話

這條缺陷**四輪 usertest 都沒抓到，因為 tester VM 給了全域免密碼 sudo**——
**我們為了讓測試跑得動而放寬的條件，正好關掉了被測物最重要的一條失敗路徑。**
測試設計要避免重蹈：不要用「反正我有 root」的環境去驗這條。

## 給接手的人：三支已交付分支裡可以直接抄的東西

- **假 `sudo` shim 的寫法**：`fix/g6-ndt-apps-liveness` 的
  `tests/shell/test_ndt_apps_liveness.sh` 已經有一個——它把 `sudo` 換成 shell function，
  記錄呼叫、可設 rc。🔴 **注意那裡踩到的坑**：所有 `app_*` 都在 `$( )` 裡跑，
  函式內對變數的賦值留在子 shell，父層看不到；**呼叫紀錄要寫檔案不要寫變數**
  （第一版斷言在變數上，那條斷言是空的，怎麼改程式都會過）。
- **變異閘門骨架**：三支的 `mutate_*.sh` 同一個形狀（anchor 唯一性、逐一變異、
  記錄**具名檢查**、只註解的對照組、`cp -p` 快照 + EXIT trap + 結束 `cmp` 對帳）。
  直接複製改 `NDT=` / `SUITE=` / 案例即可。
- **`ndtwin-lab` 已經可以被 `source`**（G-7 與 G-9 各自加了 sourced-guard，
  合併後只會有一份），所以新子命令的邏輯測得到，不必用 root 跑。
  🔴 但 `ndtwin-lab` 帶 `set -euo pipefail`，**source 之後測試要 `set +e`**，
  否則第一個故意觸發的失敗會讓套件中途離開、而且已跑過的每一條仍印成 `ok`，
  看起來像通過只是提早結束（G-7 實測過這個坑）。

## 今晚新定的環境規則（auditor 2026-09-03）

- **不要輸出到共用的 `build/`**，要編就用自己的 `build-<name>/`。
- **不要用套件安裝的執行檔當當機素材**（`bash -c 'kill -ABRT $$'` 會在 Adam 螢幕上彈出
  Ubuntu 當機視窗，已經發生過一次）。
- lab claim 在 auditor 手上到 01:51；不要 `mn -c`、不要拆別人的 fabric。
