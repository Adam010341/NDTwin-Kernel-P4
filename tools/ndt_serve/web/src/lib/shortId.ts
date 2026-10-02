// [Co-developed with claude code -- Adam]
// The short-id display rule, decided here and nowhere else (orchestrator's ruling on SCOPE-v2
// section 11, decision 4). A job id is `20260927T062127Z-a8a334`, a walk id `g...`, a read id `r...`:
// the first eight characters would be the date and tell nothing apart, so the short form is the
// id's own HHMM (UTC, as the id carries it) and its six random characters: `0621·a8a334`. Any other
// shape shows its first eight characters. The whole id is always one hover (title) or one click
// (copy) away.

const STAMPED = /^[a-z]?[0-9]{8}T([0-9]{2})([0-9]{2})[0-9]{2}Z-([0-9A-Za-z]{6})$/;

export function shortId(id: string): string {
  const m = STAMPED.exec(id);
  return m ? m[1] + m[2] + "·" + m[3] : id.slice(0, 8);
}
