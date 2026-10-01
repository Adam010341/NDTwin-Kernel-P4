// [Co-developed with claude code -- Adam]
// Class strings shared by the components: Web-GUI's palette and shapes (primary #1976d2, accent
// #FF7F50, white cards on bg-gray-100, borders #e0e0e0), each named after the Web-GUI place it
// follows (paths and lines @ f63a55ce, listed in THIRD_PARTY.md). Tailwind classes only: no style
// prop anywhere in src.

// A white card: DeviceInformation.tsx:252 (rounded-lg border border-[#e0e0e0] bg-white p-6).
export const CARD = "rounded-lg border border-[#e0e0e0] bg-white p-6";

// Buttons. Primary in Web-GUI's blue; secondary is DeleteDialog's Cancel (SwitchFlowTable.tsx:642);
// danger is DeleteDialog's Delete (SwitchFlowTable.tsx:649); ghost is AvailabilityStatus's header
// button (AvailabilityStatus.tsx:255).
export const BTN_PRIMARY =
  "rounded-lg bg-[#1976d2] px-4 py-2 text-sm font-medium text-white transition-colors duration-200 " +
  "hover:bg-[#1565c0] disabled:cursor-not-allowed disabled:bg-gray-300";
export const BTN_SECONDARY =
  "rounded-lg border border-gray-300 bg-white px-4 py-2 text-sm text-gray-700 transition-colors duration-200 " +
  "hover:bg-gray-50 disabled:cursor-not-allowed disabled:bg-gray-100 disabled:text-gray-400";
export const BTN_DANGER =
  "rounded-lg bg-red-500 px-4 py-2 text-sm text-white transition-colors duration-200 " +
  "hover:bg-red-600 disabled:cursor-not-allowed disabled:bg-red-300";
export const BTN_GHOST =
  "rounded-md px-3 py-2 text-sm text-gray-600 transition-colors hover:bg-gray-100 hover:text-gray-800";
// The small buttons in a table row: LinkFlowInformation.tsx:465's inactive segment.
export const BTN_SMALL =
  "rounded border border-blue-300 bg-white px-2 py-1 text-xs font-semibold text-blue-500 transition " +
  "hover:border-blue-500 hover:bg-blue-50 disabled:cursor-not-allowed disabled:border-gray-200 disabled:text-gray-300";

// A form field: DeviceInformation.tsx:275's bottom-bordered input, boxed here because these sit in
// a row of several.
export const INPUT =
  "rounded border border-gray-300 px-2 py-1 text-sm focus:border-[#1976d2] focus:outline-none";

// ndt's own text, verbatim.
export const PRE =
  "max-h-96 overflow-auto whitespace-pre-wrap break-words rounded bg-gray-100 p-2 font-mono text-xs text-[#222]";

// A line that answers a write (actions-answer, apps-answer, cells-answer, walk-answer).
export const ANSWER_OK = "min-h-[1.25rem] text-sm text-gray-700";
export const ANSWER_WARN = "min-h-[1.25rem] text-sm text-[#b3471d]";

// Something to look at: the accent colour.
export const WARN_TEXT = "text-[#b3471d]";
export const OK_TEXT = "text-green-700";

// Section headings inside a card.
export const H3 = "mb-2 text-lg font-semibold text-[#333]";
