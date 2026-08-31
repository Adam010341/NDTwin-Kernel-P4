---
name: tests-below-the-main-guard-are-not-collected
description: "在 Python 測試檔尾端 append 新測試，如果 `if __name__ == \"__main__\"` 在檔案中間，unittest 完全收不到——而且回報 OK"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-12T04:25:18.470Z
---

2026-08-12：我把三條新測試 append 到 `tests/python/test_p4_power_helper.py` 尾端，跑起來
`Ran 20 tests ... OK`——但新測試有三條，20 是**舊的數字**。原因是 `if __name__ == "__main__":
unittest.main()` 位在檔案中段，`unittest.main()` 在它執行的當下才收集 module 的
`TestCase` 子類，所以定義在守衛**之後**的 class 從來沒被註冊。

沒有任何錯誤訊息。綠燈、exit 0、看起來就是「新測試通過了」。

**Why：** 這是「測試不會失敗 = 未交付」的最廉價版本——測試連跑都沒跑。而且同一天的
AUDIT_B 才剛在 `p4_proxy/tests/test_p4_client_writes.py` 記載過一模一樣的形狀
（`WriteDeadlineTest` 在 `unittest.main` 之前才算數），我讀完那條之後，在隔壁檔案犯了同一個錯。
文件記載過的陷阱不等於已處理——同 [[smoke-the-accept-path-not-just-refusals]]。

**How to apply：**
- append 測試之後，**先看 `Ran N`**，N 必須比之前多。只看 `OK` 等於沒驗。
- 或直接改掉根因：把 `__main__` 守衛移到檔案最後一行（我已經對
  `test_p4_power_helper.py` 這樣做了）。守衛在中間的檔案是個陷阱，不是風格問題。
- 這個 repo 用 `unittest` 直跑不是 pytest（見 [[python-tests-need-the-venv-interpreter]]），
  所以沒有 collector 會替你發現遺漏的 class。

相關：[[mutation-gate-for-tests]]。
