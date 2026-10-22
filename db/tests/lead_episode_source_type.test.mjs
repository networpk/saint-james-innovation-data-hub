import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A fact_lead és a lead_journey (a repo többi migrációjából épülő nézet) helyettesítője; a szerepkörök (0027), a csatornák (0033) és az epizódok (0040, 0041) valódiak.
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('tag@x.hu'), ('nincs@x.hu');
    create table public.fact_lead (lead_id uuid primary key, click_ids jsonb, first_touch jsonb, referrer text, source text);
    create table public.lead_journey (lead_id uuid, created_at timestamptz, day date, business_line text, lead_type text, outcome text,
      submitted boolean, person_key text, utm_medium text);`);
  await db.exec(sql("0027_roles.sql"));
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const tag = await id("tag@x.hu"), nincs = await id("nincs@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'megtekinto')", [tag]);
  await db.exec(sql("0033_lead_channels.sql"));
  await db.exec(sql("0040_lead_episodes.sql"));
  await db.exec(sql("0041_lead_episode_source_type.sql"));
  let n = 0;
  const lead = async (o) => {
    const lid = `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`;
    await db.query("insert into fact_lead values ($1,null,null,null,$2)", [lid, o.source ?? "booking"]);
    await db.query(`insert into lead_journey values ($1,$2::timestamptz,($2::timestamptz at time zone 'Europe/Budapest')::date,$3,'idopontfoglalas',$4,true,$5,null)`,
      [lid, o.at, o.bl ?? "szemeszet", o.booked ? "foglalt" : "adatok_elkuldve", o.person === undefined ? `p${n}` : o.person]);
  };
  return { db, tag, nincs, lead };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const H = (h) => new Date(Date.parse("2026-10-06T08:00:00Z") + h * 3600_000).toISOString();
const bySource = async (db, uid, bl = "mind") =>
  Object.fromEntries((await as(db, uid, () => db.query("select * from lead_source_episode_summary('2026-10-01','2026-10-31',$1)", [bl]))).rows.map((r) => [r.source_type, r]));
const totals = async (db, uid) => (await as(db, uid, () => db.query("select * from lead_episode_totals('2026-10-01','2026-10-31','mind')"))).rows[0];

test("forrástípusok: időpontfoglaló, weboldal (Elementor), kézi import, egyéb; a három típus összege a Mindösszesen epizódszám", async () => {
  const { db, tag, lead } = await setup();
  await lead({ source: "booking", at: H(0) });
  await lead({ source: "booking", at: H(1) });
  await lead({ source: "elementor", at: H(2) });
  await lead({ source: "manual_import", at: H(3) });
  await lead({ source: "manual_import", at: H(4) });
  await lead({ source: "valami_uj", at: H(5) });
  const s = await bySource(db, tag);
  assert.equal(s.booking.episodes, 2);
  assert.equal(s.website.episodes, 1);
  assert.equal(s.manual.episodes, 2);
  assert.equal(s.other.episodes, 1);
  assert.equal(Object.values(s).reduce((a, r) => a + r.episodes, 0), (await totals(db, tag)).episodes);
});

test("az epizód forrástípusa az ELSŐ rekordjáé; nincs átfedés a típusok között", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", source: "elementor", at: H(0) });
  await lead({ person: "A", source: "booking", at: H(2), booked: true });   // ugyanaz az epizód: weboldal marad, foglalt
  await lead({ person: "B", source: "booking", at: H(0) });
  await lead({ person: "B", source: "elementor", at: H(2) });               // booking marad
  const s = await bySource(db, tag);
  assert.deepEqual([s.website.episodes, s.booking.episodes], [1, 1]);
  assert.equal(s.website.raw_leads, 2);
  assert.equal(s.website.booked, 1);
  assert.equal(s.booking.booked, 0);
  assert.equal((await totals(db, tag)).episodes, 2);
});

test("üzletág-szűrés, nyers rekordszám és személyek típusonként; a rendezés időpontfoglaló, weboldal, kézi", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", source: "manual_import", at: H(0), bl: "szemeszet" });
  await lead({ person: "A", source: "manual_import", at: H(1), bl: "szemeszet" });
  await lead({ person: "B", source: "booking", at: H(0), bl: "eszteika_plasztika" });
  await lead({ person: "C", source: "elementor", at: H(0), bl: "szemeszet" });
  const all = (await as(db, tag, () => db.query("select source_type from lead_source_episode_summary('2026-10-01','2026-10-31','mind')"))).rows.map((r) => r.source_type);
  assert.deepEqual(all, ["booking", "website", "manual"]);
  const sz = await bySource(db, tag, "szemeszet");
  assert.equal(sz.manual.episodes, 1);
  assert.equal(sz.manual.raw_leads, 2);
  assert.equal(sz.manual.people, 1);
  assert.equal(sz.booking, undefined);
});

test("jogosultság: a nézet nem olvasható a felületi szerepkörnek; tagság nélkül üres; anon nem hívhatja; a 0040 függvényei változatlanok", async () => {
  const { db, tag, nincs, lead } = await setup();
  await lead({ source: "booking", at: H(0) });
  for (const role of ["anon", "authenticated"]) {
    await db.exec(`set role ${role}`);
    await assert.rejects(db.query("select * from lead_episode"));
    await db.exec("reset role");
  }
  assert.deepEqual((await as(db, nincs, () => db.query("select * from lead_source_episode_summary('2026-10-01','2026-10-31','mind')"))).rows, []);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from lead_source_episode_summary('2026-10-01','2026-10-31','mind')"));
  await db.exec("reset role");
  assert.equal((await totals(db, tag)).episodes, 1);
  const ch = (await as(db, tag, () => db.query("select * from lead_channel_episode_summary('2026-10-01','2026-10-31','mind')"))).rows;
  assert.equal(ch.reduce((a, r) => a + r.episodes, 0), 1);
});

test("a migráció újrafuttatható és nem ír adatot", async () => {
  const { db, tag, lead } = await setup();
  await lead({ source: "elementor", at: H(0) });
  const before = (await db.query("select count(*)::int n from lead_journey")).rows[0].n;
  await db.exec(sql("0041_lead_episode_source_type.sql"));
  assert.equal((await db.query("select count(*)::int n from lead_journey")).rows[0].n, before);
  assert.equal((await bySource(db, tag)).website.episodes, 1);
});
