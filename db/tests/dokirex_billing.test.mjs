import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    alter default privileges in schema public grant all on tables to anon, authenticated;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('elemzo@x.hu'), ('tag@x.hu'), ('nincs@x.hu');`);
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0027_roles.sql"));
  const uid = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const elemzo = await uid("elemzo@x.hu"), tag = await uid("tag@x.hu"), nincs = await uid("nincs@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'elemzo'), ($2,'megtekinto')", [elemzo, tag]);
  await db.exec(sql("0037_dokirex_billing.sql"));
  return { db, elemzo, tag, nincs };
}
async function as(db, role, uid, fn) {
  await db.exec(`set role ${role}; select set_config('request.uid', '${uid ?? ""}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const bill = (db, id, date, service, amount, lines = 1, status = 1) =>
  db.query(`insert into fact_dokirex_billing(elojegyzes_id, visit_date, service, amount, lines, dx_status, modified_at)
    values ($1,$2,$3,$4,$5,$6,'2026-10-19T10:00:00Z')`, [id, date, service, amount, lines, status]);
const lead = (db, bookingId) =>
  db.query(`insert into fact_lead(lead_id, created_at, updated_at, source, dokirex_booking_id)
    values (gen_random_uuid(), now(), now(), 'booking', $1)`, [bookingId]);
const summary = async (db, uid, bl = null, from = "2026-10-13", to = "2026-10-14") =>
  (await as(db, "authenticated", uid, () => db.query("select * from dokirex_revenue_summary($1,$2,$3)", [from, to, bl]))).rows;
const sum = (rows, k) => rows.reduce((a, r) => a + Number(r[k]), 0);

async function seed(db) {
  await bill(db, 1, "2026-10-13", "Alkalmassági vizsgálat", 20000);
  await bill(db, 1, "2026-10-13", "Lézer konzultáció", 5000);
  await bill(db, 2, "2026-10-13", "Alkalmassági vizsgálat", 30000, 2);
  await bill(db, 3, "2026-10-14", "Plasztikai konzultáció", 40000);
  await db.query(`insert into dokirex_service_map(service, business_line) values
    ('Alkalmassági vizsgálat','szemeszet'), ('Lézer konzultáció','szemeszet'), ('Plasztikai konzultáció','eszteika_plasztika')`);
  // Egy foglaláshoz négy lead-sor tartozik ugyanazzal az azonosítóval (éles tapasztalat), a 2-es foglalás nem online.
  for (let i = 0; i < 4; i++) await lead(db, 1);
}

test("összesítés napra, szolgáltatásra és üzletágra; az online rész külön; több lead-sor nem duplázza a bevételt", async () => {
  const { db, tag } = await setup();
  await seed(db);
  const rows = await summary(db, tag);
  const alk = rows.find((r) => r.service === "Alkalmassági vizsgálat");
  assert.equal(alk.business_line, "szemeszet");
  assert.equal(alk.bookings, 2);
  assert.equal(Number(alk.revenue), 50000);
  assert.equal(alk.online_bookings, 1);
  assert.equal(Number(alk.online_revenue), 20000);
  const laser = rows.find((r) => r.service === "Lézer konzultáció");
  assert.equal(Number(laser.online_revenue), 5000);
  assert.equal(sum(rows, "revenue"), 95000);
  assert.equal(sum(rows, "online_revenue"), 25000);
  assert.equal(sum(await summary(db, tag, "szemeszet"), "revenue"), 55000);
  assert.equal(sum(await summary(db, tag, "eszteika_plasztika"), "revenue"), 40000);
  assert.equal(sum(await summary(db, tag, "mind"), "revenue"), 95000);
  assert.equal(sum(await summary(db, tag, null, "2026-10-14", "2026-10-14"), "revenue"), 40000); // dátumszűrés
});

test("besorolatlan szolgáltatás: az összesítésben 'besorolatlan', a szerkesztő listájában megjelenik; a sztornó levonódik", async () => {
  const { db, tag, elemzo } = await setup();
  await seed(db);
  await bill(db, 4, "2026-10-14", "Új szolgáltatás", 1000);
  await bill(db, 5, "2026-10-14", "Alkalmassági vizsgálat", 10000);
  await bill(db, 5, "2026-10-14", "Alkalmassági vizsgálat visszatérítés", -10000);
  const rows = await summary(db, tag);
  const un = rows.find((r) => r.service === "Új szolgáltatás");
  assert.equal(un.business_line, "besorolatlan");
  const un2 = (await as(db, "authenticated", elemzo, () => db.query("select * from mart_dokirex_unmapped_services order by service"))).rows;
  assert.deepEqual(un2.map((r) => [r.service, Number(r.amount), Number(r.bookings)]),
    [["Alkalmassági vizsgálat visszatérítés", -10000, 1], ["Új szolgáltatás", 1000, 1]]);
  assert.equal(sum(rows, "revenue"), 95000 + 1000 + 10000 - 10000);
});

test("fact_booking átvezetés: az előjegyzés összes sora összegződik, a meglévő időpont/állapot megmarad, az újrafuttatás nem ír semmit", async () => {
  const { db } = await setup();
  await bill(db, 10, "2026-10-13", "A", 100);
  await bill(db, 10, "2026-10-14", "B", 50); // ugyanaz az előjegyzés másik napon
  await db.query("insert into fact_booking(dokirex_booking_id, appointment_at, status, revenue, payload) values (11, '2026-10-01T09:30:00Z', 'attended', null, '{\"x\":1}')");
  await bill(db, 11, "2026-10-13", "C", 70);
  const run = async () => Number((await as(db, "service_role", "", () => db.query("select rollup_booking_revenue('2026-10-13','2026-10-13') n"))).rows[0].n);
  assert.equal(await run(), 2);
  const get = async (id) => (await db.query("select revenue, status, appointment_at, (appointment_at at time zone 'Europe/Budapest')::date as d, payload from fact_booking where dokirex_booking_id=$1", [id])).rows[0];
  const a = await get(10);
  assert.equal(Number(a.revenue), 150); // a tartományon kívüli sor is beleszámít
  assert.equal(a.status, "unknown");
  assert.equal(new Date(a.d).toISOString().slice(0, 10), "2026-10-13");
  assert.equal(a.payload.source, "billing");
  const b = await get(11);
  assert.equal(Number(b.revenue), 70);
  assert.equal(b.status, "attended"); // meglévő állapot nem íródik át
  assert.equal(b.appointment_at.toISOString(), "2026-10-01T09:30:00.000Z"); // meglévő időpont nem íródik át
  assert.equal(b.payload.x, 1); // meglévő payload megmarad
  assert.equal(await run(), 0); // idempotens
  await bill(db, 11, "2026-10-13", "D", 30); // utólagos módosítás/új sor
  assert.equal(await run(), 1);
  assert.equal(Number((await get(11)).revenue), 100);
});

test("jogosultság: megtekintő az összesítést látja, a nyers sort nem; szerep nélküli üres; anon nem futtathatja; az átvezetés csak service role-nak; megfeleltetést csak a szerkesztő írhat", async () => {
  const { db, tag, elemzo, nincs } = await setup();
  await seed(db);
  const count = async (uid) => Number((await as(db, "authenticated", uid, () => db.query("select count(*) n from fact_dokirex_billing"))).rows[0].n);
  assert.equal(await count(elemzo), 4);
  assert.equal(await count(tag), 0);
  assert.ok((await summary(db, tag)).length > 0);
  assert.equal((await summary(db, nincs)).length, 0);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from dokirex_revenue_summary('2026-10-13','2026-10-14',null)"));
  await assert.rejects(db.query("select * from fact_dokirex_billing"));
  await db.exec("reset role");
  await assert.rejects(as(db, "authenticated", elemzo, () => db.query("select rollup_booking_revenue('2026-10-13','2026-10-14')")));
  await as(db, "service_role", "", () => db.query("select rollup_booking_revenue('2026-10-13','2026-10-14')"));
  await assert.rejects(as(db, "authenticated", tag, () => db.query("insert into dokirex_service_map(service, business_line) values ('X','szemeszet')")));
  await as(db, "authenticated", elemzo, () => db.query("insert into dokirex_service_map(service, business_line) values ('X','szemeszet')"));
  await assert.rejects(as(db, "authenticated", elemzo, () => db.query("insert into dokirex_service_map(service, business_line) values ('Y','ismeretlen')")));
  await assert.rejects(as(db, "authenticated", elemzo, () => db.query("insert into fact_dokirex_billing(elojegyzes_id, visit_date, service, amount) values (99,'2026-10-13','Z',1)")));
});

test("a migráció újrafuttatható", async () => {
  const { db } = await setup();
  await seed(db);
  await db.exec(sql("0037_dokirex_billing.sql"));
  assert.equal(Number((await db.query("select count(*) n from fact_dokirex_billing")).rows[0].n), 4);
  assert.equal(Number((await db.query("select count(*) n from dokirex_service_map")).rows[0].n), 3);
});
