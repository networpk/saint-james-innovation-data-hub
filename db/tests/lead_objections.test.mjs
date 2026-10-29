import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A fact_lead és a lead_journey (a repo többi migrációjából épülő nézet) helyettesítője; a szerepkörök (0027), a csatornák (0033), az epizódok (0040, 0041)
// és a kifogások (0042) valódiak. Az email_hash/phone_hash és a lead_journey.person_key a tesztben azonos értéket kap, mint az éles nézetben.
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('tag@x.hu'), ('nincs@x.hu');
    create table public.fact_lead (lead_id uuid primary key, created_at timestamptz, business_line text not null default 'szemeszet',
      email_hash text, phone_hash text, source text, click_ids jsonb, first_touch jsonb, referrer text);
    create table public.lead_journey (lead_id uuid, created_at timestamptz, day date, business_line text, lead_type text, outcome text,
      submitted boolean, person_key text, utm_medium text, utm_campaign text);`);
  await db.exec(sql("0027_roles.sql"));
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const tag = await id("tag@x.hu"), nincs = await id("nincs@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'megtekinto')", [tag]);
  await db.exec(sql("0033_lead_channels.sql"));
  await db.exec(sql("0040_lead_episodes.sql"));
  await db.exec(sql("0041_lead_episode_source_type.sql"));
  await db.exec(sql("0042_lead_objections.sql"));
  let n = 0;
  const lead = async (o) => {
    const lid = `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`;
    const person = o.person === undefined ? `p${n}` : o.person;
    await db.query(
      `insert into fact_lead(lead_id, created_at, business_line, email_hash, phone_hash, source, click_ids, first_touch, referrer,
         crm_status, crm_status_category, objection_reason, objection_source, crm_updated_at)
       values ($1,$2::timestamptz,$3,$4,null,'booking',$5::jsonb,null,null,$6,$7,$8,$9,$10::timestamptz)`,
      [lid, o.at, o.bl ?? "szemeszet", person, o.click ? JSON.stringify(o.click) : null,
        o.status ?? null, o.cat ?? null, o.reason ?? null, o.src ?? (o.reason ? "valasztott" : null), o.crmAt ?? (o.status ? o.at : null)]);
    await db.query(
      `insert into lead_journey values ($1,$2::timestamptz,($2::timestamptz at time zone 'Europe/Budapest')::date,$3,'idopontfoglalas','adatok_elkuldve',true,$4,null,$5)`,
      [lid, o.at, o.bl ?? "szemeszet", person, o.camp ?? null]);
    return lid;
  };
  return { db, tag, nincs, lead };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const D = (d) => new Date(Date.parse("2026-10-06T08:00:00Z") + d * 24 * 3600_000).toISOString();
const H = (h) => new Date(Date.parse("2026-10-06T08:00:00Z") + h * 3600_000).toISOString();
const summary = async (db, uid, bl = "mind") =>
  Object.fromEntries((await as(db, uid, () => db.query("select * from lead_objection_summary('2026-10-01','2026-10-31',$1)", [bl]))).rows.map((r) => [`${r.kind}:${r.key}`, r]));

async function standardCohort(lead) {
  // 10 egyedi személy
  await lead({ at: D(0), status: "beirva_lezer", cat: "beirva" });
  await lead({ at: D(1), status: "beirva_altalanos", cat: "beirva" });
  await lead({ at: D(2), status: "nem_alkalmas", cat: "lezart", reason: "teves" });
  await lead({ at: D(3), status: "nem_alkalmas", cat: "lezart", reason: "draga" });
  await lead({ at: D(4), status: "nem_alkalmas", cat: "lezart", reason: "draga", src: "megjegyzesbol" });
  await lead({ at: D(5), status: "nem_alkalmas", cat: "lezart" });                                   // lezárt, ok nélkül
  await lead({ at: D(6), status: "o_fog_jelentkezni", cat: "hivas", reason: "nem_aktualis" });         // folyamatban, de van oka
  await lead({ at: D(7), status: "hivva_1", cat: "hivas" });
  await lead({ at: D(8) });                                                                           // még nincs státusz
  await lead({ at: D(9) });
}

test("migráció: újrafuttatható, a CRM-oszlopok NULL-lal jönnek, a kezdő okok betöltődnek", async () => {
  const { db } = await setup();
  await db.exec(sql("0042_lead_objections.sql"));
  const cols = (await db.query("select column_name from information_schema.columns where table_name='fact_lead' and column_name in ('crm_status','crm_status_category','objection_reason','objection_source','crm_updated_at')")).rows;
  assert.equal(cols.length, 5);
  const r = (await db.query("select count(*)::int n, count(*) filter (where is_primary)::int p from dim_objection_reason")).rows[0];
  assert.deepEqual(r, { n: 9, p: 5 });
});

test("összkép: beérkezett / beírva / lezárt / folyamatban / nincs státusz és a kifogások aránya (10 leadből)", async () => {
  const { db, tag, lead } = await setup();
  await standardCohort(lead);
  const s = await summary(db, tag);
  assert.equal(s["summary:osszes"].episodes, 10);
  assert.equal(s["summary:beirva"].episodes, 2);
  assert.equal(s["summary:lezart"].episodes, 4);
  assert.equal(s["summary:folyamatban"].episodes, 2);
  assert.equal(s["summary:nincs_statusz"].episodes, 2);
  // nem foglalt = 4 lezárt + 1 folyamatban lévő, de kifogással
  assert.equal(s["summary:nem_foglalt"].episodes, 5);
  assert.equal(s["reason:draga"].episodes, 2);
  assert.equal(Number(s["reason:draga"].per_10), 2.0);
  assert.equal(Number(s["reason:draga"].pct_of_all), 20.0);
  assert.equal(Number(s["reason:draga"].pct_of_closed), 40.0);   // 2 / 5 nem foglalt
  assert.equal(s["reason:teves"].episodes, 1);
  assert.equal(s["reason:nem_aktualis"].episodes, 1);
  assert.equal(s["reason:nincs_ok"].episodes, 1);
  assert.equal(s["meta:megjegyzesbol"].episodes, 1);
  // a címke a törzsből jön
  assert.equal(s["reason:draga"].label, "Drága / az ár nem megfelelő");
});

test("a sorrend: összegző sorok, okok a törzs sorrendjében, a „nincs ok” és a meta a végén", async () => {
  const { db, tag, lead } = await setup();
  await standardCohort(lead);
  const rows = (await as(db, tag, () => db.query("select kind, key from lead_objection_summary('2026-10-01','2026-10-31','mind')"))).rows;
  const keys = rows.map((r) => `${r.kind}:${r.key}`);
  assert.deepEqual(keys.slice(0, 6), ["summary:osszes", "summary:beirva", "summary:lezart", "summary:folyamatban", "summary:nincs_statusz", "summary:nem_foglalt"]);
  assert.ok(keys.indexOf("reason:teves") < keys.indexOf("reason:draga"));
  assert.ok(keys.indexOf("reason:draga") < keys.indexOf("reason:nem_aktualis"));
  assert.equal(keys.at(-2), "reason:nincs_ok");
  assert.equal(keys.at(-1), "meta:megjegyzesbol");
});

test("epizód: ugyanaz a személy 24 órán belül EGY epizód; a CRM az utoljára kezelt rekordból jön", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0), status: "hivva_1", cat: "hivas", crmAt: H(1) });
  await lead({ person: "A", at: H(3), status: "nem_alkalmas", cat: "lezart", reason: "tavolsag", crmAt: H(30) });   // később kezelt
  await lead({ person: "B", at: H(0), status: "nem_alkalmas", cat: "lezart", reason: "draga", crmAt: H(50) });
  await lead({ person: "B", at: H(2), status: "hivva_2", cat: "hivas", crmAt: H(5) });                              // korábban kezelt
  const s = await summary(db, tag);
  assert.equal(s["summary:osszes"].episodes, 2);
  assert.equal(s["reason:tavolsag"].episodes, 1);
  assert.equal(s["reason:draga"].episodes, 1);
  assert.equal(s["summary:lezart"].episodes, 2);
});

test("a 24 órán TÚLI rekord új epizód, a másik epizód CRM-je nem szivárog át", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0), status: "nem_alkalmas", cat: "lezart", reason: "teves" });
  await lead({ person: "A", at: H(30) });   // új epizód, nincs státusz
  const s = await summary(db, tag);
  assert.equal(s["summary:osszes"].episodes, 2);
  assert.equal(s["summary:nincs_statusz"].episodes, 1);
  assert.equal(s["reason:teves"].episodes, 1);
});

test("személykulcs nélküli rekordok külön epizódok és a saját CRM-jüket viszik", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: null, at: H(0), status: "nem_alkalmas", cat: "lezart", reason: "orvosi" });
  await lead({ person: null, at: H(1) });
  const s = await summary(db, tag);
  assert.equal(s["summary:osszes"].episodes, 2);
  assert.equal(s["reason:orvosi"].episodes, 1);
  assert.equal(s["summary:nincs_statusz"].episodes, 1);
});

test("üzletág-szűrő: szemészet / plasztika külön, a mind és a besorolatlan mindent ad", async () => {
  const { db, tag, lead } = await setup();
  await lead({ at: D(0), bl: "szemeszet", status: "nem_alkalmas", cat: "lezart", reason: "draga" });
  await lead({ at: D(1), bl: "eszteika_plasztika", status: "nem_alkalmas", cat: "lezart", reason: "tavolsag" });
  assert.equal((await summary(db, tag, "szemeszet"))["summary:osszes"].episodes, 1);
  assert.equal((await summary(db, tag, "szemeszet"))["reason:draga"].episodes, 1);
  assert.equal((await summary(db, tag, "szemeszet"))["reason:tavolsag"], undefined);
  assert.equal((await summary(db, tag, "eszteika_plasztika"))["reason:tavolsag"].episodes, 1);
  assert.equal((await summary(db, tag, "mind"))["summary:osszes"].episodes, 2);
  assert.equal((await summary(db, tag, "besorolatlan"))["summary:osszes"].episodes, 2);
});

test("CRM-adat nélkül (a foglaló még nem küld) a Hub nem dől el: minden epizód „még nincs státusz”", async () => {
  const { db, tag, lead } = await setup();
  await lead({ at: D(0) });
  await lead({ at: D(1) });
  const s = await summary(db, tag);
  assert.equal(s["summary:osszes"].episodes, 2);
  assert.equal(s["summary:nincs_statusz"].episodes, 2);
  assert.equal(s["summary:lezart"].episodes, 0);
  assert.equal(s["reason:nincs_ok"].episodes, 0);
  assert.equal(Number(s["summary:osszes"].per_10), 10.0);
});

test("üres időszak: nincs nullával osztás, az arányok NULL", async () => {
  const { db, tag } = await setup();
  const s = await summary(db, tag);
  assert.equal(s["summary:osszes"].episodes, 0);
  assert.equal(s["summary:osszes"].pct_of_all, null);
  assert.equal(s["summary:osszes"].per_10, null);
});

test("ismeretlen (a törzsben nem szereplő) ok kulcsként jelenik meg, és inaktív ok is számít a statisztikában", async () => {
  const { db, tag, lead } = await setup();
  await lead({ at: D(0), status: "nem_alkalmas", cat: "lezart", reason: "uj_ok_amit_meg_nem_toltottunk" });
  await lead({ at: D(1), status: "nem_alkalmas", cat: "lezart", reason: "mashol" });
  await db.exec("update dim_objection_reason set active = false where key = 'mashol'");
  const s = await summary(db, tag);
  assert.equal(s["reason:uj_ok_amit_meg_nem_toltottunk"].label, "uj_ok_amit_meg_nem_toltottunk");
  assert.equal(s["reason:mashol"].episodes, 1);
});

test("csatornánkénti bontás: fizetett és direkt külön, az összes és a nem foglalt sor a nevezőhöz", async () => {
  const { db, tag, lead } = await setup();
  await lead({ at: D(0), click: { gclid: "x" }, status: "nem_alkalmas", cat: "lezart", reason: "teves" });
  await lead({ at: D(1), click: { gclid: "y" }, status: "nem_alkalmas", cat: "lezart", reason: "teves" });
  await lead({ at: D(2), click: { gclid: "z" }, status: "beirva_lezer", cat: "beirva" });
  await lead({ at: D(3), status: "nem_alkalmas", cat: "lezart", reason: "draga" });   // direkt
  const rows = (await as(db, tag, () => db.query("select * from lead_objection_by_channel('2026-10-01','2026-10-31','mind')"))).rows;
  const get = (ch, k) => rows.find((r) => r.channel === ch && r.reason_key === k);
  assert.equal(get("paid", "_osszes").episodes, 3);
  assert.equal(get("paid", "_nem_foglalt").episodes, 2);
  assert.equal(get("paid", "teves").episodes, 2);
  assert.equal(get("paid", "draga"), undefined);
  assert.equal(get("direct", "_osszes").episodes, 1);
  assert.equal(get("direct", "draga").episodes, 1);
  assert.equal(get("paid", "_osszes").channel_label, "Fizetett");
});

test("kampányonkénti bontás: a limit feletti kampányok „(egyéb kampányok)” alatt összevonva, a hiányzó kampány külön", async () => {
  const { db, tag, lead } = await setup();
  await lead({ at: D(0), camp: "A", status: "nem_alkalmas", cat: "lezart", reason: "teves" });
  await lead({ at: D(1), camp: "A", status: "nem_alkalmas", cat: "lezart", reason: "teves" });
  await lead({ at: D(2), camp: "B", status: "nem_alkalmas", cat: "lezart", reason: "draga" });
  await lead({ at: D(3), camp: "C", status: "nem_alkalmas", cat: "lezart", reason: "draga" });
  await lead({ at: D(4), camp: null });
  const q = async (limit) => (await as(db, tag, () => db.query("select * from lead_objection_by_campaign('2026-10-01','2026-10-31','mind',$1)", [limit]))).rows;
  const all = await q(15);
  assert.equal(all.find((r) => r.campaign === "A" && r.reason_key === "_osszes").episodes, 2);
  assert.equal(all.find((r) => r.campaign === "(nincs kampány)" && r.reason_key === "_osszes").episodes, 1);
  const top1 = await q(1);
  assert.equal(top1.find((r) => r.campaign === "A" && r.reason_key === "teves").episodes, 2);
  const other = top1.find((r) => r.campaign === "(egyéb kampányok)" && r.reason_key === "_osszes");
  assert.equal(other.episodes, 3);   // B + C + nincs kampány
  assert.equal(top1.find((r) => r.campaign === "(egyéb kampányok)" && r.reason_key === "draga").episodes, 2);
});

test("jogosultság: szerep nélküli fiók üres választ kap, anon nem hívhat, a nézet a felületi szerepeknek zárt", async () => {
  const { db, tag, nincs, lead } = await setup();
  await standardCohort(lead);
  assert.equal((await summary(db, tag))["summary:osszes"].episodes, 10);
  const none = (await as(db, nincs, () => db.query("select * from lead_objection_summary('2026-10-01','2026-10-31','mind')"))).rows;
  assert.equal(none.length, 0);
  await db.exec("set role anon");
  await assert.rejects(() => db.query("select * from lead_objection_summary('2026-10-01','2026-10-31','mind')"), /permission denied/);
  await assert.rejects(() => db.query("select * from lead_objection_by_channel('2026-10-01','2026-10-31','mind')"), /permission denied/);
  await assert.rejects(() => db.query("select * from lead_objection_by_campaign('2026-10-01','2026-10-31','mind',5)"), /permission denied/);
  await db.exec("reset role");
  await db.exec("set role authenticated");
  await assert.rejects(() => db.query("select * from lead_episode_crm"), /permission denied/);
  await db.exec("reset role");
});

test("a törzstábla: a tag olvashatja, írni nem; szerep nélküli fiók semmit nem lát", async () => {
  const { db, tag, nincs } = await setup();
  assert.equal((await as(db, tag, () => db.query("select count(*)::int n from dim_objection_reason"))).rows[0].n, 9);
  assert.equal((await as(db, nincs, () => db.query("select count(*)::int n from dim_objection_reason"))).rows[0].n, 0);
  await assert.rejects(() => as(db, tag, () => db.query("update dim_objection_reason set label = 'x'")), /permission denied/);
});

test("a statisztikai függvények nem adnak vissza személyes adatot (csak darabszám és címke)", async () => {
  const { db, tag, lead } = await setup();
  await standardCohort(lead);
  for (const q of [
    "select * from lead_objection_summary('2026-10-01','2026-10-31','mind')",
    "select * from lead_objection_by_channel('2026-10-01','2026-10-31','mind')",
    "select * from lead_objection_by_campaign('2026-10-01','2026-10-31','mind',5)",
  ]) {
    const cols = Object.keys((await as(db, tag, () => db.query(q))).rows[0]);
    for (const c of cols) assert.doesNotMatch(c, /person|hash|lead_id|phone|email|name/);
  }
});
