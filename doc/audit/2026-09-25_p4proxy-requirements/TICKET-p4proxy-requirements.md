# TICKET-p4proxy-requirements — `p4_proxy/requirements.txt` 要描述我們實際測過的環境；再試升 protobuf

[Co-developed with claude code -- Adam]

- 發單：orchestrator「9/24 ochestrator」，2026-09-25；base＝trunk HEAD。
- **Adam 09-25 裁決**：先讓檔案與實測環境一致，再試升級；dependabot 警告**先不關**（留著當提醒）；低優先。

## 1. 事實（09-25 讀，OBSERVED；自己再核）

- dependabot（`ndtwin-lab/NDTwin-Kernel-P4` 預設分支）2 個 high，都是 `protobuf`（pip，`p4_proxy/requirements.txt`）：
  GHSA-8qvm-5x2c-j2w7／CVE-2025-4565（純 Python backend 解析不受信資料的深遞迴 DoS，修於 4.25.8）；
  GHSA-7gcm-g887-7qv7／CVE-2026-0994（`json_format.ParseDict()` 巢狀 `Any` 遞迴深度繞過，修於 5.29.6）。
- 檔案釘 `protobuf==3.20.3`，自己的註解：p4runtime 產生的 `_pb2` 在 protobuf ≥4.21 import 不了。
- **檔案與實跑 venv 不一致**：`p4_proxy/venv` 是 Python 3.13.13、p4runtime 1.5.0、grpcio 1.82.1、protobuf 3.20.3（backend＝`python`）；檔案寫 `p4runtime==1.4.1`、說在 3.12 驗證。
- 誰吃這個檔：`tools/test_workflow/components.env:45`（`P4_PROXY_PY`）、`stack.sh:1048`（叫使用者 `pip install -r`）、`.github/workflows/ci.yml:89`。
- INFERRED：proxy 只解析本機 bmv2 送來的 protobuf，`p4_proxy` 內無 `json_format`（只有 `text_format.Merge` 讀本機 p4info）⇒ 實際風險低。

## 2. 要做的

1. **對齊**：在你的 worktree 裡**新建**一個 venv（不准碰主 checkout 的 `p4_proxy/venv`，live 在用），照「實跑環境」修改後的 `requirements.txt` 安裝，跑 p4_proxy 全套＋`tools/p4_exercise` 全套，數字要和主 venv 相同。檔案寫明 Python 版本與驗證日期；CI 的 Python 版本若不一致，照實改或在 SUMMARY 說明為何不改。
2. **試升**：另開第二個 venv 試 `protobuf>=5.29.6`（必要時連 p4runtime／grpcio 一起升，或重新產生 `_pb2`）；全套測試結果照實記錄。**過了**＝交一個候選 commit（不併）；**沒過**＝寫清楚卡在哪，不要硬修。
3. 不要在 GitHub 上動任何 alert。

## 3. 驗收

- 兩個 venv 的建立指令、`pip freeze`、全套測試最後一行都進 SUMMARY 與 `logs/gates-0910/*.p4req-*.log`。
- 若試升通過：orchestrator 在 lab 上以該 venv 跑 live 01／06 各一次再決定併不併（live 由 orchestrator 做；你備好切換 venv 的最小方法，不改預設）。

## 4. 紀律

同 `doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md` §3。PyPI 下載可以；venv 放你的 worktree 裡、交件時列出大小。
交件：`scratch/overnight-2026-09-05/hunt-0911/fix/P4-REQ-SUMMARY.md`。
