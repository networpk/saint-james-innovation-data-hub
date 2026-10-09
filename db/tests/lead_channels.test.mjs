import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A fact_lead és a lead_journey (a repo többi migrációjából épülő nézet) helyettesítője; a szerepkörök (0027) valódiak.
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
  const tag = await id("tag@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'megtekinto')", [tag]);
  let n = 0;
  const lead = async (o) => {
    const lid = `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`;
    await db.query("insert into fact_lead values ($1,$2,$3,$4)", [lid, o.click ? JSON.stringify({ [o.click]: "x" }) : null, o.ft ? JSON.stringify({ referrer: o.ft }) : null, o.ref ?? null]);
    await db.query("insert into lead_journey values ($1,'2026-10-06 10:00+00','2026-10-06',$2,$3,$4,$5,$6,$7)",
      [lid, o.bl ?? "szemeszet", o.type ?? "idopontfoglalas", o.outcome ?? "adatok_elkuldve", o.submitted ?? true, o.person ?? `p${n}`, o.medium ?? null]);
  };
  await db.exec(sql("0033_lead_channels.sql"));
  return { db, tag, lead, id };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const sum = async (db, uid, bl = "mind") =>
  Object.fromEntries((await as(db, uid, () => db.query("select * from lead_channel_summary('2026-10-06','2026-10-06',$1)", [bl]))).rows.map((r) => [r.channel, r]));

test("csatorna-besorolás: fizetett, organikus keresés, közösségi, saját oldal, hivatkozó, direkt", async () => {
  const { db, tag, lead } = await setup();
  await lead({ click: "gclid" });
  await lead({ medium: "cpc" });
  await lead({ ft: "https://www.google.com/" });
  await lead({ ft: "https://www.bing.com/" });
  await lead({ ft: "https://l.facebook.com/" });
  await lead({ ft: "https://saintjameshungary.hu/" });
  await lead({ ft: "https://googleads.g.doubleclick.net/" });
  await lead({ ft: "https://valami-blog.hu/cikk" });
  await lead({ ref: "https://www.google.com/" }); // csak az aktuális referrer van meg
  await lead({});
  await lead({});
  const s = await sum(db, tag);
  assert.equal(s.paid.leads, 2);
  assert.equal(s.organic_search.leads, 3);
  assert.equal(s.organic_social.leads, 1);
  assert.equal(s.own_site.leads, 1);
  assert.equal(s.paid_unattributed.leads, 1);
  assert.equal(s.referral.leads, 1);
  assert.equal(s.direct.leads, 2);
  assert.equal(s.direct.source_known, false);
  assert.equal(Object.values(s).reduce((a, r) => a + r.leads, 0), 11);
});

test("a fizetett jel erősebb a hivatkozónál; az első érintés a jelenlegi referrer előtt", async () => {
  const { db, tag, lead } = await setup();
  await lead({ click: "fbclid", ft: "https://www.google.com/" });
  await lead({ ft: "https://www.google.com/", ref: "https://saintjameshungary.hu/" });
  const s = await sum(db, tag);
  assert.equal(s.paid.leads, 1);
  assert.equal(s.organic_search.leads, 1);
  assert.equal(s.own_site?.leads, undefined);
});

test("csak a beküldött időpontfoglalás-lead számít; üzletág-szűrés, személyek és foglalt szám", async () => {
  const { db, tag, lead } = await setup();
  await lead({ ft: "https://www.google.com/", person: "a", outcome: "foglalt" });
  await lead({ ft: "https://www.google.com/", person: "a" });
  await lead({ ft: "https://www.google.com/", person: "b", bl: "eszteika_plasztika" });
  await lead({ ft: "https://www.google.com/", submitted: false, outcome: "felbehagyta" });
  await lead({ ft: "https://www.google.com/", type: "alkalmassagi" });
  const all = await sum(db, tag);
  assert.equal(all.organic_search.leads, 3);
  assert.equal(all.organic_search.people, 2);
  assert.equal(all.organic_search.booked, 1);
  assert.equal((await sum(db, tag, "szemeszet")).organic_search.leads, 2);
  assert.equal((await sum(db, tag, "eszteika_plasztika")).organic_search.leads, 1);
});

test("hozzáférés: szerep nélküli és anonim nem kap adatot, anonim nem éri el a lead-szintű nézetet sem", async () => {
  const { db, tag, lead, id } = await setup();
  await lead({ ft: "https://www.google.com/" });
  const nincs = await id("nincs@x.hu");
  assert.deepEqual((await sum(db, nincs)), {});
  await assert.rejects(db.exec("set role anon; select * from lead_channel_summary('2026-10-06','2026-10-06')").finally(() => db.exec("reset role")), /permission denied/);
  await assert.rejects(db.exec("set role anon; select * from lead_channel").finally(() => db.exec("reset role")), /permission denied/);
  assert.equal((await sum(db, tag)).organic_search.leads, 1);
});

test("újrafuttatható", async () => {
  const { db } = await setup();
  await db.exec(sql("0033_lead_channels.sql"));
});
