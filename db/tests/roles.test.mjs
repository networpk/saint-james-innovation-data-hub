import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// Az auth séma helyettesítője (a Lovable Cloudban a Supabase adja): users tábla és auth.uid().
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('peter@lemonshakers.io'), ('viktor@lemonshakers.io'), ('tamas@lemonshakers.io'), ('mas@example.com')`);
  await db.exec(sql("0027_roles.sql"));
  return db;
}
const uid = async (db, email) => (await db.query("select id from auth.users where email=$1", [email])).rows[0].id;
const roles = async (db, email) =>
  (await db.query("select role from user_roles r join auth.users u on u.id=r.user_id where u.email=$1 order by 1", [email])).rows.map((r) => r.role);

test("0027: a meglévő felhasználók elemző jogot kapnak, admin senki", async () => {
  const db = await setup();
  assert.equal((await db.query("select count(*)::int n from user_roles where role='admin'")).rows[0].n, 0);
  assert.equal((await db.query("select count(*)::int n from user_roles where role='elemzo'")).rows[0].n, 4);
  // a migráció újrafuttatható
  await db.exec(sql("0027_roles.sql"));
  assert.equal((await db.query("select count(*)::int n from user_roles")).rows[0].n, 4);
});

test("0028: az első adminok kiosztása naplózódik, és ismételhető", async () => {
  const db = await setup();
  await db.exec(sql("0028_first_admins.sql"));
  assert.deepEqual(await roles(db, "peter@lemonshakers.io"), ["admin", "elemzo"]);
  assert.deepEqual(await roles(db, "viktor@lemonshakers.io"), ["admin", "elemzo"]);
  assert.deepEqual(await roles(db, "tamas@lemonshakers.io"), ["elemzo"]);
  assert.equal((await db.query("select count(*)::int n from role_audit where action='bootstrap'")).rows[0].n, 2);
  await db.exec(sql("0028_first_admins.sql"));
  assert.equal((await db.query("select count(*)::int n from user_roles where role='admin'")).rows[0].n, 2);
  assert.equal((await db.query("select count(*)::int n from role_audit")).rows[0].n, 2);
});

test("0028: admin nélkül hibával áll meg", async () => {
  const db = await setup();
  await db.exec("delete from auth.users where email like '%lemonshakers.io'");
  await assert.rejects(db.exec(sql("0028_first_admins.sql")), /Nem jött létre admin/);
});

test("az utolsó admin nem törölhető és nem fokozható le, de a kettő közül az egyik igen", async () => {
  const db = await setup();
  await db.exec(sql("0028_first_admins.sql"));
  await db.query("delete from user_roles where role='admin' and user_id=$1", [await uid(db, "peter@lemonshakers.io")]);
  await assert.rejects(db.query("delete from user_roles where role='admin' and user_id=$1", [await uid(db, "viktor@lemonshakers.io")]), /utolsó admin/);
  await assert.rejects(db.query("update user_roles set role='megtekinto' where role='admin'"), /utolsó admin/);
  assert.equal((await db.query("select count(*)::int n from user_roles where role='admin'")).rows[0].n, 1);
});

test("a szerepellenőrzők: admin/elemző olvashat leadet, megtekintő és szerep nélküli nem", async () => {
  const db = await setup();
  await db.exec(sql("0028_first_admins.sql"));
  await db.query("delete from user_roles where user_id=$1", [await uid(db, "mas@example.com")]);
  await db.query("insert into user_roles(user_id, role) values ($1, 'megtekinto')", [await uid(db, "tamas@lemonshakers.io")]);
  await db.query("delete from user_roles where user_id=$1 and role='elemzo'", [await uid(db, "tamas@lemonshakers.io")]);
  const f = async (fn, email) => (await db.query(`select public.${fn}($1) v`, [await uid(db, email)])).rows[0].v;
  assert.equal(await f("can_read_leads", "peter@lemonshakers.io"), true);
  assert.equal(await f("can_edit", "viktor@lemonshakers.io"), true);
  assert.equal(await f("can_read_leads", "tamas@lemonshakers.io"), false);
  assert.equal(await f("is_member", "tamas@lemonshakers.io"), true);
  assert.equal(await f("is_member", "mas@example.com"), false);
  assert.equal((await db.query("select public.has_role($1, 'admin') v", [await uid(db, "peter@lemonshakers.io")])).rows[0].v, true);
});
