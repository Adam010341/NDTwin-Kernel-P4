### line 13036
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad; cat > $S/report-draft.md <<'EOF'
# 階段三 觀測與 13/13 — 回報草稿（四段式；數字待第五次 campaign 與 D 併回後填）

## 一、做了什麼（結果）
- A（kernel L3 觀測）、B（鏈路級遙測 psample→sFlow v5＋veth→(dpid,port)）、C（合作式 A 按名字＋G7/G8/G9a/b）、E（三組量測儀器）已併 trunk 並公開（main＝7d0ef22a 時點；之後的裁決 commit 待推）。
- D（driver／13 支／通用格）：裁決 31 最後一輪，等 GO 跑閘門 → judge → 併。
- live（trunk 7242e127，`live-p3d*.log`）：01/02/02b/03/05 PASS；05 三組（link／cooperative／none）on-path>0、off-path=0；include cell PASS；06：23/26 照 exercise＋2 設計紅；3 紅＝ecn G1（0.5 Mbit/s 瓶頸、視窗太短）、p4runtime／flowcache G1 EMPTY（控制器在 G1 前被停）——D 裁決 26/28/31 修，併回後 `ONLY=ecn,p4runtime,flowcache` 重跑。
- tutorials 臂 9×2：port 9090 被 `python3 cli.py dashboard`（pid 2364314，cwd ~/claude-usage）佔住，未殺；需要 Adam 放開。
- 三組 campaign：第五次（乾淨）raw `2026-09-19T115737Z_full`；圖 fig1/fig2/fig3；前四次只當參考（093122Z 儀器修前、105437Z 汙染中止、105759Z G1 段被 D 閘門汙染）。

## 二、數字（每格從 summary.json 抄；帶臂值）
- pps 天花板 64 B／1024 B × none／coop／link：<>
- 取樣誤差 2／20／100 Mbit/s：coop <>、link <>、none n/a；shot-noise 預測 0.143／0.045／0.020
- CPU：kernel F/m（coop <>、link <>）、bmv2 coop/none <>、softirq 份額 <>
- 對帳：(a) 1024 B vs 16.0 kpps：none <>、coop <>；(b) m vs 206 µs/sample：<>；(c) 12× 表只列不除

## 三、缺陷與教訓（本輪 live／campaign 抓到的）
- 儀器：`ndt verify_p4` 不存在；manifest argv 是字串；`analyse.py` 把 C3 丟棄梯子併進 none|1024（裁決 32）；零臂 PASS；fig3 標籤重疊。
- fabric：topo-stop 之後 tear_down 不跑（B 修）；basic_tunnel EXACT `[1]`；mri scapy 巢狀前綴。
- 量測紀律：campaign 期間本機不得跑閘門（第三／四次的教訓）。
- 取樣器盲點：ecn（0.5 Mbit/s 瓶頸 → 期望樣本 ~1.8）與 qos（ICMP 內嵌標頭）。

## 四、下一步
- D 併回 → live 三臂重跑 → 13/13 最終表；tutorials 臂等 9090；raw 進 audit-raw；HPE type-3 +19/+20、include 檔不進 package、cpu_port 交叉檢查＝階段三候選。
EOF
echo "draft written: $(wc -l < $S/report-draft.md) lines"

### line 13205
F=/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory/integrate-0910-merge-state.md; python3 - "$F" <<'PY'
import sys,re,datetime
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
add = """- **20:1x（compact 前的狀態）**：①campaign 第五次跑中（`drive_e-1957.log`、raw `2026-09-19T115737Z_full`、driver pid 2223248，20:12 在 G1 `none_f1024_a`；監看 task `bjsp5614z` 結束時印 verdict）。②**D 交 `95eb13f9`（裁決 31；`75dc6605` 碼＋merge trunk）「code ready, waiting for GO」；我逐 hunk 讀完（`scratchpad/d-r9.diff` 987 行）：碼站得住，一個洞＝driver `link_usage_cell` 把 `_common.sh` 新 rc 4（視窗拒絕）映成 twin 紅句 ⇒ 裁決 33（`4d3f294f`）已傳 D，D 改完會再回「code ready at <sha>」**。③E 第七輪 worker（裁決 32：C3 併格／fig3 標籤／零臂 PASS）在 `wt-p3-measure-0919` 改碼，等 GO。④**未推的 trunk commit：`7e20d1e7`、`f4dd9f22`、`e2f4a7a3`、`4d3f294f`（全是工單裁決）**。⑤GO 順序：campaign 完 → D 閘門（重，~30 min，`rerun-D12.sh` 已備）→ E 閘門（python 輕）→ 兩 judge → 併 → 對乾淨 raw 跑修好的 analyse/plot → E 填 FINDINGS → live `ONLY=ecn,p4runtime,flowcache` → audit-raw → 回報（草稿 `scratchpad/report-draft.md`）。⑥audit-raw 擺法：worktree `scratch/overnight-2026-09-05/wt-audit-raw`（分支 `audit-raw`，head `44167103`），檔案鏡像 repo 路徑（`doc/audit/<輪>/…`、`scratch/overnight-2026-09-05/logs/orchestrator-<日>`），訊息「Raw: P3 … on trunk <sha>, 2026-09-19 -- …」。⑦105759Z（汙染參考）的 analyse／圖：`logs/orchestrator-0919/analyse-105759Z.log`、`figs-105759Z/`；形狀：kernel coop m=110 µs/sample（H-C1 只靠 m 落 [103,618] 那一支，固定份額僅 7%）、link m=84（H-C2）；取樣誤差 2M 17%/19%（遠高於 shot-noise 5%）、20M 2.6/4.8%、100M 1.8/2.9%；C1 804 kpps、C2 795 kpps、C3 +0.17 fires——**只當形狀參考，正式數字等第五次**。⑧舊的五個 `until` 等待 task（bwg9twyva 等）已停。
"""
s = s.rstrip('\n') + '\n' + add
s = re.sub(r'(^  modified: )\S+', lambda m: m.group(1)+datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), s, count=1, flags=re.M)
open(p,'w',encoding='utf-8').write(s); print("state appended:", len(s.splitlines()), "lines")
PY

### line 13900
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad; cat > "$SP/report-draft.md" <<'EOF'
# 階段三回報（草稿，2026-09-19 夜；③④ 待閘門與 live 收尾後補）

## 1. 要我裁的

**① pps 天花板這一題，這台機器量不出來——要不要再花一晚換工作點？**
「最高乾淨階」是用「3 rep 的 loss 中位數 ≤ 0.5%」定的，而整個系統在 30 kpps 的
loss 中位數就落在 0.1–0.9%，**門檻正好穿過那條帶子**。決定性證據：判別實驗裡
同一臂同一階 20 kpps 被獨立量兩次，梯子那組中位數 0.2532%（過）、確認那組 0.5276%（不過），
於是走回 12。梯子甚至非單調（20 階不乾淨、30 階乾淨）。
⇒ 我照預註冊報告（cooperative 判 unresolved／H-A0、link 16、none 30），**沒有動門檻或估計量**。
要真的量出三組天花板，得換工作點（梯子在 20–45 kpps 加密，或改用 loss 對 offered rate 的
連續曲線與內插交叉點），而那要**在取那批資料之前註冊**。一晚約 1.5 小時的機器時間。
**你要現在排，還是先收階段三、把這題留給下一輪？**

**② tutorials 對照組的 18 臂還是跑不了：port 9090 被你的 dashboard（pid 2364314）占著。**
我不殺你的行程。NDTwin 的 13×2 臂不受影響（那是驗收條件本身），對照組只是旁證。
**要我在你關掉之後補跑，還是這輪就不要對照組？**

## 2. 推翻／更正

**① 我自己 20:3x 的判斷錯了，已在記憶與工單裡改掉。** 當時看到 cooperative 天花板從
30 掉到 12，我寫下「可能是我自己在機器上讀 diff／跑 python 造成的外部負載」。
用 `external` 殘差一查就否證了：`none_f1024_b` 帶 0.0707 拿 30，`cooperative_f1024_a`
帶 0.0532 只有 12。第二個假設（取樣誤差區塊留下的狀態）也被否證：每個世代的 kernel、proxy
與十座 bmv2 都是全新 pid，而機器全空時單獨重跑同一個世代得到 f64=12、f1024=30，
**同一條件兩個答案**。真正的原因是估計量本身（見上）。

**② 「第五次 campaign 是乾淨的」這句話當時沒有量測支持。** 它只表示「沒有閘門在跑」。
我後來才把每一臂的外部 CPU 殘差列出來對照。教訓已寫進記憶：**乾淨是宣告的，不是量到的**。

**③ 負載閘（組內中位數 +0.15）對「整組一起被抬高」零鑑別力。** 它只看得見組內的異常值。
這次沒有造成錯誤結論（因為真正的問題不是負載），但它是個已知的盲區，FINDINGS 要寫。

**④ 舊結果沒有被推翻。** bmv2 的 12× 表、pps 天花板、遙測成本固定三條，對帳結果待 ③。

## 3. 交付
（待補：D 的裁決 31＋33、E 的裁決 32、兩個判官回合、合併 sha、13/13 live、圖）

## 4. 細節
（待補）
EOF
wc -l "$SP/report-draft.md"; echo "=== gate progress $(date +%H:%M)"; tail -n 2 /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_drive_exercise.p3d-ebd26684.log

### line 14210
M=/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory/integrate-0910-merge-state.md; /home/adam/miniconda3/bin/python3 - "$M" <<'PY'
import io,re,sys
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read().rstrip()
s += u"""

## 22:3x 兩個判官都回了；裁決 34／35／36 已提交並推公開

**D（`ebd26684`，裁決 31＋33）判官 MERGE AFTER FIXES，要修的全在報告層、不動 head** ⇒ 碼可併。
九支閘門全到末行（driver 163 OK、live_p1_common 163、ndt_app_package 395、thirteen 36、
dead_mutant 43、mutate_drive 97/0、mutate_live_p1 40/0＋4 控制、anchors 115/115、紅跑 5 紅 1 綠）。
我獨立重跑七支數字全同，第八支（97 顆變異）在跑。
🔴 **head 中途從 `1ec136ed` 移到 `ebd26684`，是閘門抓到 worker**：變異 67 與 93 共用一行錨點，
裁決 33 換掉那行時只重綁 93 ⇒ 錨點檢查在產出任何判決之前報 BROKEN。**修法是重綁不是放寬**，
而且那一列誠實留在驗證表上（判官特別查了）。

**E（`f51ee88f`，裁決 32）判官 MERGE AFTER FIXES，挖到一個超出範圍但決定驗收結果的錯** ⇒ 裁決 35：
`analyse.py` 的散粒雜訊預測用 `links=len(keys)`＝**32**（全 fabric inter-switch 埠），
而 PREREG §5.2 註冊的是流量真正經過的 **4** 條與 `N = 4 × pps × 8 / 256`。
用 32 ⇒ N 放大 8 倍、預測收緊 2.83 倍 ⇒ **六格 H-B 判決有四格從 H-B1 被誤判成 H-B2**。
那四條邊的身分本來就在同一份 `window.json` 的 `per_edge_peak_bps`（恰好 4 條全非零）。
🔴 **這是修 bug（儀器構不到註冊的問題），不是事後改預註冊**，而且修正方向讓結論**比較不聳動**。

**裁決 34**＝天花板估計量沒有解析度（見上一節）。**裁決 36**＝rc 2 的錯歸屬殘餘：
`link_usage_cell` 的 docstring 說權限答案會以指名它的失敗回報，碼卻讓 rc 2 與 rc 1 一樣拿到
twin 句。**不擋今晚的 live**（rc 2 要 sudo／namespace 失敗才出現），但**讀 live 結果時要明確查 rc 2**。

已推公開（`p4`／`lab` 同一顆，未認證 URL 驗過）：`57e692e2`（34）、`990a2462`（35）、`0e532cdb`（36）。

**下一步順序**：變異閘重跑收 → 併 D（訊息備在 `scratchpad/msg-merge-D4.txt`）→ 併後檢查 →
**live `06_thirteen.sh` 全套（13×2，約兩小時，從主 checkout 跑）** → E 第八輪收 → 併 E →
對乾淨 raw 跑修好的 analyse／plot → FINDINGS → audit-raw（腳本 `scratchpad/copy-audit-raw.sh`）→
四段式回報（草稿 `scratchpad/report-draft.md`，①②段已寫實）。
"""
s=re.sub(r"^(  modified: ).*$", u"  modified: 2026-09-19T14:20:00Z", s, count=1, flags=re.M)
io.open(p,"w",encoding="utf-8").write(s+u"\n")
print("lines:", len(s.splitlines()))
PY

### line 14821
cd /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad/
echo "=== report-draft.md ($(wc -l < report-draft.md) lines)"
cat report-draft.md

### line 14876
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
new_s3 = """## 3. 交付

### D — 十三支驅動程式（裁決 31＋33），已併入 `f3b6d09c`
| 項目 | 結果 |
|---|---|
| 裁決 31 | 臂的控制器 pid 真的到得了 G1、且活過整條量測；NOT RUN 變成會指名控制器的 FAIL |
| 裁決 33 | 驅動程式學會 `_common.sh` 的視窗拒絕碼（rc 4）⇒「呼叫端自己設的等待上限」不再被記成 twin 的缺陷 |
| 判官 | 一輪，四項全是文件層修正（`judge-D-r10-final.md`） |
| 閘門重跑 | `driver` 163 測試 OK；`mutate_drive_exercise` 97 變異 0 存活；`mutate_live_p1_common` 40 變異 0 存活＋4 對照 0 紅 |
| 🔴 看過紅 | `test_mutate_gate_dead_mutant` 在 `1ec136ed` 真的紅了一格（變異 67 的錨點被裁決 33 的四答案表挪走）⇒ D 在 `ebd26684` **重指錨點、沒有弱化測試**；現在 43 檢查 0 失敗 |
| merged checks | 7 項全綠（`check_gate_anchors` 115/115、`check_process_by_name` 313 檔 0 site、`check_test_tmpdirs` 347 檔 0、`test_redirection_order` 48/0、`test_log_suffix_idempotent` 30/0、`kiref` OK、`test_topo_from_json` PASS） |
| 併後套件 | 5 支全綠：`driver` 163、`live_p1_common` 163、`live_p1_thirteen` 36、`ndt_app_package` 395、`dead_mutant` 43，皆 0 失敗 |
| 推送 | 掃秘密字串（3 個植入陽性對照先中）後推 `p4`／`lab`，未認證 HTTPS 驗過公開 |

### live 13/13 驗收
（待補：26 臂逐臂、rc 2 明查、報告路徑）

### E — 三組遙測量測（裁決 32＋35）
（待補：判官第八輪、閘門重跑、合併 sha、FINDINGS、三張圖）

### 對帳
（待補：bmv2 12×／pps 天花板／遙測成本固定）
"""
s = s.replace("""## 3. 交付
（待補：D 的裁決 31＋33、E 的裁決 32、兩個判官回合、合併 sha、13/13 live、圖）
""", new_s3)
io.open(p, 'w', encoding='utf-8').write(s)
print("sections now:")
import re
for m in re.finditer(r'^## .*$', s, re.M):
    print(" ", m.group(0))
print("lines:", s.count(chr(10))+1)
PY

### line 15343
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.replace("""### live 13/13 驗收
（待補：26 臂逐臂、rc 2 明查、報告路徑）
""",
"""### live 13/13 驗收 —— 🏁 **兩向全綠**
`06_thirteen.sh` 在 trunk `f3b6d09c` 上跑,22:43:28 起、23:12:45 收,**26 臂、rc=0**,
log `live-06-thirteen-f3b6d09c-20260919T144328Z.log`,raw 在
`live-p1/runs/2026-09-19T144328Z_06_thirteen`。

| 項目 | 結果 |
|---|---|
| 13 支 × 兩臂 | 26 臂全部如該支練習所宣告:24 臂 PASS、**2 臂 RED ARM**(`basic_tunnel/skeleton`、`flowcache/skeleton`,rc=1 want=1,by design 的紅控制組) |
| rc 不符 | **0** |
| 🔴 rc == 2 明查(裁決 36) | **全程零次**——裁決 36 擔心的 rc 2 錯歸屬沒有在這次 live 發生 |
| 驅動程式指認 | `drive_exercise.py` sha256 `4ddb776bd9dd1a1a…`、`_common.sh` `36c3689b41bd000a…` |
| 旋鈕 | `host_count=4`、`telemetry_override` 不存在、`app_package_override` 不存在、link manifest 不存在 |

**通用格(驗收條件本身)**:G1 在 10 支練習的 solution 臂上跑到,
**每一支都是「路徑上的每一條邊 ≠ 0、非路徑的每一條交換機間邊 = 0」**,0 違規。

| 練習 | 路徑上(bit) | 非路徑最大 |
|---|---|---|
| basic | s1-eth4 62,936,001 / s2-eth2 37,507,094 / s4-eth1 27,971,331 | 0.000 |
| multicast | s1-eth3 34,328,462 | 0.000 |
| basic_tunnel | s1-eth3 24,157,310 / s3-eth1 32,422,431 | 0.000 |
| qos | s1-eth3 37,501,785 / s2-eth1 31,145,878 | 0.000 |
| link_monitor | s1-eth4 15,891,937 / s2-eth2 41,954,560 / s4-eth1 38,777,041 | 0.000 |
| firewall | s1-eth4 40,039,448 / s2-eth2 19,066,106 / s4-eth1 31,142,529 | 0.000 |
| ecn | s1-eth3 7,500,000 / s2-eth1 32,059,285 | 0.000 |
| mri | s1-eth3 4,500,000 / s2-eth1 36,151,061 | 0.000 |
| p4runtime | s1-eth2 21,685,642 / s2-eth1 20,977,844 | 0.000 |
| flowcache | s1-eth3 56,579,902 | 0.000 |

⚠️ 一個口徑要講明:`mri` 那一臂有一條**主機面**埠 `s1-eth1` 讀到 260,966 bit。
那不是非路徑的鏈路——它是主機埠,而 mri 那一臂另外跑一條背景 iperf(h11→h22),
入口就在別的主機埠上。取樣 campaign 自己的 `sample_error.sh:189` 早就把主機面埠
排除在 `keys` 之外(另記成 `excluded_host_facing`),**我用同一個口徑判**:
判準是「路徑上的邊都 ≠ 0,且**非路徑的交換機間邊**都 = 0」。
用這個口徑,10 支全過;若把主機埠也算進非路徑,mri 會紅,而紅的原因是別人的流量。
**這個口徑要寫進閘門,不能留給讀者猜。**
""")
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo "report-draft.md now $(wc -l < "$S/report-draft.md") lines"

### line 15436
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.replace("""## 4. 細節
（待補）""",
"""## 4. 細節

**今晚新增的裁決**
| # | sha | 內容 |
|---|---|---|
| 34 | `57e692e2` | pps 天花板估計量在 20–30 kpps 沒有解析度 ⇒ 照預註冊報，不動估計量與門檻 |
| 35 | `990a2462` | 取樣誤差的 N 數錯集合（32 條 fabric 邊 vs 註冊的 4 條） |
| 36 | `0e532cdb` | rc 2 錯歸屬的殘留（不擋 live，但 live 結果要明查 rc 2） |
| 37 | `8d8e056f` | 🔴 **裁決 35 的勘誤（四格→五格）**＋E 第八輪的裁定（MERGE AFTER FIXES） |

**判官兩輪**
- D 第十輪（裁決 31＋33）：四項全是文件層修正 ⇒ 已併 `f3b6d09c`。
- E 第八輪（`e222176d`）：MERGE AFTER FIXES。**第一次派的判官因 Fable 額度用盡（429）中斷**，
  改用 opus 重派（唯讀權限相同）。它獨立重算 H-B 得到五格、與我一致。
  🔴 **但判官也會錯**：它說「red-1b 該檔 53 行」，我 `wc -l` 查是 52（它算的是另一份 `fc617c77`，
  那份 72 行）⇒ 裁決裡標記不成立、報告不必改。**判官的每一條引用我都自己開檔驗過才簽。**

**我自己逐 hunk 讀過 E 第八輪全部 9 支檔**（960 增 26 刪）。驗過的關鍵三件：
`place_end_labels` 的代數是**解**不是逼近（`end_label_offsets` 的 `final = max(natural, previous+label)`
展開即 `f_i = max_{j≤i}(natural_j+(i-j)·label)`，f 嚴格遞增 ⇒ 只約束頂端那顆就涵蓋全部）；
`tight_layout()` 在 `set_ylim` 之前且不再 re-run、`savefig` 無 `bbox_inches="tight"` ⇒ axes box 不動；
`none` 組的 `predicted` 進不了任何圖（fig2 只讀 `median_abs_error`）。

**閘門重現（orchestrator 在 worker 最終 head 自己重跑）**
- D `1ec136ed`→`ebd26684`：`driver` 163 測試、`mutate_drive_exercise` 97 變異／0 存活、
  `mutate_live_p1_common` 40 變異／0 存活＋4 對照、`test_mutate_gate_dead_mutant` 43 檢查。
- E `e222176d`：unit 76/76（venv＋conda 兩個直譯器）、`offline_round` 78/0、
  `test_mutate_gate` 自測 14/0、`hazard_scan` 3 檔 0 finding、`mutate_analyse` 進行中。
  🔴 這一輪的 log 改帶 sha 後綴（`tmp-E1-<name>.e222176d.log`），不再覆寫第七輪那批。

**紀律事項**
- live 期間我讓一個**唯讀**判官平行跑，依據是「通用格的邊界寬數十倍」——
  那是推論不是量測（見 §2 的不確定清單）。天花板梯子則是任何負載都不准，因為它貼著門檻。
- 推送：裁決 37 掃秘密字串（陽性對照中 3、本次 0）後推 `p4`，`lab` 因 `p4` 有兩個 push URL
  而同時到位；未認證 HTTPS 對兩個公開 URL 各驗一次，都回 `8d8e056f`。""")
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo "report-draft.md now $(wc -l < "$S/report-draft.md") lines"
tail -4 /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/tasks/bb5wyjksi.output; echo "--- $(date '+%H:%M:%S')"

### line 15470
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = s[s.index("⚠️ 一個口徑要講明:`mri`"):s.index("\n## 4. 細節")]
new = """✅ **口徑這件事閘門本來就處理好了,我一開始誤以為是缺口。**
`mri` 那臂有一條**主機面**埠 `s1-eth1` 讀到 260,966 bit,我先當成違規,查了 `_common.sh:900-905`
才發現判準本來就寫著三條:①路徑上每條邊都有 twin 邊且積分 > 0;
②**非路徑的 inter-switch 邊恰為 0**;③**其餘每條邊在 floor 之下**,
floor = max(一個樣本 = 256×1500×8 = 3,072,000 bit, 0.02×最小 primary 積分)。
而且**閘門把 floor 與每條邊的 host/switch 標記印進該臂自己的報告**
(`runs/2026-09-19T150802Z_mri_solution_ndtwin.md:742-750`),數字就在被它判的讀數旁邊。
`s1-eth1` 的 260,966 遠低於 3,072,000 ⇒ 合法通過,不是我放寬判準。
(那條主機埠的流量是 mri 那臂自己另跑的背景 iperf h11→h22 的入口。)
📌 我要更正自己:我先寫了「這個口徑要寫進閘門,不能留給讀者猜」——**它已經在裡面**,
而且比我想的細(我只想到 host/switch 二分,閘門還有 floor 那一層)。

"""
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8').write(s)
PY
M=/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory
python3 - "$M/integrate-0910-merge-state.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = s[s.index("⚠️ **口徑必須寫進閘門**"):s.index("**裁決 37（`8d8e056f`")]
new = """✅ **口徑閘門本來就有,我一度誤判成缺口。** `_common.sh:900-905` 的三條:①路徑上每條邊有 twin 邊且 > 0;
②**非路徑 inter-switch 邊恰為 0**;③其餘邊在 floor 之下,floor = max(一個樣本 256×1500×8 = 3,072,000 bit,
0.02×最小 primary)。閘門還把 floor 與每條邊的 host/switch 標記印進該臂報告
(`runs/2026-09-19T150802Z_mri_solution_ndtwin.md:742-750`)。
`mri` 的 `s1-eth1` 260,966 bit(host,它自己背景 iperf h11→h22 的入口)遠在 floor 下 ⇒ 合法通過。
📌 **我先寫了「這口徑要寫進閘門」的行動項,那個缺口不存在**——查 `_common.sh` 才發現它已經在,
而且比我想的細。同一晚第三次:先下結論再查證。

"""
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo "done"; tail -4 /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/tasks/bb5wyjksi.output; echo "--- $(date '+%H:%M:%S')"

### line 15487
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
sed -n '1,40p' "$S/report-draft.md"

### line 15492
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.replace("# 階段三回報（草稿，2026-09-19 夜；③④ 待閘門與 live 收尾後補）",
              "# 階段三回報（草稿，2026-09-19 夜；live 與 D 已定案，E 待第九輪、圖與對帳待第五次 campaign 分析）")
s = s.replace("""**④ 舊結果沒有被推翻。** bmv2 的 12× 表、pps 天花板、遙測成本固定三條，對帳結果待 ③。""",
"""**④ 🔴 我的裁決 35 把「幾格翻」數錯了:四格 → 實為五格,漏的是 `link 20M`。**
機制不是算錯,是**選錯分析單位**:cooperative 20M 本來就是 H-B1(六格裡唯一真的不動的),
我看到「20M 這一列沒事」就把整個速率當結案,沒分開查 link 20M。**單位是「(組,速率)」那一格。**
工人先說五格、E 的判官逐列攤開,我才自己重算確認。已立裁決 37(`8d8e056f`)並推送。
而且**我第一版勘誤連「漏哪一格」和「機制」都寫錯**(說漏 coop 100M、說拿 H-B2 當代理),
去讀裁決原文才發現 ⇒ **更正錯誤時,更正本身也要拿證據對一次。**

**⑤ 我一度把 live 的 `mri` 讀成違規,那是誤判。** 我先寫下「非路徑=0 的口徑必須寫進閘門」,
查 `_common.sh:900-905` 才發現**它本來就在裡面**,而且比我想的細:
非路徑的 **inter-switch** 邊要恰為 0、其餘每條邊在 floor 之下,
floor = max(一個樣本 256×1500×8, 0.02×最小 primary),還把 floor 印進該臂報告。
同一晚第三次先下結論再查證。

**⑥ 判官也會錯,而且我差點簽下去。** E 的判官報「red-1b 該檔 53 行」,我 `wc -l` 查是 52
(它算的是另一份 `fc617c77`,那份 72 行)⇒ 裁決裡標記不成立。另一件是我轉述判官的算式
「十個各 15.0 jiffy/s telescoping 相消 ⇒ 分析數字沒變」,**E 指出 15.0%×0.5s = 7.5 jiffy 不是整數**
而 fixture 每列寫 `int()`,截斷可能差 0.625%/核 ⇒ 那句要用量的不能用推的。
**判官的每一條引用我都自己開檔驗過才簽,轉述它的算式時我漏了這一步。**

**⑦ 舊結果沒有被推翻。** bmv2 的 12× 表、pps 天花板、遙測成本固定三條,對帳待第五次 campaign 分析。""")
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo "lines: $(wc -l < "$S/report-draft.md")"
tail -5 /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/tasks/bb5wyjksi.output; echo "--- $(date '+%H:%M:%S')"

### line 15507
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.replace("""⇒ 我照預註冊報告（cooperative 判 unresolved／H-A0、link 16、none 30），**沒有動門檻或估計量**。""",
"""⇒ 我照預註冊報告（cooperative 兩格 12 vs 30 隔兩階＝**unresolved／H-A0**、link 兩格 12 vs 20 隔一階＝resolved 16、
none 30），**沒有動門檻或估計量**;`cell_table` 的 rung-gap ≤ 1 規則是**儀器的保護、它生效了**。
🔴 **但 link 的 16 不可以當成組效應報出去**——同一個 link 臂在參考跑（105759Z）是 30。
可說的是「遙測在拐點附近增加變異」,**不可說**「遙測把天花板壓低 N 倍」。""")
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo ok
tail -5 /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/tasks/bb5wyjksi.output; echo "--- $(date '+%H:%M:%S')"

### line 15719
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
python3 - "$S/report-draft.md" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.replace("""**⑦ 舊結果沒有被推翻。**""",
"""**⑦ 🔴 我們一直用一個 PREREG 沒註冊的粒度在貼假設標籤(E 查出來的,我驗過)。**
PREREG `:251` 的 H-B1 註冊的是「**三個速率都**在區間」、`:254` 的 H-B4 同樣、
`:252` 的 H-B2 **只註冊在 100 Mbit/s 那格**且要三視窗同號。而 `analyse.py` 是**逐格**貼
(`:432`／`:435` 沒限速率／`:459` 沒有「三速率都」),**整支碼沒有組級彙總**。
⇒ 修法前那個 `link 2M: H-B2` 是**雙重錯誤**:N 用 32 條邊之外,
**H-B2 在 2M 這個速率上根本沒被註冊過**。本輪兩個處理組三速率全在帶內,
所以組級與逐格同結論、**改不改都不影響結果**——正是該趁現在改的時機。
已立裁決 38(`f14fb691`),FINDINGS 只准引用組級判決。

**⑧ 舊結果沒有被推翻。**""")
s = s.replace("""| 37 | `8d8e056f` | 🔴 **裁決 35 的勘誤（四格→五格）**＋E 第八輪的裁定（MERGE AFTER FIXES） |""",
"""| 37 | `8d8e056f` | 🔴 **裁決 35 的勘誤（四格→五格）**＋E 第八輪的裁定（MERGE AFTER FIXES） |
| 38 | `f14fb691` | 🔴 三條註冊假設被貼在 PREREG 沒註冊的粒度上；H-B2 還被貼在沒註冊的速率上 |""")
io.open(p, 'w', encoding='utf-8').write(s)
PY
M=/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory
python3 - "$M/integrate-0910-merge-state.md" <<'PY'
import sys, io, re
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.rstrip("\n") + """

### 23:4x — 裁決 38(`f14fb691`,已推、已驗公開)

🔴 **三條註冊過的假設被貼在 PREREG 沒有註冊的粒度上。** `PREREG.md:251` 的 H-B1 註冊「三個速率**都**在區間」、
`:254` 的 H-B4 同樣、`:252` 的 H-B2 **只註冊在 100 Mbit/s 那格**且要三視窗同號;
而 `analyse.py` 逐格貼(`:432`／`:435` 無速率限制／`:459` 無「三速率都」),**整支碼無組級彙總**
(我自己 grep `H-B` 只有那三處),`plot.py` 根本不讀 `verdict` ⇒ 標籤只從文字表與 summary.json 進 FINDINGS。
⇒ 修法前的 `link 2M: H-B2` 是**雙重錯誤**:N 用 32 條邊之外,**H-B2 在 2M 根本沒被註冊過**。
本輪三速率全在帶內 ⇒ 組級與逐格同結論、**改不改都不影響結果**,正是該改的時機
(與裁決 35① 同類:讓儀器去算 PREREG 本來就寫著的東西,不是讓判準遷就已看到的數字)。
E 做成**第十輪**,不插進第九輪——裁決 37 要用它自己的證據先結案。

📌 **E 第九輪回報裡兩件值得記的自我更正**:(a) 它把我轉述判官的 `int()` 截斷疑慮**量了**——
十個等權重實測恰好 150.000000,機制擔心對了但沒咬到(`7.5×16=120` 也是整數,
且 `cpu_for_window` 只相減視窗首末),**疑慮與結果兩邊都寫進記錄**;
(b) 它 ⑨(a) 的第一版腳本用 `plt.Axes.annotate` 找 axes,把圖一圖二也收進來,印出
「height MOVED 206.49→243.50」——**那是 harness 錯誤不是發現**,log 檔頭寫著;改對之後
三面板 `set_ylim` 前後都是 206.4880 pt UNCHANGED ⇒ 我原本「推理上成立但沒量過」那條升級成量測。
"""
s = re.sub(r'(\n  modified: )[^\n]+', r'\g<1>2026-09-19T15:45:00Z', s, count=1)
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo "report: $(wc -l < "$S/report-draft.md") lines; state: $(wc -l < "$M/integrate-0910-merge-state.md") lines"

### line 15986
M=/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory
python3 - "$M/integrate-0910-merge-state.md" <<'PY'
import sys, io, re
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.rstrip("\n") + """

### 2026-09-20 00:0x — 收工點(用量將盡,Adam 要求收尾)

**E 第九輪 `9204e3e3` 交付完成、判官回 MERGE AFTER FIXES、裁決 39 已立(`315066d2`,已推、已驗公開)。**
閘門:變異 36/0 存活/0 drift＋2 對照綠、anchor sweep 38 全唯一、`check_gate_anchors` 115/115、
unit 78×2、offline 78/0、hazard 0;三份紅跑與兩支後測原文都在。碼站得住(判官與我各自核過)。

🔴 **下次開工第一件事:E 第十輪 = 裁決 39 的九項 ＋ 裁決 38(組級 H-B 判決)。**
worker `a7ae9e1f1b8368310` 已讀裁決 38、計畫寫定、**沒有動任何碼**,worktree 乾淨、head `9204e3e3`。
派它之前先讀工單 §9 裁決 38 與 39 全文。

**裁決 39 最重要的三項**:①`synthetic.py:186-191` 過時註解(與同檔 `:99-107` 互相矛盾;
判官與我各自獨立找到);②錨點自掃**覆蓋度回退且未揭露**(`e222176d` 兩節 60 行 → `9204e3e3` 一節 49 行,
外部那 10 顆沒掃);⑦裁決 37⑧ 只做一半——威脅效度寫進 SUMMARY 而 `FINDINGS.md:190` 仍是佔位符。

🔴 **我自己今晚的程序錯,兩條**:
(a) **我在 worker 最終通知之前就派了判官**(閘門 23:55:52 收、我 23:56 派,worker 的 193 行 round 9 段
是在判官審查期間寫進去的)——**那正是我在 D 第三輪之後立的規矩**(工單 `:165`)。
📌 判準改成可檢驗的:**派判官前看「worker 的最終通知在不在手上」,log 收尾不是交付完成。**
(b) **`cpu_for_window` 的機制是我說錯的**:我在放行訊息寫「only differences the endpoints」,
worker 採用,判官讀碼抓到——`analyse.py:532-542` 是逐列累加、`.5` 真的被 `int()` 截過,
是 telescoping 相消才回到端點差。結果對、機制錯。⇒ 已進 [[claim-verb-decides-the-evidence]]。

**還沒開始的最後一段(要 E 第十輪落地才輪得到)**:第五次 campaign `115737Z` 的
`analyse.py`＋`plot.py` → FINDINGS §0–§8 → 三張圖 → bmv2 12×／pps 天花板／遙測成本固定三條對帳。
🔴 那批**連 summary.json 都還沒有**,六格 H-B 判決一次都還沒算過。
報告草稿(四段式)在 scratchpad `report-draft.md`,158 行,①②③④ 都寫了,只缺 E 與圖。
"""
s = re.sub(r'(\n  modified: )[^\n]+', r'\g<1>2026-09-20T00:05:00Z', s, count=1)
io.open(p, 'w', encoding='utf-8').write(s)
PY
echo "state: $(wc -l < "$M/integrate-0910-merge-state.md") lines"
P=$(cat /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad/drv-sweeper.pid 2>/dev/null)
if [ -n "$P" ] && [ -d "/proc/$P" ]; then kill "$P" && echo "stopped sweeper pid $P"; else echo "sweeper pid $P already gone"; fi
df -h / | awk 'NR==2{print "disk free:",$4}'
cd /home/adam/Desktop/NDTwin-Kernel && NDT_OWNER=p3-orch tools/test_workflow/ndt status 2>&1 | sed -n '2,6p'

### line 16086
M=/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory
python3 - "$M/integrate-0910-merge-state.md" <<'PY'
import sys, io, re
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
s=s.rstrip("\n")+"""

### 00:2x — FINDINGS 已填到能填的極限,`c1f4174f` 已推並驗公開

填了:§2 天花板表(none 30/30、coop 12/30→21.0*、link 12/20→16.0,與 fig1 一致)、
§2 註冊比較(coop 兩格 H-A0 unresolved、link 兩格 ratio 0.533 → H-A2)、
§5 對帳三條((a) none 1.875 落外／cooperative 1.3125 一致;(b) m=122.9 us/sample 落在 [103,618] ⇒ H-C1,
固定份額 0.072 < 0.5;(c) 四列並排,本輪 30.0 kpps = 245.8 Mbit/s,**不得除以任何一格**)、
§6 威脅效度十條(裁決 39⑦ 要的兩條＋天花板解析度＋負載閘盲區＋cpu.jsonl 樣本列)。
📌 **數字是腳本從 summary.json 抽的,不是我轉抄的**——今晚的錯誤模式就是轉抄與推論。

🔴 **§3 取樣誤差刻意留空並寫明原因**:裁決 38 擋的是**標籤不是數字**,
圖／median／預測／links_used 都就緒,但組級判決做出來前填任何 H-B 標籤都是
「PREREG 沒註冊過的結論」。第十輪做完就能填。

**剩下的**:①E 第十輪(裁決 39 九項＋裁決 38);②第十輪落地後回填 §3 與 §0/§1/§4/§7/§8
的敘述空格(還有 75 個 `<>`);③四段式報告的最終版(草稿在 scratchpad `report-draft.md`)。
"""
s=re.sub(r'(\n  modified: )[^\n]+', r'\g<1>2026-09-20T00:25:00Z', s, count=1)
io.open(p,"w",encoding="utf-8").write(s)
PY
cd /home/adam/Desktop/NDTwin-Kernel
echo "state: $(wc -l < "$M/integrate-0910-merge-state.md") lines | trunk: $(git rev-parse --short HEAD) | uncommitted: $(git status --porcelain -- doc/audit/2026-09-19_telemetry-three-groups/ | wc -l)"

### line 17369
cd /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad && python3 - <<'EOF'
import json,sys
J="/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0.jsonl"
last={}
n=0
with open(J) as f:
    for line in f:
        n+=1
        try: o=json.loads(line)
        except Exception: continue
        m=o.get("message") or {}
        c=m.get("content")
        if not isinstance(c,list): continue
        for b in c:
            if b.get("type")=="tool_use" and b.get("name") in ("Write",):
                fp=(b.get("input") or {}).get("file_path","")
                if fp.endswith("report-draft.md"):
                    last[fp]=b["input"].get("content","")
print("lines",n)
for fp,txt in last.items():
    print(fp, len(txt.splitlines()),"lines")
    open("report-draft.recovered.md","w").write(txt)
EOF
ls -la; echo "### edits to the draft after the Write?"; grep -c '"file_path":"[^"]*report-draft.md"' /home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0.jsonl

### line 17385
cd /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad && python3 - <<'EOF'
import json,re
J="/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0.jsonl"
cands=[]
with open(J) as f:
    for i,line in enumerate(f):
        if "report-draft" not in line: continue
        try: o=json.loads(line)
        except Exception: continue
        c=(o.get("message") or {}).get("content")
        if not isinstance(c,list): continue
        for b in c:
            if b.get("type")=="tool_use":
                inp=b.get("input") or {}
                s=json.dumps(inp,ensure_ascii=False)
                if "report-draft" in s:
                    cands.append((i,b.get("name"),len(s),inp))
print("candidates:",[(i,n,l) for i,n,l in [(c[0],c[1],c[2]) for c in cands]])
# take the largest Bash/Write candidate and try to extract a heredoc body
best=max(cands,key=lambda c:c[2]) if cands else None
if best:
    i,name,l,inp=best
    txt=inp.get("content") or inp.get("command") or ""
    m=re.search(r"<<\s*'?(\w+)'?\n(.*?)\n\1\n",txt,re.S)
    body=m.group(2) if m else txt
    open("report-draft.recovered.md","w").write(body)
    print("recovered from line",i,name,"->",len(body.splitlines()),"lines")
    print(body[:600])
EOF

### line 17402
cd /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad && python3 - <<'EOF'
import json,re
J="/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0.jsonl"
seen=set(); out=[]
with open(J) as f:
    for i,line in enumerate(f):
        if "report-draft" not in line: continue
        try: o=json.loads(line)
        except Exception: continue
        c=(o.get("message") or {}).get("content")
        if not isinstance(c,list): continue
        for b in c:
            if b.get("type")=="tool_use" and b.get("name")=="Bash":
                cmd=(b.get("input") or {}).get("command","")
                if "report-draft" in cmd and cmd not in seen:
                    seen.add(cmd); out.append((i,cmd))
with open("draft-replay.sh","w") as w:
    for i,cmd in out:
        w.write("### line %d\n%s\n\n" % (i,cmd))
print("distinct commands:",len(out))
for i,cmd in out:
    first=cmd.strip().splitlines()[0][:150]
    danger=[t for t in ("rm ","git ","sudo","mv ","/home/adam/Desktop") if t in cmd]
    print(i, len(cmd), danger, "|", first)
EOF

