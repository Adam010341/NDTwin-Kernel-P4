# ndtwin.org/docs 勘誤三條(2026-08-15/16 實測)

給文件站維護者。三條都是照文件字面操作會失敗(或誤導)的等級,各附實測證據。

### 1. NTG 頁:Ryu 監聽 port 應為 6653,文件寫 6633

頁面:`/docs/ndtwin-user-manual/ndtwin-tools/networktrafficgeneratorntg/`(Mininet 模式步驟①)。
文件的啟動指令是 `--ofp-tcp-listen-port 6633`,但 NTG 的 `testbed_topo.py` 讓 switch
實際撥 **6653**(`ovs-vsctl get-controller` 實證)。照文件跑,switch 永遠連不上
controller,而且沒有任何錯誤訊息指向 port 不合——只會看到拓撲永不收斂。
**建議**:指令改 `--ofp-tcp-listen-port 6653`。

### 2. NTG 頁:`sudo ./testbed_topo.py` 會用錯直譯器

同一頁步驟②。`sudo ./testbed_topo.py` 以 `/usr/bin/python3` 執行,缺 `nornir`/`loguru`
→ 立即 ImportError。實際要用裝了那些相依的環境執行(我們機器上是
`sudo <ntg-env 的 python> testbed_topo.py`;腳本自己會 `sys.path.append` 借系統 Mininet)。
**建議**:文件明載相依套件與直譯器要求,或給一行「用哪個 python」的說明。

### 3. kernel 端點清單少了約一打:實際 41 條,文件列 29

kernel HTTP dispatcher 的字面 route(`src/ndt_core/http/HttpSession.cpp`)去重後共
**41 條** `/ndt/` 路徑,文件的端點清單只有 29。缺的包括 lock 生命週期
(`acquire_lock`/`release_lock`/`renew_lock`)、meter/group entry 的 install/modify/delete、
`intent_translator/text`、`historical_logging` 等。
**建議**:以 dispatcher 為真實來源重生清單;或至少補上缺的一打。
(counting 方法:對 HttpSession.cpp 的字面字串 `"/ndt/..."` 去重——如另有拼接組出的
route 不在此數內。)
