// [Co-developed with claude code -- Adam]
// ndt serve's page, v2 (Adam's 8 points and rulings R1-R3, 09-27; SCOPE-v2). The root component:
// it owns the session, the server's /meta, what the auto-refresh read, the confirm dialog's request,
// the open job and the open walk. It changes no global state but <body>'s test hooks (testhooks.ts).
//
// Order at load, as v1: the one-time key leaves the address bar and is traded for the token
// (api/session.ts); GET /meta; then one read of /lab, /apps, /health and /jobs, after which the
// auto-refresh takes over. Loading the page writes nothing.
import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { get } from "./api/client";
import type { ApiResult } from "./api/client";
import { openSession } from "./api/session";
import type {
  AnswerArea,
  AppsAnswer,
  ErrorBody,
  HealthAnswer,
  JobsAnswer,
  LabAnswer,
  Meta,
  WalkAnswer,
  WalksAnswer,
} from "./types";
import { errText } from "./lib/format";
import { CARD } from "./lib/ui";
import { hook, storageHook } from "./testhooks";
import { useAutoRefresh } from "./hooks/useAutoRefresh";
import { useJobLog } from "./hooks/useJobLog";
import type { JobOpening } from "./hooks/useJobLog";
import ErrorBoundary from "./components/common/ErrorBoundary";
import LoadingSpinner from "./components/common/LoadingSpinner";
import ConfirmDialog from "./components/ConfirmDialog";
import type { ConfirmRequest } from "./components/ConfirmDialog";
import JobPanel from "./components/JobPanel";
import TabBar from "./components/TabBar";
import type { TabId } from "./components/TabBar";
import TopBar from "./components/TopBar";
import type { SessionView } from "./components/TopBar";
import ActionsTab from "./components/tabs/ActionsTab";
import AppsTab from "./components/tabs/AppsTab";
import CellsTab from "./components/tabs/CellsTab";
import JobsTab from "./components/tabs/JobsTab";
import LabTab from "./components/tabs/LabTab";

const NO_ANSWERS: Record<AnswerArea, ApiResult<unknown> | null> = {
  actions: null,
  apps: null,
  cells: null,
  walk: null,
};

const clock = () => new Date().toLocaleTimeString();

function Page() {
  const { t } = useTranslation();
  const [session, setSession] = useState<SessionView>({ state: "opening" });
  const [meta, setMeta] = useState<Meta | null>(null);
  const [tab, setTab] = useState<TabId>("lab");

  const [lab, setLab] = useState<ApiResult<LabAnswer> | null>(null);
  const [labAt, setLabAt] = useState<string | null>(null);
  const [health, setHealth] = useState<ApiResult<HealthAnswer> | null>(null);
  const [apps, setApps] = useState<ApiResult<AppsAnswer> | null>(null);
  const [jobs, setJobs] = useState<ApiResult<JobsAnswer> | null>(null);

  const [confirmReq, setConfirmReq] = useState<ConfirmRequest | null>(null);
  const [answers, setAnswers] = useState(NO_ANSWERS);
  const [jobOpening, setJobOpening] = useState<JobOpening | null>(null);

  const [walks, setWalks] = useState<ApiResult<WalksAnswer> | null>(null);
  const [walkId, setWalkId] = useState<string | null>(null);
  const [walk, setWalk] = useState<ApiResult<WalkAnswer> | null>(null);
  const walkIdRef = useRef<string | null>(null);
  const walkGen = useRef(0);

  // --- getting in -------------------------------------------------------------------------------
  useEffect(() => {
    storageHook();
    void (async () => {
      const s = await openSession();
      if (s.state !== "ok") {
        hook("session", s.state);
        setSession(s.state === "refused" ? { state: "refused", detail: errText(s.answer) } : { state: "no-key" });
        storageHook();
        hook("loaded", "no-session");
        return;
      }
      hook("session", "ok");
      setSession({ state: "ok" });
      const m = await get<Meta>("/meta");
      if (m.status !== 200 || !m.json) {
        setSession({ state: "no-meta", detail: errText(m) });
        hook("loaded", "no-meta");
        return;
      }
      setMeta(m.json);
    })();
  }, []);

  // --- the reads the auto-refresh repeats -------------------------------------------------------
  const loadJobs = useCallback(async () => {
    setJobs(await get<JobsAnswer>("/jobs"));
  }, []);

  const readAll = useCallback(async (): Promise<LabAnswer | null> => {
    const [l, a, h, j] = await Promise.all([
      get<LabAnswer>("/lab"),
      get<AppsAnswer>("/apps"),
      get<HealthAnswer>("/health"),
      get<JobsAnswer>("/jobs"),
    ]);
    setLab(l);
    setLabAt(clock());
    setApps(a);
    setHealth(h);
    setJobs(j);
    return l.status === 200 && l.json ? l.json : null;
  }, []);

  const firstRead = useCallback(() => {
    storageHook();
    hook("loaded", "yes");
  }, []);

  const refresh = useAutoRefresh(meta !== null, readAll, firstRead);

  useEffect(() => {
    if (meta !== null) hook("refresh", refresh.state);
  }, [meta, refresh.state]);

  // --- walks ------------------------------------------------------------------------------------
  const loadWalks = useCallback(async () => {
    setWalks(await get<WalksAnswer>("/guided"));
  }, []);

  const openWalk = useCallback(async (gid: string) => {
    const mine = ++walkGen.current;
    walkIdRef.current = gid;
    setWalkId(gid);
    const r = await get<WalkAnswer>("/guided/" + encodeURIComponent(gid));
    if (mine === walkGen.current) setWalk(r);
  }, []);

  // stable handles for the cells tab (its first-open effect depends on them)
  const loadWalksNow = useCallback(() => void loadWalks(), [loadWalks]);
  const openWalkNow = useCallback((gid: string) => void openWalk(gid), [openWalk]);

  const closeWalk = useCallback(() => {
    walkGen.current += 1;
    walkIdRef.current = null;
    setWalkId(null);
    setWalk(null);
  }, []);

  // --- jobs -------------------------------------------------------------------------------------
  const openJob = useCallback((id: string) => setJobOpening({ id }), []);
  const closeJob = useCallback(() => setJobOpening(null), []);

  const onJobEnded = useCallback(() => {
    void loadJobs();
    if (walkIdRef.current !== null) void openWalk(walkIdRef.current);
  }, [loadJobs, openWalk]);

  const jobLog = useJobLog(jobOpening, onJobEnded);

  // --- writes: every one goes through the dialog ------------------------------------------------
  const confirmThen = useCallback((a: ConfirmRequest) => setConfirmReq({ ...a }), []);

  const setAnswer = useCallback((area: AnswerArea, r: ApiResult<unknown>) => {
    setAnswers((prev) => ({ ...prev, [area]: r }));
  }, []);

  const jobStarted = useCallback(
    (area: AnswerArea) => (r: ApiResult<unknown>) => {
      setAnswer(area, r);
      void loadJobs();
      const job = (r.json as ErrorBody | null)?.job;
      if (r.status === 202 && job) openJob(job.id);
    },
    [setAnswer, loadJobs, openJob],
  );

  const walkAfter = useCallback(
    (r: ApiResult<unknown>) => {
      setAnswer("walk", r);
      if (walkIdRef.current !== null) void openWalk(walkIdRef.current);
      void loadJobs();
      const w = r.status === 200 ? (r.json as WalkAnswer | null)?.walk : null;
      if (w && w.current !== null) {
        const cur = w.steps[w.current];
        if (cur && cur.job && cur.state === "running") openJob(cur.job);
      }
    },
    [setAnswer, openWalk, loadJobs, openJob],
  );

  // --- the page ---------------------------------------------------------------------------------
  const panel = (id: TabId) => ({
    id: "panel-" + id,
    role: "tabpanel",
    "aria-labelledby": "tab-" + id,
    hidden: tab !== id,
  });

  return (
    <div className="min-h-screen bg-gray-100 text-[#222]">
      <TopBar
        owner={meta?.owner ?? null}
        session={session}
        refresh={meta !== null ? refresh.state : null}
        reading={refresh.reading}
        lastRead={labAt}
        canRefresh={meta !== null}
        onRefresh={() => void refresh.refreshNow()}
        webguiUrl={meta?.webgui_url ?? null}
      />
      <main className="mx-auto max-w-7xl px-6 pb-12 pt-4">
        <TabBar tab={tab} onChange={setTab} />
        <div className="pt-4">
          {meta === null ? (
            <section className={CARD}>
              {session.state === "opening" || (session.state === "ok" && meta === null) ? (
                <LoadingSpinner text={t("ndtServe.loading")} />
              ) : (
                <p className="text-sm text-[#b3471d]">{t("ndtServe.session.getIn")}</p>
              )}
            </section>
          ) : (
            <>
              <div {...panel("lab")}>
                <LabTab lab={lab} labAt={labAt} health={health} />
              </div>
              <div {...panel("actions")}>
                <ActionsTab meta={meta} confirmThen={confirmThen} jobStarted={jobStarted} answer={answers.actions} />
              </div>
              <div {...panel("apps")}>
                <AppsTab
                  meta={meta}
                  apps={apps}
                  confirmThen={confirmThen}
                  jobStarted={jobStarted}
                  answer={answers.apps}
                />
              </div>
              <div {...panel("jobs")}>
                <JobsTab jobs={jobs} openJob={openJob} openId={jobOpening?.id ?? null} />
              </div>
              <div {...panel("cells")}>
                <CellsTab
                  active={tab === "cells"}
                  confirmThen={confirmThen}
                  jobStarted={jobStarted}
                  answers={{ cells: answers.cells, walk: answers.walk }}
                  setAnswer={setAnswer}
                  openJob={openJob}
                  walks={walks}
                  loadWalks={loadWalksNow}
                  walkId={walkId}
                  walk={walk}
                  openWalk={openWalkNow}
                  closeWalk={closeWalk}
                  walkAfter={walkAfter}
                />
              </div>
              <JobPanel id={jobOpening?.id ?? null} log={jobLog} onClose={closeJob} />
            </>
          )}
        </div>
      </main>
      <ConfirmDialog request={confirmReq} />
    </div>
  );
}

export default function NdtServeApp() {
  return (
    <ErrorBoundary>
      <Page />
    </ErrorBoundary>
  );
}
