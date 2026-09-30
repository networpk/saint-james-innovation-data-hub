import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// Determinisztikus álvéletlen (a teszt reprodukálható).
function prng(seed) { let s = seed; return () => (s = (s * 1664525 + 1013904223) % 4294967296) / 4294967296; }

async function setup() {
  const db = new PGlite();
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0002_kpi_targets.sql"));
  // A Hub projektben a kampány-besorolás nézet a Lovable migrációjából jön; itt ugyanazzal az oszlopkészlettel pótoljuk.
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  await db.exec(sql("0004_analytics_v2.sql"));
  return db;
}
const day = (i) => new Date(Date.UTC(2026, 6, 1 + i)).toISOString().slice(0, 10);

test("a téma-szabályok ékezet- és kisbetű-érzéketlenek, és a SMILE erősebb", async () => {
  const db = await setup();
  const t = async (target, text) => (await db.query("select topic_for($1,$2) as t", [target, text])).rows[0].t;
  assert.equal(await t("keyword", "Lézeres szemműtét ár"), "lezer");
  assert.equal(await t("campaign", "Perf.Max - Szürkehályog (45+) /konvmax"), "szurkehalyog");
  assert.equal(await t("campaign", "Perf.Max - SMILE AO"), "smile");
  assert.equal(await t("campaign", "LASSJOL - RLE + LASER NEW Videos - Traffic"), "lezer"); // a LASER (40) megelőzi az RLE-t (41)
  assert.equal(await t("keyword", "saint james szemészeti központ vélemények"), "brand");
  assert.equal(await t("keyword", "teljesen más"), null);
});

test("a korrelációs motor megtalálja a beültetett 3 napos késleltetést", async () => {
  const db = await setup();
  const rnd = prng(7);
  const spend = Array.from({ length: 70 }, () => 50000 + Math.round(rnd() * 100000));
  for (let i = 0; i < 70; i++) {
    await db.query(
      `insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks)
       values ($1,'meta','a','c1',$2,1000,10)`, [day(i), spend[i]]);
    const brand = i >= 3 ? Math.round(spend[i - 3] / 1000 * 3 + rnd() * 6) : 10; // a Meta-költés 3 nap múlva jelenik meg a brand-keresésben
    await db.query(
      `insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend)
       values ($1,'g','k1','ag','saint james','',$2,1,100)`, [day(i), brand]);
    // független zaj-jel: ne legyen vele erős kapcsolat
    await db.query(
      `insert into fact_web_daily(date,account_id,source,medium,channel_group,sessions)
       values ($1,'312872101','(direct)','(none)','Direct',$2)`, [day(i), Math.round(200 + rnd() * 100)]);
  }
  const { rows } = await db.query(
    `select * from signal_correlations_best($1::date,$2::date,14,true,14,2.5)`, [day(0), day(69)]);
  const planted = rows.find((r) => r.signal_a === "spend_meta" && r.signal_b === "google_brand_impressions");
  assert.ok(planted, "a beültetett kapcsolat megjelenik");
  assert.equal(planted.lag_days, 3);
  assert.ok(Number(planted.r) > 0.8, `r=${planted.r}`);
  const noise = rows.find((r) => r.signal_a === "spend_meta" && r.signal_b === "web_sessions_direct");
  assert.ok(!noise || Math.abs(Number(noise.r)) < 0.5, "a zaj-jel nem lehet erős kapcsolat");
});

test("lemorzsolódás: lépésenkénti elérés, elhagyók, kohorsz és tölcsér", async () => {
  const db = await setup();
  const L = (n) => `00000000-0000-4000-8000-00000000000${n}`;
  const t0 = "2026-07-06T09:00:00+02:00"; // hétfő
  const steps = { 1: ["contact", "choice", "treatment", "calendar"], 2: ["contact", "choice", "treatment", "calendar", "confirm", "done"], 3: ["contact", "choice"] };
  for (const [n, list] of Object.entries(steps)) {
    const done = list.includes("done");
    await db.query(
      `insert into fact_lead(lead_id,created_at,updated_at,source,booking_stage,booking_progress,dokirex_booking_id,utm)
       values ($1,$2,$2,'booking',$3,$4,$5,'{"utm_source":"facebook"}')`,
      [L(n), t0, done ? "completed" : "contact", JSON.stringify({ lastStep: list[list.length - 1] }), done ? 777 : null]);
    let id = Number(n) * 100;
    for (const s of list) {
      await db.query(
        `insert into fact_lead_event(source_id,lead_id,event,step,meta,created_at) values ($1,$2,'step_view',$3,$4,$5)`,
        [id++, L(n), s, JSON.stringify({ secondsOnLastStep: 30 }), t0]);
    }
    if (done) await db.query(
      `insert into fact_lead_event(source_id,lead_id,event,step,meta,created_at) values (999,$1,'booking_confirmed','done','{}','2026-07-06T20:00:00+02:00')`, [L(n)]);
  }
  const reach = (await db.query(`select step, leads_reached from mart_booking_step_daily order by ord`)).rows;
  const get = (s) => Number(reach.find((r) => r.step === s)?.leads_reached ?? 0);
  assert.deepEqual([get("contact"), get("choice"), get("treatment"), get("calendar"), get("confirm"), get("done")], [3, 3, 2, 2, 1, 1]);

  const ab = (await db.query(`select last_step, leads from mart_booking_abandon_weekly order by last_step`)).rows;
  assert.deepEqual(ab.map((r) => [r.last_step, Number(r.leads)]), [["calendar", 1], ["choice", 1]]);

  const c = (await db.query(`select * from mart_lead_cohort_weekly`)).rows[0];
  assert.equal(Number(c.leads), 3);
  assert.equal(Number(c.booked), 1);
  assert.equal(Number(c.booked_d1), 1);

  const f = (await db.query(`select * from mart_funnel_daily where date = '2026-07-06'`)).rows[0];
  assert.equal(Number(f.booking_leads_started), 3);
  assert.equal(Number(f.hard_leads), 1);
  assert.equal(Number(f.booked_web), 1);
});

test("a nézetek üres adatbázison is hibátlanul futnak", async () => {
  const db = await setup();
  for (const v of ["mart_topic_daily", "mart_keyword_daily", "mart_search_term_daily", "mart_funnel_daily", "mart_web_channel_daily",
    "mart_booking_step_daily", "mart_booking_abandon_weekly", "mart_quiz_step_reach", "mart_lead_cohort_weekly", "mart_lead_timing", "mart_signals_long"]) {
    const r = await db.query(`select count(*)::int as n from ${v}`);
    assert.equal(r.rows[0].n, 0, v);
  }
});

test("kvíz: elérés a közös lépésekig és befejezettek", async () => {
  const db = await setup();
  const rows = [
    { session_id: "11111111-1111-4111-8111-111111111111", furthest_order: 3, completed: false, started_at: "2026-07-06T10:00:00Z" },
    { session_id: "22222222-2222-4222-8222-222222222222", furthest_order: 11, completed: true, started_at: "2026-07-06T11:00:00Z" },
    { session_id: "33333333-3333-4333-8333-333333333333", furthest_order: 0, completed: false, started_at: "2026-07-06T12:00:00Z" },
  ];
  for (const r of rows) await db.query("insert into fact_quiz_session(session_id,payload) values ($1,$2)", [r.session_id, JSON.stringify(r)]);
  const out = (await db.query("select ord, sessions_reached, sessions_started, sessions_completed from mart_quiz_step_reach order by ord")).rows;
  assert.deepEqual(out.map((r) => Number(r.sessions_reached)), [3, 2, 2, 2, 1, 1, 1]);
  assert.equal(Number(out[0].sessions_completed), 1);
});
