#!/usr/bin/env python3
"""FINDINGS.md, sections 4 / 5(b) / 6 / 8, regenerated from the corrected summary.json, with an erratum.

[Co-developed with claude code -- Adam]

TICKET-P4 section 7 ruling 4 (Adam, 2026-09-24): correct FINDINGS 4 and fig3, keep the old
values visible in an erratum table, and label the per-rung CPU reading "climb -- decided by
Adam, NOT registered by PREREG" everywhere.

HOW IT AVOIDS HAND-EDITED NUMBERS. Every sentence that quotes a changed key is written here as a
TEMPLATE. The template is filled twice: from the OLD summary (analyse.py at 30aa500c, the union
window) -- and that text must occur in FINDINGS.md exactly once, which proves the published
sentence is what the old summary said -- and from the NEW summary (the round-2 fix), which
replaces it. Prose that is new (the erratum, the H-C1 note, the labels) is also a template whose
every number comes from the two summaries. Nothing is typed.

Usage: fill_findings_erratum.py <old summary.json> <new summary.json> <FINDINGS.md> <raw run dir>
                                <leafdiff log (old vs new)> [--write]
Without --write it prints the unified diff and changes nothing. The raw run dir is read (read-only)
for the two facts of the erratum that are not in a summary: the union window's width on the
example arm, and which 1024 B (group, rung) cells carried re-confirmation rows.
"""
import difflib
import json
import os
import re
import sys

OLD = json.load(open(sys.argv[1]))
NEW = json.load(open(sys.argv[2]))
PATH = sys.argv[3]
RAW = sys.argv[4]
LEAFDIFF = sys.argv[5]
WRITE = "--write" in sys.argv
TEXT = open(PATH).read()
ORIGINAL = TEXT

WINDOW = NEW["cpu_window"]
assert WINDOW["primary"] == "climb" and WINDOW["decided_by_prereg"] is False
assert WINDOW["decided_by"] == "Adam 2026-09-24, TICKET-P4 §7 ruling 4"
for key in ("cpu_kernel", "cpu_bmv2", "cpu_bmv2_ratio"):
    assert NEW[key]["rung_window_reading"] == "climb", key
    assert "rung_window_reading" not in OLD[key], key          # the old summary predates it
SECONDARY = WINDOW["readings"]["climb+confirmation"]


def replace(old, new, what):
    global TEXT
    count = TEXT.count(old)
    assert count == 1, "%s: the OLD text occurs %d times in FINDINGS.md (want 1):\n%s" % (what, count, old)
    TEXT = TEXT.replace(old, new)
    print("replaced  %-44s %s" % (what, "(unchanged text)" if old == new else ""))


def insert_after(anchor, new, what):
    global TEXT
    assert TEXT.count(anchor) == 1, "%s: anchor occurs %d times" % (what, TEXT.count(anchor))
    TEXT = TEXT.replace(anchor, anchor + new)
    print("inserted  %s" % what)


def rows(summary, group):
    return {r["kpps"]: r for r in summary["cpu_kernel"]["rows"] if r["group"] == group}


def fit(summary, group):
    return summary["cpu_kernel"]["fits"][group]


def recon_b(summary, group):
    return next(r for r in summary["reconciliation"] if r["id"] == "b" and r["group"] == group)


def bmv2_rows(summary):
    return {r["kpps"]: r for r in summary["cpu_bmv2_ratio"]["rows"]}


# ---- (1) the per-rung table of section 4 ------------------------------------------------------
def table_row(summary, k):
    c, l = rows(summary, "cooperative")[k], rows(summary, "link")[k]
    return "| %g | %.0f | %+.3f | %+.3f | coop %.3f／link %.3f | %s |" % (
        k, c["samples_per_s"], c["delta_percent"], l["delta_percent"], c["spread"], l["spread"],
        "是" if (c["resolved"] and l["resolved"]) else "否")


KPPS = sorted(rows(OLD, "cooperative"))
assert KPPS == sorted(rows(NEW, "cooperative"))
changed_rungs = [k for k in KPPS if table_row(OLD, k) != table_row(NEW, k)]
for k in KPPS:
    replace(table_row(OLD, k), table_row(NEW, k), "section 4 table, %g kpps" % k)


def resolved_count(summary):
    return sum(1 for k in KPPS if rows(summary, "cooperative")[k]["resolved"]
               and rows(summary, "link")[k]["resolved"])


assert resolved_count(OLD) == resolved_count(NEW) == 11
replace("本輪 11 階全解析、差異未改判決", "本輪 %d 階全解析、差異未改判決" % resolved_count(NEW),
        "section 4 table header (11 resolved)")

# ---- (2) the decomposition --------------------------------------------------------------------
def hc2_tail(summary, group):
    h = fit(summary, group)["H-C2"]
    return ("（H-C2 條件一%s：share %.3f；條件二 Δ(高)/Δ(低) %.3f vs S(高)/S(低) %.3f，PREREG 無註冊容差 ⇒ "
            "不可判，裁決 40③）" % ("成立" if h["condition_1"] else "不成立", h["share"],
                                h["delta_ratio"], h["s_ratio"]))


def decomposition_row(summary, group, note=""):
    e = fit(summary, group)
    f = e["fit"]
    return "| `%s` | %.4f | %.2f | %.4f | %s%s%s |" % (
        group, f["fixed_percent"], f["marginal_us_per_sample"], e["H-C2"]["share"], e["verdict"],
        note, hc2_tail(summary, group))


coop_new = fit(NEW, "cooperative")
assert coop_new["verdict"].startswith("H-C1")
HC1_NOTE = ("【🔴 標籤名說「固定成分主導」，但固定份額只有 %.4f——H-C1 在這裡成立的依據**只有** m＝%.2f "
            "落在 [103, 618]（裁決 40④）；固定份額那一條（≥ 0.5）不成立】"
            % (coop_new["H-C2"]["share"], coop_new["fit"]["marginal_us_per_sample"]))
replace(decomposition_row(OLD, "cooperative"), decomposition_row(NEW, "cooperative", HC1_NOTE),
        "decomposition, cooperative")
replace(decomposition_row(OLD, "link"), decomposition_row(NEW, "link"), "decomposition, link")
replace("### 分解（PREREG 5.3）\n",
        "### 分解（PREREG 5.3）\n\n逐階視窗＝**climb**（Adam 2026-09-24 裁定、非 PREREG 註冊，§4.0）。\n",
        "decomposition heading: the reading")


def how_to_read(summary):
    c, l = fit(summary, "cooperative"), fit(summary, "link")
    return ("（%.2f ∈ [103, 618]）；固定份額 %.4f < 0.5" % (c["fit"]["marginal_us_per_sample"],
                                                    c["H-C2"]["share"]),
            "m %.2f 落帶外、固定份額 %.4f" % (l["fit"]["marginal_us_per_sample"], l["H-C2"]["share"]))


for old, new in zip(how_to_read(OLD), how_to_read(NEW)):
    replace(old, new, "how-to-read paragraph")

# ---- (3) the registered bmv2 per-rung statement ----------------------------------------------
def bmv2_sentence(summary):
    b = bmv2_rows(summary)
    out = [k for k in sorted(b) if b[k]["inside"] is False]
    return ("`bmv2(cooperative)/bmv2(none)` 逐階＝%s；區間 [0.90, 1.15] ⇒ **%d 階一致、%d 階不一致**（落外的階：%s）。"
            % ("、".join("%g kpps %.3f" % (k, b[k]["ratio"]) for k in sorted(b)),
               sum(1 for k in b if b[k]["inside"]), len(out),
               "、".join("%g kpps %.3f" % (k, b[k]["ratio"]) for k in out)))


ob, nb = bmv2_rows(OLD), bmv2_rows(NEW)
flips = [(k, ob[k], nb[k]) for k in sorted(ob) if ob[k]["inside"] != nb[k]["inside"]]
flip_text = "、".join("%g kpps 由帶%s翻帶%s（%.3f→%.3f）" % (k, "內" if o["inside"] else "外",
                                                      "內" if n["inside"] else "外", o["ratio"], n["ratio"])
                     for k, o, n in flips)
replace(bmv2_sentence(OLD),
        bmv2_sentence(NEW) + "逐階視窗＝climb（Adam 2026-09-24 裁定、非 PREREG 註冊）；勘誤翻了 %d 個註冊的逐階判決：%s，見 §4.0。"
        % (len(flips), flip_text), "bmv2 per-rung sentence")

# ---- (4) section 4's own pointers --------------------------------------------------------------
replace("數字由腳本從 `cpu_kernel`／`cpu_bmv2_ratio`／`external_gate` 抽出。",
        "數字由腳本從 `cpu_kernel`／`cpu_bmv2_ratio`／`external_gate` 抽出（2026-09-24 起取自勘誤後的 "
        "summary.json；逐階視窗＝climb，Adam 裁定、非 PREREG 註冊；勘誤前的值在 §4.0）。",
        "section 4 intro: source")
replace("**圖：`fig3_cpu.png` / `.pdf`（bmv2／kernel／proxy+emitter 三個面板）。**",
        "**圖：`fig3_cpu.png` / `.pdf`（bmv2／kernel／proxy+emitter 三個面板）。** 2026-09-24 以 climb 讀法重生"
        "（標題寫明 `rung window: climb`）；勘誤前的圖在 git 歷史 `c1f4174f`。",
        "section 4 intro: figure")

# ---- (5) reconciliation (b) -------------------------------------------------------------------
def recon_rows(summary):
    lines = []
    for group in ("cooperative", "link"):
        r = recon_b(summary, group)
        m, share = r["marginal_us_per_sample"], r["fixed_share"]
        lines.append("| m（us/sample）（%s） | %.1f | 206 | 落在 [103, 618] | **%s** |"
                     % (group, m, "一致" if 103 <= m <= 618 else "落外"))
        lines.append("| 固定份額（%s） | %.3f | 0.81 | 大於等於 0.5 | **%s** |"
                     % (group, share, "成立" if share >= 0.5 else "不成立"))
    return lines


for old, new in zip(recon_rows(OLD), recon_rows(NEW)):
    assert old.rsplit("|", 2)[-2] == new.rsplit("|", 2)[-2], (old, new)   # the verdict holds
    replace(old, new, "reconciliation (b) row")
replace("### (b) CPU vs 08-20「遙測成本固定、不是每樣本」\n",
        "### (b) CPU vs 08-20「遙測成本固定、不是每樣本」\n\n逐階視窗＝**climb**（Adam 2026-09-24 裁定、非 PREREG 註冊；勘誤前的值在 §4.0）。\n",
        "reconciliation (b) heading: the reading")
lo, ln = recon_b(OLD, "link"), recon_b(NEW, "link")
replace("（本輪 %.1f < 103）" % lo["marginal_us_per_sample"], "（本輪 %.1f < 103）" % ln["marginal_us_per_sample"],
        "reconciliation (b) candidate 1")
replace("固定份額（%.3f）自然變小" % lo["fixed_share"], "固定份額（%.3f）自然變小" % ln["fixed_share"],
        "reconciliation (b) candidate 2")

# ---- (6) section 8 ----------------------------------------------------------------------------
co, cn = recon_b(OLD, "cooperative"), recon_b(NEW, "cooperative")
replace("對帳 (b) `cooperative` 的 m＝%.1f µs/sample 落在 [103,618]" % co["marginal_us_per_sample"],
        "對帳 (b) `cooperative` 的 m＝%.1f µs/sample 落在 [103,618]（climb 讀法）" % cn["marginal_us_per_sample"],
        "section 8, supported")
replace("對帳 (b) `link` 的 m＝%.1f 落外且固定份額 %.3f" % (lo["marginal_us_per_sample"], lo["fixed_share"]),
        "對帳 (b) `link` 的 m＝%.1f 落外且固定份額 %.3f（climb 讀法）" % (ln["marginal_us_per_sample"], ln["fixed_share"]),
        "section 8, not supported")

# ---- (7) the two readings agree on every verdict? ---------------------------------------------
climb = WINDOW["readings"]["climb"]
agree_hc = all(climb["cpu_kernel"]["fits"][g]["verdict"] == SECONDARY["cpu_kernel"]["fits"][g]["verdict"]
               for g in ("cooperative", "link"))
agree_b = all((a["consistent"], a["verdict"]) == (b["consistent"], b["verdict"])
              for a, b in zip(climb["reconciliation_b"], SECONDARY["reconciliation_b"]))
cb, sb = bmv2_rows(climb), bmv2_rows(SECONDARY)
agree_bmv2 = all(cb[k]["inside"] == sb[k]["inside"] for k in cb)
print("the two readings agree: H-C %s, (b) %s, bmv2 per rung %s" % (agree_hc, agree_b, agree_bmv2))
assert agree_hc and agree_b and agree_bmv2, "the readings disagree -- the erratum text below would be false"
old_verdicts = [fit(OLD, g)["verdict"] for g in ("cooperative", "link")]
new_verdicts = [fit(NEW, g)["verdict"] for g in ("cooperative", "link")]
assert old_verdicts == new_verdicts
assert [(recon_b(OLD, g)["consistent"], recon_b(OLD, g)["verdict"]) for g in ("cooperative", "link")] == \
       [(recon_b(NEW, g)["consistent"], recon_b(NEW, g)["verdict"]) for g in ("cooperative", "link")]

# ---- (8) the erratum, at the top of section 4 -------------------------------------------------
def cell_rows():
    out = []
    labels = (("量到的 samples/s（coop）", "cooperative", "samples_per_s", "%.1f"),
              ("Δkernel(coop−none)", "cooperative", "delta_percent", "%+.3f"),
              ("Δkernel(link−none)", "link", "delta_percent", "%+.3f"),
              ("散佈 coop", "cooperative", "spread", "%.3f"),
              ("散佈 link", "link", "spread", "%.3f"))
    for k in changed_rungs:
        for name, group, key, fmt in labels:
            o, n = rows(OLD, group)[k][key], rows(NEW, group)[k][key]
            if fmt % o != fmt % n:
                out.append("| §4 表 %g kpps | %s | %s | %s |" % (k, name, fmt % o, fmt % n))
    for group in ("cooperative", "link"):
        fo, fn = fit(OLD, group), fit(NEW, group)
        out.append("| §4 分解 `%s` | F（%% of one core） | %.4f | %.4f |" % (group, fo["fit"]["fixed_percent"], fn["fit"]["fixed_percent"]))
        out.append("| §4 分解 `%s` | m（µs/sample） | %.2f | %.2f |" % (group, fo["fit"]["marginal_us_per_sample"], fn["fit"]["marginal_us_per_sample"]))
        out.append("| §4 分解 `%s` | 固定份額（＝H-C2 條件一的 share） | %.4f | %.4f |" % (group, fo["H-C2"]["share"], fn["H-C2"]["share"]))
        out.append("| §4 分解 `%s` | 判定 | %s | **不變** |" % (group, fo["verdict"]))
        out.append("| §4 分解 `%s` | Δ比 / S比（1 與 110 kpps） | %.3f / %.3f | **不變** |" % (group, fo["H-C2"]["delta_ratio"], fo["H-C2"]["s_ratio"]))
    for k in sorted(ob):
        if "%.3f" % ob[k]["ratio"] != "%.3f" % nb[k]["ratio"]:
            out.append("| §4 bmv2 coop/none | %g kpps | %.3f（%s） | %.3f（%s）%s |" % (
                k, ob[k]["ratio"], "帶內" if ob[k]["inside"] else "帶外", nb[k]["ratio"],
                "帶內" if nb[k]["inside"] else "帶外",
                "——**註冊的逐階判決翻轉**" if ob[k]["inside"] != nb[k]["inside"] else ""))
    out.append("| §4 bmv2 coop/none | 帶外的階 | %s（%d／%d） | %s（%d／%d） |" % (
        "、".join("%g" % k for k in sorted(ob) if ob[k]["inside"] is False), sum(1 for k in ob if ob[k]["inside"] is False), len(ob),
        "、".join("%g" % k for k in sorted(nb) if nb[k]["inside"] is False), sum(1 for k in nb if nb[k]["inside"] is False), len(nb)))
    for group in ("cooperative", "link"):
        o, n = recon_b(OLD, group), recon_b(NEW, group)
        out.append("| §5 (b) `%s` | m / 固定份額 | %.1f / %.3f | %.1f / %.3f |" % (group, o["marginal_us_per_sample"], o["fixed_share"], n["marginal_us_per_sample"], n["fixed_share"]))
        out.append("| §5 (b) `%s` | 判定 | %s | **不變** |" % (group, "一致" if o["consistent"] else "落外"))
    return out


link_sb = (bmv2_rows(climb)[30.0]["ratio"], bmv2_rows(SECONDARY)[30.0]["ratio"])
ERRATUM = """
### 4.0 🔴 勘誤（2026-09-24）：逐階 CPU 視窗吞進了更高階

**錯在哪。** `analyse.py` 的 `rung_windows`（`:693-703`；本段行號皆為勘誤前的 `30aa500c`）把 `rungs.tsv` 裡同一個 kpps 的所有列聯集成**一個** (min t_start, max t_end) 視窗。梯頂再確認的三個 rep（`c1`–`c3`，`run_group_arm.sh:420-440`）以同一個 kpps 記在**整個爬梯之後**，所以被確認那一階的視窗從爬梯第一個 rep 一路包到確認最後一個 rep、中間更高的階全在裡面（例：`G4/link_f64_b` 的 20 kpps 視窗 %(example).1f s，包住 30–110 kpps）。兩個消費者都錯在那一階：逐階 CPU（`cpu_by_rung`，`:739-740`）與 S(k)（`rung_samples_per_second`，`:708`——分子只有爬梯的樣本、分母是整段）。本節 1024 B 受影響的格：%(affected)s kpps。第四次 campaign 的 raw 同形狀。

**誰、何時。** 2026-09-24 由 P4 worker P 發現；orchestrator、worker C（離線重驗）與判官（opus，HOLDS WITH CORRECTIONS）各自驗證。修正後每一階的視窗＝它自己的 rep，S(k) 只用爬梯（PREREG A1.5 `:505-507`）。

**讀法——Adam 裁定，不是 PREREG 註冊的。** 梯頂再確認的 rep 算不算該階的 CPU，PREREG 沒有決定（§4.1 `:161-162` 只說再確認是梯子程序的一部分）。本文的主讀法＝**climb（只算爬升的 rep）**，由 **%(decided_by)s** 裁定、**非 PREREG 註冊**。記錄的理由：§5.3（`:263-266`）把 CPU(k) 與 S(k) 配成同一個擬合，而 S(k) 只涵蓋爬升（`:505-507`）⇒ 兩邊同一個窗；本輪沿用的 08-28 規則（`2026-08-28_flow-count-capacity/PREREG.md:254-255`）把首讀與再確認分開記，“so a disagreement between them is visible rather than overwritten”。另一讀法（climb＋再確認 rep）照算、並列在 `summary.json` 的 `cpu_window`；**兩種讀法在第五次 campaign 的判決逐項相同**（H-C ×2、對帳 (b) ×2、bmv2 逐階 ×%(n_rungs)d），但數字不全同（例：bmv2 30 kpps 比值 %(b30c).3f vs %(b30s).3f）。

**判決。** H-C（兩組）與對帳 (b) **不變**；**註冊的 bmv2 逐階判決有 %(n_flips)d／%(n_rungs)d 翻轉**（%(flip_text)s），帶外總數仍 %(n_out)d／%(n_rungs)d。`cooperative` 仍是 H-C1，但它的固定份額現在是 %(coop_share).4f——H-C1 成立的依據**只有** m 落帶（裁決 40④）。

**舊值不刪。** 下表每一列＝一個被這次勘誤改動的數（舊＝勘誤前公開的值，新＝climb 讀法）；本節其餘的數字與 §1–§3、§5(a)(c) 都沒有變（summary.json 逐葉對帳：%(same)d 個葉值相同、%(changed)d 個變，全在 `cpu_kernel`／`cpu_bmv2`／`cpu_bmv2_ratio`／對帳 (b)）。

| 出處 | 量 | 舊（勘誤前） | 新（climb） |
|---|---|---|---|
%(rows)s
| fig3 | 三個面板在 12／20／30 kpps 的點 | `c1f4174f` 的圖 | 重生，標題寫明 `rung window: climb` |

勘誤後的數字取自 `%(new_summary)s`（勘誤前的取自 `%(old_summary)s`）。重驗的全部輸出（兩份 summary.json、逐葉對帳、不 import `analyse.py` 的第二套儀器、逐臂的再確認段 CPU）：`scratch/overnight-2026-09-05/logs/orchestrator-0924/cpu-window-recheck/`；報告 `scratch/overnight-2026-09-05/hunt-0911/fix/P4-C-SUMMARY.md`。
"""
leaf_log = open(LEAFDIFF).read()
leaf_same = int(re.search(r"leaf values identical in both: (\d+)", leaf_log).group(1))
leaf_changed = int(re.search(r"changed: (\d+)", leaf_log).group(1))
changed_paths = re.findall(r"^  CHANGED /([a-z0-9_]+)", leaf_log, re.M)
assert set(changed_paths) == {"cpu_kernel", "cpu_bmv2", "cpu_bmv2_ratio", "reconciliation"}, set(changed_paths)


def read_tsv(path):
    lines = [l.rstrip("\n") for l in open(path) if l.strip()]
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]]


def union_width(arm_dir, kpps):
    spans = [(float(r["t_start"]), float(r["t_end"])) for r in read_tsv(os.path.join(arm_dir, "rungs.tsv"))
             if float(r["kpps"]) == kpps]
    return max(t1 for _t0, t1 in spans) - min(t0 for t0, _t1 in spans)


example_width = union_width(os.path.join(RAW, "G4", "link_f64_b"), 20.0)
affected = {}
for gen in sorted(os.listdir(RAW)):
    gdir = os.path.join(RAW, gen)
    if not (gen.startswith("G") and os.path.isdir(gdir)):
        continue
    for arm in sorted(os.listdir(gdir)):
        tsv = os.path.join(gdir, arm, "rungs.tsv")
        if not os.path.exists(tsv) or "_f1024_" not in arm:
            continue
        for r in read_tsv(tsv):
            if r["rep"].startswith("c"):
                affected.setdefault(arm.split("_f1024_")[0], set()).add(float(r["kpps"]))
short = {"cooperative": "coop", "link": "link", "none": "none"}
affected_text = "、".join("%s %s" % (short[g], "／".join("%g" % k for k in sorted(affected[g])))
                          for g in ("cooperative", "link", "none") if g in affected)
print("from the raw: union window of G4/link_f64_b at 20 kpps = %.1f s; 1024 B cells with c-rows: %s"
      % (example_width, affected_text))
erratum = ERRATUM % {
    "decided_by": WINDOW["decided_by"], "example": example_width, "affected": affected_text,
    "new_summary": os.path.basename(sys.argv[2]), "old_summary": os.path.basename(sys.argv[1]),
    "n_rungs": len(nb), "b30c": link_sb[0], "b30s": link_sb[1], "n_flips": len(flips),
    "flip_text": flip_text, "n_out": sum(1 for k in nb if nb[k]["inside"] is False),
    "coop_share": coop_new["H-C2"]["share"], "same": leaf_same, "changed": leaf_changed,
    "rows": "\n".join(cell_rows())}
insert_after("## 4. 三、CPU\n", erratum, "section 4.0 erratum")

# ---- (9) section 6: the non-registered choice, as a threat --------------------------------------
cl20 = (rows(climb, "link")[20.0]["spread"], rows(SECONDARY, "link")[20.0]["spread"])
insert_after("    一份「header 宣告十台、每列只寫一台」的 fixture 會完整通過那支對帳。\n",
             "11. 🔴 **逐階 CPU 視窗的讀法不是 PREREG 註冊的**（§4.0）：PREREG 沒說梯頂再確認的 rep 算不算該階；"
             "本文用 climb（Adam 2026-09-24 裁定）。另一讀法的數字在 `summary.json` 的 `cpu_window`——第五次兩讀法判決逐項相同，"
             "但數字不全同（bmv2 30 kpps 比值 %.3f vs %.3f、link 20 kpps 散佈 %.3f vs %.3f）。\n"
             % (link_sb[0], link_sb[1], cl20[0], cl20[1]), "section 6 item 11")

diff = difflib.unified_diff(ORIGINAL.splitlines(True), TEXT.splitlines(True), "FINDINGS.md (before)",
                            "FINDINGS.md (after)")
sys.stdout.writelines(diff)
if WRITE:
    open(PATH, "w").write(TEXT)
    print("\nwritten: %s" % PATH)
