---
name: apparmor-shields-tcpdump-from-kill
description: "背景跑的 tcpdump 殺不掉——AppArmor tcpdump profile(enforce)拒收外部 kill(2),連 root 的 SIGKILL 都 EPERM;timeout 也失效。診斷特徵與替代方案。"
metadata: 
  node_type: memory
  type: project
  originSessionId: 81179fb8-1de4-40bc-b6a5-2c8aa038171b
  modified: 2026-08-15T18:23:15.314Z
---

2026-08-16 凌晨實測:判別腳本用 `sudo mnexec … sh -c "timeout 66 tcpdump -i lo …"` 背景抓
:6343,結果 tcpdump 活了 4 小時:`timeout` 的 TERM、adam 的 sudo kill、root 門
(`sudo -n mnexec -a 1 kill -9`)全部 EPERM。

**診斷特徵(下次 10 秒認出它)**:`/proc/<pid>/status` 的 `ShdPnd` 全零(訊號根本沒排進
佇列=送出端被拒,不是凍結)+ `/proc/<pid>/attr/current` = `tcpdump (enforce)`。
機制:AppArmor signal 仲裁擋掉外部進程的 kill(2);互動式 Ctrl-C 平常有效是因為那是
tty 驅動的 kernel 訊號、不走 LSM——所以沒人平時會發現這個坑。tcpdump 還會自動降權成
`tcpdump` 使用者,別被 owner 騙去猜權限問題。

**Why**:量測腳本裡背景 tcpdump=留下一個誰都殺不掉的殘留,卡住 harness 背景工作
4 小時、UI 恆顯 Running。

**How to apply**:
1. 量 sFlow 到達率優先用 **kernel 量子法**(get_graph_data edge 值 ÷ 3.01Mb 量子/秒)
   ——零殘留、不用 root。
2. 非用 tcpdump 不可時:**前景跑+固定 -c 包數上限**,不要 timeout+背景;或跑完由
   同一 shell 的 tty 信號收掉。
3. 已產生的殘留:無害(睡眠 0% CPU),等自然重開機;或 Adam 自行走
   `apparmor_parser -R` → kill → `-a`(動安全設定,agent 不代做)。
