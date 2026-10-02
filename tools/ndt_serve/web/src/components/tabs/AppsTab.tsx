// [Co-developed with claude code -- Adam]
// Apps: the apps ndt knows (from /meta), start / stop through the confirm dialog, and
// `ndt apps status` verbatim, read by the auto-refresh. A start or stop runs only under your own
// claim -- this server refuses it otherwise (409 claim), because ndt's apps verbs check no claim.
import { useTranslation } from "react-i18next";
import type { ApiResult } from "../../api/client";
import type { AnswerArea, AppsAnswer, Meta } from "../../types";
import type { ConfirmRequest } from "../ConfirmDialog";
import { errText, readText } from "../../lib/format";
import { BTN_SMALL, CARD, PRE } from "../../lib/ui";
import Answer from "../Answer";
import { Cell, DataTable, Row } from "../DataTable";
import Explain from "../Explain";

export default function AppsTab({
  meta,
  apps,
  confirmThen,
  jobStarted,
  answer,
}: {
  meta: Meta;
  apps: ApiResult<AppsAnswer> | null;
  confirmThen: (a: ConfirmRequest) => void;
  jobStarted: (area: AnswerArea) => (r: ApiResult<unknown>) => void;
  answer: ApiResult<unknown> | null;
}) {
  const { t } = useTranslation();
  const act = (name: string, action: "start" | "stop") =>
    confirmThen({
      title: t("ndtServe.confirm.titleApp", { action, name }),
      path: "/apps/" + encodeURIComponent(name) + "/" + action,
      body: {},
      word: action,
      preview: true,
      then: jobStarted("apps"),
    });

  return (
    <section className={CARD}>
      <h2 className="mb-1 text-xl font-bold text-[#333]">{t("ndtServe.tabs.apps")}</h2>
      <Explain section="apps" />
      <DataTable id="apps-table" head={[t("ndtServe.apps.name"), "", ""]}>
        {meta.apps.map((name) => (
          <Row key={name}>
            <Cell mono>{name}</Cell>
            {(["start", "stop"] as const).map((action) => (
              <Cell key={action}>
                <button
                  id={"app-" + action + "-" + name}
                  type="button"
                  data-app={name}
                  data-action={action}
                  onClick={() => act(name, action)}
                  className={BTN_SMALL}
                >
                  {t("ndtServe.apps." + action)}
                </button>
              </Cell>
            ))}
          </Row>
        ))}
      </DataTable>
      <Answer id="apps-answer" r={answer} />
      <h3 className="mb-2 mt-4 text-sm font-semibold text-gray-700">{t("ndtServe.apps.status")}</h3>
      <pre id="apps-out" className={PRE}>
        {apps === null
          ? t("ndtServe.apps.notRead")
          : apps.status === 200 && apps.json
            ? readText(apps.json.stdout, apps.json.stderr)
            : errText(apps)}
      </pre>
    </section>
  );
}
