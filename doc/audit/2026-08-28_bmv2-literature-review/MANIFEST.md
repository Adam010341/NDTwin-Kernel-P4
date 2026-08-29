# Paper manifest：本輪 14 篇的身分與雜湊

**建立日 2026-08-28。** 8/27 auditor 結案裁決的追加項：PDF 不在 git 裡
（在 `~/Desktop/NDTwin slide material/paper/bmv2 performance/`），沒有這張表，
「`sweep_keywords.sh` 可重生」就是空頭支票——重跑的人無從確認手上的 PDF 是不是我們讀的那 14 份。
雜湊＝`sha256sum`，對原始 PDF 檔。

| 代號 | 檔名 | sha256 | venue／年 |
|---|---|---|---|
| TOMACS25 | `3725530.pdf` | `b86ad975a56bf6448dafe05f2c05630411c7a801ed5c164f2075c2eca4c36669` | ACM TOMACS 35(2), 2025 |
| PADS23 | `3573900.3591120.pdf` | `bcd7522b31971cf288ac17ad4b512dfe1653f3f29aaae08647dea686720bc10e` | SIGSIM-PADS 2023 |
| PADS24 | `3615979.3662157.pdf` | `107524a1d3088e6873c70a79206096ce931f94da99c9ebf43f9b932f3552a971` | SIGSIM-PADS 2024 |
| ICNCC23 | `3638837.3638871.pdf` | `a1cfed5b6ea2b3f6b9213bbe9a0420d837cb539bb07a3400b8ae150b6d068e29` | ICNCC 2023 |
| TSSA23 | `Performance_Analysis_of_Mininet-based_Testbed_for_Software_Defined_Network_with_P4_Programmable_Data_Plane.pdf` | `2ab2134209338d94eb3c6f88f8388b5e30327405d6d7a1283dcad132c8d3c228` | IEEE TSSA 2023（DOI `10.1109/TSSA59948.2023.10366975`） |
| WSNAP17 | `3050220.3050231.pdf` | `52dae45cfcb010f94bfbda5ce1f36a1513ffef5258b8a20c21d9144e91a2d17e` | SOSR 2017 |
| TUM21 | `TUM_NET-2022-01-1_Taxonomy-of-the-Performance-of-P4-Targets.pdf` | `4c1843015802928dc874e8ce5a24a6a4ec3c432987c0578a85e1baf0530bec10` | TUM seminar IITM SS21（報告編號 NET-2022-01-1，2021-11 刊） |
| COMPNET21 | `1-s2.0-S1389128621000372-main.pdf` | `0361d7cf40dd34a6b50f5d45293abdd39b8ee81ca1532703c27cc4a6e532bfc5` | Computer Networks 188 (2021) 107861 |
| NETSOFT19 | `A_benchmarking_methodology_for_evaluating_software_switch_performance_for_NFV.pdf` | `6bc9209fdcf027bbb76527c6458e28296f57b1c4a512a63576e857421c41e00f` | IEEE NetSoft 2019 |
| P4CEP18 | `arXiv_P4CEP_In-Network-Complex-Event-Processing.pdf` | `2b736441f9519f4f8757402ba469f9ab260fcd40a96d6d0ed620a071ca0358d1` | NetCompute 2018（arXiv 副本） |
| P4NIDS | `arXiv_P4-NIDS.pdf` | `f12dc55709431e549b90349f3ed3abf5c709318e7974310816ff8811bd1e780e` | arXiv（內文引用日期至 2024-11；發表狀態未查證） |
| VSDNEMUL | `arXiv_vSDNEmul_container-SDN-emulator.pdf` | `7173a4925e549ddd9a88f8c17956a7e9bfa276bd83c016385652d5c5d78e74fc` | arXiv（年份未查證） |
| HOTSDN13 | `HotSDN13_High-Fidelity-Switch-Models-for-SDN-Emulation.pdf` | `a5789721b5609c7e4b45d391181ae9a5cbddf1d65c3f19f82a65e8247672b813` | HotSDN 2013 |
| POLITO | `PoliTO_thesis_Delay-Control-with-Programmable-Data-Planes.pdf` | `722a7c1063b9157d1e8136fa613c0df6af59c092e5c2083a40294cbe2a05baff` | Politecnico di Torino 碩士論文（年份未查證） |

重跑流程：對照本表驗 sha256 → 依 `raw/README.md` 重生 txt → 跑 `sweep_keywords.sh`。
「未查證」欄照實標——venue／年來自 PDF 內文自述，arXiv 條目的正式發表狀態沒有另行查核。

## 檢索第一輪新增（2026-08-28 深夜；非原 14 篇，裁決見 `SEARCH-ROUND-1.md`）

| 代號 | 檔名 | sha256 | venue／年 |
|---|---|---|---|
| PADS26-OFFLOAD | `3806789.3810263.pdf` | `13a2a86829126d6b0b1cbfe6fd8baad8b30166a90e906d412e16cc91d56ec164` | SIGSIM-PADS 2026 |
| MDPI-NET25 | `network-05-00021.pdf`（08-29 已入 paper 目錄；同雜湊重驗） | `9895afc11b276db5c00b3c82a9f3855902c418b266d677bfd551aaf33c7057fd` | MDPI *Network* 5(2), 21, 2025（期刊版；與 preprint 結論逐字核對一致，08-29） |
| MDPI-NET25-PRE | `preprints202504.2530.v1.pdf` | `abef2d9e0d5626b2e7a6a4acbd6cf36b80d3b3c1beb6408acab354b56be0e131` | Preprints.org 2025-04（同文預印本） |
| P4DOCKER24 | `29948-217-24388-1-10-20240813.pdf` | `a054a172ee9960d9686f2734b99a6e9242849e7688b8904920502f2d83cb488c` | WPEIF/SBRC 系 demo，2024（venue 未逐字查證） |

## 檢索第二輪新增（2026-08-29 入庫；裁決見 `SEARCH-ROUND-2.md` §2）

| 代號 | 檔名 | sha256 | venue／年 |
|---|---|---|---|
| P4SIM25 | `2503.17554v1.pdf` | `aba393ab2143fd78c13c207cc1358a56aa389957e6a28e03af7635e9e30b6349` | arXiv 2503.17554（2025；Ma & Nguyen，TU Dresden；正式發表狀態未查證） |

[Co-developed with claude code -- Adam]
