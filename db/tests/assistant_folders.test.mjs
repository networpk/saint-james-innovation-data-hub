import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A Hub meglévő táblái és az auth séma helyettesítője.
async function setup(withData = true) {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    create table public.assistant_conversation (id uuid primary key default gen_random_uuid(), user_id uuid not null, title text, created_at timestamptz not null default now());
    create table public.assistant_message (id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.assistant_conversation(id) on delete cascade, role text, content text, created_at timestamptz not null default now());
    alter table public.assistant_conversation enable row level security;
    create policy conv_owner_all on public.assistant_conversation for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
    grant all on public.assistant_conversation, public.assistant_message to authenticated;
    insert into auth.users(email) values ('a@x.hu'), ('b@x.hu')`);
  const id = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const a = await id("a@x.hu"), b = await id("b@x.hu");
  if (withData) {
    await db.query(`insert into assistant_conversation(id, user_id, title, created_at) values
      ('00000000-0000-0000-0000-0000000000a1', $1, 'Régi, de később használt', '2026-09-01 10:00+00'),
      ('00000000-0000-0000-0000-0000000000a2', $1, 'Üres', '2026-09-02 10:00+00')`, [a]);
    await db.query(`insert into assistant_message(conversation_id, role, content, created_at) values
      ('00000000-0000-0000-0000-0000000000a1', 'user', 'k', '2026-09-03 10:00+00'), ('00000000-0000-0000-0000-0000000000a1', 'assistant', 'v', '2026-09-05 12:00+00')`);
  }
  await db.exec(sql("0032_assistant_folders.sql"));
  return { db, a, b };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const A1 = "00000000-0000-0000-0000-0000000000a1";

test("kitöltés: az utolsó aktivitás az utolsó üzenet ideje, üres beszélgetésnél a létrehozás", async () => {
  const { db } = await setup();
  const r = (await db.query("select id, last_activity_at at from assistant_conversation order by id")).rows;
  assert.equal(new Date(r[0].at).toISOString(), "2026-09-05T12:00:00.000Z");
  assert.equal(new Date(r[1].at).toISOString(), "2026-09-02T10:00:00.000Z");
});

test("új üzenet a régi beszélgetést a lista elejére hozza", async () => {
  const { db, a } = await setup();
  await as(db, a, () => db.query("insert into assistant_message(conversation_id, role, content) values ($1,'user','új kérdés')", [A1]));
  const top = (await as(db, a, () => db.query("select title from assistant_conversation order by last_activity_at desc limit 1"))).rows[0];
  assert.equal(top.title, "Régi, de később használt");
  assert.ok(new Date((await db.query("select last_activity_at at from assistant_conversation where id=$1", [A1])).rows[0].at) > new Date("2026-10-01"));
});

test("mappák: egymásba ágyazhatók, körkörös és túl mély beágyazás tiltott, azonos szinten nincs azonos név", async () => {
  const { db, a } = await setup();
  const f = async (name, parent) => (await as(db, a, () => db.query("insert into assistant_folder(user_id, parent_id, name) values ($1,$2,$3) returning id", [a, parent, name]))).rows[0].id;
  const f1 = await f("Kampányok", null), f2 = await f("2026", f1), f3 = await f("Szeptember", f2);
  await assert.rejects(as(db, a, () => db.query("update assistant_folder set parent_id=$1 where id=$2", [f3, f1])), /saját almappájába/);
  await assert.rejects(as(db, a, () => db.query("update assistant_folder set parent_id=id where id=$1", [f1])), /saját szülője/);
  await assert.rejects(f("kampányok", null), /unique|duplicate/);
  assert.ok(await f("Kampányok", f2)); // más szülő alatt lehet azonos név
  let p = f3; for (let i = 0; i < 3; i++) p = await f("m" + i, p);
  await assert.rejects(f("túl mély", p), /6 szint/);
});

test("mappa törlése: az almappák és a beszélgetések a szülőbe kerülnek, nem törlődnek", async () => {
  const { db, a } = await setup();
  const f = async (name, parent) => (await as(db, a, () => db.query("insert into assistant_folder(user_id, parent_id, name) values ($1,$2,$3) returning id", [a, parent, name]))).rows[0].id;
  const top = await f("Felső", null), mid = await f("Közép", top), low = await f("Alsó", mid);
  await as(db, a, () => db.query("update assistant_conversation set folder_id=$1 where id=$2", [mid, A1]));
  await as(db, a, () => db.query("delete from assistant_folder where id=$1", [mid]));
  assert.equal((await db.query("select parent_id p from assistant_folder where id=$1", [low])).rows[0].p, top);
  assert.equal((await db.query("select folder_id p from assistant_conversation where id=$1", [A1])).rows[0].p, top);
  await as(db, a, () => db.query("delete from assistant_folder where id=$1", [top]));
  assert.equal((await db.query("select parent_id p from assistant_folder where id=$1", [low])).rows[0].p, null);
  assert.equal((await db.query("select folder_id p from assistant_conversation where id=$1", [A1])).rows[0].p, null);
  assert.equal((await db.query("select count(*)::int n from assistant_conversation")).rows[0].n, 2);
});

test("a mappák személyesek: más mappájába nem lehet tenni, mást nem látni, anonim nem fér hozzá", async () => {
  const { db, a, b } = await setup();
  const fa = (await as(db, a, () => db.query("insert into assistant_folder(user_id, name) values ($1,'Enyém') returning id", [a]))).rows[0].id;
  assert.equal((await as(db, b, () => db.query("select * from assistant_folder"))).rows.length, 0);
  await assert.rejects(as(db, b, () => db.query("insert into assistant_folder(user_id, name) values ($1,'Hamis')", [a])), /row-level security/);
  await assert.rejects(as(db, b, () => db.query("insert into assistant_folder(user_id, parent_id, name) values ($1,$2,'Idegen alá')", [b, fa])), /szülő mappa/);
  await db.query("insert into assistant_conversation(id, user_id, title) values ('00000000-0000-0000-0000-0000000000b1', $1, 'B beszélgetése')", [b]);
  await assert.rejects(as(db, b, () => db.query("update assistant_conversation set folder_id=$1 where id='00000000-0000-0000-0000-0000000000b1'", [fa])), /mappa nem található/);
  assert.equal((await db.query("select has_table_privilege('anon','public.assistant_folder','SELECT') s")).rows[0].s, false);
});

test("újrafuttatható", async () => {
  const { db } = await setup();
  await db.exec(sql("0032_assistant_folders.sql"));
});
