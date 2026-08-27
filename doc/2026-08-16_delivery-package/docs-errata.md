# ndtwin.org/docs 勘誤(2026-08-15/16 提出,2026-08-21 與 08-27 複驗)

給文件站維護者。**兩條成立**,照文件字面操作會失敗或誤導,各附實測證據。
原本的第 1 條(port 6633)**已撤回** —— 它是錯的,理由寫在最後一節,請不要照它改。

---

### 1. NTG 頁:`sudo ./testbed_topo.py` 會用錯直譯器

**狀態:✅ 成立(08-27 複驗)**

頁面:`/docs/ndtwin-user-manual/ndtwin-tools/networktrafficgeneratorntg/` 步驟②。

`sudo ./testbed_topo.py` 以 `/usr/bin/python3` 執行,缺 `nornir`/`loguru` → 立即
ImportError。實際要用裝了那些相依的環境執行(我們機器上是
`sudo <ntg-env 的 python> testbed_topo.py`;腳本自己會 `sys.path.append` 借系統 Mininet)。

**建議**:文件明載相依套件與直譯器要求,或給一行「用哪個 python」的說明。

> ⚠️ **改之前先確認你在改哪一支** —— 站上有**兩支同名的 `testbed_topo.py`**,
> 只有其中一支有這個問題:
>
> | 出處 | 行數 | 額外 import | 系統 python3 跑得動? |
> |---|---:|---|---|
> | 安裝手冊 §5 貼的(`assets/snippet/`) | 240 | 無 | ✅ **可以**(實測 3.12.3 全部 import 成功) |
> | NTG 頁自己的(User Manual) | 250 | `from network_traffic_generator import command_line` | ❌ 需要 ntg-env |
>
> **本條只適用於下面那一支。** 如果照這條去改安裝手冊那一支,會把一個本來能跑的
> 範例改成需要額外環境,反而擋住讀者。

### 2. kernel 端點清單少了約一打:實際 41 條,文件列 29

**狀態:✅ 成立(08-27 重數仍是 41,跨 580 個 commit 沒變)**

kernel HTTP dispatcher 的字面 route(`src/ndt_core/http/HttpSession.cpp`)去重後共
**41 條** `/ndt/` 路徑,文件的端點清單只有 29。缺的包括 lock 生命週期
(`acquire_lock`/`release_lock`/`renew_lock`)、meter/group entry 的 install/modify/delete、
`intent_translator/text`、`historical_logging` 等。

**建議**:以 dispatcher 為真實來源重生清單;或至少補上缺的一打。
(counting 方法:對 HttpSession.cpp 的字面字串 `"/ndt/..."` 去重——如另有拼接組出的
route 不在此數內。)

---

## 🔴 已撤回:「Ryu 監聽 port 應為 6653,文件寫 6633」

**這一條在 2026-08-21 的 live 複驗中被否證。文件是對的,不要改。**

原本的主張是:文件寫 `--ofp-tcp-listen-port 6633`,但 switch 實際撥 6653,所以照文件跑
永遠連不上。**實測結果相反:照文件逐字跑,10/10 個 switch 都連上了。**

原因在 Mininet 自己。`RemoteController.checkListening`
(`/usr/lib/python3/dist-packages/mininet/node.py:1551`)在沒有明指 port 時,
**兩個 port 都探,誰有回應就連誰**:

```python
else:
    for port in 6653, 6633:
        if self.isListening( self.ip, port ):
            self.port = port
            ...
            break

if self.port is None:
    self.port = 6653          # 只有兩個都不通才落到這個預設
```

⇒ **6653 只是「兩個都探不到」時的退路,不是硬性要求。** Ryu 聽 6633 時,
第二輪探測就命中了。

🔑 **當初怎麼會弄錯的**:證據是 `ovs-vsctl get-controller` 讀到 6653 —— 那個讀數本身沒錯,
但它是**結果**不是**規格**。那台機器上當時 Ryu 剛好聽在 6653,所以探測第一輪就中。
**把一次觀察到的協商結果當成了協定要求。**
