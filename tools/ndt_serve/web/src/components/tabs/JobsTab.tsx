// [Co-developed with claude code -- Adam]
// 工作紀錄: the last jobs, newest first, read by the auto-refresh. 開啟 opens a job's panel (below
// the tabs), whose log is followed while the job runs.
import { useTranslation } from "react-i18next";
import type { ApiResult } from "../../api/client";
import type { JobsAnswer } from "../../types";
import { errText } from "../../lib/format";
import { BTN_SMALL, CARD, WARN_TEXT } from "../../lib/ui";
import Badge from "../Badge";
import { Cell, DataTable, Row } from "../DataTable";
import Explain from "../Explain";
import ShortId from "../ShortId";

export default function JobsTab({
  jobs,
  openJob,
  openId,
}: {
  jobs: ApiResult<JobsAnswer> | null;
  openJob: (id: string) => void;
  openId: string | null;
}) {
  const { t } = useTranslation();
  return (
    <section className={CARD}>
      <h2 className="mb-1 text-xl font-bold text-[#333]">{t("ndtServe.tabs.jobs")}</h2>
      <Explain section="jobs" />
      {jobs !== null && (jobs.status !== 200 || !jobs.json) && (
        <p className={"mb-2 text-sm " + WARN_TEXT}>{errText(jobs)}</p>
      )}
      <DataTable
        id="jobs-table"
        head={[
          t("ndtServe.jobs.id"),
          t("ndtServe.jobs.kind"),
          t("ndtServe.jobs.state"),
          t("ndtServe.jobs.rc"),
          t("ndtServe.jobs.rcClass"),
          t("ndtServe.jobs.meaning"),
          "",
        ]}
      >
        {jobs?.json?.jobs.map((j) => (
          <Row key={j.id} current={j.id === openId}>
            <Cell>
              <ShortId id={j.id} />
            </Cell>
            <Cell mono>{j.kind}</Cell>
            <Cell>
              <Badge kind="state" value={j.state} />
            </Cell>
            <Cell mono>{j.rc === null ? "" : String(j.rc)}</Cell>
            <Cell>
              <Badge kind="rc" value={j.rc_class} />
            </Cell>
            <Cell>{j.meaning}</Cell>
            <Cell>
              <button type="button" data-job-open={j.id} onClick={() => openJob(j.id)} className={BTN_SMALL}>
                {t("ndtServe.jobs.open")}
              </button>
            </Cell>
          </Row>
        ))}
      </DataTable>
      {jobs?.json && jobs.json.jobs.length === 0 && <p className="mt-2 text-sm text-gray-500">{t("ndtServe.jobs.none")}</p>}
    </section>
  );
}
