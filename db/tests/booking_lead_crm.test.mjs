import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const crm = fs.readFileSync(new URL("../../integrations/booking-app/0003_lead_crm.sql", import.meta.url), "utf8");

// A foglaló alkalmazás meglévő tábláinak és az auth sémának a helyettesítője.
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    create type public.app_role as enum ('admin','staff','viewer');
    create table public.user_roles (id uuid primary key default gen_random_uuid(), user_id uuid not null, role public.app_role not null);
    create table public.profiles (id uuid primary key, email text, full_name text);
    create table public.leads (id uuid primary key default gen_random_uuid(), name text, phone text, email text, created_at timestamptz default now(),
      source text, booking_details jsonb, booking_stage text, business_line text, dokirex_booking_id bigint);
    alter table public.leads enable row level security;
    create policy leads_read on public.leads for select to authenticated using (true);
    grant select on public.leads to authenticated;
    insert into auth.users(email) values ('admin@x.hu'), ('recepcio@x.hu'), ('nezo@x.hu')`);
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const [a, s, v] = [await id("admin@x.hu"), await id("recepcio@x.hu"), await id("nezo@x.hu")];
  await db.query("insert into user_roles(user_id, role) values ($1,'admin'),($2,'staff'),($3,'viewer')", [a, s, v]);
  await db.query("insert into profiles values ($1,'admin@x.hu',null), ($2,'recepcio@x.hu','Kiss Réka')", [a, s]);
  await db.exec(`insert into leads(id, name, phone, email, booking_stage, booking_details, dokirex_booking_id) values
    ('00000000-0000-0000-0000-000000000001','Teszt Egy','+361111','egy@x.hu','completed','{"treatment":"Lézer","date":"2026-10-20"}', null),
    ('00000000-0000-0000-0000-000000000002','Teszt Kettő','+362222','ketto@x.hu','completed','{}', 777),
    ('00000000-0000-0000-0000-000000000003','Vázlat','+363333','vazlat@x.hu','contact','{}', null)`);
  await db.exec(crm);
  return { db, a, s, v };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const L1 = "00000000-0000-0000-0000-000000000001";

test("15 státusz, újrafuttatható", async () => {
  const { db } = await setup();
  await db.exec(crm);
  assert.equal((await db.query("select count(*)::int n from lead_status")).rows[0].n, 15);
  assert.equal((await db.query("select count(*)::int n from lead_status where category='beirva'")).rows[0].n, 7);
});

test("a hívási lista csak az elküldött leadeket mutatja, e-mail nélkül, recepciósnak és adminnak", async () => {
  const { db, a, s, v } = await setup();
  for (const u of [a, s]) {
    const r = (await as(db, u, () => db.query("select * from lead_call_list order by name"))).rows;
    assert.deepEqual(r.map((x) => x.name), ["Teszt Egy", "Teszt Kettő"]);
    assert.equal("email" in r[0], false);
    assert.equal(r[0].status_key, null);
    assert.equal(r[1].has_dokirex_booking, true);
    assert.equal(r[0].treatment, "Lézer");
  }
  assert.equal((await as(db, v, () => db.query("select * from lead_call_list"))).rows.length, 0);
  await assert.rejects(db.exec("set role anon; select * from lead_call_list").finally(() => db.exec("reset role")), /permission denied/);
});

test("státusz beállítása: a recepciós állíthatja, a név a profilból jön, az előzmény naplózódik, ismétlés frissít", async () => {
  const { db, s } = await setup();
  await as(db, s, () => db.query("select * from set_lead_status($1,'hivva_1','nem vette fel',null)", [L1]));
  await as(db, s, () => db.query("select * from set_lead_status($1,'hivva_2',null,'2026-10-09 10:00+00')", [L1]));
  await as(db, s, () => db.query("select * from set_lead_status($1,'beirva_lezer','Beírtam 10/20-ra',null)", [L1]));
  const row = (await as(db, s, () => db.query("select * from lead_call_list where lead_id=$1", [L1]))).rows[0];
  assert.equal(row.status_key, "beirva_lezer");
  assert.equal(row.status_label, "Lézerre beírva");
  assert.equal(row.is_open, false);
  assert.equal(row.updated_by_name, "Kiss Réka");
  assert.equal(row.note, "Beírtam 10/20-ra");
  assert.equal((await db.query("select count(*)::int n from lead_crm")).rows[0].n, 1);
  const log = (await as(db, s, () => db.query("select from_status, to_status, user_name, note from lead_crm_log where lead_id=$1 order by id", [L1]))).rows;
  assert.deepEqual(log.map((l) => `${l.from_status}>${l.to_status}`), ["null>hivva_1", "hivva_1>hivva_2", "hivva_2>beirva_lezer"]);
  assert.equal(log[0].user_name, "Kiss Réka");
});

test("védelmek: megtekintő és anonim nem állíthat, ismeretlen státusz, vázlat lead és hosszú megjegyzés elutasítva, közvetlen írás tiltott", async () => {
  const { db, a, s, v } = await setup();
  await assert.rejects(as(db, v, () => db.query("select * from set_lead_status($1,'hivva_1')", [L1])), /nincs jogosultságod/);
  await assert.rejects(db.exec(`set role anon; select * from set_lead_status('${L1}','hivva_1')`).finally(() => db.exec("reset role")), /permission denied/);
  await assert.rejects(as(db, s, () => db.query("select * from set_lead_status($1,'valami')", [L1])), /Ismeretlen/);
  await assert.rejects(as(db, s, () => db.query("select * from set_lead_status('00000000-0000-0000-0000-000000000003','hivva_1')")), /nem található/);
  await assert.rejects(as(db, a, () => db.query("select * from set_lead_status($1,'hivva_1',$2)", [L1, "x".repeat(2001)])), /2000/);
  await assert.rejects(as(db, s, () => db.query("insert into lead_crm(lead_id, status_key) values ($1,'hivva_1')", [L1])), /permission denied/);
  await assert.rejects(as(db, s, () => db.query("update lead_crm set status_key='nem_alkalmas'")), /permission denied/);
  await assert.rejects(as(db, s, () => db.query("delete from lead_crm_log")), /permission denied/);
});

test("a napló olvasható recepciósnak, megtekintőnek nem; a lead törlése törli a státuszt és a naplót", async () => {
  const { db, a, s, v } = await setup();
  await as(db, s, () => db.query("select * from set_lead_status($1,'hivva_1')", [L1]));
  assert.equal((await as(db, s, () => db.query("select * from lead_crm_log"))).rows.length, 1);
  assert.equal((await as(db, v, () => db.query("select * from lead_crm_log"))).rows.length, 0);
  assert.equal((await as(db, a, () => db.query("select * from lead_status"))).rows.length, 15);
  await db.query("delete from leads where id=$1", [L1]);
  assert.equal((await db.query("select count(*)::int n from lead_crm")).rows[0].n + (await db.query("select count(*)::int n from lead_crm_log")).rows[0].n, 0);
});
