// [Co-developed with claude code -- Adam]
// Mounts <NdtServeApp/> and counts CSP violations into <body data-csp-violations> ("0" from the
// start), which the browser tests assert is 0 (SCOPE-v2 section 4). Nothing else.
//
// Two counters, because one cannot see everything: the securitypolicyviolation listener counts what
// happens after this module runs, and a buffered ReportingObserver also hands over the reports of
// violations that happened BEFORE it -- an inline <script> in index.html is blocked while the HTML is
// parsed, and a module script runs only after that. Each violation reaches both, so the hook shows
// the larger of the two counts, not their sum.
import { createRoot } from "react-dom/client";
import "./index.css";
import "./i18n";
import NdtServeApp from "./NdtServeApp";
import { hook } from "./testhooks";

let live = 0;
let reported = 0;
const showViolations = () => hook("cspViolations", String(Math.max(live, reported)));
showViolations();
document.addEventListener("securitypolicyviolation", () => {
  live += 1;
  showViolations();
});
if (typeof ReportingObserver === "function") {
  try {
    new ReportingObserver(
      (reports) => {
        reported += reports.length;
        showViolations();
      },
      { types: ["csp-violation"], buffered: true },
    ).observe();
  } catch {
    // a browser without csp-violation reports: the listener alone counts
  }
}

const root = document.getElementById("root");
if (root !== null) createRoot(root).render(<NdtServeApp />);
