import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");
// az érintett táblák listája a migráció ellenőrző blokkjából
const TABLES = [...sql("0030_rls_tighten.sql").match(/tablename in \(([^)]*)\)/s)[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
const LEAD = ["fact_lead", "fact_lead_event", "fact_quiz_session", "fact_booking", "fact_ac_contact", "fact_ac_contact_automation", "raw_windsor"];
const EDIT = ["campaign_mapping", "kpi_target", "topic"];

async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    alter default privileges in schema public grant all on tables to authenticated;
    insert into auth.users(email) values ('admin@x.hu'), ('elemzo@x.hu'), ('megtekinto@x.hu'), ('szerep-nelkul@x.hu')`);
  await db.exec(sql("0027_roles.sql"));
  await db.exec("delete from user_roles");
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  await db.query("insert into user_roles(user_id, role) values ($1,'admin'),($2,'elemzo'),($3,'megtekinto')", [await id("admin@x.hu"), await id("elemzo@x.hu"), await id("megtekinto@x.hu")]);
  // a régi állapot: minden táblán „mindenki" szabály, eltérő nevekkel (ahogy az élő adatbázisban)
  for (const t of TABLES) {
    await db.exec(`create table public.${t} (id int default 1, user_id uuid default auth.uid());
      alter table public.${t} enable row level security;
      create policy "auth read ${t}" on public.${t} for select to authenticated using (true);
      create policy "${t}_select_auth" on public.${t} for select to authenticated using (true);
      create policy "weird old name ${t}" on public.${t} for all to authenticated using (true) with check (true);
      insert into public.${t} default values`);
  }
  await db.exec(`create table public.assistant_conversation (user_id uuid); alter table public.assistant_conversation enable row level security;
    create policy conv_owner_all on public.assistant_conversation for all to authenticated using (user_id = auth.uid());
    create table public.lead_journey (day date, lead_type text, submitted boolean, outcome text, business_line text);
    insert into public.lead_journey values ('2026-10-01','idopontfoglalas',true,'foglalt','szemeszet'),('2026-10-01','idopontfoglalas',false,'felbehagyta','szemeszet'),
      ('2026-10-01','alkalmassagi',true,'adatok_elkuldve','eszteika_plasztika');
    create function public.alerts_mark_notified(ids bigint[]) returns void language sql as $$ select 1 $$;
    grant execute on function public.alerts_mark_notified(bigint[]) to authenticated`);
  return { db, id };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const count = async (db, uid, t) => (await as(db, uid, () => db.query(`select count(*)::int n from public.${t}`))).rows[0].n;

test("admin nélkül a szigorítás nem fut le", async () => {
  const { db } = await setup();
  await db.exec("delete from user_roles where role='admin'").catch(() => {});
  // az utolsó admin védelme miatt a törlés elbukhat: ilyenkor a szerepeket új, admin nélküli állapotra állítjuk
  await db.exec("alter table user_roles disable trigger user_roles_last_admin; delete from user_roles where role='admin'");
  await assert.rejects(db.exec(sql("0030_rls_tighten.sql")), /Nincs admin/);
});

test("szigorítás: a megtekintő nem lát lead-szintű adatot, a szerep nélküli semmit; a régi nyitott szabályok eltűnnek", async () => {
  const { db, id } = await setup();
  await db.exec(sql("0030_rls_tighten.sql"));
  const [a, e, m, n] = [await id("admin@x.hu"), await id("elemzo@x.hu"), await id("megtekinto@x.hu"), await id("szerep-nelkul@x.hu")];
  for (const t of LEAD) {
    assert.equal(await count(db, a, t), 1, `admin ${t}`);
    assert.equal(await count(db, e, t), 1, `elemzo ${t}`);
    assert.equal(await count(db, m, t), 0, `megtekinto ${t}`);
    assert.equal(await count(db, n, t), 0, `szerep nélkül ${t}`);
  }
  for (const t of ["fact_ad_performance_daily", "dim_ad", "alert_rule", "ingestion_run"]) {
    assert.equal(await count(db, m, t), 1, `megtekinto ${t}`);
    assert.equal(await count(db, n, t), 0, `szerep nélkül ${t}`);
  }
  const open = await db.query("select tablename, policyname from pg_policies where schemaname='public' and (qual='true' or with_check='true')");
  assert.deepEqual(open.rows, []);
});

test("írás: megtekintő és szerep nélküli nem írhat, elemző igen, riasztásszabályt csak admin", async () => {
  const { db, id } = await setup();
  await db.exec(sql("0030_rls_tighten.sql"));
  const [a, e, m] = [await id("admin@x.hu"), await id("elemzo@x.hu"), await id("megtekinto@x.hu")];
  for (const t of EDIT) {
    await assert.rejects(as(db, m, () => db.query(`insert into public.${t} default values`)), /row-level security/, `megtekinto ${t}`);
    await as(db, e, () => db.query(`insert into public.${t} default values`));
  }
  await assert.rejects(as(db, e, () => db.query("insert into public.alert_rule default values")), /row-level security/);
  await as(db, a, () => db.query("insert into public.alert_rule default values"));
});

test("overview_lead_counts: csak összesítés, tagnak; szerep nélkülinek üres; a megtekintő a lead-táblát közvetlenül nem éri el", async () => {
  const { db, id } = await setup();
  await db.exec(sql("0030_rls_tighten.sql"));
  const [m, n] = [await id("megtekinto@x.hu"), await id("szerep-nelkul@x.hu")];
  const q = (u, bl) => as(db, u, () => db.query("select * from overview_lead_counts('2026-10-01','2026-10-02',$1)", [bl]));
  const all = (await q(m, "mind")).rows;
  assert.equal(all.length, 1);
  assert.deepEqual({ s: all[0].submitted, q: all[0].suitability, st: all[0].started, b: all[0].booked }, { s: 1, q: 1, st: 1, b: 1 });
  assert.equal((await q(m, "szemeszet")).rows[0].suitability, 0);
  assert.equal((await q(n, "mind")).rows.length, 0);
  await assert.rejects(as(db, m, () => db.query("select alerts_mark_notified('{1}')")), /permission denied/);
  await assert.rejects(db.exec("set role anon; select * from overview_lead_counts('2026-10-01','2026-10-02')").finally(() => db.exec("reset role")), /permission denied/);
});

test("a szigorító migráció újrafuttatható", async () => {
  const { db } = await setup();
  await db.exec(sql("0030_rls_tighten.sql"));
  await db.exec(sql("0030_rls_tighten.sql"));
});
