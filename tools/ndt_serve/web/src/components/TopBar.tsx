// [Co-developed with claude code -- Adam]
// The bar across the top: title, owner, the session, the auto-refresh state and 立即更新, and the
// two links out -- Web-GUI (its address comes from the server's /meta, webgui_url, set with
// `ndt serve --webgui-url`; the browser keeps no copy) and this page's manual (./manual.html, a
// static file beside the page). Web-GUI has no global bar; this follows AvailabilityStatus.tsx's
// header (Web-GUI @ f63a55ce, 236-260: the h1 at 242, the badge at 246, the ghost button at 255).
import { useTranslation } from "react-i18next";
import { REFRESH_INTERVAL_MS } from "../hooks/useAutoRefresh";
import type { RefreshState } from "../hooks/useAutoRefresh";
import { BTN_GHOST, BTN_PRIMARY } from "../lib/ui";
import LoadingSpinner from "./common/LoadingSpinner";

export interface SessionView {
  state: "opening" | "ok" | "refused" | "no-key" | "no-meta";
  detail?: string;
}

const LINK = BTN_GHOST + " border border-[#e0e0e0] bg-white";

export default function TopBar({
  owner,
  session,
  refresh,
  reading,
  lastRead,
  canRefresh,
  onRefresh,
  webguiUrl,
}: {
  owner: string | null;
  session: SessionView;
  refresh: RefreshState | null;
  reading: boolean;
  lastRead: string | null;
  canRefresh: boolean;
  onRefresh: () => void;
  webguiUrl: string | null;
}) {
  const { t } = useTranslation();
  const sessionText =
    session.state === "ok"
      ? t("ndtServe.session.ok")
      : session.state === "no-key"
        ? t("ndtServe.session.noKey")
        : session.state === "refused"
          ? t("ndtServe.session.refused", { detail: session.detail ?? "" })
          : session.state === "no-meta"
            ? t("ndtServe.session.noMeta", { detail: session.detail ?? "" })
            : t("ndtServe.session.opening");
  const sessionOk = session.state === "ok";

  return (
    <header className="sticky top-0 z-20 border-b border-gray-200 bg-white shadow-sm">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-6 py-3">
        <h1 className="text-2xl font-semibold text-gray-900">{t("ndtServe.app.title")}</h1>
        {owner !== null && (
          <span id="who" className="text-sm text-gray-600">
            {t("ndtServe.top.owner", { owner })}
          </span>
        )}
        <span
          id="session"
          className={
            "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium " +
            (sessionOk ? "bg-green-100 text-green-800" : "bg-[#FFE8DF] text-[#b3471d]")
          }
        >
          {sessionText}
        </span>
        {refresh !== null && (
          <span
            id="refresh-state"
            data-state={refresh}
            className={
              "inline-flex items-center gap-2 rounded-full px-2.5 py-0.5 text-xs font-medium " +
              (refresh === "running" ? "bg-blue-100 text-[#1976d2]" : "border border-[#FF7F50] bg-[#FFE8DF] text-[#b3471d]")
            }
            title={t("ndtServe.refresh.hint." + refresh, { seconds: REFRESH_INTERVAL_MS / 1000 })}
          >
            {t("ndtServe.refresh.state." + refresh, { seconds: REFRESH_INTERVAL_MS / 1000 })}
            {refresh !== "running" && <span className="font-normal">{t("ndtServe.refresh.hint." + refresh)}</span>}
          </span>
        )}
        {lastRead !== null && (
          <span id="last-read" className="text-xs text-gray-500">
            {t("ndtServe.refresh.last", { time: lastRead })}
          </span>
        )}
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <button
            id="refresh-now"
            type="button"
            disabled={!canRefresh || reading}
            onClick={onRefresh}
            className={BTN_PRIMARY + " inline-flex items-center gap-2"}
          >
            {reading && <LoadingSpinner size="small" color="text-white" />}
            {t("ndtServe.refresh.now")}
          </button>
          {webguiUrl !== null && (
            <a
              id="open-webgui"
              href={webguiUrl}
              target="_blank"
              rel="noopener noreferrer"
              title={t("ndtServe.top.webguiTitle", { url: webguiUrl })}
              className={LINK}
            >
              {t("ndtServe.top.webgui")}
            </a>
          )}
          <a
            id="open-manual"
            href="./manual.html"
            target="_blank"
            rel="noopener noreferrer"
            className={LINK}
          >
            {t("ndtServe.top.manual")}
          </a>
        </div>
      </div>
    </header>
  );
}
