import type pg from "pg";
import { upsertRows, withRun } from "../db.js";

/** Az időpontfoglaló app leads_export nézetéből tölt (csak olvasó hub_reader szerepkörrel). */
export async function ingestLeads(hub: pg.Pool, app: pg.Pool): Promise<void> {
  await withRun(hub, "leads", {}, async () => {
    const wm = await hub.query("select coalesce(max(updated_at), 'epoch') as w from fact_lead");
    const { rows } = await app.query(
      "select * from public.leads_export where updated_at > $1 order by updated_at limit 20000",
      [wm.rows[0].w],
    );
    const mapped = rows.map((r) => ({
      lead_id: r.lead_id, created_at: r.created_at, updated_at: r.updated_at, source: r.source,
      booking_stage: r.booking_stage, result_type: r.result_type, business_line: r.business_line ?? "szemeszet",
      treatment: r.treatment, doctor: r.doctor,
      booking_date: /^\d{4}-\d{2}-\d{2}$/.test(r.booking_date ?? "") ? r.booking_date : null,
      booking_time: r.booking_time, utm: r.utm, click_ids: r.click_ids, first_touch: r.first_touch,
      landing_url: r.landing_url, referrer: r.referrer, ga_client_id: r.ga_client_id, parent_host: r.parent_host,
      quiz_session_id: r.quiz_session_id, dokirex_booking_id: r.dokirex_booking_id, booking_progress: r.booking_progress,
      email_hash: r.email_hash, phone_hash: r.phone_hash,
    }));
    return upsertRows(hub, "fact_lead", mapped, ["lead_id"]);
  });

  await withRun(hub, "lead_events", {}, async () => {
    const wm = await hub.query("select coalesce(max(source_id), 0) as w from fact_lead_event");
    const { rows } = await app.query(
      "select id, lead_id, session_id, event, step, meta, created_at from public.lead_events where id > $1 order by id limit 50000",
      [wm.rows[0].w],
    );
    const mapped = rows.map((r) => ({
      source_id: r.id, lead_id: r.lead_id, session_id: r.session_id, event: r.event, step: r.step,
      meta: r.meta ?? {}, created_at: r.created_at,
    }));
    return upsertRows(hub, "fact_lead_event", mapped, ["source_id"]);
  });

  await withRun(hub, "quiz_sessions", {}, async () => {
    const { rows } = await app.query("select * from public.quiz_sessions");
    const mapped = rows.map((r) => ({ session_id: r.session_id, payload: r }));
    return upsertRows(hub, "fact_quiz_session", mapped, ["session_id"]);
  });
}
