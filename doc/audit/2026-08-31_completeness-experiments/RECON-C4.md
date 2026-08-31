# RECON C4 — 偵察紀錄（量測前；prereg v0.2-stamped 授權「安裝與列舉」）

**目的**：為三處【TBD】蒐集定案材料。本檔＝偵察紀錄，非規則檔；**不含任何量測數字**。

## R1（08-31，零安裝：repo/README 層級，WebFetch github.com/usi-systems/p4benchmark）

- Benchmark 產生器（`p4bench.py --feature`）的**九個類別**（README 措辭）：
  parse field／parse header／parse complex（depth 2、每節點 2 分支）／action complexity
  （set-field）／header addition（N=2）／header removal（N=2）／processing pipeline
  （N=2 tables）／read state（10 reads）／write state（10 writes）。
- 量測腳本：`experiment.py`（README 無細節）、`run_test.py`（Python 封包產生與接收）、
  `pktgen/`（C 產生器，"c copies at t Byte per second"）。
- ⚠️ **README 層級查不到輸出指標定義**（latency/throughput/pps 皆未載明）——
  primary 清單**不能**從 README 定案，維持 prereg 原設計：install 後列舉
  `experiment.py` 的實際輸出欄位再定，定案回 auditor 快核。
- 論文頭條（parse 1 header 11.2 ms）屬 parse-header 類 ⇒ 該類必然入 primary 候選。
- container base 的線索：install 腳本裝 thrift 0.9.3＋python2＋R——等 install 偵察
  （nslab VM 或本機空檔）實測依賴再定 14.04/16.04。

## 待辦（依 prereg 閘）

1. 【install 偵察】period container 起、跑 `install_bmv2.sh`（僅安裝）——定 container base
   ＋記 install 腳本抓到的 bmv2 commit（樹世代 TBD 材料）。⚠️ 環境閘：nslab（等 VPN）
   或本機空檔（claim＋不疊 9/03 窗）。
2. 【列舉】`experiment.py`/`run_test.py` 的輸出欄位清單 → primary 清單草案 → auditor 快核
   → prereg 升 v1.0。
3. v1.0 之後才有第一個量測 rep。

[Co-developed with claude code -- Adam]
