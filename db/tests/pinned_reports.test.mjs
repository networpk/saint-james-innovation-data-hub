import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// Az auth séma és az assistant_message helyettesítője (a Lovable Cloudban léteznek).
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    create table public.assistant_message (id uuid primary key default gen_random_uuid());
    insert into auth.users(email) values ('admin@x.hu'), ('elemzo@x.hu'), ('megtekinto@x.hu'), ('szerep-nelkul@x.hu')`);
  await db.exec(sql("0027_roles.sql"));
  await db.exec("delete from user_roles");
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  await db.query("insert into user_roles(user_id, role) values ($1,'admin'),($2,'elemzo'),($3,'megtekinto')", [await id("admin@x.hu"), await id("elemzo@x.hu"), await id("megtekinto@x.hu")]);
  await db.exec(sql("0029_pinned_reports.sql"));
  return { db, id };
}
// Lekérdezés egy bejelentkezett felhasználó nevében (RLS érvényes).
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}

test("0029: újrafuttatható, anon nem fér hozzá", async () => {
  const { db } = await setup();
  await db.exec(sql("0029_pinned_reports.sql"));
  const r = await db.query("select has_table_privilege('anon','public.pinned_report','SELECT') s");
  assert.equal(r.rows[0].s, false);
});

test("személyes jelentés: csak a tulajdonos látja, megosztottá tenni önmaga nem tudja", async () => {
  const { db, id } = await setup();
  const [a, e] = [await id("admin@x.hu"), await id("elemzo@x.hu")];
  await as(db, e, () => db.query("insert into pinned_report(owner_id, title, tool) values ($1,'Saját','get_campaigns')", [e]));
  assert.equal((await as(db, e, () => db.query("select * from pinned_report"))).rows.length, 1);
  assert.equal((await as(db, a, () => db.query("select * from pinned_report"))).rows.length, 0);
  await assert.rejects(as(db, e, () => db.query("insert into pinned_report(owner_id, scope, title, tool) values ($1,'shared','Hamis','get_campaigns')", [e])), /row-level security/);
  await assert.rejects(as(db, e, () => db.query("update pinned_report set scope='shared'")), /row-level security/);
});

test("megosztott jelentés: csak admin hozhat létre, a megtekintő a nem lead-szintűt látja, a szerep nélküli semmit", async () => {
  const { db, id } = await setup();
  const [a, e, m, n] = [await id("admin@x.hu"), await id("elemzo@x.hu"), await id("megtekinto@x.hu"), await id("szerep-nelkul@x.hu")];
  await as(db, a, () => db.query(`insert into pinned_report(owner_id, scope, title, tool, lead_level) values
    ($1,'shared','Kampányok','get_campaigns', false), ($1,'shared','Leadek','get_overview', true)`, [a]));
  await assert.rejects(as(db, e, () => db.query("insert into pinned_report(owner_id, scope, title, tool) values ($1,'shared','X','get_campaigns')", [e])), /row-level security/);
  const titles = async (u) => (await as(db, u, () => db.query("select title from pinned_report order by title"))).rows.map((r) => r.title);
  assert.deepEqual(await titles(m), ["Kampányok"]);
  assert.deepEqual(await titles(e), ["Kampányok", "Leadek"]);
  assert.deepEqual(await titles(n), []);
  // a nem admin a megosztottat nem törölheti és nem írhatja át
  await as(db, e, () => db.query("delete from pinned_report where scope='shared'"));
  assert.equal((await db.query("select count(*)::int n from pinned_report")).rows[0].n, 2);
});

test("a személyes sorrend csak a sajátja, és a jelentés törlésekor a sorrend-sor is törlődik", async () => {
  const { db, id } = await setup();
  const [a, m] = [await id("admin@x.hu"), await id("megtekinto@x.hu")];
  const rid = (await db.query("insert into pinned_report(owner_id, scope, title, tool) values ($1,'shared','K','get_campaigns') returning id", [a])).rows[0].id;
  await as(db, m, () => db.query("insert into pinned_report_order(user_id, report_id, position, hidden) values ($1,$2,3,true)", [m, rid]));
  await assert.rejects(as(db, m, () => db.query("insert into pinned_report_order(user_id, report_id, position) values ($1,$2,1)", [a, rid])), /row-level security/);
  assert.equal((await as(db, a, () => db.query("select * from pinned_report_order"))).rows.length, 0);
  await db.query("delete from pinned_report where id=$1", [rid]);
  assert.equal((await db.query("select count(*)::int n from pinned_report_order")).rows[0].n, 0);
});

test("0031: táblázat-pillanatkép: a kind és a kötelező tartalom ellenőrizve, a meglévő jelentések élők maradnak, újrafuttatható", async () => {
  const { db, id } = await setup();
  const a = await id("admin@x.hu");
  await db.query("insert into pinned_report(owner_id, title, tool) values ($1,'Régi','get_campaigns')", [a]);
  await db.exec(sql("0031_pinned_table_snapshot.sql"));
  await db.exec(sql("0031_pinned_table_snapshot.sql"));
  assert.equal((await db.query("select kind from pinned_report")).rows[0].kind, "live");
  await db.query(`insert into pinned_report(owner_id, title, kind, snapshot) values ($1,'Tábla','table','{"columns":["a"],"rows":[["1"]]}')`, [a]);
  await assert.rejects(db.query("insert into pinned_report(owner_id, title, kind) values ($1,'Üres tábla','table')", [a]), /kind_payload_check/);
  await assert.rejects(db.query("insert into pinned_report(owner_id, title, kind) values ($1,'Élő eszköz nélkül','live')", [a]), /kind_payload_check/);
  await assert.rejects(db.query("insert into pinned_report(owner_id, title, kind, tool) values ($1,'Hibás','mas','x')", [a]), /kind_check/);
  // a megosztott táblázat lead-szintű jelzése az RLS-ben is érvényes (megtekintő nem látja)
  const m = await id("megtekinto@x.hu");
  await db.query(`insert into pinned_report(owner_id, scope, title, kind, snapshot, lead_level) values ($1,'shared','Lead tábla','table','{"rows":[]}', true), ($1,'shared','Nyílt tábla','table','{"rows":[]}', false)`, [a]);
  const seen = (await as(db, m, () => db.query("select title from pinned_report order by title"))).rows.map((r) => r.title);
  assert.deepEqual(seen, ["Nyílt tábla"]);
});
