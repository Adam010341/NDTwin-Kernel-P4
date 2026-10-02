// [Co-developed with claude code -- Adam]
// The one line under a section's heading that says what the section is for (Adam's point 4).
import { useTranslation } from "react-i18next";

export default function Explain({ section }: { section: string }) {
  const { t } = useTranslation();
  return (
    <p className="mb-4 text-sm text-gray-600" data-explain={section}>
      {t("ndtServe.section." + section + ".explain")}
    </p>
  );
}
