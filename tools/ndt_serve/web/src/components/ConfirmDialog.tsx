// [Co-developed with claude code -- Adam]
// The one door every write goes through (SCOPE section 2 of the GUI cut; v1's confirmThen, carried
// over rule for rule). This is the ONLY file that calls post, and it does so twice below:
//
//   1. a fresh GET /lab, every time the dialog opens;
//   2. for a write the server can preview, the server's own dry run of it -- the argv shown is the one
//      the server answered with; the page never builds an argv;
//   3. a typed word when the server says confirm === "typed", or measuring is not `nothing`, or a
//      measurement is declared;
//   4. "claim first" when the server says needs_own_claim and the claim is not yours;
//   5. a checkbox when the write rewrites shared state;
//   6. Cancel has the focus, Enter on Confirm does nothing, and Confirm works once.
//
// The look is DeleteDialog's (SwitchFlowTable.tsx:623-657, Web-GUI @ f63a55ce) inside a native
// <dialog> opened with showModal(), so the browser keeps the focus in it and Escape cancels it.
// The element ids are v1's: the browser tests drive the dialog by them. data-phase on #confirm says
// where an opening is: reading (the fresh /lab and the dry run are out), ready, closed.
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import i18n from "../i18n";
import { get, post } from "../api/client";
import type { ApiResult } from "../api/client";
import type { DryRunAnswer, LabAnswer } from "../types";
import { busyText, errText } from "../lib/format";
import { BTN_DANGER, BTN_SECONDARY, WARN_TEXT, OK_TEXT } from "../lib/ui";
import LoadingSpinner from "./common/LoadingSpinner";

export interface ConfirmRequest {
  title: string;
  path: string; // under the API base, e.g. "/claim"
  body: Record<string, unknown>;
  word: string; // what Adam types when the confirmation is typed
  preview: boolean; // the server can dry-run this write: ask it for the argv
  shared?: string | null; // this write rewrites shared state (what, in the server's words)
  sharedInBody?: boolean; // the confirmation goes in the body (confirm_shared_state_write)
  effect?: string; // what a write that runs no ndt does, for the argv row
  then: (r: ApiResult<unknown>) => void;
}

interface View {
  phase: "closed" | "reading" | "ready";
  title: string;
  preview: boolean;
  effect: string;
  lab: LabAnswer | null;
  dry: DryRunAnswer | null;
  blockers: string[];
  shared: string | null;
  sharedInBody: boolean;
  typed: boolean;
  word: string;
}

const CLOSED: View = {
  phase: "closed",
  title: "",
  preview: false,
  effect: "",
  lab: null,
  dry: null,
  blockers: [],
  shared: null,
  sharedInBody: false,
  typed: false,
  word: "",
};

export default function ConfirmDialog({ request }: { request: ConfirmRequest | null }) {
  const { t } = useTranslation();
  const dialogRef = useRef<HTMLDialogElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const goRef = useRef<HTMLButtonElement>(null);
  const typedRef = useRef<HTMLInputElement>(null);
  const sharedRef = useRef<HTMLInputElement>(null);
  const gen = useRef(0); // this opening; cancelling, closing or another opening replaces it
  const fired = useRef(false); // Confirm was pressed in this opening
  const ready = useRef<() => boolean>(() => false);
  const [view, setView] = useState<View>(CLOSED);
  const [inputsOk, setInputsOk] = useState(false);
  const [sent, setSent] = useState(false);

  // Whatever changes the typed word or the checkbox -- a key, a paste, a script -- re-reads them
  // from the DOM, as v1 did; and closing the dialog (Cancel, Escape, Confirm) ends this opening.
  useEffect(() => {
    const d = dialogRef.current;
    if (!d) return;
    const recheck = () => setInputsOk(ready.current());
    const closed = () => {
      gen.current += 1;
      // nothing of this opening stays on screen for the next one to be read against
      ready.current = () => false;
      setView(CLOSED);
      setInputsOk(false);
    };
    d.addEventListener("input", recheck);
    d.addEventListener("change", recheck);
    d.addEventListener("close", closed);
    return () => {
      d.removeEventListener("input", recheck);
      d.removeEventListener("change", recheck);
      d.removeEventListener("close", closed);
    };
  }, []);

  // A layout effect: the previous opening's content is replaced before the dialog is shown and before
  // the browser paints, in the same task as the click that asked for it.
  useLayoutEffect(() => {
    if (request === null) return;
    const a = request;
    const d = dialogRef.current;
    if (!d) return;
    const mine = ++gen.current;
    fired.current = false;
    ready.current = () => false;
    if (typedRef.current) typedRef.current.value = "";
    if (sharedRef.current) sharedRef.current.checked = false;
    setSent(false);
    setInputsOk(false);
    setView({ ...CLOSED, phase: "reading", title: a.title, preview: a.preview, effect: a.effect ?? "", word: a.word });
    if (!d.open) d.showModal();
    cancelRef.current?.focus();

    void (async () => {
      const lab = await get<LabAnswer>("/lab");
      const dry = a.preview ? await post(a.path, { ...a.body, dry_run: true }) : null;
      if (mine !== gen.current || !d.open) return; // cancelled, or another dialog took over

      const blockers: string[] = [];
      const L = lab.status === 200 ? lab.json : null;
      const D = dry && dry.status === 200 ? (dry.json as DryRunAnswer | null) : null;
      if (!L) blockers.push(i18n.t("ndtServe.confirm.blockLab", { detail: errText(lab) }));
      if (a.preview) {
        if (D) {
          if (D.needs_own_claim && !(L && L.claim_is_yours)) blockers.push(i18n.t("ndtServe.confirm.blockClaim"));
        } else if (dry) {
          blockers.push(i18n.t("ndtServe.confirm.blockRefused", { detail: errText(dry) }));
        }
      }
      const shared = (D && D.writes_shared_state) || a.shared || null;
      const sharedInBody = a.sharedInBody === true;
      if (shared && sharedRef.current) sharedRef.current.checked = !sharedInBody;
      // typed: the server says so for this write, or anything is measuring or declared
      const typed = (D !== null && D.confirm === "typed") || !(L && L.measuring_is_nothing) || (L !== null && L.declared !== null);
      ready.current = () =>
        blockers.length === 0 &&
        (!typed || typedRef.current?.value === a.word) &&
        (!shared || sharedRef.current?.checked === true);
      setView({
        phase: "ready",
        title: a.title,
        preview: a.preview,
        effect: a.effect ?? "",
        lab: L,
        dry: D,
        blockers,
        shared,
        sharedInBody,
        typed,
        word: a.word,
      });
      setInputsOk(ready.current());
    })();
  }, [request]);

  const cancel = useCallback(() => {
    gen.current += 1;
    dialogRef.current?.close();
  }, []);

  const go = useCallback(async () => {
    const a = request;
    if (a === null || fired.current || view.phase !== "ready" || !ready.current()) return;
    fired.current = true; // once: a second click finds it spent (and the slot would 409)
    if (goRef.current) goRef.current.disabled = true;
    setSent(true);
    const mine = gen.current;
    const body: Record<string, unknown> = { ...a.body };
    if (view.shared && view.sharedInBody) body.confirm_shared_state_write = true;
    const r = await post(a.path, body);
    if (mine === gen.current) dialogRef.current?.close();
    a.then(r);
  }, [request, view]);

  const L = view.lab;
  const D = view.dry;
  const reading = view.phase === "reading";

  return (
    <dialog
      id="confirm"
      ref={dialogRef}
      data-phase={view.phase}
      className="w-[92vw] max-w-3xl rounded-lg border border-gray-200 bg-white p-8 text-[#222] shadow-xl backdrop:bg-black/30"
    >
      <h3 id="c-title" className="mb-4 text-lg font-semibold text-gray-800">
        {view.title}
      </h3>
      <div id="c-state" className="mb-3 text-sm text-gray-500">
        {reading && (
          <span className="inline-flex items-center gap-2">
            <LoadingSpinner size="small" />
            {t(view.preview ? "ndtServe.confirm.readingPreview" : "ndtServe.confirm.reading")}
          </span>
        )}
      </div>
      <div className="mb-4 space-y-2 text-sm">
        <div className="flex items-start gap-4">
          <span className="w-24 shrink-0 font-medium text-[#1976d2]">{t("ndtServe.confirm.argv")}</span>
          <div id="c-argv" className="flex min-w-0 flex-wrap gap-1">
            {view.phase === "ready" && view.preview && D && D.argv === null && (
              <span className="text-gray-500">{t("ndtServe.confirm.noJob", { kind: D.kind })}</span>
            )}
            {view.phase === "ready" &&
              view.preview &&
              D &&
              (D.argv ?? []).map((arg, i) => (
                <code key={i} className="rounded border border-[#e0e0e0] bg-gray-100 px-1 font-mono text-xs">
                  {arg}
                </code>
              ))}
            {view.phase === "ready" && !view.preview && (
              <span className="text-gray-500">{t("ndtServe.confirm.noCommand", { effect: view.effect })}</span>
            )}
          </div>
        </div>
        <div className="flex items-start gap-4">
          <span className="w-24 shrink-0 font-medium text-[#1976d2]">{t("ndtServe.lab.claim")}</span>
          <code id="c-claim" className={"font-mono text-xs " + (L ? (L.claim_is_yours ? OK_TEXT : WARN_TEXT) : "")}>
            {L ? (L.claim === null ? t("ndtServe.lab.noClaimRow") : L.claim) : ""}
          </code>
        </div>
        <div className="flex items-start gap-4">
          <span className="w-24 shrink-0 font-medium text-[#1976d2]">{t("ndtServe.lab.measuring")}</span>
          <code id="c-measuring" className={"font-mono text-xs " + (L && !L.measuring_is_nothing ? WARN_TEXT : "")}>
            {L ? (L.measuring === null ? t("ndtServe.lab.noMeasuringRow") : L.measuring) : ""}
          </code>
        </div>
        <div
          id="c-declared-row"
          hidden={!L || L.declared === null}
          className={(!L || L.declared === null ? "hidden" : "flex") + " items-start gap-4"}
        >
          <span className="w-24 shrink-0 font-medium text-[#1976d2]">{t("ndtServe.lab.declared")}</span>
          <code id="c-declared" className={"font-mono text-xs " + WARN_TEXT}>
            {L && L.declared !== null ? L.declared : ""}
          </code>
        </div>
        <div className="flex items-start gap-4">
          <span className="w-24 shrink-0 font-medium text-[#1976d2]">{t("ndtServe.lab.slot")}</span>
          <span id="c-busy">{L ? busyText(L.busy) : ""}</span>
        </div>
      </div>
      <p id="c-note" className="mb-3 text-sm text-gray-500">
        {D ? D.note : ""}
      </p>
      <ul id="c-blockers" className={"mb-3 list-disc pl-5 text-sm " + WARN_TEXT}>
        {view.blockers.map((b, i) => (
          <li key={i}>{b}</li>
        ))}
      </ul>
      <p id="c-shared-row" hidden={!view.shared} className="mb-3 text-sm">
        <label className="inline-flex items-start gap-2">
          <input id="c-shared" ref={sharedRef} type="checkbox" disabled={!view.sharedInBody} className="mt-1" />
          <span id="c-shared-text">
            {view.shared
              ? t(view.sharedInBody ? "ndtServe.confirm.sharedBody" : "ndtServe.confirm.sharedWalk", {
                  what: view.shared,
                })
              : ""}
          </span>
        </label>
      </p>
      <p id="c-typed-row" hidden={!view.typed} className="mb-4 text-sm">
        <label className="inline-flex flex-wrap items-center gap-2">
          <span>{t("ndtServe.confirm.typeBefore")}</span>
          <code id="c-word" className="rounded bg-gray-100 px-1 font-mono">
            {view.typed ? view.word : ""}
          </code>
          <span>{t("ndtServe.confirm.typeAfter")}</span>
          <input
            id="c-typed"
            ref={typedRef}
            type="text"
            autoComplete="off"
            spellCheck={false}
            className="rounded border border-gray-300 px-2 py-1 font-mono text-sm focus:border-[#1976d2] focus:outline-none"
          />
        </label>
      </p>
      <div className="flex justify-end gap-3">
        <button id="c-cancel" ref={cancelRef} type="button" onClick={cancel} className={BTN_SECONDARY}>
          {t("ndtServe.confirm.cancel")}
        </button>
        <button
          id="c-go"
          ref={goRef}
          type="button"
          disabled={view.phase !== "ready" || !inputsOk || sent}
          onKeyDown={(e) => {
            if (e.key === "Enter") e.preventDefault(); // Enter never confirms
          }}
          onClick={() => void go()}
          className={BTN_DANGER}
        >
          {t("ndtServe.confirm.go")}
        </button>
      </div>
    </dialog>
  );
}
