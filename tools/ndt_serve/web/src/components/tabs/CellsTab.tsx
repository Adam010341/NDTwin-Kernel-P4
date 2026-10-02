// [Co-developed with claude code -- Adam]
// 驗證格: the live_cells grid (GET /cells, i.e. run_cells.sh --list), one line per cell saying what it
// checks, and the four buttons Adam's point 8 renamed -- 修前紀錄 (old/), 修好當晚 (new/), 現在重跑
// (run), 逐步驗證 (walk) -- each explained in the legend and on hover. Below: the fixture view, the
// walks, and the walk panel. Nothing here refreshes by itself: the grid is read when the tab is first
// opened and when 讀取驗證格 is pressed.
import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { get } from "../../api/client";
import type { ApiResult } from "../../api/client";
import type { AnswerArea, CellsAnswer, FixtureAnswer, WalkAnswer, WalksAnswer } from "../../types";
import type { ConfirmRequest } from "../ConfirmDialog";
import { errText } from "../../lib/format";
import { BTN_SECONDARY, BTN_SMALL, CARD, WARN_TEXT } from "../../lib/ui";
import Answer from "../Answer";
import { Cell, DataTable, Row } from "../DataTable";
import Explain from "../Explain";
import FixturePanel from "../FixturePanel";
import type { FixtureOpening } from "../FixturePanel";
import ShortId from "../ShortId";
import WalkPanel from "../WalkPanel";
import LoadingSpinner from "../common/LoadingSpinner";

const BUTTONS = ["old", "new", "run", "walk"] as const;

export default function CellsTab({
  active,
  confirmThen,
  jobStarted,
  answers,
  setAnswer,
  openJob,
  walks,
  loadWalks,
  walkId,
  walk,
  openWalk,
  closeWalk,
  walkAfter,
}: {
  active: boolean;
  confirmThen: (a: ConfirmRequest) => void;
  jobStarted: (area: AnswerArea) => (r: ApiResult<unknown>) => void;
  answers: { cells: ApiResult<unknown> | null; walk: ApiResult<unknown> | null };
  setAnswer: (area: AnswerArea, r: ApiResult<unknown>) => void;
  openJob: (id: string) => void;
  walks: ApiResult<WalksAnswer> | null;
  loadWalks: () => void;
  walkId: string | null;
  walk: ApiResult<WalkAnswer> | null;
  openWalk: (gid: string) => void;
  closeWalk: () => void;
  walkAfter: (r: ApiResult<unknown>) => void;
}) {
  const { t, i18n } = useTranslation();
  const [cells, setCells] = useState<ApiResult<CellsAnswer> | null>(null);
  const [loading, setLoading] = useState(false);
  const [fixture, setFixture] = useState<FixtureOpening | null>(null);
  const fixtureGen = useRef(0);
  const opened = useRef(false);

  const loadCells = useCallback(async () => {
    setLoading(true);
    try {
      setCells(await get<CellsAnswer>("/cells"));
    } finally {
      setLoading(false);
    }
  }, []);

  // the first time the tab is shown: the grid and the walks, once
  useEffect(() => {
    if (!active || opened.current) return;
    opened.current = true;
    void loadCells();
    loadWalks();
  }, [active, loadCells, loadWalks]);

  const openFixture = async (cell: string, which: "old" | "new") => {
    const mine = ++fixtureGen.current;
    const r = await get<FixtureAnswer>("/cells/" + encodeURIComponent(cell) + "/" + which);
    if (mine === fixtureGen.current) setFixture({ cell, which, r });
  };

  const what = (name: string, expected: string | undefined) => {
    const key = "ndtServe.cells." + name + ".what";
    return i18n.exists(key) ? t(key) : (expected ?? "");
  };

  const cellList = cells && cells.status === 200 && cells.json ? cells.json.cells : null;

  return (
    <>
      <section className={CARD}>
        <h2 className="mb-1 text-xl font-bold text-[#333]">{t("ndtServe.tabs.cells")}</h2>
        <Explain section="cells" />
        <dl id="cells-legend" className="mb-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 rounded-lg border border-[#e0e0e0] p-3 text-sm">
          {BUTTONS.map((b) => (
            <div key={b} className="contents">
              <dt className="font-medium text-[#1976d2]">{t("ndtServe.cellsTab.buttons." + b + ".label")}</dt>
              <dd className="text-gray-700">{t("ndtServe.cellsTab.buttons." + b + ".explain")}</dd>
            </div>
          ))}
        </dl>
        <div className="mb-3 flex flex-wrap items-center gap-3">
          <button id="cells-load" type="button" onClick={() => void loadCells()} disabled={loading} className={BTN_SECONDARY}>
            {t("ndtServe.cellsTab.load")}
          </button>
          <button id="walks-load" type="button" onClick={loadWalks} className={BTN_SECONDARY}>
            {t("ndtServe.cellsTab.walksLoad")}
          </button>
          {loading && <LoadingSpinner size="small" />}
        </div>
        {cells !== null && cellList === null && <p className={"mb-2 text-sm " + WARN_TEXT}>{errText(cells)}</p>}
        <DataTable
          id="cells-table"
          head={[
            t("ndtServe.cellsTab.col.cell"),
            t("ndtServe.cellsTab.col.what"),
            t("ndtServe.cellsTab.col.requires"),
            "",
          ]}
        >
          {(cellList ?? []).map((c) => (
            <Row key={c.name}>
              <Cell>
                <code className="font-mono text-xs">{c.name}</code>
                {c.writes_shared_state && (
                  <div className={"mt-1 text-xs " + WARN_TEXT}>
                    {t("ndtServe.cellsTab.writesShared", { what: c.writes_shared_state })}
                  </div>
                )}
              </Cell>
              <Cell>
                <span title={c.expected ?? ""} data-what={c.name}>
                  {what(c.name, c.expected)}
                </span>
              </Cell>
              <Cell>
                <span className="font-mono text-xs" title={i18n.exists("ndtServe.cellsTab.requires." + c.requires) ? t("ndtServe.cellsTab.requires." + c.requires) : ""}>
                  {c.requires}
                </span>
              </Cell>
              <Cell>
                <div className="flex flex-wrap gap-1">
                  <button
                    type="button"
                    data-cell={c.name}
                    data-action="old"
                    disabled={!c.old}
                    title={t("ndtServe.cellsTab.buttons.old.explain")}
                    onClick={() => void openFixture(c.name, "old")}
                    className={BTN_SMALL}
                  >
                    {t("ndtServe.cellsTab.buttons.old.label")}
                  </button>
                  <button
                    type="button"
                    data-cell={c.name}
                    data-action="new"
                    disabled={!c.new}
                    title={t("ndtServe.cellsTab.buttons.new.explain")}
                    onClick={() => void openFixture(c.name, "new")}
                    className={BTN_SMALL}
                  >
                    {t("ndtServe.cellsTab.buttons.new.label")}
                  </button>
                  <button
                    type="button"
                    data-cell={c.name}
                    data-action="run"
                    title={t("ndtServe.cellsTab.buttons.run.explain")}
                    onClick={() =>
                      confirmThen({
                        title: t("ndtServe.confirm.titleRun", { cell: c.name }),
                        path: "/cells/" + encodeURIComponent(c.name) + "/run",
                        body: {},
                        word: "run",
                        preview: true,
                        sharedInBody: true,
                        then: jobStarted("cells"),
                      })
                    }
                    className={BTN_SMALL}
                  >
                    {t("ndtServe.cellsTab.buttons.run.label")}
                  </button>
                  <button
                    type="button"
                    data-cell={c.name}
                    data-action="walk"
                    title={t("ndtServe.cellsTab.buttons.walk.explain")}
                    onClick={() =>
                      confirmThen({
                        title: t("ndtServe.confirm.titleWalk", { cell: c.name }),
                        path: "/cells/" + encodeURIComponent(c.name) + "/guided",
                        body: {},
                        word: "walk",
                        preview: false,
                        shared: c.writes_shared_state,
                        sharedInBody: true,
                        effect: t("ndtServe.confirm.effectWalk"),
                        then: (w) => {
                          setAnswer("cells", w);
                          const made = w.status === 201 ? (w.json as WalkAnswer | null) : null;
                          if (made) {
                            loadWalks();
                            openWalk(made.walk.id);
                          }
                        },
                      })
                    }
                    className={BTN_SMALL}
                  >
                    {t("ndtServe.cellsTab.buttons.walk.label")}
                  </button>
                </div>
              </Cell>
            </Row>
          ))}
        </DataTable>
        <Answer id="cells-answer" r={answers.cells} />
      </section>

      <FixturePanel open={fixture} onClose={() => setFixture(null)} />

      <section className={CARD + " mt-6"}>
        <h3 className="mb-1 text-lg font-semibold text-[#333]">{t("ndtServe.cellsTab.walksTitle")}</h3>
        <p className="mb-3 text-sm text-gray-600">{t("ndtServe.cellsTab.walksExplain")}</p>
        {walks !== null && (walks.status !== 200 || !walks.json) && (
          <p className={"mb-2 text-sm " + WARN_TEXT}>{errText(walks)}</p>
        )}
        <DataTable
          id="walks-table"
          head={[
            t("ndtServe.cellsTab.walkCol.walk"),
            t("ndtServe.cellsTab.walkCol.cell"),
            t("ndtServe.cellsTab.walkCol.current"),
            t("ndtServe.cellsTab.walkCol.done"),
            t("ndtServe.cellsTab.walkCol.verdict"),
            "",
          ]}
        >
          {(walks?.json?.walks ?? []).map((w) => (
            <Row key={w.id} current={w.id === walkId}>
              <Cell>
                <ShortId id={w.id} />
              </Cell>
              <Cell mono>{w.cell}</Cell>
              <Cell>{w.current === null ? "" : t("ndtServe.cellsTab.stepN", { n: w.current + 1 })}</Cell>
              <Cell>{w.done ? t("ndtServe.cellsTab.yes") : ""}</Cell>
              <Cell>{w.verdict ? t("ndtServe.walk.verdict." + w.verdict.verdict) : ""}</Cell>
              <Cell>
                <button type="button" data-walk-open={w.id} onClick={() => openWalk(w.id)} className={BTN_SMALL}>
                  {t("ndtServe.cellsTab.open")}
                </button>
              </Cell>
            </Row>
          ))}
        </DataTable>
      </section>

      <WalkPanel
        walkId={walkId}
        walk={walk}
        confirmThen={confirmThen}
        after={walkAfter}
        openJob={openJob}
        onClose={closeWalk}
        answer={answers.walk}
      />
    </>
  );
}
