# P4Runtime 規格查證：SetForwardingPipelineConfig 的 mastership 條款

[Co-developed with claude code -- Adam]

這份文件是「bmv2 接受非 primary 的 pipeline push」上游回報準備的**離線一半**：把規格條文
釘死、引文可覆核。另一半（用第三方 client 重現，排除我方 client 的嫌疑）需要活的 bmv2，
狀態與阻礙記在 `doc/audit/2026-08-12_overnight-review/` 的 mastership 段與交接筆記
（`p4lang/tutorials` 的 `p4runtime_lib` 會在 `MasterArbitrationUpdate()` 永久阻塞，
要繞過它的 stream 封裝手寫低階 gRPC）。

## 我們觀測到的行為（2026-08-13 下午，live 坐實）

對 s10：仲裁被拒（`mastership_confirmed=False`，election id 較低）之後，
`set_forwarding_pipeline_config()`（`VERIFY_AND_COMMIT`）**照樣成功**，表上規則 4 → 0。
同一個連線的 route `Write` 則被正確拒絕。也就是說 bmv2 對 `Write` 有 primary 檢查、
對 `SetForwardingPipelineConfig` 沒有——而後者的破壞力更大（清整張表）。

## 規格怎麼說

來源：`p4lang/p4runtime` 的 `docs/v1/P4Runtime-Spec.adoc`，main @ `c33bd2e`
（2026-06-12）。以下逐字引用。

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

「must return a `PERMISSION_DENIED` error」——不是 SHOULD，沒有裁量空間。

**舊版同文**：v1.3.0（bmv2 世代對應的版本；當年檔名還是 `P4Runtime-Spec.mdk`）同一句
逐字存在（欄位名是 `role_id` 而非 `role`，僅此差異）：

> 2. If the client is not the primary for (`device_id`, `role_id`) according to
>    the `election_id` value, the server must return a `PERMISSION_DENIED` error.

**對照組——`Write` RPC 的檢查清單有一模一樣的第二條**（v1.3.0 與 main 皆然）。
bmv2 對 `Write` 是有執行的（我們實測非 primary 的 route push 被拒），所以這不是
「實作沒跟上新規格」，是**同一條規則在同一個 server 裡只做了一半**。

另外可佐證危害機制的一句（`VERIFY_AND_COMMIT` 的語意）：

> `VERIFY_AND_COMMIT`: saves and realizes the given config if the P4Runtime
> target can realize it. The forwarding state in the target is cleared.

規則 4 → 0 的清表**對 primary 而言**是規格內行為；整個缺陷只在缺了那道 primary 檢查。

## 結論與回報主張

- **主張**：bmv2 / PI（`simple_switch_grpc`，本機 binary `1.15.3-f0b7d201`）違反
  P4Runtime 規格 `SetForwardingPipelineConfig` 一節的檢查次序第 2 條：非 primary client
  的 pipeline push 未被 `PERMISSION_DENIED` 拒絕，且因 `VERIFY_AND_COMMIT` 清表而
  具破壞性。規格自 v1.3.0 至 main 一致，無版本模糊空間。
- **回報前仍缺**：第三方 client 重現（排除我方 `p4_client.py` 的組包嫌疑）。
  現有嘗試與繞法見上；需要活的 bmv2。
- 疑似的實作落點在 PI 的 device/mastership 管理（`Write` 路徑有檢查、
  `SetForwardingPipelineConfig` 路徑沒有），但**未讀 PI 原始碼求證**——回報時交給上游
  定位即可，不必替他們猜。

## 覆核方式

```bash
gh api repos/p4lang/p4runtime/contents/docs/v1/P4Runtime-Spec.adoc --jq '.content' | base64 -d | grep -n -A3 "not the primary for"
```

v1.3.0：同指令加 `?ref=v1.3.0`、檔名換 `P4Runtime-Spec.mdk`。
