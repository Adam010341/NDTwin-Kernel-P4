// [Co-developed with claude code -- Adam]
// One guided walk (逐步驗證): its steps with the server-derived state of each, where to look, the
// result a step recorded and the job it ran; 下一步 and 中止 through the confirm dialog; and, at the
// verdict step, Adam's own call. Whether a button is on is decided from the walk's current, blocked,
// done and aborted fields, as v1 did. v1's element ids.
import { useRef } from "react";
import { useTranslation } from "react-i18next";
import type { ApiResult } from "../api/client";
import type { WalkAnswer } from "../types";
import type { ConfirmRequest } from "./ConfirmDialog";
import { errText } from "../lib/format";
import { shortId } from "../lib/shortId";
import { BTN_DANGER, BTN_PRIMARY, BTN_SECONDARY, BTN_SMALL, CARD, INPUT, PRE, WARN_TEXT } from "../lib/ui";
import Answer from "./Answer";
import Badge from "./Badge";
import ShortId from "./ShortId";

export default function WalkPanel({
  walkId,
  walk,
  confirmThen,
  after,
  openJob,
  onClose,
  answer,
}: {
  walkId: string | null;
  walk: ApiResult<WalkAnswer> | null;
  confirmThen: (a: ConfirmRequest) => void;
  after: (r: ApiResult<unknown>) => void;
  openJob: (id: string) => void;
  onClose: () => void;
  answer: ApiResult<unknown> | null;
}) {
  const { t } = useTranslation();
  const noteRef = useRef<HTMLInputElement>(null);
  const w = walk && walk.status === 200 && walk.json ? walk.json.walk : null;
  const cur = w && w.current !== null ? w.steps[w.current] : null;
  const atVerdict = cur !== null && cur.step === "verdict" && !w?.aborted;
  const path = (tail: string) => "/guided/" + encodeURIComponent(walkId ?? "") + tail;
  const short = walkId === null ? "" : shortId(walkId);

  const next = () =>
    confirmThen({
      title: t("ndtServe.confirm.titleNext", { walk: short }),
      path: path("/next"),
      body: {},
      word: "next",
      preview: true,
      sharedInBody: false,
      then: after,
    });
  const abort = () =>
    confirmThen({
      title: t("ndtServe.confirm.titleAbort", { walk: short }),
      path: path("/abort"),
      body: {},
      word: "abort",
      preview: false,
      effect: t("ndtServe.confirm.effectAbort"),
      then: after,
    });
  const verdict = (v: "green" | "red") =>
    confirmThen({
      title: t("ndtServe.confirm.titleVerdict", { walk: short, verdict: t("ndtServe.walk.verdict." + v) }),
      path: path("/verdict"),
      body: { verdict: v, note: noteRef.current?.value ?? "" },
      word: v,
      preview: false,
      effect: t("ndtServe.confirm.effectVerdict"),
      then: after,
    });

  return (
    <section id="walk" hidden={walkId === null} className={CARD + " mt-6"}>
      <div className="mb-3 flex items-center justify-between">
        <h3 className="flex flex-wrap items-center gap-2 text-lg font-semibold text-[#333]">
          {t("ndtServe.walk.title")}
          {walkId !== null && <ShortId id={walkId} domId="walk-id" />}
          <span id="walk-cell" className="font-mono text-sm text-gray-600">
            {w ? w.cell + (w.aborted ? t("ndtServe.walk.aborted") : "") + (w.done ? t("ndtServe.walk.done") : "") : ""}
          </span>
        </h3>
        <button id="walk-close" type="button" onClick={onClose} className={BTN_SECONDARY}>
          {t("ndtServe.walk.close")}
        </button>
      </div>
      {walk !== null && w === null && <p className={"mb-3 text-sm " + WARN_TEXT}>{errText(walk)}</p>}
      <p id="walk-blocked" hidden={!w?.blocked} className={"mb-3 rounded border border-[#FF7F50] bg-[#FFE8DF] p-3 text-sm " + WARN_TEXT}>
        {w?.blocked ? t("ndtServe.walk.blocked", { why: w.blocked }) : ""}
      </p>
      <ol id="walk-steps" className="mb-4 space-y-2">
        {(w?.steps ?? []).map((st, i) => (
          <li
            key={i}
            data-step={st.step}
            data-state={st.state}
            className={
              "rounded-lg border p-3 " +
              (i === w?.current ? "border-[#1976d2] bg-blue-50" : "border-[#e0e0e0] bg-white")
            }
          >
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-xs text-gray-500">{String(i + 1) + "."}</span>
              <Badge kind="state" value={st.state} />
              <strong className="font-mono text-sm">{st.step}</strong>
              <span className="text-sm">{st.title}</span>
            </div>
            <p className="mt-1 text-sm text-gray-600">{st.look_at}</p>
            {st.result !== null && st.result !== undefined && (
              <details className="mt-1">
                <summary className="cursor-pointer text-xs text-gray-500">{t("ndtServe.walk.result")}</summary>
                <pre className={PRE + " mt-1"}>{JSON.stringify(st.result, null, 1)}</pre>
              </details>
            )}
            {st.job && (
              <button type="button" data-step-job={st.job} onClick={() => openJob(st.job as string)} className={BTN_SMALL + " mt-2"}>
                {t("ndtServe.walk.job")}
              </button>
            )}
          </li>
        ))}
      </ol>
      <div className="flex flex-wrap items-center gap-3">
        <button
          id="walk-next"
          type="button"
          onClick={next}
          disabled={!w || w.done || !!w.aborted || atVerdict || (cur !== null && cur.state === "running")}
          className={BTN_PRIMARY}
        >
          {t("ndtServe.walk.next")}
        </button>
        <button id="walk-abort" type="button" onClick={abort} disabled={!w || w.done || !!w.aborted} className={BTN_SECONDARY}>
          {t("ndtServe.walk.abort")}
        </button>
      </div>
      <div id="walk-verdict" hidden={!atVerdict} className="mt-4 rounded-lg border border-[#e0e0e0] p-4">
        <p className="mb-2 text-sm text-gray-600">{t("ndtServe.walk.verdictExplain")}</p>
        <div className="flex flex-wrap items-center gap-3">
          <label className="inline-flex items-center gap-2 text-sm">
            {t("ndtServe.walk.note")}
            <input id="walk-note" ref={noteRef} type="text" size={50} className={INPUT} />
          </label>
          <button id="walk-green" type="button" onClick={() => verdict("green")} className={BTN_PRIMARY}>
            {t("ndtServe.walk.green")}
          </button>
          <button id="walk-red" type="button" onClick={() => verdict("red")} className={BTN_DANGER}>
            {t("ndtServe.walk.red")}
          </button>
        </div>
      </div>
      <Answer id="walk-answer" r={answer} />
    </section>
  );
}
