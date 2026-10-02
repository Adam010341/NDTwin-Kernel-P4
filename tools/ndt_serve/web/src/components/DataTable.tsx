// [Co-developed with claude code -- Adam]
// A table: FlowTablePanel.tsx:186-212's (Web-GUI @ f63a55ce) -- a sticky white header, xs semibold
// column names, rows divided by a light line that turn blue-50 under the pointer.
import type { ReactNode } from "react";

export function DataTable({
  id,
  head,
  children,
}: {
  id?: string;
  head: string[];
  children: ReactNode;
}) {
  return (
    <div className="max-h-[32rem] overflow-auto rounded-lg border border-[#e0e0e0] bg-white">
      <table id={id} className="min-w-full text-sm">
        <thead className="sticky top-0 z-10 border-b border-gray-200 bg-white">
          <tr>
            {head.map((h, i) => (
              <th key={i} className="px-3 py-2 text-left text-xs font-semibold tracking-wider text-gray-700">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}

export function Row({ children, current }: { children: ReactNode; current?: boolean }) {
  return (
    <tr
      className={
        "group border-b border-gray-100 align-top transition last:border-b-0 hover:bg-blue-50" +
        (current ? " bg-blue-50" : "")
      }
    >
      {children}
    </tr>
  );
}

export function Cell({ children, mono }: { children?: ReactNode; mono?: boolean }) {
  return <td className={"px-3 py-2" + (mono ? " font-mono text-xs" : "")}>{children}</td>;
}
