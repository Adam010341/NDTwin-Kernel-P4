// [Co-developed with claude code -- Adam]
// 操作: claim / release and up / down. Every button opens the confirm dialog; nothing here writes.
// The forms offer what /meta says the server takes (up_hosts, the claim limits); the values are read
// from the fields when the button is pressed, as v1 did.
import { useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import type { ApiResult } from "../../api/client";
import type { AnswerArea, Meta } from "../../types";
import type { ConfirmRequest } from "../ConfirmDialog";
import { BTN_DANGER, BTN_PRIMARY, BTN_SECONDARY, CARD, H3, INPUT } from "../../lib/ui";
import Answer from "../Answer";
import Explain from "../Explain";

export default function ActionsTab({
  meta,
  confirmThen,
  jobStarted,
  answer,
}: {
  meta: Meta;
  confirmThen: (a: ConfirmRequest) => void;
  jobStarted: (area: AnswerArea) => (r: ApiResult<unknown>) => void;
  answer: ApiResult<unknown> | null;
}) {
  const { t } = useTranslation();
  const minRef = useRef<HTMLInputElement>(null);
  const noteRef = useRef<HTMLInputElement>(null);
  const planeRef = useRef<HTMLSelectElement>(null);
  const hostsRef = useRef<HTMLSelectElement>(null);
  const planes = Object.keys(meta.up_hosts);
  const [plane, setPlane] = useState<string>(planes[0] ?? "");

  const claim = () => {
    const body: Record<string, unknown> = { minutes: Number(minRef.current?.value) };
    if (noteRef.current?.value) body.note = noteRef.current.value;
    confirmThen({
      title: t("ndtServe.confirm.titleClaim"),
      path: "/claim",
      body,
      word: "claim",
      preview: true,
      then: jobStarted("actions"),
    });
  };
  const release = () =>
    confirmThen({
      title: t("ndtServe.confirm.titleRelease"),
      path: "/release",
      body: {},
      word: "release",
      preview: true,
      then: jobStarted("actions"),
    });
  const up = () => {
    const body: Record<string, unknown> = { plane: planeRef.current?.value ?? plane };
    const hosts = hostsRef.current?.value ?? "";
    if (hosts !== "") body.hosts = Number(hosts);
    confirmThen({
      title: t("ndtServe.confirm.titleUp"),
      path: "/up",
      body,
      word: "up",
      preview: true,
      then: jobStarted("actions"),
    });
  };
  const down = () =>
    confirmThen({
      title: t("ndtServe.confirm.titleDown"),
      path: "/down",
      body: {},
      word: "down",
      preview: true,
      then: jobStarted("actions"),
    });

  return (
    <section className={CARD}>
      <h2 className="mb-1 text-xl font-bold text-[#333]">{t("ndtServe.tabs.actions")}</h2>
      <Explain section="actions" />

      <div className="mb-6 rounded-lg border border-[#e0e0e0] p-4">
        <h3 className={H3}>{t("ndtServe.actions.claimTitle")}</h3>
        <p className="mb-3 text-sm text-gray-600">{t("ndtServe.actions.claimExplain")}</p>
        <div className="flex flex-wrap items-center gap-3">
          <label className="inline-flex items-center gap-2 text-sm">
            {t("ndtServe.actions.minutes")}
            <input
              id="claim-min"
              ref={minRef}
              type="number"
              min={1}
              step={1}
              max={meta.max_claim_minutes}
              defaultValue={meta.default_claim_minutes}
              className={INPUT + " w-24"}
            />
          </label>
          <label className="inline-flex items-center gap-2 text-sm">
            {t("ndtServe.actions.note")}
            <input
              id="claim-note"
              ref={noteRef}
              type="text"
              maxLength={meta.max_note_chars}
              size={40}
              className={INPUT}
            />
          </label>
          <button id="do-claim" type="button" onClick={claim} className={BTN_PRIMARY}>
            {t("ndtServe.actions.claim")}
          </button>
          <button id="do-release" type="button" onClick={release} className={BTN_SECONDARY}>
            {t("ndtServe.actions.release")}
          </button>
        </div>
      </div>

      <div className="mb-4 rounded-lg border border-[#e0e0e0] p-4">
        <h3 className={H3}>{t("ndtServe.actions.upTitle")}</h3>
        <p className="mb-3 text-sm text-gray-600">{t("ndtServe.actions.upExplain")}</p>
        <div className="flex flex-wrap items-center gap-3">
          <label className="inline-flex items-center gap-2 text-sm">
            {t("ndtServe.actions.plane")}
            <select
              id="up-plane"
              ref={planeRef}
              defaultValue={plane}
              onChange={(e) => setPlane(e.target.value)}
              className={INPUT}
            >
              {planes.map((p) => (
                <option key={p} value={p}>
                  {p}
                </option>
              ))}
            </select>
          </label>
          <label className="inline-flex items-center gap-2 text-sm">
            {t("ndtServe.actions.hosts")}
            <select id="up-hosts" ref={hostsRef} key={plane} className={INPUT}>
              {(meta.up_hosts[plane] ?? []).map((h) => (
                <option key={h === null ? "default" : String(h)} value={h === null ? "" : String(h)}>
                  {h === null ? t("ndtServe.actions.hostsDefault") : String(h)}
                </option>
              ))}
            </select>
          </label>
          <button id="do-up" type="button" onClick={up} className={BTN_DANGER}>
            {t("ndtServe.actions.up")}
          </button>
          <button id="do-down" type="button" onClick={down} className={BTN_DANGER}>
            {t("ndtServe.actions.down")}
          </button>
        </div>
      </div>
      <Answer id="actions-answer" r={answer} />
    </section>
  );
}
