# Phase 8: P4 Programs, Mininet & Topologies (P4 程式與拓撲配置) 審查總結

## 1. 測試腳本的完整度與覆蓋盲區

### Python 拓樸建構腳本缺乏單元測試
在 `p4_proxy/mininet/p4_testbed_topo.py` 中，負責啟動 BMv2 交換機並連結 Mininet 的腳本**完全沒有被任何 Python 單元測試覆蓋**。所有的驗證都是依賴於 `run_layers.sh` 與 `stack.sh` 這類的 E2E 整合測試。
雖然對於這種基礎設施建置腳本來說，E2E 測試通常是主要手段，但缺乏針對 `BMv2Switch` 類別中 `is_alive()` 或 `grpc_is_listening()` 的單元測試，代表系統在硬體資源耗盡（例如 gRPC Port 被佔用或記憶體不足導致啟動失敗）時的邊界行為，只能依賴除錯時的人工觀察。

### 設定檔 (Topology JSONs) 無 Schema 驗證
在 `setting/` 目錄下包含了多個龐大的 JSON 拓樸檔（如 `StaticNetworkTopologyMininet_10Switches.json`）。
系統中缺乏自動化的設定檔驗證機制（例如 JSON Schema validation）。若在部署時手誤打錯 JSON 欄位（例如將 `capacity` 的字串誤植為整數），錯誤不會在解析階段被攔截，而是會蔓延至 C++ 核心，並由那包山包海的 `catch(std::exception)` 吞噬，導致系統靜默失敗。

## 2. 邊界與錯誤處理 (Edge Cases)

### 背景行程的 PID 捕捉風險
在 `p4_testbed_topo.py` 中：
```python
out = self.cmd(f"{cmd} > {self.log_file} 2>&1 & echo $!")
self.bmv2_pid = int(out.strip().split()[-1])
```
這段依賴 `echo $!` 來獲取背景 Simple Switch gRPC 的 PID。如果 `cmd` 執行過程中產生了額外的警告或多行輸出（例如某些環境下的 bash profile 輸出），`.split()[-1]` 可能會抓到非整數的錯誤字串，導致 `ValueError`。雖然有 `except (ValueError, IndexError): self.bmv2_pid = None` 捕獲，但這會讓後續的關機邏輯無法殺掉該行程，導致僵屍行程 (Zombie Process) 與 Port 佔用問題。

## 總結
Phase 8 的測試覆蓋嚴重依賴 E2E 腳本，且設定檔與 Mininet 建構腳本缺乏嚴謹的邊界值處理。這增加了日後擴展拓樸或升級 BMv2 版本的維護風險。
