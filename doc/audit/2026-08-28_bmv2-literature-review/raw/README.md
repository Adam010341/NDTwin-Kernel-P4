# raw/ — 這輪文獻審核的證據檔

- `hits_*.txt`：`sweep_keywords.sh` 對 14 篇 txt 的關鍵詞掃描結果（單行片段）。
- **全文 txt 不入 repo**（公開 repo 不可收論文全文）。重生方式：

```
cd "~/Desktop/NDTwin slide material/paper/bmv2 performance"
for f in *.pdf; do pdftotext -layout "$f" "out/${f%.pdf}.txt"; done
```

RELATED-WORK.md／GAP.md 引註的「txt N 行」即指上述輸出的行號
（pdftotext 0.86+，`-layout`；行號對 poppler 版本穩定性未驗，差一兩行屬正常）。

[Co-developed with claude code -- Adam]
