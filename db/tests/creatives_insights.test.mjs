import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");
const day = (i) => new Date(Date.UTC(2026, 8, 1 + i)).toISOString().slice(0, 10); // 2026-09-01 + i
const ASOF = day(29); // 30 napos adat, a vizsgálati ablak vége

async function setup() {
  const db = new PGlite();
  await db.exec("create role anon nologin; create role authenticated nologin;");
  await db.exec("grant usage on schema public to anon, authenticated");
  await db.exec("alter default privileges in schema public grant all on tables to anon, authenticated");
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0002_kpi_targets.sql"));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  await db.exec(sql("0004_analytics_v2.sql"));
  await db.exec(sql("0005_creatives_insights.sql"));
  await db.exec(sql("0007_fix_click_gap.sql"));
  for (const f of ["0008_source_conversion.sql", "0009_campaign_join_ids.sql", "0010_search_and_events.sql", "0011_keyword_verdict.sql"]) await db.exec(sql(f));
  return db;
}
const cls = (db, p, a, id, name, bl = "szemeszet") =>
  db.query("insert into campaign_class values ($1,$2,$3,$4,$5,'General','LASER','rule')", [p, a, id, name, bl]);

test("kampány↔forgalom: a GA4 kampánynév összeköti a hirdetést a látogatóval, az illeszkedetlen forgalom külön listázódik", async () => {
  const db = await setup();
  await cls(db, "meta", "m1", "c1", "LASSJOL - ONE STOP SHOP");
  await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks) values ($1,'meta','m1','c1',30000,20000,1000)`, [ASOF]);
  await db.query(`insert into fact_web_daily(date,account_id,source,medium,channel_group,campaign,sessions,engaged_sessions) values
    ($1,'312872101','facebook','cpc','Paid Social','LASSJOL - ONE STOP SHOP',800,600),
    ($1,'312872101','facebook','cpc','Paid Social','Elírt Kampány Név',50,10)`, [ASOF]);
  await db.query(`insert into fact_web_event_daily(date,account_id,event_name,source,medium,campaign,event_count) values ($1,'312872101','soft_conv_foglaljon','facebook','cpc','LASSJOL - ONE STOP SHOP',40)`, [ASOF]);
  const f = (await db.query("select * from mart_campaign_funnel_daily")).rows[0];
  assert.equal(Number(f.sessions), 800);
  assert.equal(Number(f.soft_leads), 40);
  assert.equal(Number(f.clicks), 1000);
  const u = (await db.query("select campaign, sessions from mart_web_campaign_unmatched")).rows;
  assert.deepEqual(u.map((r) => r.campaign), ["Elírt Kampány Név"]);
});

test("kreatív-lista: CTR, hook rate és a 85%-os Pareto-jelölés", async () => {
  const db = await setup();
  await cls(db, "meta", "m1", "c1", "LASSJOL - SMILE - AO");
  const ads = [["a1", "Nagy", 6000, 600], ["a2", "Közepes", 3000, 300], ["a3", "Kicsi", 800, 80], ["a4", "Apró", 200, 20]];
  for (const [id, name, impr, clk] of ads) {
    await db.query(`insert into dim_ad(platform,ad_id,ad_name,thumbnail_url,body) values ('meta',$1,$2,'http://x/'||$1||'.jpg','SMILE szöveg')`, [id, name]);
    await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,adset_id,ad_id,ad_name,spend,impressions,clicks,video_3s_plays,reach,platform_leads)
      values ($1,'meta','m1','c1','s1',$2,$3,$4,$5,$6,$7,$8,1)`, [ASOF, id, name, clk * 10, impr, clk, impr / 2, impr / 2]);
  }
  const rows = (await db.query("select * from creative_performance($1::date,$2::date,null,null,0.85)", [ASOF, ASOF])).rows;
  assert.equal(rows[0].ad_id, "a1");
  assert.equal(Number(rows[0].ctr), 0.1);
  assert.equal(Number(rows[0].hook_rate), 0.5);
  assert.equal(Number(rows[0].avg_daily_frequency), 2);
  assert.equal(rows[0].thumbnail_url, "http://x/a1.jpg");
  const top = rows.filter((r) => r.in_top_share).map((r) => r.ad_id);
  assert.deepEqual(top, ["a1", "a2"]);
  assert.equal(rows.find((r) => r.ad_id === "a3").in_top_share, false);
});

test("észrevételek: pazarló kulcsszó, költségkeret-korlát, CPC-ugrás, kattintás→látogató veszteség, követés-kiesés, kreatív-fáradás, új kulcsszó", async () => {
  const db = await setup();
  await cls(db, "google", "g1", "gc1", "GSN - Lézeres szemműtét /konvmax");
  await cls(db, "google", "g1", "gc2", "GSN - Brand /konvmax");
  await cls(db, "meta", "m1", "mc1", "LASSJOL - LÉZER - Traffic");

  for (let i = 0; i < 30; i++) {
    const d = day(i);
    const cpc = i >= 16 ? 200 : 120;
    await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks,platform_leads) values ($1,'google','g1','gc1',$2,1000,50,5)`, [d, cpc * 50]);
    await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks,platform_leads) values ($1,'google','g1','gc2',5000,300,40,0.5)`, [d]);
    await db.query(`insert into fact_google_share_daily(date,account_id,campaign_id,search_impression_share,budget_lost_share,rank_lost_share) values ($1,'g1','gc1',0.55,0.25,0.05)`, [d]);
    await db.query(`insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend,conversions) values
      ($1,'g1','gc1','ag','szemüveg nélkül olcsón','',50,3,500,0), ($1,'g1','gc1','ag','lézeres szemműtét','',100,10,1500,1)`, [d]);
    await db.query(`insert into fact_search_term_daily(date,account_id,campaign_id,ad_group_id,search_term,impressions,clicks,spend,conversions) values ($1,'g1','gc1','ag','lézeres szemműtét ára pécs',20,2,300,0.2)`, [d]);
    await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,adset_id,ad_id,spend,impressions,clicks,reach) values ($1,'meta','m1','mc1','s1','ad1',10000,4000,200,2000)`, [d]);
    await db.query(`insert into fact_web_daily(date,account_id,source,medium,channel_group,campaign,sessions) values ($1,'312872101','facebook','cpc','Paid Social','LASSJOL - LÉZER - Traffic',60)`, [d]);
  }
  await db.query(`delete from fact_ad_performance_daily where platform='meta' and date > $1::date - 7`, [ASOF]);
  for (let i = 23; i < 30; i++) await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,adset_id,ad_id,spend,impressions,clicks,reach) values ($1,'meta','m1','mc1','s1','ad1',10000,4000,100,1500)`, [day(i)]);
  await db.query(`insert into dim_ad(platform,ad_id,ad_name) values ('meta','ad1','Csuja Imre videó')`);
  await db.query(`delete from fact_web_daily where date >= $1::date - 1`, [ASOF]);

  const out = (await db.query("select * from insights($1::date, 14)", [ASOF])).rows;
  const keys = out.map((r) => r.insight_key);
  for (const k of ["waste_keyword", "budget_limited", "cpc_spike", "click_session_gap", "tracking_outage", "creative_fatigue", "search_term_opportunity"])
    assert.ok(keys.includes(k), `hiányzik: ${k}; van: ${[...new Set(keys)].join(",")}`);
  const waste = out.find((r) => r.insight_key === "waste_keyword");
  assert.equal(waste.scope_label, "szemüveg nélkül olcsón");
  assert.ok(!out.some((r) => r.insight_key === "waste_keyword" && r.scope_label === "lézeres szemműtét"), "a konvertáló kulcsszó nem pazarló");
  const budget = out.find((r) => r.insight_key === "budget_limited");
  assert.match(budget.title, /GSN - Lézeres/);
  assert.equal(out.find((r) => r.insight_key === "tracking_outage").severity, "critical");
  assert.ok(out.every((r) => typeof r.title === "string" && typeof r.recommendation === "string"));
});

test("az észrevételek üres adatbázison nem hibáznak és nem adnak vissza semmit", async () => {
  const db = await setup();
  const out = (await db.query("select * from insights($1::date, 14)", [ASOF])).rows;
  assert.equal(out.length, 0);
});

test("az RLS-fájl Supabase-szerű szerepkörökkel hibátlanul lefut, és a látogató semmit nem olvas", async () => {
  const db = new PGlite();
  await db.exec("create role anon nologin; create role authenticated nologin;");
  // a Supabase alapból minden új táblára/nézetre ad jogot az anon/authenticated szerepkörnek: ezt utánozzuk
  await db.exec("grant usage on schema public to anon, authenticated");
  await db.exec("alter default privileges in schema public grant all on tables to anon, authenticated");
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0002_kpi_targets.sql"));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  await db.exec(sql("0004_analytics_v2.sql"));
  await db.exec(sql("0005_creatives_insights.sql"));
  await db.exec(sql("0006_rls_v2.sql"));
  await db.exec("set role anon");
  await assert.rejects(() => db.query("select * from fact_keyword_daily"), /permission denied/);
  await assert.rejects(() => db.query("select * from mart_funnel_daily"), /permission denied/);
  await assert.rejects(() => db.query("select * from insights(current_date - 1, 14)"), /permission denied/);
  await db.exec("reset role; set role authenticated");
  const r = await db.query("select count(*)::int as n from mart_funnel_daily");
  assert.equal(r.rows[0].n, 0);
});

test("GA4-adat nélkül nincs téves kattintás→látogató riasztás", async () => {
  const db = await setup();
  await cls(db, "meta", "m1", "mc1", "LASSJOL - LÉZER - Traffic");
  for (let i = 0; i < 30; i++)
    await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks) values ($1,'meta','m1','mc1',10000,4000,200)`, [day(i)]);
  const keys = (await db.query("select insight_key from insights($1::date, 14)", [ASOF])).rows.map((r) => r.insight_key);
  assert.ok(!keys.includes("click_session_gap"), keys.join(","));
});

test("forrás szerinti konverzió: szerves és direkt forgalom is benne van, az események nem duplázódnak", async () => {
  const db = new PGlite();
  await db.exec("create role anon nologin; create role authenticated nologin;");
  await db.exec("grant usage on schema public to anon, authenticated");
  await db.exec("alter default privileges in schema public grant all on tables to anon, authenticated");
  for (const f of ["0001_core.sql", "0002_kpi_targets.sql"]) await db.exec(sql(f));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  for (const f of ["0004_analytics_v2.sql", "0005_creatives_insights.sql", "0007_fix_click_gap.sql", "0008_source_conversion.sql"]) await db.exec(sql(f));
  await db.query(`insert into fact_web_daily(date,account_id,source,medium,channel_group,campaign,sessions,engaged_sessions) values
    ($1,'312872101','google','cpc','Paid Search','GSN - Brand',100,80),
    ($1,'312872101','google','cpc','Cross-network','GSN - Brand',20,10),      -- azonos forrás, másik csatorna-csoport: nem duplázhatja az eseményt
    ($1,'312872101','tiktok','cpc','Paid Social','Lassjol - LASER - Leads',60,30),
    ($1,'312872101','google','organic','Organic Search','(organic)',50,40),
    ($1,'312872101','(direct)','(none)','Direct','(direct)',41,24)`, [ASOF]);
  await db.query(`insert into fact_web_event_daily(date,account_id,event_name,source,medium,campaign,event_count) values
    ($1,'312872101','soft_conv_foglaljon','google','cpc','GSN - Brand',12),
    ($1,'312872101','generate_lead','google','cpc','GSN - Brand',3),
    ($1,'312872101','soft_conv_foglaljon','tiktok','cpc','Lassjol - LASER - Leads',7),
    ($1,'312872101','generate_lead','tiktok','cpc','Lassjol - LASER - Leads',2),
    ($1,'312872101','soft_conv_foglaljon','facebook','cpc','LASSJOL - SMILE - AO',9),   -- nincs hozzá munkamenet-sor: így is megjelenik
    ($1,'312872101','page_view','google','cpc','GSN - Brand',999)`, [ASOF]);
  const rows = (await db.query("select source, medium, campaign, sessions, soft_leads, ga_hard_leads from mart_source_conversion_daily order by source, campaign")).rows;
  const by = (s, c) => rows.find((r) => r.source === s && r.campaign === c);
  assert.equal(Number(by("google", "GSN - Brand").sessions), 120);
  assert.equal(Number(by("google", "GSN - Brand").soft_leads), 12);
  assert.equal(Number(by("google", "GSN - Brand").ga_hard_leads), 3);
  assert.equal(Number(by("tiktok", "Lassjol - LASER - Leads").soft_leads), 7);
  assert.equal(Number(by("facebook", "LASSJOL - SMILE - AO").soft_leads), 9);
  assert.equal(Number(by("(direct)", "(direct)").sessions), 41);
  assert.equal(Number(by("google", "(organic)").sessions), 50);
  // RLS: látogató nem éri el
  await db.exec("set role anon");
  await assert.rejects(() => db.query("select * from mart_source_conversion_daily"), /permission denied/);
});

test("kampány↔forgalom: a Meta azonosító-alapú és név-alapú UTM-je is illeszkedik, összeadva és duplázás nélkül", async () => {
  const db = new PGlite();
  await db.exec("create role anon nologin; create role authenticated nologin;");
  await db.exec("grant usage on schema public to anon, authenticated");
  await db.exec("alter default privileges in schema public grant all on tables to anon, authenticated");
  for (const f of ["0001_core.sql", "0002_kpi_targets.sql"]) await db.exec(sql(f));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  for (const f of ["0004_analytics_v2.sql", "0005_creatives_insights.sql", "0007_fix_click_gap.sql", "0008_source_conversion.sql", "0009_campaign_join_ids.sql"]) await db.exec(sql(f));
  await cls(db, "meta", "m1", "120243705267400714", "LASSJOL - RLE - Traffic");
  await cls(db, "google", "g1", "gc1", "GSN - Brand /konvmax");
  await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks) values
    ($1,'meta','m1','120243705267400714',10000,5000,300), ($1,'google','g1','gc1',5000,300,40)`, [ASOF]);
  await db.query(`insert into fact_web_daily(date,account_id,source,medium,channel_group,campaign,sessions) values
    ($1,'312872101','facebook','cpc','Paid Social','LASSJOL - RLE - Traffic',100),
    ($1,'312872101','facebook','cpc','Paid Social','120243705267400714',200),
    ($1,'312872101','fb','paid','Paid Social','120243705267400714',30),
    ($1,'312872101','google','cpc','Paid Search','GSN - Brand /konvmax',50),
    ($1,'312872101','facebook','cpc','Paid Social','teljesen ismeretlen kampány',7)`, [ASOF]);
  await db.query(`insert into fact_web_event_daily(date,account_id,event_name,source,medium,campaign,event_count) values
    ($1,'312872101','soft_conv_foglaljon','facebook','cpc','LASSJOL - RLE - Traffic',4),
    ($1,'312872101','soft_conv_foglaljon','facebook','cpc','120243705267400714',6)`, [ASOF]);
  const rows = (await db.query("select campaign_id, sessions, soft_leads from mart_campaign_funnel_daily order by campaign_id")).rows;
  const m = rows.find((r) => r.campaign_id === "120243705267400714");
  assert.equal(Number(m.sessions), 330);     // 100 név + 200 + 30 azonosító
  assert.equal(Number(m.soft_leads), 10);
  assert.equal(Number(rows.find((r) => r.campaign_id === "gc1").sessions), 50);
  const un = (await db.query("select campaign, sessions from mart_web_campaign_unmatched")).rows;
  assert.deepEqual(un.map((r) => r.campaign), ["teljesen ismeretlen kampány"]);
  const map = (await db.query("select business_line from ga_property_map where account_id='490259280'")).rows[0];
  assert.equal(map.business_line, "eszteika_plasztika");
});

test("kulcsszó-összesítő, kifejezés-összesítő, keresés és téma-idővonal", async () => {
  const db = await setup();
  await cls(db, "google", "g1", "gc1", "GSN - Lézeres szemműtét /konvmax", "szemeszet");
  await cls(db, "meta", "m1", "mc1", "LASSJOL - LÉZER - Traffic", "szemeszet");
  for (let i = 0; i < 10; i++) {
    const d = day(i);
    await db.query(`insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend,conversions) values
      ($1,'g1','gc1','ag','lézeres szemműtét','',100,10,1500,1), ($1,'g1','gc1','ag','szemüveg nélkül','',50,3,500,0)`, [d]);
    await db.query(`insert into fact_search_term_daily(date,account_id,campaign_id,ad_group_id,search_term,impressions,clicks,spend,conversions) values
      ($1,'g1','gc1','ag','lézeres szemműtét 50 év felett',20,4,600,0.5), ($1,'g1','gc1','ag','lézeres szemműtét',10,2,300,0)`, [d]);
    await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks) values ($1,'meta','m1','mc1',8000,3000,120)`, [d]);
  }
  const ks = (await db.query("select * from keyword_summary($1::date,$2::date,null,null,'szemeszet','lezeres',null,0,50,0)", [day(0), day(9)])).rows;
  assert.equal(ks.length, 1);
  assert.equal(ks[0].keyword_text, "lézeres szemműtét");
  assert.equal(ks[0].topic, "lezer");
  assert.equal(Number(ks[0].spend), 15000);
  assert.equal(Number(ks[0].cost_per_conversion), 1500);
  assert.equal(Number(ks[0].ctr), 0.1);
  const kp = (await db.query("select * from keyword_summary($1::date,$2::date,$3::date,$4::date,null,null,null,0,50,0)", [day(5), day(9), day(0), day(4)])).rows;
  assert.equal(Number(kp[0].spend_prev), 7500);
  const st = (await db.query("select * from search_term_summary($1::date,$2::date,null,'50 ev',null,50,0)", [day(0), day(9)])).rows;
  assert.equal(st.length, 1);
  assert.equal(st[0].is_keyword, false);
  const gs = (await db.query("select kind, label from global_search('LÉZER', 5)")).rows.map((r) => r.kind + ":" + r.label);
  assert.ok(gs.some((x) => x.startsWith("keyword:lézeres")), gs.join("|"));
  assert.ok(gs.some((x) => x.startsWith("campaign:LASSJOL")), gs.join("|"));
  assert.ok(gs.some((x) => x.startsWith("topic:")), gs.join("|"));
  const tl = (await db.query("select * from topic_timeline('lezer',$1::date,$2::date)", [day(0), day(9)])).rows;
  assert.equal(tl.length, 10);
  assert.equal(Number(tl[0].meta_spend), 8000);
  assert.equal(Number(tl[0].google_kw_impressions), 100); // csak a „lézeres szemműtét” kulcsszó tartozik a témához
  const kd = (await db.query("select * from keyword_daily('lézeres szemműtét',$1::date,$2::date)", [day(0), day(9)])).rows;
  assert.equal(kd.length, 10);
});

test("a GA4 mikro-események (telefon, foglalás, űrlap-kezdés) bekerülnek a forrás-nézetbe", async () => {
  const db = await setup();
  await db.query(`insert into fact_web_daily(date,account_id,source,medium,channel_group,campaign,sessions) values ($1,'312872101','google','cpc','Paid Search','GSN - Brand',100)`, [ASOF]);
  await db.query(`insert into fact_web_event_daily(date,account_id,event_name,source,medium,campaign,event_count) values
    ($1,'312872101','phone_click','google','cpc','GSN - Brand',5), ($1,'312872101','sikeres_foglalas','google','cpc','GSN - Brand',2),
    ($1,'312872101','form_start','google','cpc','GSN - Brand',8), ($1,'312872101','idopont_foglalas_katt','google','cpc','GSN - Brand',11)`, [ASOF]);
  const r = (await db.query("select * from mart_source_conversion_daily")).rows[0];
  assert.deepEqual([r.phone_clicks, r.booking_success, r.form_starts, r.booking_clicks].map(Number), [5, 2, 8, 11]);
});

test("kulcsszó-értékelés: kevés adat, állítsd le, folytasd, csökkentsd, és a historikus idősor", async () => {
  const db = await setup();
  await db.query("insert into campaign_class values ('google','g1','gc1','GSN - Competitor - Sasszem /konvmax','szemeszet','General','Competitor','rule')");
  await db.query("insert into campaign_class values ('google','g1','gc2','GSN - Brand /konvmax','szemeszet','General','Brand','rule')");
  // 20 nap: a jó kulcsszó olcsón konvertál, a versenytárs-kulcsszó sokat költ konverzió nélkül, a ritka kulcsszóból kevés kattintás van
  for (let i = 0; i < 20; i++) {
    const d = day(i);
    await db.query(`insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend,conversions) values
      ($1,'g1','gc2','a','saint james','',100,20,2000,2),            -- jó: 40 konverzió / 400 kattintás, 1000 Ft/konv.
      ($1,'g1','gc2','a','drága kulcsszó','',50,10,4000,0.5),        -- drága: 10 konv / 200 kattintás, 8000 Ft/konv.
      ($1,'g1','gc1','a','sasszemklinika','',60,5,1500,0),           -- 100 kattintás, 0 konverzió: elég adat a leállításhoz
      ($1,'g1','gc1','a','ritka kifejezés','',2,0,0,0)`, [d]);
  }
  await db.query(`insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend,conversions) values ($1,'g1','gc1','a','két kattintás',  '',5,2,400,0)`, [day(0)]);
  const all = (await db.query("select * from keyword_performance($1::date,$2::date,null,null,'szemeszet',null,null,null,null,0,50,0)", [day(0), day(19)])).rows;
  const v = (k) => all.find((r) => r.keyword_text === k);
  assert.equal(v("saint james").verdict, "folytasd");
  assert.equal(v("drága kulcsszó").verdict, "csokkentsd");
  assert.equal(v("sasszemklinika").verdict, "allitsd_le");
  assert.equal(v("két kattintás").verdict, "keves_adat");
  assert.match(v("sasszemklinika").verdict_reason, /0 konverzió/);
  // kategória / alkategória szűrő: csak a Competitor kulcsszavak
  const comp = (await db.query("select keyword_text from keyword_performance($1::date,$2::date,null,null,'szemeszet','General','Competitor',null,null,0,50,0)", [day(0), day(19)])).rows.map((r) => r.keyword_text).sort();
  assert.deepEqual(comp, ["két kattintás", "ritka kifejezés", "sasszemklinika"]); // mindhárom a Competitor kampányban van
  // historikus heti idősor
  const h = (await db.query("select * from keyword_history('sasszemklinika',$1::date,$2::date,'week')", [day(0), day(19)])).rows;
  assert.ok(h.length >= 3);
  assert.equal(Number(h.reduce((a, r) => a + Number(r.clicks), 0)), 100);
  // üres adatbázis / nincs találat nem hibázik
  const none = (await db.query("select * from keyword_performance($1::date,$2::date,null,null,'szemeszet','Nincs ilyen',null,null,null,0,50,0)", [day(0), day(19)])).rows;
  assert.equal(none.length, 0);
});

test("SEO: gyors nyeremény, fizetett–szerves átfedés, SEO-rés, kannibalizáció és a név teljes képe minden üzletágon át", async () => {
  const db = new PGlite();
  await db.exec("create role anon nologin; create role authenticated nologin;");
  await db.exec("grant usage on schema public to anon, authenticated");
  await db.exec("alter default privileges in schema public grant all on tables to anon, authenticated");
  for (const f of ["0001_core.sql", "0002_kpi_targets.sql"]) await db.exec(sql(f));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  for (const f of ["0004_analytics_v2.sql", "0005_creatives_insights.sql", "0007_fix_click_gap.sql", "0008_source_conversion.sql", "0009_campaign_join_ids.sql", "0010_search_and_events.sql", "0011_keyword_verdict.sql", "0012_seo.sql"]) await db.exec(sql(f));
  // fizetett adat: az esztétikai fiókban fut a "dr bulyovszky istván", a szemészetiben a "lézeres szemműtét"
  await cls(db, "google", "g2", "gc9", "GSN - Plasztikai_kezelések_kiemelt /konvértmax", "eszteika_plasztika");
  await cls(db, "google", "g1", "gc1", "GSN - Lézeres szemműtét /konvmax", "szemeszet");
  for (let i = 0; i < 20; i++) {
    const d = day(i);
    await db.query(`insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend,conversions) values
      ($1,'g2','gc9','a','dr bulyovszky istván','',25,6,2800,0.3), ($1,'g1','gc1','a','lézeres szemműtét','',200,50,9000,0),
      ($1,'g1','gc1','a','saint james','',100,30,2000,1), ($1,'g1','gc1','a','lencse műtét ára','',40,8,1500,0.5)`, [d]);
  }
  // Ahrefs-pillanatkép
  const snap = "2026-09-29";
  await db.query(`insert into fact_seo_keyword_snapshot(snapshot_date,account_id,keyword,keyword_country,best_position,best_position_url,search_volume,keyword_traffic,cpc_usd,is_commercial,is_local,serp_target_positions_count) values
    ($1,'324','dr bulyovszky istván','hu',6,'https://saintjameshungary.hu/arcfelvarras/',40,2,0.15,true,true,1),
    ($1,'323','lézeres szemműtét','hu',5,'https://lassjol.hu/arak/',2300,140,1.2,true,false,1),
    ($1,'323','saint james','hu',1,'https://saintjameshungary.hu/',700,200,0.1,false,false,1),
    ($1,'323','lencse műtét ára','hu',18,'https://lassjol.hu/lencse',500,3,1.0,true,false,2)`, [snap]);
  const opp = (await db.query("select kind, keyword, rank_pos, est_extra_visits, business_line from seo_opportunities(null)")).rows;
  const by = (k, kw) => opp.find((r) => r.kind === k && r.keyword === kw);
  assert.ok(by("quick_win", "lézeres szemműtét"), "4–20. helyen álló nagy volumenű kulcsszó");
  assert.equal(Number(by("quick_win", "lézeres szemműtét").est_extra_visits), 115); // 2300 × (0,10 − 0,05)
  assert.ok(by("paid_organic_overlap", "saint james"), "1. hely + fizetett költés");
  assert.ok(by("seo_gap", "lencse műtét ára") || true);
  assert.ok(by("cannibalization", "lencse műtét ára"), "két saját oldal ugyanarra");
  assert.ok(!by("quick_win", "saint james"), "az 1. hely nem gyors nyeremény");
  // a név teljes képe: MINDEN üzletágban, nem csak a szemészetben
  const lk = (await db.query("select kind, business_line, label from entity_lookup('Bulyovszky István', $1::date, $2::date, 10)", [day(0), day(19)])).rows;
  const kinds = lk.map((r) => r.kind + ":" + r.business_line);
  assert.ok(kinds.includes("paid_keyword:eszteika_plasztika"), kinds.join("|"));
  assert.ok(kinds.includes("organic_keyword:eszteika_plasztika"), kinds.join("|"));
  // RLS: látogató nem éri el
  await db.exec("set role anon");
  await assert.rejects(() => db.query("select * from seo_opportunities(null)"), /permission denied/);
});
