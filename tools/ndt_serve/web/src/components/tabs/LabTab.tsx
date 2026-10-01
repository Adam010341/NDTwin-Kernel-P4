// [Co-developed with claude code -- Adam]
// 實驗室: what `ndt status` says right now -- the claim, measuring and declared rows verbatim, the
// server's two readings of them (claim_is_yours, measuring_is_nothing), the slot, when it was read,
// the whole report, and the ndt_drift warning from /health. Read by the auto-refresh.
import { useTranslation } from "react-i18next";
import type { ApiResult } from "../../api/client";
import type { HealthAnswer, LabAnswer } from "../../types";
import { busyText, errText, readText } from "../../lib/format";
import { CARD, OK_TEXT, PRE, WARN_TEXT } from "../../lib/ui";
import Explain from "../Explain";
import ShortId from "../ShortId";
import { StatusRow, StatusRows } from "../StatusRows";

export default function LabTab({
  lab,
  labAt,
  health,
}: {
  lab: ApiResult<LabAnswer> | null;
  labAt: string | null;
  health: ApiResult<HealthAnswer> | null;
}) {
  const { t } = useTranslation();
  const h = health && health.status === 200 ? health.json : null;
  const j = lab && lab.status === 200 ? lab.json : null;
  const drift = h !== null && h.ndt_drift === true;

  return (
    <section className={CARD}>
      <h2 className="mb-1 text-xl font-bold text-[#333]">{t("ndtServe.tabs.lab")}</h2>
      <Explain section="lab" />
      <p id="drift" hidden={!drift} className={"mb-4 rounded border border-[#FF7F50] bg-[#FFE8DF] p-3 text-sm " + WARN_TEXT}>
        {drift && h ? t("ndtServe.lab.drift", { path: h.ndt_realpath }) : ""}
      </p>
      {lab === null && <p className="text-sm text-gray-500">{t("ndtServe.lab.notRead")}</p>}
      {lab !== null && j === null && (
        <p id="lab-yours" className={"text-sm " + WARN_TEXT}>
          {t("ndtServe.lab.unreadable", { detail: errText(lab) })}
        </p>
      )}
      {j !== null && (
        <>
          <StatusRows>
            <StatusRow label={t("ndtServe.lab.claim")}>
              <code id="lab-claim" className="break-all font-mono text-xs">
                {j.claim === null ? t("ndtServe.lab.noClaimRow") : j.claim}
              </code>
              <span
                id="lab-yours"
                data-yours={j.claim_is_yours ? "yes" : "no"}
                className={
                  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium " +
                  (j.claim_is_yours ? "bg-green-100 text-green-800" : "bg-[#FFE8DF] text-[#b3471d]")
                }
              >
                {t(j.claim_is_yours ? "ndtServe.lab.yours" : "ndtServe.lab.notYours")}
              </span>
            </StatusRow>
            <StatusRow label={t("ndtServe.lab.measuring")}>
              <code id="lab-measuring" className={"break-all font-mono text-xs " + (j.measuring_is_nothing ? "" : WARN_TEXT)}>
                {j.measuring === null ? t("ndtServe.lab.noMeasuringRow") : j.measuring}
              </code>
            </StatusRow>
            <StatusRow label={t("ndtServe.lab.declared")} rowId="lab-declared-row" hidden={j.declared === null}>
              <code id="lab-declared" className={"break-all font-mono text-xs " + WARN_TEXT}>
                {j.declared ?? ""}
              </code>
            </StatusRow>
            <StatusRow label={t("ndtServe.lab.slot")}>
              <span id="lab-busy" className={j.busy ? WARN_TEXT : OK_TEXT}>
                {busyText(j.busy)}
              </span>
              {j.busy && <ShortId id={j.busy.id} />}
            </StatusRow>
            <StatusRow label={t("ndtServe.lab.read")}>
              <span id="lab-read" className="text-gray-500">
                {t("ndtServe.lab.readLine", {
                  time: labAt ?? "",
                  rc: j.rc === null ? "-" : String(j.rc),
                  rcClass: j.rc_class,
                  seconds: j.duration_s,
                })}
              </span>
              <ShortId id={j.read.id} />
            </StatusRow>
          </StatusRows>
          <details className="mt-4">
            <summary className="cursor-pointer text-sm text-gray-600">{t("ndtServe.lab.whole")}</summary>
            <pre id="lab-out" className={PRE + " mt-2"}>
              {readText(j.stdout, j.stderr)}
            </pre>
          </details>
        </>
      )}
    </section>
  );
}
