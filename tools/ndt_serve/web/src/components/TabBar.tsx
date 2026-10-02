// [Co-developed with claude code -- Adam]
// The five tabs. The segmented row is LinkFlowInformation.tsx:463-480's (Web-GUI @ f63a55ce); the
// chosen tab takes Sidebar.tsx:146's active look (border-[#1976d2] bg-white text-[#1976d2]),
// its border along the bottom here because the row is horizontal. Which tab is open lives in React
// state only: not in the URL (the fragment belongs to the one-time key) and not in storage.
import { useTranslation } from "react-i18next";

export const TABS = ["lab", "actions", "apps", "jobs", "cells"] as const;
export type TabId = (typeof TABS)[number];

export default function TabBar({ tab, onChange }: { tab: TabId; onChange: (t: TabId) => void }) {
  const { t } = useTranslation();
  return (
    <div role="tablist" className="flex flex-wrap gap-1 border-b border-[#e0e0e0]">
      {TABS.map((id) => {
        const active = id === tab;
        return (
          <button
            key={id}
            id={"tab-" + id}
            type="button"
            role="tab"
            aria-selected={active}
            aria-controls={"panel-" + id}
            onClick={() => onChange(id)}
            className={
              "-mb-px rounded-t-lg border-b-2 px-4 py-2 text-sm font-medium transition-all duration-200 " +
              (active
                ? "border-[#1976d2] bg-white text-[#1976d2]"
                : "border-transparent text-[#222] hover:bg-white hover:text-[#1976d2]")
            }
          >
            {t("ndtServe.tabs." + id)}
          </button>
        );
      })}
    </div>
  );
}
