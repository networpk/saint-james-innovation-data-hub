import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");
const yesterday = new Date(Date.now() - 86_400_000).toISOString().slice(0, 10);

const G_E = "556-030-7472", G_S = "149-137-6230", M = "2060753947612996", CONV = "120249145359870714";

async function setup() {
  const db = new PGlite();
  await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
    grant usage on schema public to anon, authenticated, service_role;
    alter default privileges in schema public grant all on tables to anon, authenticated;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
    grant usage on schema auth to authenticated, service_role;
    insert into auth.users(email) values ('elemzo@x.hu'), ('tag@x.hu');`);
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0027_roles.sql"));
  const uid = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const elemzo = await uid("elemzo@x.hu"), tag = await uid("tag@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'elemzo'), ($2,'megtekinto')", [elemzo, tag]);
  await db.exec(sql("0035_conversion_roles.sql"));
  return { db, elemzo, tag };
}
async function as(db, role, uid, fn) {
  await db.exec(`set role ${role}; select set_config('request.uid', '${uid ?? ""}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const perf = (db, d, platform, account, campaign, leads, adset = "", ad = "") =>
  db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,adset_id,ad_id,spend,impressions,clicks,platform_leads)
    values ($1,$2,$3,$4,$5,$6,1000,100,10,$7)`, [d, platform, account, campaign, adset, ad, leads]);
const act = (db, d, platform, account, campaign, action, conv, all = conv, adset = "", ad = "") =>
  db.query(`insert into fact_conversion_action_daily(date,platform,account_id,campaign_id,adset_id,ad_id,action_name,conversions,all_conversions)
    values ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, [d, platform, account, campaign, adset, ad, action, conv, all]);
const lead = async (db, d, platform, campaign, adset = "", ad = "") =>
  (await db.query("select platform_leads, extra from fact_ad_performance_daily where date=$1 and platform=$2 and campaign_id=$3 and adset_id=$4 and ad_id=$5", [d, platform, campaign, adset, ad])).rows[0];

test("Google (esztétika): csak a Sikeres időpontfoglalás kemény lead, a kattintás soft, a GA4-import duplikátum kimarad", async () => {
  const { db } = await setup();
  await perf(db, "2026-10-14", "google", G_E, "c1", 85, "ag1"); // a platform nyers száma: 23 + 62
  await act(db, "2026-10-14", "google", G_E, "c1", "Sikeres időpontfoglalás", 23, 23, "ag1");
  await act(db, "2026-10-14", "google", G_E, "c1", "Időpontfoglalás kattintás", 62, 62, "ag1");
  await act(db, "2026-10-14", "google", G_E, "c1", "saintjameshungary.hu (web) sikeres_foglalas", 0, 22, "ag1");
  assert.equal(Number((await db.query("select apply_conversion_roles('2026-10-01','2026-10-31') n")).rows[0].n), 1);
  const r = await lead(db, "2026-10-14", "google", "c1", "ag1");
  assert.equal(Number(r.platform_leads), 23);
  assert.equal(Number(r.extra.soft_conversions), 62);
});

test("Google (szemészet): a mai működés megmarad (a Lead a kemény, a soft_conv_foglaljon soft)", async () => {
  const { db } = await setup();
  await perf(db, "2026-10-14", "google", G_S, "s1", 12, "ag1");
  await act(db, "2026-10-14", "google", G_S, "s1", "Lead", 12, 12, "ag1");
  await act(db, "2026-10-14", "google", G_S, "s1", "soft_conv_foglaljon", 0, 40, "ag1");
  await db.query("select apply_conversion_roles('2026-10-01','2026-10-31')");
  assert.equal(Number((await lead(db, "2026-10-14", "google", "s1", "ag1")).platform_leads), 12);
});

test("Meta: a konverziós kampány egyedi pixel-eseménye kemény lead (11 a 0 helyett), a Traffic kampányé soft, a lead-űrlap marad", async () => {
  const { db } = await setup();
  for (const [camp, lead_, custom] of [[CONV, 0, 3], ["traffic", 0, 31], ["leadform", 2, 2]]) {
    await perf(db, "2026-10-16", "meta", M, camp, lead_, "as1", "ad1");
    if (lead_) await act(db, "2026-10-16", "meta", M, camp, "actions_lead", lead_, lead_, "as1", "ad1");
    await act(db, "2026-10-16", "meta", M, camp, "actions_offsite_conversion_fb_pixel_custom", custom, custom, "as1", "ad1");
  }
  await db.query("select apply_conversion_roles('2026-10-01','2026-10-31')");
  assert.equal(Number((await lead(db, "2026-10-16", "meta", CONV, "as1", "ad1")).platform_leads), 3);
  const t = await lead(db, "2026-10-16", "meta", "traffic", "as1", "ad1");
  assert.equal(Number(t.platform_leads), 0);
  assert.equal(Number(t.extra.soft_conversions), 31);
  const f = await lead(db, "2026-10-16", "meta", "leadform", "as1", "ad1");
  assert.equal(Number(f.platform_leads), 2);
  assert.equal(Number(f.extra.soft_conversions), 2);
});

test("ahol nincs műveleti adat, a sor változatlan; a tartományon kívüli napot nem érinti; az újrafuttatás nem módosít semmit", async () => {
  const { db } = await setup();
  await perf(db, "2026-10-14", "tiktok", "t1", "tt1", 9); // TikTok: nincs műveleti bontás
  await perf(db, "2026-10-13", "google", G_E, "c1", 5, "ag1"); // nincs műveleti adat azon a napon
  await perf(db, "2026-09-01", "google", G_E, "c1", 85, "ag1"); // tartományon kívül
  await act(db, "2026-09-01", "google", G_E, "c1", "Sikeres időpontfoglalás", 23, 23, "ag1");
  await perf(db, "2026-10-15", "google", G_E, "c2", 62, "ag1");
  await act(db, "2026-10-15", "google", G_E, "c2", "Időpontfoglalás kattintás", 62, 62, "ag1");
  const n1 = Number((await db.query("select apply_conversion_roles('2026-10-01','2026-10-31') n")).rows[0].n);
  assert.equal(n1, 1);
  assert.equal(Number((await lead(db, "2026-10-14", "tiktok", "tt1")).platform_leads), 9);
  assert.equal(Number((await lead(db, "2026-10-13", "google", "c1", "ag1")).platform_leads), 5);
  assert.equal(Number((await lead(db, "2026-09-01", "google", "c1", "ag1")).platform_leads), 85);
  assert.equal(Number((await lead(db, "2026-10-15", "google", "c2", "ag1")).platform_leads), 0); // csak soft: a kemény 0
  assert.equal(Number((await db.query("select apply_conversion_roles('2026-10-01','2026-10-31') n")).rows[0].n), 0);
});

test("szabály-erősség: a kampány-szintű szabály erősebb a fiók-szintűnél, és az az általánosnál; ismeretlen művelet soft és a besorolatlanok között jelenik meg", async () => {
  const { db } = await setup();
  await act(db, yesterday, "google", G_E, "c1", "Időpontfoglalás kattintás", 5, 5);
  await act(db, yesterday, "google", G_E, "c2", "Időpontfoglalás kattintás", 7, 7);
  await db.query("insert into conversion_action_map(platform,account_id,campaign_id,action_name,role) values ('google',$1,'c1','Időpontfoglalás kattintás','hard')", [G_E]);
  const roles = Object.fromEntries((await db.query("select campaign_id, role from conversion_action_resolved where action_name='Időpontfoglalás kattintás' order by 1")).rows.map((r) => [r.campaign_id, r.role]));
  assert.deepEqual(roles, { c1: "hard", c2: "soft" });
  await act(db, yesterday, "google", G_E, "c1", "Új, ismeretlen művelet", 4, 4);
  const un = (await db.query("select action_name, role from conversion_action_resolved where action_name='Új, ismeretlen művelet'")).rows[0];
  assert.equal(un.role, "soft");
  const list = (await db.query("select action_name, conversions from mart_unmapped_conversion_actions")).rows;
  assert.deepEqual(list.map((r) => r.action_name), ["Új, ismeretlen művelet"]);
  const split = (await db.query("select hard_conversions, soft_conversions, all_conversions from mart_conversion_split_daily where campaign_id='c1'")).rows[0];
  assert.deepEqual([Number(split.hard_conversions), Number(split.soft_conversions), Number(split.all_conversions)], [5, 4, 9]);
});

test("jogosultság: tag olvas, nem ír; elemző a szerepeket szerkesztheti; az alkalmazás csak a service role-nak futtatható; anon semmit", async () => {
  const { db, elemzo, tag } = await setup();
  assert.ok((await as(db, "authenticated", tag, () => db.query("select * from conversion_action_map"))).rows.length >= 9);
  await as(db, "authenticated", tag, () => db.query("select * from fact_conversion_action_daily"));
  await assert.rejects(as(db, "authenticated", tag, () => db.query("insert into conversion_action_map(platform,action_name,role) values ('meta','x','soft')")));
  await assert.rejects(as(db, "authenticated", tag, () => db.query("insert into fact_conversion_action_daily(date,platform,account_id,campaign_id,action_name) values ('2026-10-01','meta','a','c','x')")));
  await as(db, "authenticated", elemzo, () => db.query("insert into conversion_action_map(platform,action_name,role) values ('meta','x','soft')"));
  await assert.rejects(as(db, "authenticated", elemzo, () => db.query("select apply_conversion_roles('2026-10-01','2026-10-31')")));
  await as(db, "service_role", "", () => db.query("select apply_conversion_roles('2026-10-01','2026-10-31')"));
  await assert.rejects(as(db, "anon", "", () => db.query("select * from conversion_action_map")));
  await assert.rejects(as(db, "anon", "", () => db.query("select * from mart_conversion_split_daily")));
});

test("a migráció újrafuttatható: a kezdeti szerepek nem duplázódnak", async () => {
  const { db } = await setup();
  const count = async () => Number((await db.query("select count(*) n from conversion_action_map")).rows[0].n);
  const first = await count();
  assert.equal(first, 9);
  await db.exec(sql("0035_conversion_roles.sql"));
  assert.equal(await count(), first);
});
