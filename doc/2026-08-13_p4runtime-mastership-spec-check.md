# P4Runtime mastership：規格查證 + live 重現（結論：**bmv2 沒有違反規格，是我方的 election id 重用**）

[Co-developed with claude code -- Adam]

> ⚠️ **2026-08-13 晚更正。** 這份文件原本是「bmv2 接受非 primary 的 pipeline push」**上游回報
> 的準備稿**，主張 bmv2 違反規格。**live 第三方重現（C8）推翻了那個主張。**
> **上游回報取消——不要送出。** 原本的主張與「殺手佐證」（Write 有檢查、pipeline push 沒有）
> **兩者皆不成立**，詳見下面第 2、3 節。規格引文（第 1 節）本身查證無誤，保留。

## 1. 規格怎麼說（此節內容不變，引文查證無誤）

來源：`p4lang/p4runtime` 的 `docs/v1/P4Runtime-Spec.adoc`，main @ `c33bd2e`（2026-06-12）。

`SetForwardingPipelineConfig` RPC 一節，server 在動作前**依序必查**的第二條：

> The server is expected to perform the following checks (in this order)
> before performing the required `action`:
>
> 1. If `device_id` does not match any of the devices known to the P4Runtime
>    server or if `role` does not match any of the roles for the device, the
>    server must return a `NOT_FOUND` error.
>
> 2. If the client is not the primary for (`device_id`, `role`) according to
>    the `election_id` value, the server must return a `PERMISSION_DENIED` error.

v1.3.0 同句逐字存在（欄位名是 `role_id` 而非 `role`）。`Write` RPC 的檢查清單有一模一樣的第二條。

**但關鍵在「according to the `election_id` value」這句話怎麼解**——當初就是這裡讀漏了。
同一份規格在 controller 連線模型一節（`P4Runtime-Spec.adoc:528`）寫得很白：

> A server must use all three of these values from a `WriteRequest` message to
> identify which client is making the `WriteRequest`, not only the `election_id`.

那「三個值」是 (`device_id`, `role`, `election_id`)，而且**是從 request 訊息裡讀的**。
也就是說：**unary RPC 的送出者身分，規格規定就是用訊息裡帶的那組三元組認定，不是用它從哪條
連線進來認定。** 任何帶著 primary 三元組的 client，在 server 眼中就是 primary。
這正是我方 client 會「以非 primary 身分推成 pipeline」的原因，而且 server 的行為是對的。

## 2. live 重現結果（2026-08-13 晚，C8）

工具：`p4_proxy/reference/p4runtime_mastership_probe.py`（**第三方 client**，只用 raw grpc ＋
stock protobuf，與 `p4_client.py` 零共用組包程式碼——排除我方 client 的嫌疑本來就是這步的目的）。
對象：本機 `simple_switch_grpc` **1.15.3-f0b7d201**，10 台 live bmv2，每個情境各用一台乾淨 device。

| 情境 | 設定 | pipeline push | route Write |
|---|---|---|---|
| 1 真正的非 primary | A `(0,2)` primary、B `(0,1)` backup（**兩條 stream 都活著**） | **`PERMISSION_DENIED: Not primary`** | `PERMISSION_DENIED: Not primary` |
| 2 election id 重複 | O `(0,1)` primary、D `(0,1)` 重複（D 的 stream 被殺） | **`OK`（清表 1→0）** | **`OK`** |
| 3 順序 | 情境 2，但在兩個 RPC 之間關掉 O 的 stream | `OK`（O 還活著時） | **`PERMISSION_DENIED: Not primary`**（O 走了之後） |

**情境 1 直接推翻原主張**：面對 election id 確實較低、且經 bmv2 明確回覆
`code=6 (ALREADY_EXISTS) "Is backup"` 的 client，bmv2 **有**擋下 pipeline push，回的正是規格
要求的 `PERMISSION_DENIED`。腳本會先自證「A 是 primary、B 是 backup」才往下跑，
所以這不是偽陰性。

**情境 2 推翻「殺手佐證」**：原文說「Write 這條檢查 bmv2 有做、pipeline push 沒做」。
實測是**兩個都放行**——根本沒有那個不對稱。當初之所以看起來不對稱，是情境 3 的順序造成的。

## 3. 那 08-13 下午看到的四行 log 是什麼？

下午對 s10 的觀察本身沒錯（仲裁被拒 → pipeline push 成功 → route 全被拒 → 回報 success），
**錯的是對機制的推論**。真正的因果鏈是情境 2 + 情境 3：

1. `p4_client.py` **把 election id 寫死成 `(high=0, low=1)`**——arbitration（`:186`）、
   `SetForwardingPipelineConfig`（`:273`）、每一個 `Write`（`:308`/`:518`/`:576`/`:608`）全都是。
   所以 readopt 開的「新 client」跟還在線上的舊 client **是同一組三元組**。
2. 新 client 的 arbitration 因**重複**被 bmv2 依規格殺掉 stream
   （`INVALID_ARGUMENT: Election id already exists`）→ `mastership_confirmed=False`。
   ⚠️ 下午把這個狀態記成「election id 較低」，**那是推論不是觀察**；
   當時自己的 log 明明白白寫著 `Election id already exists`（＝重複，不是較低）。
3. 新 client 推 pipeline，帶的 `(0,1)` **正好等於當時在線 primary（舊 client）的三元組**
   → server 依規格認定它就是 primary → **放行、清表**。
4. `topology_manager.readopt_switch` 接著在 `:831` 呼叫 `old.stop()`，**把真正的 primary 關掉**，
   然後才在 `:836` 跑 `install_initial_routes()`。此時已無任何在線 primary，
   `(0,1)` 對不上任何人 → **每一筆 route write 都 `Not primary`**。

所以「pipeline 過、route 全拒」不是「兩個 RPC 檢查得不一樣」，而是**中間那個 `old.stop()`**。
情境 3 把它做成對照實驗坐實：同一個 client、同一組 election id、同一種 RPC，
**唯一變數是 primary 還在不在**，結果就從 `OK` 翻成 `PERMISSION_DENIED`。

## 4. 結論

- ❌ **不回報上游。** bmv2 / PI（`1.15.3-f0b7d201`）在三個情境下**行為都符合規格**：
  真非 primary 擋下、重複 election id 殺 stream（規格明訂 shall terminate with
  `INVALID_ARGUMENT`）、unary RPC 依訊息裡的三元組認定身分（規格明訂）。
- ✅ **真正的缺陷在我方**：`p4_client.py` 對每一個 client 都用同一組寫死的 election id `(0,1)`。
  這讓 readopt 的「新 client」在協定層面**與現任 primary 無法區分**，於是它能用對方的憑證
  做一次破壞性清表。
- ✅ **既有的防呆（`topology_manager.py:800` 的 mastership gate）依然正確、不必動。**
  它擋的是「arbitration 沒拿到就不准碰 switch」，在新的理解下反而更站得住腳：
  那個 client 是拿別人憑證的冒名者。**只有它的註解把機制寫錯了**，已一併更正。
- ⏳ **election id 政策仍是 Adam 的裁決**（甲類既有項）。這次多了一條實測依據：
  在本機 bmv2 上，**所有 controller 都離線之後，用同一組 `(0,1)` 重新 bid 仍可再次當選
  primary**（情境 2/3 在同一台 device 上重跑兩輪都成立），所以「每次 readopt 遞增 election id」
  不是唯一可行解，「沿用固定值但確保舊 client 先退場」也在選項內。
  ⚠️ 這句是**實測行為**，不是從規格推導的——規格 v1.1.0 的敘述比這嚴格。

## 5. 覆核方式

規格引文：

```bash
gh api repos/p4lang/p4runtime/contents/docs/v1/P4Runtime-Spec.adoc --jq '.content' | base64 -d | grep -n -A3 "not the primary for"
```

live 重現（需要活的 bmv2；**會清掉目標 device 的表**，只對 scratch switch 跑）：

```bash
p4_proxy/venv/bin/python p4_proxy/reference/p4runtime_mastership_probe.py --scenario all
```
