import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

const ESZT = "490259280", SZEM = "312872101";

async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    alter default privileges in schema public grant all on tables to anon, authenticated;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('tag@x.hu'), ('nincs@x.hu');`);
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0002_kpi_targets.sql"));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  for (const f of ["0004_analytics_v2.sql", "0005_creatives_insights.sql", "0007_fix_click_gap.sql", "0008_source_conversion.sql", "0009_campaign_join_ids.sql", "0010_search_and_events.sql", "0027_roles.sql"]) await db.exec(sql(f));
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const tag = await id("tag@x.hu"), nincs = await id("nincs@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'megtekinto')", [tag]);
  await db.query("insert into ga_property_map(account_id, site, business_line) values ($1,'lassjol.hu','szemeszet') on conflict (account_id) do update set business_line='szemeszet'", [SZEM]);
  await db.query("update ga_property_map set business_line='eszteika_plasztika' where account_id=$1", [ESZT]);
  await db.exec(sql("0036_web_conversion_channels.sql"));
  return { db, tag, nincs };
}
const ev = (db, d, account, name, source, medium, n) =>
  db.query("insert into fact_web_event_daily(date,account_id,event_name,source,medium,campaign,event_count) values ($1,$2,$3,$4,$5,'',$6)", [d, account, name, source, medium, n]);
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const call = async (db, uid, bl, from = "2026-10-01", to = "2026-10-31") =>
  Object.fromEntries((await as(db, uid, () => db.query("select * from web_conversion_channels($1,$2,$3)", [from, to, bl]))).rows.map((r) => [r.channel, r]));

// Az éles esztétika-property mintája (audit, 30 nap): [forrás, médium, sikeres foglalás, foglalás-kattintás]
const SAMPLE = [
  ["google", "cpc", 60, 137], ["(not set)", "(not set)", 35, 142], ["facebook", "cpc", 24, 98], ["(data not available)", "(data not available)", 18, 61],
  ["saint-james-vision-and-aesthetics-center.salonic.hu", "referral", 9, 0], ["fb", "paid", 8, 28], ["google", "organic", 7, 39],
  ["chatgpt.com", "ai-assistant", 4, 2], ["(direct)", "(none)", 4, 15], ["ig", "social", 2, 25], ["l.facebook.com", "referral", 1, 5],
  ["yahoo", "organic", 0, 2], ["facebook.com", "referral", 0, 3], ["ig", "paid", 0, 5],
];

test("csatorna-besorolás az éles esztétika-mintán: fizetett, organikus, közösségi, AI, saját foglaló, direkt, ismeretlen", async () => {
  const { db, tag } = await setup();
  for (const [s, m, ok, click] of SAMPLE) {
    if (ok) await ev(db, "2026-10-10", ESZT, "sikeres_foglalas", s, m, ok);
    if (click) await ev(db, "2026-10-10", ESZT, "idopont_foglalas_katt", s, m, click);
  }
  const r = await call(db, tag, "eszteika_plasztika");
  assert.equal(r.paid.booking_success, 92); // google/cpc + facebook/cpc + fb/paid
  assert.equal(r.unknown.booking_success, 53); // (not set) 35 + (data not available) 18
  assert.equal(r.unknown.source_known, false);
  assert.equal(r.own_site.booking_success, 9);
  assert.equal(r.organic_search.booking_success, 7);
  assert.equal(r.organic_search.booking_click, 41); // google + yahoo
  assert.equal(r.ai_assistant.booking_success, 4);
  assert.equal(r.direct.booking_success, 4);
  assert.equal(r.organic_social.booking_success, 3); // ig/social 2 + l.facebook.com referral 1
  assert.equal(r.organic_social.booking_click, 33); // + facebook.com referral 3
  assert.equal(r.other, undefined);
  assert.equal(Object.values(r).reduce((a, x) => a + x.booking_success, 0), 172);
  const first = (await as(db, tag, () => db.query("select channel from web_conversion_channels('2026-10-01','2026-10-31','eszteika_plasztika')"))).rows[0].channel;
  assert.equal(first, "paid");
});

test("üzletág- és dátumszűrés; 'mind' mindkettőt összegzi", async () => {
  const { db, tag } = await setup();
  await ev(db, "2026-10-10", ESZT, "sikeres_foglalas", "google", "organic", 5);
  await ev(db, "2026-10-10", SZEM, "sikeres_foglalas", "google", "organic", 7);
  await ev(db, "2026-09-01", ESZT, "sikeres_foglalas", "google", "organic", 100); // tartományon kívül
  assert.equal((await call(db, tag, "eszteika_plasztika")).organic_search.booking_success, 5);
  assert.equal((await call(db, tag, "szemeszet")).organic_search.booking_success, 7);
  assert.equal((await call(db, tag, "mind")).organic_search.booking_success, 12);
  assert.equal((await call(db, tag, null)).organic_search.booking_success, 12);
});

test("jogosultság: a megtekintő látja; szerep nélküli azonosító üres eredményt kap; anon nem futtathatja; nem-konverziós esemény nem számít", async () => {
  const { db, tag, nincs } = await setup();
  await ev(db, "2026-10-10", ESZT, "sikeres_foglalas", "google", "organic", 5);
  await ev(db, "2026-10-10", ESZT, "page_view", "google", "organic", 999);
  const r = await call(db, tag, "eszteika_plasztika");
  assert.equal(r.organic_search.booking_success, 5);
  assert.equal(Object.keys(await call(db, nincs, "eszteika_plasztika")).length, 0);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from web_conversion_channels('2026-10-01','2026-10-31', null)"));
  await db.exec("reset role");
});
