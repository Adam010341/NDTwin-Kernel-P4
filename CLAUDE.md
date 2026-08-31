# CLAUDE.md — NDTwin-Kernel 專案守則

（Adam 2026-08-31 定稿；session 開工先讀完整份再動手。）

## 溝通與裁決

- 對 Adam 回報一律中文；code／commit message 維持英文。
- 多題裁決用互動表單：建議放第一、寫後果、末留自由輸入。
- 手上的工作放進 task list（`TaskCreate`／`TaskUpdate`），狀態隨進度更新：開工標 `in_progress`、
  做完標 `completed`、擋住的寫清楚被什麼擋。**那是 Adam 唯一看得到各 session 在幹嘛的地方**，
  不是給自己看的備忘 ⇒ 放真的待辦，不放佔位資料。
- Session 命名規則：
  - 有明確工作項目名稱＝負責該工作項目的 session。
  - **auditor**＝Adam 的代理人。Adam 會列出需要交給 auditor 管理的 session；auditor 負責審查
    它們的成果、發派工作，並確保 Adam 離開時 worker session 沒有不必要的停止工作。
    **auditor 不負責實際完成工作。**
  - **mainDev**＝主要開發 session。無法歸類為特定種類的工作（找不到其他符合名稱的 session）
    都交給這個 session 來做。

## 授權邊界

- commit 時機自主、做完就推——但**公開與否只能打公開 URL 驗**（tracking ref 不算數；
  push URL 可能一私一公）。
- **diff 瞬間暴漲太多的時候，先確認有沒有不必要的東西被推上了 repo。**

## 工程紀律

- AI 參與的碼標 `[Co-developed with claude code -- Adam]`。
- 永不 `pkill -f`／`pgrep -f` 殺程序；斷鏈路用 `tc netem` 不用 `ifconfig down`；長跑包 `setsid`。
- 共用 worktree：`git commit -m "..." -- <paths>`；新檔先 `git add -N`。
  🔴 **目錄不算「明確路徑」。** 目錄 pathspec 的語意是「這個目錄**現在**的全部樣子」，
  而「現在」是好幾個人共用的——它等同於局部的 `git add -A`，會把別人未提交的修改
  一起帶走，且帶進一個沒有描述它的 commit message。**列到檔案。**
- 引用共用 worktree 裡未提交的修改時，要明講「這是未提交的觀測」；
  不要拿別人的 working tree 當決策依據。
- `ndt` 指令都帶 `NDT_OWNER`；動 lab 前 claim；問「有沒有實驗在跑」看 `measuring` 欄。
- 環境狀態自己查，不佔使用者往返。

## 量測與宣稱

- benchmark 必指認 binary（sha＋哪種識別碼）；「跑過」與「讀過未執行」永不混表。
- raw 進 audit-raw；宣稱口徑與 raw 存檔不可協商。
- 每次實驗對帳舊結果（推翻／更新／可比對哪個）。
- 測試沒看過紅就不算交付（mutation gate）。

## 委派

- subagent 明寫 opus；機械活 deepseek-cli；orchestrator 不做 grunt work。

[Co-developed with claude code -- Adam]
