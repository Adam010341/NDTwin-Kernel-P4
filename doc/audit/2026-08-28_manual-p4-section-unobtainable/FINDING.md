# 🔴 官網手冊的整個 §6（P4／BMv2）對照著讀的人是**跑不起來的**

**2026-08-28 查核，純讀檔（`git cat-file` / `git show`），沒有跑任何安裝。**
對象：`~/NDTwin-Website` 分支 `docs/p4-bmv2-environment`，
檔案 `content/en/docs/NDTwin Installation Manual/NDTwin Kernel/Operate an Emulated (Software) Network/Native-Linux Excution Environment.md`

## 一句話

**§4.1 叫讀者 clone 公開的 `ndtwin-lab/NDTwin-Kernel`，而 §6.2–§6.7 用到的每一個 P4 檔案，那個 repo 都沒有。**

## 逐項對帳

| 手冊要求的路徑 | 出現在 | 公開 repo | 我們的分支 |
|---|---|---|---|
| `p4_proxy/p4_src/ndtwin_switch.p4` | §6.2 | ❌ | ✅ |
| `p4_proxy/requirements.txt` | §6.3 | ❌ | ✅ |
| `p4_proxy/proxy_agent` | §6.4 說明 | ❌ | ✅ |
| `p4_proxy/mininet/host_count_override` | §6.5 | ❌ | ✅ |
| `p4_proxy/mininet/bmv2_binary_override` | §6.6 | ❌ | ✅ |
| `setting/StaticNetworkTopologyP4_10Switches_128Hosts.json` | §6.5 | ❌ | ✅ |
| `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` | §6.5 | ❌ | ✅ |
| `AppConfig` 的 `P4_PROXY_IP_AND_PORT`／`ALLOW_MIXED_DATAPLANE` | §6.4 | **0 / 2** | **2 / 2** |

（最後一列查的是 `setting/AppConfig.hpp.example`，因為 `AppConfig.hpp` 本身被 `.gitignore`
擋著、由 CMake 產生 —— 見下。）

兩個 repo 的距離：**我們的分支領先 `origin/main` 672 個 commit。**

## 讀者實際會遇到什麼

§6.2 的第一行 `mkdir -p p4_proxy/p4_src/build` **會成功**（`mkdir -p` 樂於建空目錄），
所以讀者不會在那裡察覺不對；下一行 `p4c-bm2-ss ... p4_proxy/p4_src/ndtwin_switch.p4`
才會抱怨找不到輸入檔。**這是「先讓你以為在前進，再失敗」的形狀。**

§6.4 更糟一點：`AppConfig.hpp` **會存在**（§4.2 的 cmake 產生它），讀者打開它、
照手冊找那兩個欄位、**找不到**，而手冊把它們印得像本來就在那裡。
⇒ 最可能的反應是「我是不是版本不對」，而不是「這個 repo 沒有 P4 支援」。

## ✅ 一個我原本以為是缺陷、查了之後不是的

我一度以為 §6.4 叫人開 `setting/AppConfig.hpp` 是錯的，因為那個檔沒有被追蹤
（`.gitignore` 第 3、4、6 行都列了它）。**但 `CMakeLists.txt:18-31` 會在它不存在時
從 `AppConfig.hpp.example` 複製一份**，而 §4.2 在 §6 之前，所以讀者手上一定有。
**建置沒有被擋，§6.4 的路徑也是對的。** 記在這裡是因為它差一點被我寫成缺陷。

## 這不是「§4.1 的 URL 要改」而已

先前記錄把這件事收斂成「§4.1 的 clone URL 待定，卡在 `NDTwin-Kernel-P4` 還沒公開」。
**實際的影響面是 §6.2 到 §6.7 全部六個小節**，而那正好是這份交付的主體
（教授要的是「NDTwin p4 support 的完整 website 文件」）。

## 需要 Adam 決定的三條路

| | 做法 | 代價 |
|---|---|---|
| **A** | 把 `NDTwin-Kernel-P4` 設為公開，§4.1 對 P4 讀者改指它 | Adam 自己的動作；兩個 repo 並存要說明何時用哪個 |
| **B** | 把 `p4_proxy/` 與 P4 拓撲 JSON 併進公開的 `NDTwin-Kernel` | 一個 repo、最少混淆；但要處理 672 個 commit 的落差 |
| **C** | 手冊在 §6 開頭明說「本節需要尚未公開的 repo，取得方式是 …」 | 誠實且今天就能做，但交付的是「拿不到的東西的說明書」 |

**建議 B，其次 A。** 理由：教授要的是「能照著把新版裝起來」，
**C 交付的文件在拿到 repo 之前無法驗證，等於把驗收推遲到我們看不見的地方**。

⚠️ **在其中一條落定之前，§6.2–§6.7 沒有辦法做乾淨室驗證** ——
不是「還沒做」，是**做不了**：測試機拿不到那些檔案。
目前 §6 只有 §6.1（裝 BMv2／p4c）是可測的，而它正在測。

[Co-developed with claude code -- Adam]
