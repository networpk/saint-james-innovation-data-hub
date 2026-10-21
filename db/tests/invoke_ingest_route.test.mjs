import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");

// A pg_net helyettesítője: a hívást egy táblába naplózza. A 0039 előtti függvény (a 'ingest-dokirex' nélküli fehérlistával) ugyanaz, mint az éles.
async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    create table public.private_settings (key text primary key, value text);
    insert into public.private_settings values ('ingest_base_url', 'https://hub.example/api/public/'), ('ingest_secret', 's3cr3t');
    create table public.net_calls (id serial primary key, url text, headers jsonb, body jsonb, timeout_ms integer);
    create schema net;
    create function net.http_post(url text, headers jsonb default '{}'::jsonb, body jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
      returns bigint language plpgsql as $$ declare i integer; begin
        insert into public.net_calls(url, headers, body, timeout_ms) values (url, headers, body, timeout_milliseconds) returning id into i; return i; end $$;
    create or replace function public.invoke_ingest(p_route text, p_body jsonb default '{}'::jsonb)
    returns bigint language plpgsql security definer set search_path to 'public' as $f$
    declare v_base text; v_secret text;
    begin
      if p_route not in ('ingest-ads','ingest-web','ingest-google-search','ingest-ads-dim','ingest-breakdowns','ingest-leads','ingest-ac','ingest-seo','ingest-alerts','ingest-social') then
        raise exception 'unknown ingest route %', p_route;
      end if;
      select value into v_base from public.private_settings where key = 'ingest_base_url';
      select value into v_secret from public.private_settings where key = 'ingest_secret';
      if v_base is null or v_secret is null then raise exception 'ingest_base_url or ingest_secret missing'; end if;
      return net.http_post(url := rtrim(v_base, '/') || '/' || p_route,
        headers := jsonb_build_object('Content-Type','application/json','x-ingest-secret', v_secret),
        body := p_body, timeout_milliseconds := 150000);
    end $f$;
    revoke execute on function public.invoke_ingest(text, jsonb) from public, anon, authenticated;
    grant execute on function public.invoke_ingest(text, jsonb) to service_role;`);
  return db;
}
const call = (db, route, body = "{}") => db.query("select public.invoke_ingest($1, $2::jsonb) as id", [route, body]);

test("0039 előtt az 'ingest-dokirex' útvonalat a függvény elutasítja, utána átmegy", async () => {
  const db = await setup();
  await assert.rejects(call(db, "ingest-dokirex"), /unknown ingest route/);
  await db.exec(sql("0039_invoke_ingest_dokirex.sql"));
  const r = await call(db, "ingest-dokirex", '{"from":"2026-07-01"}');
  assert.ok(Number(r.rows[0].id) > 0);
  const c = (await db.query("select * from net_calls")).rows[0];
  assert.equal(c.url, "https://hub.example/api/public/ingest-dokirex");
  assert.equal(c.headers["x-ingest-secret"], "s3cr3t");
  assert.deepEqual(c.body, { from: "2026-07-01" });
  assert.equal(c.timeout_ms, 150000);
});

test("a meglévő útvonalak változatlanok, ismeretlen útvonal továbbra is hiba", async () => {
  const db = await setup();
  await db.exec(sql("0039_invoke_ingest_dokirex.sql"));
  for (const route of ["ingest-ads", "ingest-web", "ingest-google-search", "ingest-ads-dim", "ingest-breakdowns", "ingest-leads", "ingest-ac", "ingest-seo", "ingest-alerts", "ingest-social"]) {
    await call(db, route);
  }
  assert.equal(Number((await db.query("select count(*) n from net_calls")).rows[0].n), 10);
  await assert.rejects(call(db, "ingest-valami"), /unknown ingest route/);
  await assert.rejects(call(db, "ingest-dokirex; drop table x"), /unknown ingest route/);
});

test("jogosultság: anon és authenticated nem hívhatja, a service_role igen; a migráció újrafuttatható", async () => {
  const db = await setup();
  await db.exec(sql("0039_invoke_ingest_dokirex.sql"));
  await db.exec(sql("0039_invoke_ingest_dokirex.sql"));
  for (const role of ["anon", "authenticated"]) {
    await db.exec(`set role ${role}`);
    await assert.rejects(call(db, "ingest-dokirex"));
    await db.exec("reset role");
  }
  await db.exec("set role service_role");
  await call(db, "ingest-dokirex");
  await db.exec("reset role");
});

test("hiányzó beállítás esetén hiba (nincs csendes hívás)", async () => {
  const db = await setup();
  await db.exec(sql("0039_invoke_ingest_dokirex.sql"));
  await db.exec("delete from private_settings where key='ingest_secret'");
  await assert.rejects(call(db, "ingest-dokirex"), /ingest_base_url or ingest_secret missing/);
});
