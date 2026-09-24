#!/usr/bin/env python3
"""Fill FINDINGS sections 3 and 4 from a summary.json produced by analyse.py (rulings 38 + 40).
Usage: fill_findings_34.py <summary.json> <FINDINGS.md> [--dry-run]
Every number is read from the JSON; the only prose is the registered-level wording of ruling 40.
[Co-developed with claude code -- Adam]"""
import io, json, statistics, sys
S, F = sys.argv[1], sys.argv[2]; dry = "--dry-run" in sys.argv
d = json.load(open(S)); s = io.open(F, encoding="utf-8").read()
def rep(old, new):
    global s
    assert s.count(old) == 1, (s.count(old), old[:70]); s = s.replace(old, new)
rows = {(r["group"], r["offered_mbit"]): r for r in d["sampling_error"]}
def f4(x): return "n/a" if x is None else "%.4f" % x
def sf(x): return "n/a" if x is None else "%+.4f" % x
def cell(g, rate, key): return f4(rows[(g, rate)][key])
def scell(g, rate): return sf(rows[(g, rate)]["median_signed_error"])
# --- section 3 banner
old_banner = s[s.index("🔴 **本節的 H-B 判決暫不填寫"):s.index("**圖：`fig2_sampling_error.png`")]
rep(old_banner, "本節的 H-B 判決是**組級**的（裁決 38／40）：H-B1／H-B4 對一組的三個速率判一次、H-B2 只在 100 Mbit/s 判且要三個視窗同號；逐格只留「在帶內／帶上／帶下」的描述當資料。數字由腳本從 `summary.json` 的 `sampling_error` 與 `sampling_error_by_group`／`sampling_error_cross_group_registered` 抽出。\n\n")
for g, label in (("cooperative", "`cooperative` median abs err"), ("link", "`link` median abs err")):
    rep("| %s | `<>` | `<>` | `<>` |" % label, "| %s | %s | %s | %s |" % ((label,) + tuple(cell(g, r, "median_abs_error") for r in (2, 20, 100))))
for g, label in (("cooperative", "`cooperative` 帶號中位數"), ("link", "`link` 帶號中位數")):
    rep("| %s | `<>` | `<>` | `<>` |" % label, "| %s | %s | %s | %s |" % ((label,) + tuple(scell(g, r) for r in (2, 20, 100))))
def ncell(rate):
    c, l = rows[("cooperative", rate)], rows[("link", rate)]
    nc, nl = c["predicted"]["n_samples"], l["predicted"]["n_samples"]
    if c.get("links_used") == l.get("links_used"): return "%.1f（%d 條邊）" % (nc, c["links_used"])
    return "coop %.1f（%d 條邊）／link %.1f（%d 條邊）" % (nc, c["links_used"], nl, l["links_used"])
rep("| 量到的 N（`addressed_total` 增量） | `<>` | `<>` | `<>` |", "| 量到的 N（每視窗樣本數 4×pps×8/256，邊數＝twin 讀到非零的邊） | %s | %s | %s |" % tuple(ncell(r) for r in (2, 20, 100)))
byg = {r["group"]: r for r in d["sampling_error_by_group"]}
def hb1(g):
    h = byg[g]["H-B1"]; out = []
    for r in h["rates"]:
        out.append("%g M %s（%s，帶 [%s, %s]）" % (r["offered_mbit"], {"inside": "內", "above": "上", "below": "下"}.get(r["position"], "?"), f4(r["median_abs_error"]), f4(r["band"][0]), f4(r["band"][1])))
    return ("**成立**" if h["holds"] else "**不成立**") + "：" + "、".join(out)
rep("| H-B1 shot-noise 主導（落在 [0.5, 2.0]×預測） | `<>` |", "| H-B1 shot-noise 主導（三個速率都落在 [0.5, 2.0]×預測） | `cooperative` %s；`link` %s |" % (hb1("cooperative"), hb1("link")))
def hb2(g):
    h = byg[g]["H-B2"]
    return ("**成立**" if h["holds"] else "**不成立**") + "（100 M 在帶%s，%s 個視窗%s）" % ({"inside": "內", "above": "上", "below": "下"}.get(h["position"], "?"), h.get("windows"), "同號" if h.get("same_sign") else "不同號")
rep("| H-B2 系統性偏差（大於 2×預測且三個視窗同號） | `<>` |", "| H-B2 系統性偏差（100 Mbit/s 那格大於 2×預測且三個視窗同號） | `cooperative` %s；`link` %s |" % (hb2("cooperative"), hb2("link")))
em = d["emitter_counters"]; dropped = sum(v for k, v in em.items() if k.startswith("dropped_") or k == "enobufs")
cross = {r["offered_mbit"]: r for r in d["sampling_error_cross_group"]}
over2 = [r for r in cross if cross[r]["ratio"] is not None and cross[r]["ratio"] > 2.0]
rep("| H-B3 `link` 的樣本掉了 | `<只有在 emitter 的 dropped_*／enobufs 大於 0 時才能寫；計數值：<>>` |",
    "| H-B3 `link` 的樣本掉了（E(link)/E(coop) > 2 且 emitter 計數 > 0） | **不可寫**：沒有任何速率 link/coop > 2（%s）；emitter `dropped_*`＋`enobufs`＝%d |" % ("、".join("%g M %.3f" % (r, cross[r]["ratio"]) for r in sorted(cross)), dropped))
cg = d["sampling_error_cross_group_registered"]
rep("| H-B4 兩條路一樣準（link/coop 落在 [0.5, 2.0]） | `<>` |",
    "| H-B4 兩條路一樣準（三個速率的 link/coop 都落在 [0.5, 2.0]） | %s：%s |" % ("**成立**" if cg["holds"] else "**不成立**", "、".join("%g M %.3f（%s）" % (r["offered_mbit"], r["ratio"], "內" if r["inside"] else "外") for r in cg["rates"])))
rep("emitter 統計行（每臂的 `emitter.log`）：`samples=<> emitted=<> dropped_*=<> enobufs=<>`。",
    "emitter 統計行（梯子臂 `emitter.log` 加總）：`samples=%d emitted=%d dropped_*=%d enobufs=%d`。" % (em["samples"], em["emitted"], sum(v for k, v in em.items() if k.startswith("dropped_")), em["enobufs"]))
coop_label = byg["cooperative"]["label"]
extra3 = ("\n🔴 **`cooperative` 的結局「%s」是 PREREG 沒有註冊的分支**（裁決 40②）：H-B1 不成立、H-B2 不成立，PREREG 5.2 與 §9 的結局表都沒有這一支 ⇒ 報數字、不貼標籤、不套用結局表的任何動作；登記為 PREREG 缺口（§6）。\n"
          "🔴 **`link` 20 M／100 M 的帶用 N＝5 條邊算**（第一個視窗讀到 5 條、另兩個 4 條，`sampling_summary` 取 `members[0]`；裁決 40⑧）：改用註冊的 4 條邊算帶，兩格同樣在帶內，判決不變。\n" % coop_label)
rep("🔴 **計數器是 0 就不准寫「樣本掉了」**", extra3 + "\n🔴 **計數器是 0 就不准寫「樣本掉了」**")
# --- section 4
old_banner4 = s[s.index("🔴 **本節的 H-C 判決暫不填寫"):s.index("**圖：`fig3_cpu.png`")]
rep(old_banner4, "本節的 H-C 判決是**每個處理組一次**（PREREG 5.3 為 kernel 的擬合註冊 H-C1／H-C2／H-C3／H-C0，擬合用三組共同的每一階；bmv2 只註冊逐階比值 ∈ [0.90, 1.15]、不帶 H-C 標籤——第十輪任務 C 查證、裁決 40）。H-C2 的第二條件沒有註冊容差 ⇒ 本輪**不可判**（裁決 40③），不准事後挑容差。數字由腳本從 `cpu_kernel`／`cpu_bmv2_ratio`／`external_gate` 抽出。\n\n")
ck = d["cpu_kernel"]; per = {}
for r in ck["rows"]: per.setdefault(r["kpps"], {})[r["group"]] = r
lines = []
for k in sorted(per):
    c, l = per[k].get("cooperative"), per[k].get("link")
    sps = (c or l)["samples_per_s"]
    lines.append("| %g | %s | %s | %s | %s | %s |" % (k, "n/a" if sps is None else "%.0f" % sps,
        "n/a" if not c else "%+.3f" % c["delta_percent"], "n/a" if not l else "%+.3f" % l["delta_percent"],
        "coop %s／link %s" % ("n/a" if not c else "%.3f" % c["spread"], "n/a" if not l else "%.3f" % l["spread"]),
        "是" if (c and c.get("resolved")) and (l and l.get("resolved")) else "否"))
rep("| `<>` | `<>` | `<>` | `<>` | `<>` | `<>` |", "\n".join(lines))
def fitrow(g):
    e = ck["fits"][g]; fit = e.get("fit") or {}
    F, m = fit.get("fixed_percent"), fit.get("marginal_us_per_sample"); stop = fit.get("max_samples_per_s")
    share = None if (F is None or m is None or not stop) else F / (F + m * 1e-6 * 100.0 * stop / 100.0 * 100.0 / 100.0) if False else None
    share = fit.get("fixed_share")
    if share is None and F is not None and m is not None and stop:
        share = F / (F + m * stop * 1e-4)  # m us/sample * S samples/s = us/s of one core; /1e4 -> % of one core
    v = e.get("verdict") or ""
    hc2 = e.get("H-C2") or {}
    note = ""
    if hc2:
        r3 = lambda x: "n/a" if x is None else "%.3f" % x
        note = "（H-C2 條件一%s：share %s；條件二 Δ(高)/Δ(低) %s vs S(高)/S(低) %s，PREREG 無註冊容差 ⇒ 不可判，裁決 40③）" % (
            "成立" if hc2.get("condition_1") else "不成立", r3(hc2.get("share")), r3(hc2.get("delta_ratio")), r3(hc2.get("s_ratio")))
    return "| `%s` | %s | %s | %s | %s%s |" % (g, "n/a" if F is None else "%.4f" % F, "n/a" if m is None else "%.2f" % m, "n/a" if share is None else "%.4f" % share, v, note)
rep("| `cooperative` | `<>` | `<>` | `<>` | `<H-C1 / H-C2 / H-C3 / H-C0>` |", fitrow("cooperative"))
rep("| `link` | `<>` | `<>` | `<>` | `<>` |", fitrow("link"))
br = d["cpu_bmv2_ratio"]; inside = [r for r in br["rows"] if r["inside"]]; outside = [r for r in br["rows"] if r["inside"] is False]
rep("**bmv2 CPU**（08-20 預測不動）：`bmv2(cooperative)/bmv2(none)` ＝ `<>`，區間 [0.90, 1.15] ⇒ `<一致／不一致>`。",
    "**bmv2 CPU**（08-20 預測不動；PREREG 5.3 逐階註冊、沒有跨階彙總）：`bmv2(cooperative)/bmv2(none)` 逐階＝%s；區間 [0.90, 1.15] ⇒ **%d 階一致、%d 階不一致**（%s）。" % (
        "、".join("%g kpps %.3f" % (r["kpps"], r["ratio"]) for r in br["rows"] if r["ratio"] is not None), len(inside), len(outside),
        "落外的階：" + "、".join("%g kpps %.3f" % (r["kpps"], r["ratio"]) for r in outside) if outside else "全部在內"))
sirq = {}
for e in d["external_gate"]: sirq.setdefault(e["group"], []).append(e["softirq_share"])
med = {g: statistics.median(v) for g, v in sirq.items()}
came_true = med.get("link", 0) > max(med.get("cooperative", 0), med.get("none", 0))
rep("**softirq**（`link` 的資料面成本歸屬不到任何 pid）：`<none / cooperative / link 的份額>` ⇒ `<預測成真／沒有>`。",
    "**softirq**（`link` 的資料面成本歸屬不到任何 pid；各組臂的 `softirq_share` 中位數）：`none` %.4f／`cooperative` %.4f／`link` %.4f ⇒ **%s**（PREREG 5.3 只註冊「逐組報」與方向，沒有區間）。" % (med.get("none", float("nan")), med.get("cooperative", float("nan")), med.get("link", float("nan")), "預測成真：link 最高" if came_true else "沒有成真"))
print("remaining placeholders:", s.count("`<"))
if not dry: io.open(F, "w", encoding="utf-8").write(s); print("written", F)
else: io.open(F + ".dryrun", "w", encoding="utf-8").write(s); print("dry-run written to", F + ".dryrun")
