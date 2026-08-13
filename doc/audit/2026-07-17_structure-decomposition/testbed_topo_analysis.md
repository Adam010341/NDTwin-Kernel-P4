# testbed_topo.py 檔案架構與功能深度解析

看完了 C++ 核心與 Ryu 控制器，現在我們來到整個 NDTwin 系統運作的「最底層基礎設施」—— **`testbed_topo.py`**。

這是一支基於 Mininet 的 Python 腳本。在 NDTwin 的模擬模式 (Mininet Mode) 中，這份腳本負責無中生有地建立出一個包含數十台主機與交換機的虛擬網路環境。

以下為您詳細剖析這份腳本的核心設定，這對您後續轉換成 P4 環境非常重要：

---

## 1. 拓撲建立 (Topology Construction)
程式碼的前半段定義了 `MyTopo` 類別，它實作了這張網路的骨架：
* **10 台交換機 (`s1` - `s10`)**：分為邊緣層與核心層，形成一個具有備援路徑 (Resilient) 的網路架構。
* **128 台主機 (`h1` - `h128`)**：平均分配連接到最外層的四台邊緣交換機上。

> **與系統的關聯性**：這段程式碼建立出來的拓撲結構，必須與 NDTwin Kernel 讀取的 `StaticNetworkTopologyMininet_10Switches.json` 一模一樣。這就是為什麼 NDTwin 在模擬模式下可以直接讀檔，因為拓撲已經被寫死在這裡了。

## 2. sFlow 遙測設定 (Telemetry Configuration) - 本檔案最關鍵的邏輯
這份腳本不只是單純把網路跑起來而已，它還負責了非常複雜的 sFlow 底層設定，這正是 `FlowLinkUsageCollector.cpp` 能夠收到資料的原因。

腳本在網路啟動後執行了三個巧妙的步驟：
1. **建立 Collector 收信匣 (`os.system("sudo ip addr add 192.168.123.1/24 dev lo")`)**：
   為了讓虛擬交換機能把封包丟給架設在 Host 作業系統上的 NDTwin Kernel，腳本在 Linux 本機的 Loopback 介面上綁定了一個虛擬 IP `192.168.123.1`，假裝自己是 Collector。
2. **分配交換機 Management IP**：
   腳本為 10 台交換機分配了 `192.168.123.11` 到 `192.168.123.20` 的 IP。
3. **下發 `ovs-vsctl` 指令啟用 sFlow (`enable_sflow`)**：
   針對每台交換機，執行 `ovs-vsctl` 指令，告訴 OVS：「請把你抽樣到的封包，打包成 UDP 送給 `192.168.123.1:6343` 喔！」

## 3. 流量產生與 ARP 預先綁定 (Traffic Generation)
* **靜態 ARP 綁定**：為了避免網路剛啟動時產生可怕的廣播風暴 (Broadcast Storm)，腳本預先為 128 台主機互相寫入了靜態的 ARP 表 (`h.cmd(f"arp -s {dst_ip} {dst_mac}")`)。
* **並行 Ping 測試 (`ping_test`)**：在啟動的最後，腳本會開啟多個執行緒，讓這 128 台主機互相發送 Ping 封包。
  這個動作有兩個目的：
  1. 驗證連線是否成功。
  2. 刻意觸發 Ryu 控制器 (`intelligent_router.py`) 內的 `Packet-In` 事件，讓 Ryu 有機會認識這些主機，並把它們加到動態拓撲地圖中！

---

> [!WARNING]
> **給 P4 開發者的重點總結：這將是您的 P4 網路啟動腳本原型！**
> 
> 在您接下來的 P4 專案中，您將會寫一支類似的拓撲啟動腳本，但您需要做以下關鍵修改：
> 1. **交換機替換**：把 `OVSKernelSwitch` 換成 `P4Switch` 或 `Bmv2Switch`。
> 2. **Controller 替換**：您不能再把 Controller 指向 6633 port 的 Ryu。在 P4 環境中，您通常不會在建立拓撲時指定 OpenFlow Controller，而是讓您的 `P4-Proxy-Agent` 事後透過 P4Runtime (gRPC port，如 50051) 連進這些 BMv2 交換機。
> 3. **移除/重寫 sFlow 設定**：BMv2 無法透過 `ovs-vsctl` 來設定 sFlow。您可以選擇暫時移除這個設定（那麼 NDTwin 將無法收到流量數據），或是改用您自己的 P4 INT 遙測封包回傳機制。
