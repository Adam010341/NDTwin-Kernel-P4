# 量測機環境快照（外審 C5/C6 補量）

**擷取 2026-08-29（晚於實驗）。可回溯性：`uptime -s` ＝ **2026-08-24 17:01:33**——
本次開機早於全部四輪量測（③ 08-28 20:15 起、② 08-29 09:13、①/①b 08-29 10:11/10:39）
⇒ kernel 與硬體身分在整個量測窗內不變。**

| 項 | 值 |
|---|---|
| Host | Lenovo Yoga 7 2-in-1 16IML9（`adam-Yoga-7-2-in-1-16IML9`） |
| CPU | Intel(R) Core(TM) Ultra 5 125U，`nproc`＝14 |
| 頻率 | max 4300 MHz；擷取當下 scaling 73% ⇒ **無定頻、無 CPU pinning、Turbo 未關**（與 CompNet 2021 的釘核定頻做法相反——這是我們的效度限制，照實報） |
| Kernel | `7.0.0-30-generic #30~24.04.1-Ubuntu SMP PREEMPT_DYNAMIC` |
| iperf3 | 3.16（cJSON 1.7.15） |
| bmv2 | behavioral-model `f0b7d201`；兩 build 之 sha256/BuildID/flags＝`doc/audit/bmv2-binary-provenance.md` |
| ndtwin_kernel | `a40e04ce`（符號指認，provenance 同上） |
| P4 program | ⚠️ 名稱與 commit 未在本檔釘死——跨 repo（fabric 起機組態），**camera-ready 前補**（NOTES 待辦） |

[Co-developed with claude code -- Adam]
