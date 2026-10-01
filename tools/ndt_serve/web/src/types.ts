// [Co-developed with claude code -- Adam]
// The JSON shapes tools/ndt_serve/serve.py answers with. The page reads these fields and decides only
// on the ones the server computed (claim_is_yours, measuring_is_nothing, declared, busy, confirm,
// needs_own_claim, writes_shared_state, rc_class, state, a walk's current/blocked/done); ndt's own
// text is shown as text and never parsed.

export interface ReadRef {
  id: string;
  stdout: string;
  stderr: string;
}

export interface Job {
  id: string;
  kind: string;
  argv: string[] | null;
  state: string;
  rc: number | null;
  rc_class: string | null;
  meaning: string;
  cell?: string | null;
  cell_verdict?: { line: string; state?: string } | null;
  created_at?: number | null;
}

// A read-only ndt call (run_read): /status, /apps, and the read under /lab.
export interface ReadAnswer {
  argv: string[];
  rc: number | null;
  rc_class: string;
  meaning: string;
  stdout: string;
  stderr: string;
  duration_s: number;
  owner: string;
  read: ReadRef;
  note?: string;
}

export interface LabAnswer extends ReadAnswer {
  claim: string | null;
  measuring: string | null;
  declared: string | null;
  claim_is_yours: boolean;
  measuring_is_nothing: boolean;
  busy: Job | null;
}

export interface AppsAnswer extends ReadAnswer {
  apps: string[];
}

export interface HealthAnswer {
  owner: string;
  ndt_realpath: string;
  ndt_drift: boolean;
  busy: string | null;
}

export interface Meta {
  owner: string;
  apps: string[];
  up_hosts: Record<string, (number | null)[]>;
  max_claim_minutes: number;
  default_claim_minutes: number;
  max_note_chars: number;
  webgui_url: string;
}

export interface JobsAnswer {
  jobs: Job[];
}

export interface JobAnswer {
  job: Job;
}

// {"dry_run": true} on a write that allows it: the argv that write would run, and how hard the page
// asks (confirm_policy in serve.py).
export interface DryRunAnswer {
  dry_run: true;
  kind: string;
  argv: string[] | null;
  confirm: "typed" | "plain";
  needs_own_claim: boolean;
  note: string;
  cell?: string;
  requires?: string;
  writes_shared_state?: string | null;
}

export interface Cell {
  name: string;
  tag: string;
  requires: string;
  old: boolean;
  new: boolean;
  writes_shared_state: string | null;
  source?: string;
  fix?: string;
  expected?: string;
  fixture?: string;
}

export interface CellsAnswer {
  cells: Cell[];
  grid: string;
}

export interface Assert {
  ok: boolean;
  id: string;
  detail: string;
  file: string | null;
}

export interface Verdict {
  state: string;
  name: string;
  rest: string;
  line: string;
}

export interface FixtureAnswer {
  asserts: Assert[];
  verdict: Verdict | null;
  skip: string | null;
  timed_out: boolean;
  files: string[];
  failing: string[];
  expected_fails?: string[] | null;
  failing_matches_expected?: boolean;
  provenance?: string | null;
  gap_note?: string;
}

export interface WalkStep {
  step: string;
  title: string;
  look_at: string;
  state: string;
  job: string | null;
  result: unknown;
}

export interface WalkVerdict {
  verdict: string;
  note: string;
}

export interface Walk {
  id: string;
  cell: string;
  steps: WalkStep[];
  current: number | null;
  blocked: string | null;
  done: boolean;
  aborted?: number | null;
  verdict?: WalkVerdict | null;
}

export interface WalkSummary {
  id: string;
  cell: string;
  current: number | null;
  blocked: string | null;
  done: boolean;
  verdict: WalkVerdict | null;
}

export interface WalksAnswer {
  walks: WalkSummary[];
}

export interface WalkAnswer {
  walk: Walk;
  note?: string;
}

// Any answer: {error, note} on a refusal, {job} when a write started one.
export interface ErrorBody {
  error?: string;
  note?: string;
  job?: Job;
}

// Where a write's answer is shown: the line under the button that asked for it.
export type AnswerArea = "actions" | "apps" | "cells" | "walk";
