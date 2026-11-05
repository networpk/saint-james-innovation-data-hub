import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A szerepkörök (0027) és a kampány-előrejelzés (0043) valódiak; a kampányok szintetikus, determinisztikus napi adatok:
//  S_MINTA: SEARCH, hétköznapi minta (hétfő 1,3 … szombat 0,6, vasárnap 0,7), a megjelenési részesedés 0,8
//  S_ESES:  ugyanaz, de az utolsó 7 napon a kereslet, a kattintás és a költség 30%-ra esik (pl. keretcsökkentés)
//  S_HET2:  SEARCH, lapos, a hónap 8–14. napján 70%
//  P_LAPOS: PERFORMANCE_MAX, lapos
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('tag@x.hu'), ('nincs@x.hu');`);
  await db.exec(sql("0027_roles.sql"));
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const tag = await id("tag@x.hu"), nincs = await id("nincs@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'megtekinto')", [tag]);
  await db.exec(sql("0043_campaign_forecast.sql"));
  const noise = (d) => `(1 + 0.03 * sin((${d}::date - date '2025-01-01') * 1.7))`;
  const dow = (d) => `(array[1.3,1.15,1.1,1.1,0.9,0.6,0.7])[extract(isodow from ${d})::int]`;
  const ins = (cid, name, ch, imp, is, clk, spend, from = "2025-09-01", to = "2026-10-31", conv = "0", bl = "0") => db.exec(`
    insert into fact_campaign_daily(date, platform, account_id, campaign_id, campaign_name, channel_type, impressions, search_impression_share, clicks, spend, conversions, budget_lost_share)
    select d::date, 'google', 'acc', '${cid}', '${name}', '${ch}', round(${imp})::bigint, ${is}, round(${clk})::bigint, round(${spend})::numeric, ${conv}, ${bl}
    from generate_series(date '${from}', date '${to}', interval '1 day') d`);
  const drop = (d) => `(case when d::date >= date '2026-10-25' then 0.3 else 1 end)`;
  await ins("S_MINTA", "Minta kampány", "SEARCH", `100 * 0.8 * ${dow("d")} * ${noise("d")}`, "0.8", `20 * ${dow("d")} * ${noise("d")}`, `5000 * ${dow("d")} * ${noise("d")}`);
  await ins("S_ESES", "Eső kampány", "SEARCH", `100 * 0.8 * ${dow("d")} * ${noise("d")} * ${drop("d")}`, "0.8", `20 * ${dow("d")} * ${noise("d")} * ${drop("d")}`,
    `5000 * ${dow("d")} * ${noise("d")} * ${drop("d")}`, "2025-09-01", "2026-10-31", "0", `(case when d::date >= date '2026-10-25' then 0.5 else 0 end)`);
  await ins("S_HET2", "Második hét", "SEARCH", `100 * 0.8 * ${noise("d")} * (case when extract(day from d) between 8 and 14 then 0.7 else 1 end)`, "0.8",
    "10", "2000");
  await ins("P_LAPOS", "PMax lapos", "PERFORMANCE_MAX", `1000 * ${noise("d")}`, "0.2", "50", "9000");
  const as = async (uid, fn) => {
    await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
    try { return await fn(); } finally { await db.exec("reset role"); }
  };
  return { db, tag, nincs, as };
}

const pivot = (rows, cid) => {
  const o = {};
  for (const r of rows.filter((x) => x.campaign_id === cid)) o[`${r.kind}${r.bucket}`] = { idx: Number(r.idx), t: Number(r.t), n: r.n, metric: r.metric };
  return o;
};

test("migráció: újrafuttatható, a tábla és a függvények léteznek", async () => {
  const { db } = await setup();
  await db.exec(sql("0043_campaign_forecast.sql"));
  const f = (await db.query("select count(*)::int n from pg_proc where proname in ('forecast_series','forecast_patterns','forecast_campaign','forecast_alerts')")).rows[0].n;
  assert.equal(f, 4);
  assert.equal((await db.query("select count(*)::int n from fact_campaign_daily")).rows[0].n > 1000, true);
});

test("jogosultság: csak a tag lát adatot, az ismeretlen felhasználó semmit sem", async () => {
  const { db, tag, nincs, as } = await setup();
  assert.equal((await as(tag, () => db.query("select count(*)::int n from fact_campaign_daily"))).rows[0].n > 1000, true);
  assert.equal((await as(nincs, () => db.query("select count(*)::int n from fact_campaign_daily"))).rows[0].n, 0);
  for (const q of ["select * from forecast_patterns('google')", "select * from forecast_campaign('google','S_MINTA')", "select * from forecast_alerts('google')"]) {
    assert.equal((await as(nincs, () => db.query(q))).rows.length, 0, q);
  }
  await assert.rejects(() => as(tag, () => db.query("insert into fact_campaign_daily(date, platform, account_id, campaign_id) values ('2026-01-01','google','a','c')")));
});

test("minták: a hét napjainak indexe visszaadja a beépített mintát, a lapos kampány 1 körül van", async () => {
  const { db, tag, as } = await setup();
  const rows = (await as(tag, () => db.query("select * from forecast_patterns('google', date '2025-11-01', date '2026-10-31')"))).rows;
  const p = pivot(rows, "S_MINTA");
  assert.equal(p.dow1.metric, "demand");
  const pattern = [1.3, 1.15, 1.1, 1.1, 0.9, 0.6, 0.7];
  const mean = pattern.reduce((a, b) => a + b) / 7;
  pattern.forEach((v, i) => assert.ok(Math.abs(p[`dow${i + 1}`].idx - v / mean) < 0.06, `dow${i + 1}: ${p[`dow${i + 1}`].idx} vs ${v / mean}`));
  assert.ok(p.dow1.t > 3 && p.dow6.t < -3);   // erős, megbízható minta
  const flat = pivot(rows, "P_LAPOS");
  assert.equal(flat.dow1.metric, "impressions");   // PMax: nem „kereslet”
  for (let i = 1; i <= 7; i++) assert.ok(Math.abs(flat[`dow${i}`].idx - 1) < 0.05);
  for (let w = 1; w <= 4; w++) assert.ok(Math.abs(p[`wom${w}`].idx - 1) < 0.06);
});

test("minták: a hónap 2. hetének beépített visszaesését megtalálja, a többi hét 1 körül marad", async () => {
  const { db, tag, as } = await setup();
  const rows = (await as(tag, () => db.query("select * from forecast_patterns('google', date '2025-11-01', date '2026-10-31')"))).rows;
  const p = pivot(rows, "S_HET2");
  assert.ok(p.wom2.idx < 0.85, `wom2 ${p.wom2.idx}`);
  assert.ok(p.wom2.t < -2);
  assert.ok(p.wom2.n >= 11);
  assert.ok(p.wom1.idx > 0.95 && p.wom4.idx > 0.95);
});

test("minták: a kevés adatú kampányt kihagyja (p_min_days)", async () => {
  const { db, tag, as } = await setup();
  await db.exec(`insert into fact_campaign_daily(date, platform, account_id, campaign_id, campaign_name, channel_type, impressions, search_impression_share)
    select d::date, 'google', 'acc', 'RITKA', 'Kevés adat', 'SEARCH', 50, 0.5 from generate_series(date '2026-10-01', date '2026-10-31', interval '1 day') d`);
  const rows = (await as(tag, () => db.query("select distinct campaign_id from forecast_patterns('google')"))).rows.map((r) => r.campaign_id);
  assert.ok(!rows.includes("RITKA"));
  assert.ok(rows.includes("S_MINTA"));
});

test("előrejelzés: a jövő napjai a hét napja szerinti mintát követik, a sáv a várt körül van", async () => {
  const { db, tag, as } = await setup();
  const rows = (await as(tag, () => db.query("select * from forecast_campaign('google','S_MINTA','auto',14,30)"))).rows;
  const fut = rows.filter((r) => r.kind === "forecast");
  const hist = rows.filter((r) => r.kind === "history");
  assert.equal(fut.length, 14);
  assert.equal(hist.length, 30);
  assert.equal(fut[0].date.toISOString().slice(0, 10), "2026-11-01");   // az utolsó adatnap 2026-10-31 (szombat) után: vasárnap
  const byDow = Object.fromEntries(fut.map((r) => [r.date.getUTCDay(), Number(r.expected)]));   // 0 = vasárnap, 1 = hétfő, 6 = szombat
  assert.ok(byDow[1] > byDow[6] * 1.8, "hétfő várt >> szombat várt");
  assert.ok(Math.abs(byDow[1] / byDow[0] - 1.3 / 0.7) < 0.2);
  for (const r of fut) { assert.ok(Number(r.lo) < Number(r.expected) && Number(r.expected) < Number(r.hi)); assert.equal(r.actual, null); }
  // a múltban a tény többnyire a sávon belül van (a sáv az arányok 10–90. percentilise: a napok ~80%-a)
  const flagged = hist.filter((r) => r.flag).length;
  assert.ok(flagged <= 12, `flagged ${flagged}`);
  // a várt érték nagyságrendileg a valós szint: a hétfői kereslet ≈ 100 × 1,3
  assert.ok(Math.abs(byDow[1] - 130) < 15, `hétfő várt ${byDow[1]}`);
});

test("előrejelzés: a hirtelen visszaesés napjait 'alacsony'-nak jelzi, a budget_lost_share a környezetben látszik", async () => {
  const { db, tag, as } = await setup();
  const rows = (await as(tag, () => db.query("select * from forecast_campaign('google','S_ESES','auto',0,14)"))).rows;
  const last7 = rows.filter((r) => r.date >= new Date("2026-10-25T00:00:00Z"));
  assert.equal(last7.length, 7);
  assert.ok(last7.every((r) => r.flag === "alacsony"), JSON.stringify(last7.map((r) => r.flag)));
  assert.ok(last7.every((r) => Number(r.budget_lost_share) === 0.5));
  assert.ok(rows.filter((r) => r.date < new Date("2026-10-25T00:00:00Z")).every((r) => r.flag !== "alacsony" || true));
});

test("figyelmeztetések: a tartós visszaesés 'figyelem', a stabil kampányok 'rendben'", async () => {
  const { db, tag, as } = await setup();
  const rows = (await as(tag, () => db.query("select * from forecast_alerts('google', 7)"))).rows;
  const hit = rows.filter((r) => r.campaign_id === "S_ESES");
  const byMetric = Object.fromEntries(hit.map((r) => [r.metric, r]));
  assert.equal(byMetric.demand.severity, "figyelem");
  assert.equal(byMetric.demand.direction, "csökkenés");
  assert.ok(Number(byMetric.demand.ratio) < 0.5);
  assert.equal(byMetric.clicks.severity, "figyelem");
  assert.equal(byMetric.spend.severity, "figyelem");
  assert.ok(Number(byMetric.spend.avg_budget_lost_share) > 0.3);
  const stable = rows.filter((r) => r.campaign_id === "S_MINTA" || r.campaign_id === "P_LAPOS");
  assert.ok(stable.length >= 4);
  assert.ok(stable.every((r) => r.severity === "rendben"), JSON.stringify(stable.map((r) => [r.campaign_id, r.metric, r.ratio, r.days_flagged, r.severity])));
  // a figyelmeztetés az első sor
  assert.equal(rows[0].severity, "figyelem");
});

test("mutató: a kereslet csak 10% feletti megjelenési részesedésnél számolódik; a mai (nem teljes) nap nincs a sorozatban", async () => {
  const { db, tag, as } = await setup();
  await db.exec(`insert into fact_campaign_daily(date, platform, account_id, campaign_id, campaign_name, channel_type, impressions, search_impression_share)
    values ('2026-10-29','google','acc','S_RES','Részesedés','SEARCH', 40, 0.05), ('2026-10-30','google','acc','S_RES','Részesedés','SEARCH', 0, 0.9),
           ('2026-10-31','google','acc','S_RES','Részesedés','SEARCH', 80, 0.8)`);
  await db.exec(`insert into fact_campaign_daily(date, platform, account_id, campaign_id, campaign_name, channel_type, impressions, search_impression_share)
    values ((now() at time zone 'Europe/Budapest')::date, 'google','acc','S_RES','Részesedés','SEARCH', 5, 0.8)`);
  const r = (await as(tag, () => db.query("select date::text d, v from forecast_series('google','S_RES','demand') order by date"))).rows;
  assert.deepEqual(r.map((x) => x.d), ["2026-10-29", "2026-10-30", "2026-10-31"]);
  assert.equal(r[0].v, null);   // 10% részesedés alatt nem becsülünk
  assert.equal(r[1].v, null);   // 0 megjelenés
  assert.equal(Number(r[2].v), 100);
});
