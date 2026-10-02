// [Co-developed with claude code -- Adam]
// As Web-GUI's src/i18n.ts @ f63a55ce: i18next + react-i18next, resources bundled (no fetch, no
// backend), one language forced, namespace "translation". Here the language is zh; every key sits
// under ndtServe.*, so the whole block can later be merged into Web-GUI's messages file. No language
// detector and no storage: the page keeps nothing in the browser.
import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import zh from "./zh.json";

void i18n.use(initReactI18next).init({
  resources: { zh: { translation: zh } },
  lng: "zh",
  fallbackLng: "zh",
  ns: ["translation"],
  defaultNS: "translation",
  initAsync: false,
  interpolation: { escapeValue: false }, // React escapes; nothing here is HTML
  react: { useSuspense: false },
});

export default i18n;
