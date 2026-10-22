import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A fact_lead és a lead_journey (a repo többi migrációjából épülő nézet) helyettesítője; a szerepkörök (0027) és a csatornák (0033) valódiak.
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('tag@x.hu'), ('nincs@x.hu');
    create table public.fact_lead (lead_id uuid primary key, click_ids jsonb, first_touch jsonb, referrer text);
    create table public.lead_journey (lead_id uuid, created_at timestamptz, day date, business_line text, lead_type text, outcome text,
      submitted boolean, person_key text, utm_medium text);`);
  await db.exec(sql("0027_roles.sql"));
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const tag = await id("tag@x.hu"), nincs = await id("nincs@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'megtekinto')", [tag]);
  await db.exec(sql("0033_lead_channels.sql"));
  await db.exec(sql("0040_lead_episodes.sql"));
  let n = 0;
  // at: UTC időpont; paid: fizetett (gclid) vagy direkt; person: null = nincs személykulcs
  const lead = async (o) => {
    const lid = `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`;
    await db.query("insert into fact_lead values ($1,$2,null,null)", [lid, o.paid ? JSON.stringify({ gclid: "x" }) : null]);
    await db.query(`insert into lead_journey values ($1,$2::timestamptz,($2::timestamptz at time zone 'Europe/Budapest')::date,$3,'idopontfoglalas',$4,$5,$6,null)`,
      [lid, o.at, o.bl ?? "szemeszet", o.booked ? "foglalt" : "adatok_elkuldve", o.submitted ?? true, o.person === undefined ? `p${n}` : o.person]);
    return lid;
  };
  return { db, tag, nincs, lead };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const H = (h) => new Date(Date.parse("2026-10-06T08:00:00Z") + h * 3600_000).toISOString();
const totals = async (db, uid, from = "2026-10-01", to = "2026-10-31", bl = "mind") =>
  (await as(db, uid, () => db.query("select * from lead_episode_totals($1,$2,$3)", [from, to, bl]))).rows[0];
const byChannel = async (db, uid, from = "2026-10-01", to = "2026-10-31", bl = "mind") =>
  Object.fromEntries((await as(db, uid, () => db.query("select * from lead_channel_episode_summary($1,$2,$3)", [from, to, bl]))).rows.map((r) => [r.channel, r]));

test("ugyanaz a személy 24 órán belül egy epizód; a nyers rekordszám külön látszik", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0) });
  await lead({ person: "A", at: H(0.05) });   // gyors ismétlés (újratöltés)
  await lead({ person: "A", at: H(3) });       // a foglalás befejezése új sorral
  await lead({ person: "B", at: H(1) });
  const t = await totals(db, tag);
  assert.deepEqual({ ...t }, { episodes: 2, raw_leads: 4, people: 2, booked: 0 });
});

test("az ablak az epizód ELSŐ rekordjához van rögzítve, nem láncolt: pontosan 24 óra már új epizód", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0) });
  await lead({ person: "A", at: H(23.99) });  // még ugyanaz az epizód
  assert.equal((await totals(db, tag)).episodes, 1);
  await lead({ person: "A", at: H(24) });     // pontosan 24 óra: új epizód
  assert.equal((await totals(db, tag)).episodes, 2);
});

test("láncolás nincs: a 20. és 30. órai rekord különböző epizód, a 40. órai a 30. óráé", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0) });
  await lead({ person: "A", at: H(20) });
  await lead({ person: "A", at: H(30) });     // 30h > 0h+24h: új epizód, bár a 20. órától 10 óra
  await lead({ person: "A", at: H(40) });     // a 30. órai epizód ablakán belül (54h-ig)
  const t = await totals(db, tag);
  assert.equal(t.episodes, 2);
  assert.equal(t.raw_leads, 4);
  assert.equal(t.people, 1);
});

test("más üzletág külön epizód; személykulcs nélkül minden rekord külön epizód", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0), bl: "szemeszet" });
  await lead({ person: "A", at: H(1), bl: "eszteika_plasztika" });
  await lead({ person: null, at: H(2) });
  await lead({ person: null, at: H(3) });
  const all = await totals(db, tag);
  assert.equal(all.episodes, 4);
  assert.equal((await totals(db, tag, "2026-10-01", "2026-10-31", "szemeszet")).episodes, 3);
  assert.equal((await totals(db, tag, "2026-10-01", "2026-10-31", "eszteika_plasztika")).episodes, 1);
});

test("foglalt, ha bármelyik rekord foglalt; a csatorna az első ISMERT forrású rekordé", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0), paid: false });            // direkt (ismeretlen)
  await lead({ person: "A", at: H(2), paid: true, booked: true }); // fizetett, foglalt
  await lead({ person: "B", at: H(0), paid: true });
  await lead({ person: "B", at: H(2), paid: false });            // a második direkt: a fizetett marad
  const s = await byChannel(db, tag);
  assert.equal(s.paid.episodes, 2);
  assert.equal(s.paid.raw_leads, 4);
  assert.equal(s.paid.booked, 1);
  assert.equal(s.direct, undefined);
  assert.equal((await totals(db, tag)).booked, 1);
});

test("a Total személyei nem a csatornánkénti személyek összege; a csatornaösszesítő epizódjai összeadódnak a Totallal", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0), paid: true });
  await lead({ person: "A", at: H(48), paid: false });   // két epizód, két csatorna, egy személy
  await lead({ person: "B", at: H(1), paid: false });
  const s = await byChannel(db, tag);
  const t = await totals(db, tag);
  assert.equal(Object.values(s).reduce((a, r) => a + r.people, 0), 3);  // csatornánként számolva 3
  assert.equal(t.people, 2);                                             // valójában 2 személy
  assert.equal(Object.values(s).reduce((a, r) => a + r.episodes, 0), t.episodes);
});

test("az epizód az első rekordja napjához tartozik (budapesti nap); az időszakhatáron átnyúló epizód nem számít újnak", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: "2026-10-05T21:30:00Z" });   // budapesti nap: 10-05 23:30 (UTC+2): 10-05
  await lead({ person: "A", at: "2026-10-06T09:00:00Z" });   // ugyanaz az epizód, 10-06-án
  assert.equal((await totals(db, tag, "2026-10-05", "2026-10-05")).episodes, 1);
  assert.equal((await totals(db, tag, "2026-10-06", "2026-10-06")).episodes, 0);
  assert.equal((await totals(db, tag, "2026-10-05", "2026-10-06")).episodes, 1);
});

test("a nem beküldött (félbehagyott) rekord nem számít; a lead_channel_summary változatlan, nyers rekordszámot ad", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0), submitted: false });
  await lead({ person: "B", at: H(0) });
  await lead({ person: "B", at: H(1) });
  assert.equal((await totals(db, tag)).episodes, 1);
  const raw = (await as(db, tag, () => db.query("select * from lead_channel_summary('2026-10-01','2026-10-31','mind')"))).rows;
  assert.equal(raw.reduce((a, r) => a + r.leads, 0), 2);   // a régi összesítő továbbra is nyers rekordokat számol
});

test("jogosultság: a nézet lead-szintű, nem olvasható a felületi szerepkörnek; a tagság nélküli semmit sem kap; a tag csak összesítőt", async () => {
  const { db, tag, nincs, lead } = await setup();
  await lead({ person: "A", at: H(0) });
  for (const role of ["anon", "authenticated"]) {
    await db.exec(`set role ${role}`);
    await assert.rejects(db.query("select * from lead_episode"));
    await db.exec("reset role");
  }
  assert.equal((await totals(db, tag)).episodes, 1);
  const none = await totals(db, nincs);
  assert.equal(none.episodes, 0);
  assert.deepEqual((await as(db, nincs, () => db.query("select * from lead_channel_episode_summary('2026-10-01','2026-10-31','mind')"))).rows, []);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from lead_episode_totals('2026-10-01','2026-10-31','mind')"));
  await db.exec("reset role");
});

test("a migráció újrafuttatható és nem ír adatot", async () => {
  const { db, tag, lead } = await setup();
  await lead({ person: "A", at: H(0) });
  const before = (await db.query("select count(*)::int n from lead_journey")).rows[0].n;
  await db.exec(sql("0040_lead_episodes.sql"));
  assert.equal((await db.query("select count(*)::int n from lead_journey")).rows[0].n, before);
  assert.equal((await totals(db, tag)).episodes, 1);
});

test("nagyobb adatmennyiségen is gyors és helyes (2000 rekord, 700 személy)", async () => {
  const { db, tag } = await setup();
  await db.exec(`insert into fact_lead select gen_random_uuid(), null, null, null from generate_series(1,2000);`);
  await db.exec(`insert into lead_journey
    select lead_id, timestamptz '2026-10-01 08:00+00' + (row_number() over ())::int * interval '17 minutes',
           date '2026-10-01', 'szemeszet', 'idopontfoglalas', 'adatok_elkuldve', true, 'p' || (row_number() over ()) % 700, null
    from fact_lead`);
  const t0 = Date.now();
  const t = await totals(db, tag, "2026-09-01", "2026-12-31");
  assert.equal(t.raw_leads, 2000);
  assert.ok(t.people <= 700 && t.episodes >= t.people && t.episodes <= 2000);
  assert.ok(Date.now() - t0 < 20000, `lassú: ${Date.now() - t0} ms`);
});
