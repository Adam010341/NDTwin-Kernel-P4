// [Co-developed with claude code -- Adam]
// A pill for a server-computed class: a job's rc_class or state, a walk step's state. The shape is
// AvailabilityStatus.tsx:246's badge (Web-GUI @ f63a55ce). The colours keep v1's rule: `refused`
// and `dirty` are two different colours on purpose -- ndt help, "1 AND 5 ARE DIFFERENT QUESTIONS";
// nothing / report / skip / see-verdict are grey. The value is shown as the server sent it; the
// hover text says what it means.
import { useTranslation } from "react-i18next";

const GREEN = "bg-green-100 text-green-800";
const RED = "bg-red-100 text-red-800";
const PURPLE = "bg-purple-100 text-purple-800";
const AMBER = "bg-[#FFE8DF] text-[#b3471d]";
const GREY = "bg-gray-100 text-gray-700";
const BLUE = "bg-blue-100 text-[#1976d2]";

const COLOUR: Record<string, string> = {
  ok: GREEN,
  pass: GREEN,
  finished: GREEN,
  done: GREEN,
  dirty: RED,
  fail: RED,
  failed: RED,
  harness: RED,
  blocked: RED,
  lost: RED,
  refused: PURPLE,
  usage: AMBER,
  unknown: AMBER,
  signal: AMBER,
  timeout: AMBER,
  orphaned: AMBER,
  nothing: GREY,
  report: GREY,
  skip: GREY,
  "see-verdict": GREY,
  pending: GREY,
  running: BLUE,
};

export default function Badge({ value, kind }: { value: string | null | undefined; kind: "rc" | "state" }) {
  const { t, i18n } = useTranslation();
  if (value === null || value === undefined || value === "") return null;
  const key = "ndtServe.badge." + kind + "." + value;
  return (
    <span
      className={
        "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium " + (COLOUR[value] ?? GREY)
      }
      title={i18n.exists(key) ? t(key) : undefined}
      data-badge={kind}
      data-value={value}
    >
      {value}
    </span>
  );
}
