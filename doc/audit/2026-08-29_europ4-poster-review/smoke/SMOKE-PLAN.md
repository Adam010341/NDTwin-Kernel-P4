# 單跳 build-ratio smoke——計劃（跑之前寫死，Adam 08-29 裁定選項 B）

**目的**：審查員第三方 sanity check——① 的「stock 45 / fast 360、R=8.0」能不能被
照著它自己的方法重現到**同一階**。**不是**正式量測、**不是**預註冊輪、不進論文。

## 儀器＝① 自己的，逐 byte 未改

- `drive_p1.sh` sha256 `e7c69a2c…`＝正本（`2026-08-28_single-switch-build-ratio/`）
- `run_build_arm.sh` sha256 `4d84e1e2…`＝正本
- 只透過**環境變數**改參數（`RATES_MBIT`），腳本內容零修改。
- 輸出進本目錄 `raw/`，**不寫入 ① 的 audit 目錄**。

## 設計（每 build 一臂，短梯）

| 臂 | build | 梯（Mbit/流） | 判讀 |
|---|---|---|---|
| `smoke_stock` | stock | `30 45 70` | 過＝45 乾淨且 70 髒（highest_clean=45） |
| `smoke_fast` | fast | `240 360 540` | 過＝360 乾淨且 540 髒（highest_clean=360） |

兩臂都照原判讀規則（≤0.5% 乾淨、非零損失 3 reps 取中位、雙向 EventLogger 簽名、
one-hop 計數器驗證、外來 CPU 殘差 gate）——全部由原腳本執行，我不重造。

## 與正式協定的偏差（smoke 的定義，全列）

1. **每 build 只有 1 臂**（正式＝每 build ≥2 臂交錯）⇒ 無複製、無散布資訊。
2. **梯只有 3 階**（正式 14 階、由停止規則封頂）⇒ 只能答「同一階？」，不能重推 R 的區間。
3. **發送端對照繼承 ①b 昨天的量測**（1400 B loopback 7902 Mbit vs 頂階 540＝14.6×
   餘裕）——同機、同 payload、隔一天。正式協定要求本輪自量；smoke 揭露繼承。
4. 未預註冊 ⇒ 結果**只作為審查佐證**，任何方向都不得寫進 abstract。

## 判讀（先寫死）

- 兩臂 highest_clean 都同 ① ⇒ 「第三方照方法可重現到同一階」，寫進審查報告。
- 任一臂不同階 ⇒ **不推翻 ①**（單臂 smoke 對上四臂正式輪），但升級為
  「需要正式複跑」的建議，回報 Adam 與 bmv2 session。
- 任何儀器失敗（簽名不符、one-hop 不成立、gate 發火）⇒ 臂作廢照實記，不重跑硬湊。

## 環境約定

- claim：`NDT_OWNER="8/29 poster-reviewer"`、`NDT_EXCLUSIVE_CPU=1`、60 分。
- 量測窗內不 commit（agy 污染）。
- 結束：留 fabric（fast）＋寫 `.test_run/lab.handoff`（`可直接拆`）＋release；
  `bmv2_binary_override` 恢復為進場時內容（進場時＝bmv2-fast，末臂 fast ⇒ 應已一致，仍比對）。

[Co-developed with claude code -- Adam]
