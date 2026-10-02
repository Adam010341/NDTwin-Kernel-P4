// [Co-developed with claude code -- Adam]
// One job, opened from the job table, from a write's answer or from a walk step. It sits below the
// tabs, so a job started in 操作, Apps or 驗證格 shows its log where it was started; there is one
// panel, so its element ids (v1's: job, job-id, job-close, job-rows, job-stdout, job-stderr) are
// unique. The log is useJobLog's: every 2 s while the job runs, never while hidden, and not after
// 關閉.
import { useTranslation } from "react-i18next";
import type { JobLog } from "../hooks/useJobLog";
import { BTN_SECONDARY, CARD, PRE, WARN_TEXT } from "../lib/ui";
import Badge from "./Badge";
import ShortId from "./ShortId";
import { StatusRow, StatusRows } from "./StatusRows";

export default function JobPanel({ id, log, onClose }: { id: string | null; log: JobLog; onClose: () => void }) {
  const { t } = useTranslation();
  const j = log.job;
  return (
    <section id="job" hidden={id === null} className={CARD + " mt-6"}>
      <div className="mb-4 flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-xl font-bold text-[#333]">
          {t("ndtServe.job.title")}
          {id !== null && <ShortId id={id} domId="job-id" />}
        </h2>
        <button id="job-close" type="button" onClick={onClose} className={BTN_SECONDARY}>
          {t("ndtServe.job.close")}
        </button>
      </div>
      <p id="job-following" className="mb-3 text-xs text-gray-500">
        {t(log.following ? "ndtServe.job.following" : "ndtServe.job.notFollowing")}
      </p>
      {log.error !== null && <p className={"mb-3 text-sm " + WARN_TEXT}>{log.error}</p>}
      <div id="job-rows">
        {j !== null && (
          <StatusRows>
            <StatusRow label={t("ndtServe.job.kind")}>
              <code className="font-mono text-xs">{j.kind}</code>
            </StatusRow>
            <StatusRow label={t("ndtServe.job.state")}>
              <Badge kind="state" value={j.state} />
            </StatusRow>
            <StatusRow label={t("ndtServe.job.rc")}>
              <code className="font-mono text-xs">{j.rc === null ? "" : String(j.rc)}</code>
            </StatusRow>
            <StatusRow label={t("ndtServe.job.rcClass")}>
              <Badge kind="rc" value={j.rc_class} />
            </StatusRow>
            <StatusRow label={t("ndtServe.job.meaning")}>
              <span>{j.meaning}</span>
            </StatusRow>
            <StatusRow label={t("ndtServe.job.argv")}>
              <code className="break-all font-mono text-xs">{(j.argv ?? []).join(" ")}</code>
            </StatusRow>
            {j.cell_verdict && (
              <StatusRow label={t("ndtServe.job.cellVerdict")}>
                <code className="break-all font-mono text-xs">{j.cell_verdict.line}</code>
              </StatusRow>
            )}
          </StatusRows>
        )}
      </div>
      <h3 className="mb-1 mt-4 text-sm font-semibold text-gray-700">{t("ndtServe.job.stdout")}</h3>
      <pre id="job-stdout" className={PRE}>
        {log.stdout}
      </pre>
      <h3 className="mb-1 mt-4 text-sm font-semibold text-gray-700">{t("ndtServe.job.stderr")}</h3>
      <pre id="job-stderr" className={PRE}>
        {log.stderr}
      </pre>
    </section>
  );
}
