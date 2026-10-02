// [Co-developed with claude code -- Adam]
// What a write answered, in one line: the status, and the job it started; or the refusal as the
// server wrote it (error -- note).
import { useTranslation } from "react-i18next";
import type { ApiResult } from "../api/client";
import type { ErrorBody } from "../types";
import { errText } from "../lib/format";
import { ANSWER_OK, ANSWER_WARN } from "../lib/ui";
import ShortId from "./ShortId";

export default function Answer({ id, r }: { id: string; r: ApiResult<unknown> | null }) {
  const { t } = useTranslation();
  if (r === null) return <p id={id} className={ANSWER_OK} />;
  if (r.status >= 200 && r.status < 300) {
    const job = (r.json as ErrorBody | null)?.job;
    return (
      <p id={id} className={ANSWER_OK}>
        {String(r.status)}
        {job && (
          <>
            {" -- " + t("ndtServe.answer.job") + " "}
            <ShortId id={job.id} />
            {" " + t("ndtServe.answer.started")}
          </>
        )}
      </p>
    );
  }
  return (
    <p id={id} className={ANSWER_WARN}>
      {errText(r)}
    </p>
  );
}
