// [Co-developed with claude code -- Adam]
// Label on the left, value on the right: DeviceInformation.tsx:252-305's rows (Web-GUI @ f63a55ce),
// `flex items-center justify-between`, the label in the primary colour.
import type { ReactNode } from "react";

export function StatusRows({ children }: { children: ReactNode }) {
  return <div className="divide-y divide-gray-100">{children}</div>;
}

export function StatusRow({
  label,
  children,
  rowId,
  hidden,
}: {
  label: string;
  children: ReactNode;
  rowId?: string;
  hidden?: boolean;
}) {
  return (
    // `hidden` also drops `flex`: a utility's display would otherwise beat preflight's [hidden] rule
    <div id={rowId} hidden={hidden} className={(hidden ? "hidden" : "flex") + " items-start justify-between gap-6 py-2"}>
      <span className="shrink-0 text-sm font-medium text-[#1976d2]">{label}</span>
      <div className="flex min-w-0 flex-wrap items-center justify-end gap-2 text-right text-sm text-[#222]">
        {children}
      </div>
    </div>
  );
}
