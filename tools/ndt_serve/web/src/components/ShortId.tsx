// [Co-developed with claude code -- Adam]
// An id, short (lib/shortId.ts decides how). The whole id is the native title, as Web-GUI shows its
// tooltips (title=, 58 places @ f63a55ce); a click copies it and says so for 1.5 s.
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { shortId } from "../lib/shortId";

export const COPIED_MS = 1500;

export default function ShortId({ id, domId }: { id: string; domId?: string }) {
  const { t } = useTranslation();
  const [copied, setCopied] = useState<"ok" | "failed" | null>(null);
  const timer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(timer.current), []);

  const copy = async () => {
    let result: "ok" | "failed" = "ok";
    try {
      await navigator.clipboard.writeText(id);
    } catch {
      result = "failed";
    }
    setCopied(result);
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setCopied(null), COPIED_MS);
  };

  return (
    <span className="inline-flex items-center gap-1">
      <button
        type="button"
        id={domId}
        title={id}
        data-full-id={id}
        onClick={copy}
        className="rounded px-1 font-mono text-sm text-[#1976d2] hover:bg-blue-50"
      >
        {shortId(id)}
      </button>
      {copied !== null && (
        <span className={"text-xs " + (copied === "ok" ? "text-green-700" : "text-[#b3471d]")} data-copied={copied}>
          {t(copied === "ok" ? "ndtServe.shortId.copied" : "ndtServe.shortId.copyFailed")}
        </span>
      )}
    </span>
  );
}
