// [Co-developed with claude code -- Adam]
// A cell's old/ (修前紀錄) or new/ (修好當晚) fixture, as the cell's own judge reads it: its ASSERT
// rows, its CELL: line, and -- for old/ -- whether the failing set is the reviewed EXPECTED-FAILS,
// the PROVENANCE.md and the fixture-gap note. A raw file opens below it. v1's element ids.
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { get } from "../api/client";
import type { ApiResult } from "../api/client";
import type { FixtureAnswer } from "../types";
import { errText } from "../lib/format";
import { BTN_SECONDARY, BTN_SMALL, CARD, PRE, WARN_TEXT } from "../lib/ui";
import { Cell, DataTable, Row } from "./DataTable";
import { StatusRow, StatusRows } from "./StatusRows";

export interface FixtureOpening {
  cell: string;
  which: "old" | "new";
  r: ApiResult<FixtureAnswer>;
}

export default function FixturePanel({ open, onClose }: { open: FixtureOpening | null; onClose: () => void }) {
  const { t } = useTranslation();
  const [raw, setRaw] = useState<{ name: string; text: string } | null>(null);
  const [rawFor, setRawFor] = useState<FixtureOpening | null>(null);
  if (rawFor !== open) {
    // another fixture was opened: its raw file view starts empty
    setRawFor(open);
    setRaw(null);
  }
  const j = open && open.r.status === 200 ? open.r.json : null;
  const base = open ? "/cells/" + encodeURIComponent(open.cell) + "/" + open.which : "";

  const readRaw = async (f: string) => {
    const fr = await get(base + "/raw/" + encodeURIComponent(f));
    setRaw({ name: f, text: fr.status === 200 ? fr.text : errText(fr) });
  };

  return (
    <section id="fixture" hidden={open === null} className={CARD + " mt-6"}>
      <div className="mb-3 flex items-center justify-between">
        <h3 id="fixture-title" className="text-lg font-semibold text-[#333]">
          {open
            ? t("ndtServe.fixture.title", {
                cell: open.cell,
                which: t(open.which === "old" ? "ndtServe.cellsTab.buttons.old.label" : "ndtServe.cellsTab.buttons.new.label"),
                dir: open.which + "/",
              })
            : ""}
        </h3>
        <button id="fixture-close" type="button" onClick={onClose} className={BTN_SECONDARY}>
          {t("ndtServe.fixture.close")}
        </button>
      </div>
      <p className="mb-3">
        <code id="fixture-verdict" className={"font-mono text-sm " + (j ? "" : WARN_TEXT)}>
          {open === null
            ? ""
            : j === null
              ? errText(open.r)
              : j.verdict
                ? j.verdict.line
                : t("ndtServe.fixture.noVerdict") + (j.timed_out ? t("ndtServe.fixture.timedOut") : "")}
        </code>
      </p>
      {j !== null && (
        <>
          <DataTable id="fixture-asserts" head={["", t("ndtServe.fixture.assert"), t("ndtServe.fixture.detail")]}>
            {j.asserts.map((a, i) => (
              <Row key={i}>
                <Cell>
                  <span className={a.ok ? "text-green-700" : "font-semibold text-red-700"}>
                    {a.ok ? t("ndtServe.fixture.ok") : t("ndtServe.fixture.fail")}
                  </span>
                </Cell>
                <Cell mono>{a.id}</Cell>
                <Cell>{a.detail}</Cell>
              </Row>
            ))}
          </DataTable>
          <div id="fixture-rows" className="mt-4">
            <StatusRows>
              <StatusRow label={t("ndtServe.fixture.failing")}>
                <code className="break-all font-mono text-xs">{(j.failing ?? []).join(" ")}</code>
              </StatusRow>
              {open?.which === "old" && (
                <>
                  <StatusRow label={t("ndtServe.fixture.expectedFails")}>
                    <code className="break-all font-mono text-xs">{(j.expected_fails ?? []).join(" ")}</code>
                  </StatusRow>
                  <StatusRow label={t("ndtServe.fixture.matches")}>
                    <span className={j.failing_matches_expected ? "text-green-700" : WARN_TEXT}>
                      {t(j.failing_matches_expected ? "ndtServe.fixture.yes" : "ndtServe.fixture.no")}
                    </span>
                  </StatusRow>
                  <StatusRow label={t("ndtServe.fixture.note")}>
                    <span className="text-left">{j.gap_note ?? ""}</span>
                  </StatusRow>
                </>
              )}
              <StatusRow label={t("ndtServe.fixture.rawFiles")}>
                {(j.files ?? []).map((f) => (
                  <button key={f} type="button" data-raw={f} onClick={() => void readRaw(f)} className={BTN_SMALL}>
                    {f}
                  </button>
                ))}
              </StatusRow>
            </StatusRows>
          </div>
          {open?.which === "old" && j.provenance && (
            <details className="mt-4">
              <summary className="cursor-pointer text-sm text-gray-600">{t("ndtServe.fixture.provenance")}</summary>
              <pre className={PRE + " mt-2"}>{j.provenance}</pre>
            </details>
          )}
        </>
      )}
      {raw !== null && <h4 className="mb-1 mt-4 font-mono text-xs text-gray-600">{raw.name}</h4>}
      <pre id="fixture-raw" hidden={raw === null} className={PRE}>
        {raw?.text ?? ""}
      </pre>
    </section>
  );
}
