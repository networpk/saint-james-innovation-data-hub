import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");
const day = (i) => new Date(Date.UTC(2026, 9, 1 + i)).toISOString().slice(0, 10); // 2026-10-01 + i

// Az éles campaign_mapping_rule tartalma a 0034 előtt (audit, 2026-10-16): a besorolási próba ezekre épül.
const BL = "eszteika_plasztika";
const E = "Esztétika / plasztika";
const LIVE_RULES = [
  [10, null, "556-030-7472", null, null, BL, null, null],
  [11, null, "149-137-6230", null, null, "szemeszet", null, null],
  [12, "meta", null, "SAINTJAMESHUNGARY%", null, BL, null, null],
  [13, null, null, "LASSJOL%", null, "szemeszet", null, null],
  [14, null, null, "Lássjól%", null, "szemeszet", null, null],
  [30, null, null, "%SMILE%", "szemeszet", null, "SMILE", "SMILE"],
  [31, null, null, "%ONE STOP SHOP%", "szemeszet", null, "One Stop Shop", "One Stop Shop"],
  [32, null, null, "%RLE + LASER%", "szemeszet", null, "General", "RLE+LASER"],
  [33, null, null, "%Lencse%", "szemeszet", null, "General", "RLE"],
  [34, null, null, "%RLE%", "szemeszet", null, "General", "RLE"],
  [35, null, null, "%LASER%", "szemeszet", null, "General", "LASER"],
  [36, null, null, "%LEZER%", "szemeszet", null, "General", "LASER"],
  [37, null, null, "%Szurkehalyog%", "szemeszet", null, "General", "Szürkehályog"],
  [38, null, null, "%Brand%", "szemeszet", null, "General", "Brand"],
  [39, null, null, "%Competitor%", "szemeszet", null, "General", "Competitor"],
  [40, null, null, "%Altalanos%", "szemeszet", null, "General", "Általános"],
  [41, null, null, "%boost%", "szemeszet", null, "General", "Boost"],
  [42, null, null, "%Awareness%", "szemeszet", null, "General", "Awareness"],
  [43, null, null, "%Engagement%", "szemeszet", null, "General", "Boost"],
  [49, null, null, "%Esztetika%plasztika%", BL, null, E, "Esztétika általános"],
  [50, null, null, "%Szemhejplasztika%", BL, null, E, "Szemhéjplasztika"],
  [51, null, null, "%Plasztik%", BL, null, E, "Plasztika"],
  [52, null, null, "%Borsebeszet%", BL, null, E, "Bőrsebészet"],
  [53, null, null, "%Borgyogyaszat%", BL, null, E, "Bőrgyógyászat"],
  [54, null, null, "%Competitor%", BL, null, E, "Competitor"],
  [55, null, null, "%Arckezel%", BL, null, E, "Arckezelés"],
  [56, null, null, "%Ranckezel%", BL, null, E, "Ránckezelés"],
  [57, null, null, "%Esztetikai%", BL, null, E, "Esztétikai kezelések"],
  [58, null, null, "%Awareness%", BL, null, E, "Awareness"],
  [59, null, null, "%Engagement%", BL, null, E, "Boost"],
  [60, null, null, "%Traffic%", BL, null, E, "Traffic"],
];

// Az éles kampányok (audit, 90 nap + a 0 költésű, besorolatlan TikTok-kampányok): [platform, fiók, név, üzletág, kategória, alkategória].
const G_E = "556-030-7472", G_S = "149-137-6230", M = "2060753947612996", T = "7038500154873364482";
const CAMPAIGNS = [
  ["google", G_E, "GSN - Szemhéjplasztika /konvmax", BL, E, "Szemhéjplasztika"],
  ["google", G_E, "GSN - Plasztikai_kezelések_kiemelt /konvértmax", BL, E, "Plasztika"],
  ["google", G_E, "Perf.Max - Esztétika, plasztika /konvértmax", BL, E, "Esztétika általános"],
  ["google", G_E, "GSN - Bőrsebészet", BL, E, "Bőrsebészet"],
  ["google", G_E, "GSN - Bőrgyógyászat", BL, E, "Bőrgyógyászat"],
  ["google", G_E, "GSN - Esztétikai kezelések /konvmax", BL, E, "Esztétikai kezelések"],
  ["google", G_E, "GSN - Arckezelések", BL, E, "Arckezelés"],
  ["google", G_E, "GSN - Szemhéjplasztika AI MAX /konvmax", BL, E, "Szemhéjplasztika"],
  ["google", G_E, "GSN - Competitors", BL, E, "Competitor"],
  ["google", G_E, "GSN - Plasztikai_kezelések_egyéb /konvmax", BL, E, "Plasztika"],
  ["meta", M, "SAINTJAMESHUNGARY - Traffic", BL, E, "Traffic"],
  ["meta", M, "SAINTJAMESHUNGARY - Awareness", BL, E, "Awareness"],
  ["meta", M, "SAINTJAMESHUNGARY - Engagement / Post Boost", BL, E, "Boost"],
  ["meta", M, "SAINTJAMESHUNGARY - RÁNCKEZELÉS - LEADFORM", BL, E, "Ránckezelés"],
  ["meta", M, "SAINTJAMESHUNGARY - CONVERSION", BL, E, "Konverzió"], // 0034 előtt: nincs kategória
  ["google", G_S, "Perf.Max - Lézeres szemműtét / konvmax", "szemeszet", "General", "LASER"],
  ["google", G_S, "Perf.Max - Lencse (45+) /konvmax", "szemeszet", "General", "RLE"],
  ["google", G_S, "GSN - Brand /konvmax", "szemeszet", "General", "Brand"],
  ["google", G_S, "GSN - Lézeres szemműtét /konvmax", "szemeszet", "General", "LASER"],
  ["google", G_S, "Perf.Max - Szürkehályog (45+) /konvmax", "szemeszet", "General", "Szürkehályog"],
  ["google", G_S, "GSN - Competitor - Sasszem /konvmax", "szemeszet", "General", "Competitor"],
  ["google", G_S, "Perf.Max - SMILE AO", "szemeszet", "SMILE", "SMILE"],
  ["google", G_S, "GSN - Pécs - Lézeres szemműtét /konvmax", "szemeszet", "General", "LASER"],
  ["google", G_S, "Perf.Max - SMILE", "szemeszet", "SMILE", "SMILE"],
  ["google", G_S, "Perf.Max - Általános /konvmax", "szemeszet", "General", "Általános"],
  ["google", G_S, "GSN - Általános szemészet /kattmax", "szemeszet", "General", "Általános"],
  ["google", G_S, "GSN - SMILE", "szemeszet", "SMILE", "SMILE"],
  ["meta", M, "LASSJOL - SMILE - TRAFFIC", "szemeszet", "SMILE", "SMILE"],
  ["meta", M, "LASSJOL - ONE STOP SHOP", "szemeszet", "One Stop Shop", "One Stop Shop"],
  ["meta", M, "LASSJOL - SMILE - AO", "szemeszet", "SMILE", "SMILE"],
  ["meta", M, "LASSJOL - RLE + LASER NEW Videos - Traffic", "szemeszet", "General", "RLE+LASER"],
  ["meta", M, "LASSJOL - RLE - Traffic", "szemeszet", "General", "RLE"],
  ["meta", M, "LASSJOL - LÉZER - Traffic", "szemeszet", "General", "LASER"],
  ["meta", M, "LASSJOL - SMILE - TRAFFIC - REMARKETING", "szemeszet", "SMILE", "SMILE"],
  ["meta", M, "LASSJOL - Post boost", "szemeszet", "General", "Boost"],
  ["meta", M, "LASSJOL - SMILE - THRUPLAY - VV", "szemeszet", "SMILE", "SMILE"],
  ["meta", M, "LASSJOL - SMILE - AWR - REACH", "szemeszet", "SMILE", "SMILE"],
  ["tiktok", T, "Lássjól - SMILE Pro - Lead - Ongoing", "szemeszet", "SMILE", "SMILE"],
  ["tiktok", T, "Lássjól - SMILE Pro - Lead", "szemeszet", "SMILE", "SMILE"],
  ["tiktok", T, "Lassjol - LASER - Leads", "szemeszet", "General", "LASER"],
  ["tiktok", T, "Lassjol - Lencse - Leads", "szemeszet", "General", "RLE"],
  ["tiktok", T, "Lassjol - CV - REM - Leads", "szemeszet", "General", "Konverzió"], // 0034 előtt: nincs kategória
  ["tiktok", T, "Lassjol - CV - Seany - Conversion", "szemeszet", "General", "Konverzió"], // 0034 előtt: nincs kategória
  ["tiktok", T, "Olvasószemüveg", "szemeszet", "General", "Olvasószemüveg"], // 0034 előtt: nincs üzletág sem
];

async function setup({ apply = true } = {}) {
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
  await db.exec(sql("0002_kpi_targets.sql"));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  await db.exec(`create table campaign_mapping_rule (id bigserial primary key, priority int not null, platform text, account_id text,
    name_pattern text, only_business_line text, business_line text, category text, subcategory text, note text,
    active boolean not null default true, updated_at timestamptz not null default now())`);
  for (const f of ["0004_analytics_v2.sql", "0005_creatives_insights.sql", "0007_fix_click_gap.sql", "0008_source_conversion.sql", "0009_campaign_join_ids.sql", "0027_roles.sql"]) await db.exec(sql(f));
  const uid = async (e) => (await db.query("select id from auth.users where email=$1", [e])).rows[0].id;
  const elemzo = await uid("elemzo@x.hu"), tag = await uid("tag@x.hu");
  await db.query("delete from user_roles");
  await db.query("insert into user_roles(user_id, role) values ($1,'elemzo'), ($2,'megtekinto')", [elemzo, tag]);
  for (const r of LIVE_RULES)
    await db.query("insert into campaign_mapping_rule(priority, platform, account_id, name_pattern, only_business_line, business_line, category, subcategory) values ($1,$2,$3,$4,$5,$6,$7,$8)", r);
  if (apply) await db.exec(sql("0034_campaign_name_match.sql"));
  return { db, elemzo, tag };
}
async function as(db, uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.uid', '${uid}', false)`);
  try { return await fn(); } finally { await db.exec("reset role"); }
}
const cls = (db, p, a, id, name) =>
  db.query("insert into campaign_class values ($1,$2,$3,$4,'szemeszet','General','LASER','rule')", [p, a, id, name]);
const ad = (db, d, p, a, id, name, spend) =>
  db.query("insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,campaign_name,spend,impressions,clicks) values ($1,$2,$3,$4,$5,$6,1000,100)", [d, p, a, id, name, spend]);
const web = (db, d, source, campaign, sessions) =>
  db.query("insert into fact_web_daily(date,account_id,source,medium,channel_group,campaign,sessions,engaged_sessions) values ($1,'312872101',$2,'cpc','Paid',$3,$4,1)", [d, source, campaign, sessions]);
const soft = (db, d, source, campaign, n) =>
  db.query("insert into fact_web_event_daily(date,account_id,event_name,source,medium,campaign,event_count) values ($1,'312872101','soft_conv_foglaljon',$2,'cpc',$3,$4)", [d, source, campaign, n]);
const funnel = async (db) =>
  Object.fromEntries((await db.query("select campaign_id, sum(sessions) s, sum(soft_leads) l, sum(spend) sp from mart_campaign_funnel_daily group by 1")).rows
    .map((r) => [r.campaign_id, { sessions: Number(r.s), soft: Number(r.l), spend: Number(r.sp) }]));

test("átnevezett kampány: a régi UTM-név alatti forgalom és soft lead is a kampányhoz kerül, a költés nem duplázódik", async () => {
  for (const apply of [false, true]) {
    const { db } = await setup({ apply });
    await cls(db, "google", "g1", "c1", "GSN - Lézeres szemműtét / Abs.Top of Page"); // a jelenlegi név
    await ad(db, day(0), "google", "g1", "c1", "GSN - Lézeres szemműtét /konvmax", 100); // a régi név
    await ad(db, day(8), "google", "g1", "c1", "GSN - Lézeres szemműtét / Abs.Top of Page", 100);
    await web(db, day(0), "google", "GSN - Lézeres szemműtét /konvmax", 500); // a régi UTM
    await web(db, day(8), "google", "GSN - Lézeres szemműtét / Abs.Top of Page", 40);
    await soft(db, day(0), "google", "GSN - Lézeres szemműtét /konvmax", 30);
    const f = (await funnel(db)).c1;
    if (!apply) { assert.equal(f.sessions, 40, "a javítás előtt csak az új név párosul"); continue; }
    assert.equal(f.sessions, 540);
    assert.equal(f.soft, 30);
    assert.equal(f.spend, 200);
    assert.equal((await db.query("select count(*)::int n from mart_web_campaign_unmatched")).rows[0].n, 0);
  }
});

test("a régi név nem lopható el: egy másik kampány jelenlegi nevét az a kampány kapja", async () => {
  const { db } = await setup();
  await cls(db, "google", "g1", "c1", "GSN - Új név");
  await cls(db, "google", "g1", "c2", "GSN - Közös név");
  await ad(db, day(0), "google", "g1", "c1", "GSN - Közös név", 50); // c1 korábban ezt a nevet viselte
  await ad(db, day(5), "google", "g1", "c1", "GSN - Új név", 50);
  await ad(db, day(5), "google", "g1", "c2", "GSN - Közös név", 70);
  await web(db, day(5), "google", "GSN - Közös név", 200);
  const f = await funnel(db);
  assert.equal(f.c2.sessions, 200);
  assert.equal(f.c1.sessions, 0);
  assert.equal(f.c1.spend, 100);
  assert.equal(f.c2.spend, 70);
});

test("azonosító szerinti és név szerinti forgalom együtt, duplázódás nélkül; az illeszkedetlen név továbbra is listázódik", async () => {
  const { db } = await setup();
  await cls(db, "meta", "m1", "c1", "LASSJOL - ONE STOP SHOP");
  await ad(db, day(0), "meta", "m1", "c1", "LASSJOL - ONE STOP SHOP", 30);
  await web(db, day(0), "facebook", "LASSJOL - ONE STOP SHOP", 800);
  await web(db, day(0), "facebook", "c1", 100); // a kampány azonosítójával érkező forgalom
  await web(db, day(0), "facebook", "Elírt Kampány Név", 50);
  await soft(db, day(0), "facebook", "LASSJOL - ONE STOP SHOP", 40);
  const f = (await funnel(db)).c1;
  assert.deepEqual(f, { sessions: 900, soft: 40, spend: 30 });
  assert.deepEqual((await db.query("select campaign, sessions from mart_web_campaign_unmatched")).rows.map((r) => [r.campaign, Number(r.sessions)]), [["Elírt Kampány Név", 50]]);
});

test("kézi alias: a rövidített UTM-név a kampányhoz kerül; a migráció az audit négy aliasát felveszi", async () => {
  const { db } = await setup();
  await cls(db, "meta", "m1", "120243705267400714", "LASSJOL - RLE - Traffic");
  await ad(db, day(0), "meta", "m1", "120243705267400714", "LASSJOL - RLE - Traffic", 10);
  await web(db, day(0), "facebook", "LASSJOL - RLE", 300);
  assert.equal((await funnel(db))["120243705267400714"].sessions, 300);
  assert.equal((await db.query("select count(*)::int n from mart_web_campaign_unmatched")).rows[0].n, 0);
  const aliases = (await db.query("select platform, alias_norm from campaign_utm_alias order by 1,2")).rows.map((r) => `${r.platform}:${r.alias_norm}`);
  assert.deepEqual(aliases, ["google:brand", "meta:lassjol - rle", "meta:lassjol - rle laser new videos - traffic", "meta:lassjol - smile - awr"]);
});

test("alias-tábla jogosultság: tag olvashat, nem írhat; elemző írhat; anon semmit", async () => {
  const { db, elemzo, tag } = await setup();
  assert.ok((await as(db, tag, () => db.query("select * from campaign_utm_alias"))).rows.length >= 4);
  await assert.rejects(as(db, tag, () => db.query("insert into campaign_utm_alias(platform, alias_norm, campaign_id) values ('meta','x','1')")));
  await as(db, elemzo, () => db.query("insert into campaign_utm_alias(platform, alias_norm, campaign_id) values ('meta','x','1')"));
  assert.equal((await db.query("select count(*)::int n from campaign_utm_alias where alias_norm='x'")).rows[0].n, 1);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from campaign_utm_alias"));
  await db.exec("reset role");
});

test("besorolás: mind a 44 éles kampány felismert üzletággal, kategóriával és alkategóriával (a 0034 előtt négy hiányos volt)", async () => {
  const classify = async (db, p, a, name) => (await db.query(`
    with m as (select * from campaign_mapping_rule r where r.active and (r.platform is null or r.platform = $1)
      and (r.account_id is null or r.account_id = $2) and (r.name_pattern is null or sj_norm($3) like sj_norm(r.name_pattern))),
    bl as (select business_line from m where business_line is not null order by priority, id limit 1),
    pick as (select category, subcategory from m where category is not null and (only_business_line is null or only_business_line = (select business_line from bl)) order by priority, id limit 1)
    select (select business_line from bl) bl, (select category from pick) cat, (select subcategory from pick) sub`, [p, a, name])).rows[0];
  const before = await setup({ apply: false });
  const missing = [];
  for (const [p, a, name, bl, cat, sub] of CAMPAIGNS) {
    const r = await classify(before.db, p, a, name);
    if (r.bl !== bl || r.cat !== cat || r.sub !== sub) missing.push(name);
  }
  assert.deepEqual(missing.sort(), ["Lassjol - CV - REM - Leads", "Lassjol - CV - Seany - Conversion", "Olvasószemüveg", "SAINTJAMESHUNGARY - CONVERSION"].sort());
  const { db } = await setup();
  assert.equal(CAMPAIGNS.length, 44);
  for (const [p, a, name, bl, cat, sub] of CAMPAIGNS)
    assert.deepEqual(await classify(db, p, a, name), { bl, cat, sub }, name);
});

test("a migráció újrafuttatható: a szabályok, az aliasok és a nézetek nem duplázódnak", async () => {
  const { db } = await setup();
  const count = async () => (await db.query("select (select count(*) from campaign_mapping_rule)::int r, (select count(*) from campaign_utm_alias)::int a")).rows[0];
  const first = await count();
  assert.equal(first.r, LIVE_RULES.length + 6);
  await db.exec(sql("0034_campaign_name_match.sql"));
  assert.deepEqual(await count(), first);
});
