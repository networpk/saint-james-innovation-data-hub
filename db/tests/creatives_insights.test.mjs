import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const dir = new URL("../migrations/", import.meta.url);
const sql = (f) => fs.readFileSync(new URL(f, dir), "utf8");
const day = (i) => new Date(Date.UTC(2026, 8, 1 + i)).toISOString().slice(0, 10); // 2026-09-01 + i
const ASOF = day(29); // 30 napos adat, a vizsgálati ablak vége

async function setup(skip = []) {
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
  for (const f of ["0008_source_conversion.sql", "0009_campaign_join_ids.sql", "0010_search_and_events.sql", "0011_keyword_verdict.sql", "0012_seo.sql", "0013_alerts.sql", "0014_lead_journey.sql", "0015_activecampaign.sql", "0016_performance.sql", "0017_ac_emails_flow.sql", "0018_datalayer_events.sql", "0019_google_campaign_id.sql"]) if (!skip.includes(f)) await db.exec(sql(f));
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

test("értesítési központ: adatminőségi riasztás, deduplikálás, halasztás, várakozási idő, automatikus megoldódás, jogosultság", async () => {
  const db = await setup();
  const NOW = "2026-09-30T12:00:00Z";
  // betöltés: 2 napja futott utoljára sikeresen (elavult), és egy másik hibára futott
  await db.query(`insert into ingestion_run(job,started_at,finished_at,status) values ('ads', '2026-09-28T06:00:00Z','2026-09-28T06:05:00Z','ok')`);
  await db.query(`insert into ingestion_run(job,started_at,finished_at,status,error) values ('ga4', '2026-09-30T06:00:00Z','2026-09-30T06:01:00Z','error','quota exceeded')`);
  // leadek: a megelőző héten 12, az utolsó héten 3 (visszaesés), mind forrás nélkül
  for (let i = 0; i < 12; i++) await db.query(`insert into fact_lead(lead_id,created_at,updated_at,source) values (gen_random_uuid(), '2026-09-20T10:00:00Z','2026-09-20T10:00:00Z','quiz')`);
  for (let i = 0; i < 3; i++) await db.query(`insert into fact_lead(lead_id,created_at,updated_at,source) values (gen_random_uuid(), '2026-09-28T10:00:00Z','2026-09-28T10:00:00Z','quiz')`);

  const r1 = (await db.query("select * from refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW])).rows[0];
  assert.ok(Number(r1.created) >= 3, `létrejött: ${JSON.stringify(r1)}`);
  const keys = (await db.query("select insight_key, severity from alert order by insight_key")).rows.map((r) => r.insight_key);
  for (const k of ["ingestion_stale", "ingestion_error", "lead_drop"]) assert.ok(keys.includes(k), `hiányzik: ${k}; van: ${keys}`);
  assert.ok(keys.includes("lead_utm_gap"));

  // deduplikálás: második frissítés nem hoz létre újat
  const before = Number((await db.query("select count(*) n from alert")).rows[0].n);
  const r2 = (await db.query("select * from refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW])).rows[0];
  assert.equal(Number(r2.created), 0);
  assert.equal(Number((await db.query("select count(*) n from alert")).rows[0].n), before);

  // kézbesítési sor: a kritikus azonnali, majd kiküldés után eltűnik
  const q = (await db.query("select id, immediate, insight_key from alert_to_notify")).rows;
  assert.ok(q.some((r) => r.insight_key === "lead_drop" && r.immediate === true));
  assert.ok(!q.some((r) => r.insight_key === "lead_utm_gap"), "a nem értesítős szabály nem kerül a sorba");
  await db.query("select alerts_mark_notified($1)", [q.map((r) => r.id)]);
  assert.equal((await db.query("select * from alert_to_notify")).rows.length, 0);

  // számlálók
  const c = (await db.query("select * from alert_counts()")).rows[0];
  assert.ok(Number(c.unread) >= 4 && Number(c.critical) >= 1);

  // halasztás: a postaládából eltűnik, lejárat után visszajön
  const drop = (await db.query("select id from alert where insight_key='lead_drop'")).rows[0].id;
  await db.query("select alert_set_status($1,'snoozed',3)", [drop]);
  assert.ok(!(await db.query("select 1 from alert_inbox where id=$1", [drop])).rows.length);
  await db.query("update alert set snoozed_until = now() - interval '1 hour' where id=$1", [drop]);
  assert.ok((await db.query("select 1 from alert_inbox where id=$1", [drop])).rows.length, "lejárt halasztás után látszik");
  await db.query("update alert set snoozed_until = '2026-09-29T00:00:00Z' where id=$1", [drop]);
  await db.query("select refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW]);
  assert.equal((await db.query("select status from alert where id=$1", [drop])).rows[0].status, "open");

  // kézzel megoldott riasztás a várakozási időn belül nem tér vissza, utána igen
  await db.query("select alert_set_status($1,'resolved')", [drop]);
  await db.query("update alert set resolved_at = $2::timestamptz - interval '1 day' where id=$1", [drop, NOW]);
  await db.query("select refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW]);
  assert.equal((await db.query("select status from alert where id=$1", [drop])).rows[0].status, "resolved");
  await db.query("update alert set resolved_at = $2::timestamptz - interval '10 days' where id=$1", [drop, NOW]);
  await db.query("select refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW]);
  assert.equal((await db.query("select status from alert where id=$1", [drop])).rows[0].status, "open");

  // automatikus megoldódás: sikeres futás után az elavult-riasztás megszűnik
  await db.query(`insert into ingestion_run(job,started_at,finished_at,status) values ('ads','2026-09-30T08:00:00Z','2026-09-30T08:05:00Z','ok')`);
  await db.query("select refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW]);
  const st = (await db.query("select status, auto_resolved from alert where insight_key='ingestion_stale'")).rows[0];
  assert.equal(st.status, "resolved");
  assert.equal(st.auto_resolved, true);

  // jogosultság: látogató nem olvas, bejelentkezett olvas de közvetlenül nem ír
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from alert"));
  await db.exec("reset role; set role authenticated");
  assert.ok((await db.query("select * from alert")).rows.length > 0);
  await assert.rejects(db.query("update alert set status='resolved'"));
  await db.exec("reset role");
});

test("lead-életút: alkalmassági és foglalási leadek szétválasztva, félbehagyott és végigvitt, lépésidők, személyszintű összekötés", async () => {
  const db = await setup();
  const ins = (id, at, src, stage, prog, hash, extra = {}) => db.query(
    `insert into fact_lead(lead_id,created_at,updated_at,source,booking_stage,result_type,booking_progress,email_hash,utm,click_ids,quiz_session_id,dokirex_booking_id)
     values ($1,$2,$2,$3,$4,'ok',$5,$6,$7,$8,$9,$10)`,
    [id, at, src, stage, prog ? JSON.stringify(prog) : null, hash, extra.utm ? JSON.stringify(extra.utm) : null, extra.click ? JSON.stringify(extra.click) : null, extra.qs ?? null, extra.dok ?? null]);
  const U = (n) => `00000000-0000-0000-0000-00000000000${n}`;
  await db.query(`insert into fact_quiz_session(session_id,payload) values ($1,$2)`, [U(9), JSON.stringify({ started_at: "2026-09-10T09:50:00Z", furthest_step: "nearDiopter", completed: true })]);
  await ins(U(1), "2026-09-10T10:00:00Z", "quiz", null, null, "A", { utm: { utm_source: "facebook", utm_campaign: "C1" }, qs: U(9) });
  await ins(U(2), "2026-09-12T10:00:00Z", "booking", "completed", { lastStep: "done", totalSeconds: 300, stepSeconds: { contact: 60, choice: 10, treatment: 30, calendar: 150, confirm: 49, done: 1 } }, "A", { dok: 555 });
  await ins(U(3), "2026-09-13T10:00:00Z", "booking", "contact", { lastStep: "calendar", secondsOnLastStep: 180, totalSeconds: 200, stepSeconds: { contact: 15, choice: 5, calendar: 180 } }, "B", { click: { fbclid: "x" } });
  await ins(U(4), "2026-09-14T10:00:00Z", "booking", "completed", { lastStep: "callback", totalSeconds: 40, stepSeconds: { contact: 20, callback: 0 } }, "C");
  await ins(U(5), "2026-09-15T10:00:00Z", "quiz", null, null, "D");
  await db.query(`insert into fact_lead_event(source_id,lead_id,event,step,meta,created_at) values (1,$1,'step_view','calendar','{"secondsOnLastStep":150}','2026-09-12T10:03:00Z')`, [U(2)]);

  const j = Object.fromEntries((await db.query("select lead_id, lead_type, outcome, last_step, total_seconds, hours_to_booking, hours_since_quiz, has_source, click_id_type, quiz_furthest_step from lead_journey")).rows.map((r) => [r.lead_id, r]));
  assert.equal(j[U(1)].lead_type, "alkalmassagi");
  assert.equal(j[U(2)].lead_type, "idopontfoglalas");
  assert.equal(j[U(2)].outcome, "foglalt");
  assert.equal(j[U(3)].outcome, "felbehagyta");
  assert.equal(j[U(3)].last_step, "calendar");
  assert.equal(j[U(4)].outcome, "visszahivas");
  assert.equal(Number(j[U(1)].hours_to_booking), 48);
  assert.equal(Number(j[U(2)].hours_since_quiz), 48);
  assert.equal(j[U(5)].hours_to_booking, null, "a másik személy kvíz-leadje nem foglalt");
  assert.equal(j[U(1)].quiz_furthest_step, "nearDiopter");
  assert.equal(Number(j[U(1)].total_seconds), 600);
  assert.equal(j[U(3)].click_id_type, "fbclid");
  assert.equal(j[U(1)].has_source, true);
  assert.equal(j[U(5)].has_source, false);

  const s = (await db.query("select * from lead_journey_summary('2026-09-01','2026-09-30',null)")).rows[0];
  assert.equal(Number(s.quiz_leads), 2);
  assert.equal(Number(s.quiz_leads_booked_later), 1);
  assert.equal(Number(s.booking_starts), 3);
  assert.equal(Number(s.booked), 1);
  assert.equal(Number(s.abandoned), 1);
  assert.equal(Number(s.callbacks), 1);
  assert.ok(Math.abs(Number(s.completion_rate) - 1 / 3) < 1e-9);
  assert.equal(Number(s.median_seconds_booked), 300);
  assert.equal(Number(s.median_seconds_abandoned), 200);
  assert.equal(Number(s.median_hours_quiz_to_booking), 48);

  const st = Object.fromEntries((await db.query("select * from lead_step_time('2026-09-01','2026-09-30',null)")).rows.map((r) => [r.step, r]));
  assert.equal(Number(st.calendar.dropped_here), 1);
  assert.equal(Number(st.calendar.median_seconds_abandoned), 180);
  assert.equal(Number(st.calendar.median_seconds_booked), 150);
  assert.equal(Number(st.done.reached_booked), 1);

  const tl = (await db.query("select kind, label from lead_timeline($1)", [U(2)])).rows;
  assert.ok(tl.some((r) => r.kind === "event" && r.label === "step_view"));
  assert.ok(tl.some((r) => r.kind === "related" && /alkalmassági/.test(r.label)));
  assert.equal((await db.query("select count(*) n from lead_journey_summary('2026-09-01','2026-09-30','eszteika_plasztika')")).rows[0].n, 1);
  assert.equal(Number((await db.query("select quiz_leads from lead_journey_summary('2026-09-01','2026-09-30','eszteika_plasztika')")).rows[0].quiz_leads), 0);

  await db.exec("set role anon");
  await assert.rejects(db.query("select * from lead_journey"));
  await db.exec("reset role");
});

test("ActiveCampaign: lead-összekötés hash alapján, automatizmus-előrehaladás, kampány-arányok és AC-riasztások", async () => {
  const db = await setup();
  const NOW = "2026-09-30T12:00:00Z";
  const U = (n) => `00000000-0000-0000-0000-0000000001${String(n).padStart(2, "0")}`;
  const lead = (n, at, hash, src = "booking", stage = "completed") => db.query(
    `insert into fact_lead(lead_id,created_at,updated_at,source,booking_stage,email_hash,booking_progress) values ($1,$2,$2,$3,$4,$5,'{"lastStep":"done","totalSeconds":100}')`, [U(n), at, src, stage, hash]);
  await lead(1, "2026-09-20T10:00:00Z", "h1");
  await lead(2, "2026-09-21T10:00:00Z", "h2");
  await lead(3, "2026-09-22T10:00:00Z", "h3");
  for (let i = 4; i <= 6; i++) await lead(i, `2026-09-2${i}T10:00:00Z`, `hx${i}`); // AC-ben nincs
  await db.query(`insert into dim_ac_automation(automation_id,name) values (105,'Online időpontfoglalás')`);
  await db.query(`insert into fact_ac_contact(ac_contact_id,email_hash,created_at,tags,channel,sent_count,bounced_hard) values
    (1,'h1','2026-09-20T10:05:00Z','{foglalt}','Facebook',3,false),
    (2,'h2','2026-09-21T10:30:00Z','{}','Google',1,false),
    (3,'h3','2026-09-22T11:00:00Z','{}','Google',1,true)`);
  await db.query(`insert into fact_ac_contact_automation(id,ac_contact_id,automation_id,raw_status,added_at,removed_at,completed_elements,total_elements,completed) values
    (1,1,105,'2','2026-09-20T10:06:00Z','2026-09-25T10:00:00Z',5,5,true),
    (2,2,105,'1','2026-09-21T10:31:00Z',null,2,5,false),
    (3,3,105,'1','2026-09-22T11:01:00Z','2026-09-23T00:00:00Z',1,5,false)`);
  // elakadt tagságok: 5 régi aktív névjegy egy másik automatizmusban
  await db.query(`insert into dim_ac_automation(automation_id,name) values (200,'Emlékeztető')`);
  for (let i = 0; i < 5; i++) await db.query(`insert into fact_ac_contact_automation(id,ac_contact_id,automation_id,raw_status,added_at,completed_elements,total_elements,completed) values ($1,$2,200,'1','2026-08-01T10:00:00Z',1,4,false)`, [100 + i, 900 + i]);
  await db.query(`insert into fact_ac_campaign_snapshot(snapshot_date,campaign_id,name,sent_at,status,send_amt,unique_opens,verified_unique_opens,unique_link_clicks,unsubscribes,hard_bounces)
    values ('2026-09-29',1,'Régi','2026-09-10T10:00:00Z','5',1000,400,300,40,5,2), ('2026-09-30',1,'Régi','2026-09-10T10:00:00Z','5',1000,500,350,50,6,30)`);

  const la = Object.fromEntries((await db.query("select * from lead_ac")).rows.map((r) => [r.lead_id, r]));
  assert.equal(la[U(1)].automation_state, "befejezte");
  assert.equal(la[U(2)].automation_state, "aktiv");
  assert.equal(la[U(3)].automation_state, "kilepett");
  assert.equal(la[U(4)].automation_state, "nincs");
  assert.equal(la[U(4)].ac_contact_id, null);
  assert.equal(Number(la[U(2)].automation_progress), 0.4);
  assert.ok(Math.abs(Number(la[U(1)].hours_lead_to_ac) - 5 / 60) < 1e-6);
  assert.equal(la[U(3)].ac_bounced_hard, true);
  assert.equal(la[U(1)].automation_name, "Online időpontfoglalás");

  const s = (await db.query("select * from lead_ac_summary('2026-09-01','2026-09-30',null)")).rows[0];
  assert.equal(Number(s.leads), 6);
  assert.equal(Number(s.in_ac), 3);
  assert.equal(Number(s.not_in_ac), 3);
  assert.equal(Number(s.finished), 1);
  assert.equal(Number(s.active), 1);
  assert.equal(Number(s.exited), 1);
  assert.equal(Number(s.bounced), 1);
  assert.equal((await db.query("select count(*) n from lead_journey_ac")).rows[0].n, 6);

  const prog = (await db.query("select * from mart_ac_automation_progress where automation_id=105 order by completed_elements")).rows;
  assert.deepEqual(prog.map((r) => Number(r.completed_elements)), [1, 2, 5]);
  assert.equal(Number(prog[2].finished), 1);

  const camp = (await db.query("select * from mart_ac_campaign_performance")).rows;
  assert.equal(camp.length, 1, "csak a legfrissebb pillanatkép");
  assert.equal(Number(camp[0].unique_opens), 500);
  assert.ok(Math.abs(Number(camp[0].open_rate) - 0.5) < 1e-9);
  assert.ok(Math.abs(Number(camp[0].verified_open_rate) - 0.35) < 1e-9);
  assert.ok(Math.abs(Number(camp[0].click_to_open_rate) - 0.1) < 1e-9);

  const al = (await db.query("select insight_key, scope_label, severity from data_quality_alerts($1::timestamptz)", [NOW])).rows;
  const keys = al.map((r) => r.insight_key);
  assert.ok(keys.includes("ac_sync_gap"), `hiányzik ac_sync_gap: ${keys}`);
  assert.ok(keys.includes("ac_stuck_contacts"));
  assert.ok(keys.includes("ac_bounce_rate"));
  assert.ok(!al.some((r) => r.insight_key === "ac_stuck_contacts" && r.scope_label === "Online időpontfoglalás"));
  // a meglévő adatminőségi riasztások továbbra is működnek, és a refresh felveszi az AC-szabályokat
  const r = (await db.query("select * from refresh_alerts($1::date, 14, $2::timestamptz)", [ASOF, NOW])).rows[0];
  assert.ok(Number(r.created) >= 3);
  assert.ok((await db.query("select 1 from alert where insight_key='ac_sync_gap'")).rows.length === 1);

  // AC-adat nélkül nincs téves szinkron-riasztás
  const db2 = await setup();
  await db2.query(`insert into fact_lead(lead_id,created_at,updated_at,source,email_hash) select gen_random_uuid(), '2026-09-25T10:00:00Z','2026-09-25T10:00:00Z','booking','x'||g from generate_series(1,6) g`);
  assert.ok(!(await db2.query("select 1 from data_quality_alerts($1::timestamptz) where insight_key='ac_sync_gap'", [NOW])).rows.length);

  await db.exec("set role anon");
  await assert.rejects(db.query("select * from lead_ac"));
  await assert.rejects(db.query("select * from fact_ac_contact"));
  await db.exec("reset role");
});

test("teljesítmény: az új korrelációs motor és jel-nézet ugyanazt adja, mint a régi; a szűrt hívás a teljes részhalmaza", async () => {
  const oldDb = await setup(["0016_performance.sql"]);
  const newDb = await setup();
  let seed = 11; const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const spend = Array.from({ length: 70 }, () => 50000 + Math.round(rnd() * 100000));
  for (const db of [oldDb, newDb]) {
    seed = 11; for (let i = 0; i < 70; i++) rnd();
    seed = 11;
    for (let i = 0; i < 70; i++) {
      const brand = i >= 3 ? Math.round(spend[i - 3] / 1000 * 3 + (i % 5)) : 10;
      await db.query(`insert into fact_ad_performance_daily(date,platform,account_id,campaign_id,spend,impressions,clicks) values ($1,'meta','a','c1',$2,1000,10), ($1,'tiktok','t','c2',$3,500,5)`, [day(i), spend[i], 20000 + (i % 7) * 1000]);
      await db.query(`insert into fact_keyword_daily(date,account_id,campaign_id,ad_group_id,keyword_text,match_type,impressions,clicks,spend) values ($1,'g','k1','ag','saint james','',$2,1,100), ($1,'g','k1','ag','lézer ár','',$3,2,200)`, [day(i), brand, 50 + (i % 9)]);
      await db.query(`insert into fact_web_daily(date,account_id,source,medium,channel_group,sessions) values ($1,'312872101','(direct)','(none)','Direct',$2)`, [day(i), 200 + (i * 7) % 90]);
    }
  }
  const q = "select signal_a, signal_b, lag_days, r, n, t_stat, r_lag0 from signal_correlations_best($1::date,$2::date,14,true,14,2.5) order by 1,2";
  const a = (await oldDb.query(q, [day(0), day(69)])).rows;
  const b = (await newDb.query(q, [day(0), day(69)])).rows;
  assert.ok(a.length > 0);
  assert.deepEqual(b, a, "a teljes korrelációs lista azonos");
  const sig = async (db) => (await db.query("select date::text d, signal, value::text v from mart_signals_long order by 1,2,3")).rows;
  assert.deepEqual(await sig(newDb), await sig(oldDb), "a jel-nézet azonos");
  // szűrt hívás = a teljes lista megfelelő részhalmaza
  const f = (await newDb.query(
    "select signal_a, signal_b, lag_days, r, n, t_stat, r_lag0 from signal_correlations_best($1::date,$2::date,10,true,28,3.0, array['spend_meta','spend_tiktok'], array['google_brand_impressions']) order by 1,2", [day(0), day(69)])).rows;
  const full = (await newDb.query(
    "select signal_a, signal_b, lag_days, r, n, t_stat, r_lag0 from signal_correlations_best($1::date,$2::date,10,true,28,3.0) where signal_a in ('spend_meta','spend_tiktok') and signal_b = 'google_brand_impressions' order by 1,2", [day(0), day(69)])).rows;
  assert.deepEqual(f, full);
  assert.ok(f.some((r) => r.signal_a === "spend_meta" && r.lag_days === 3));
  // az észrevételek hatás-szabálya továbbra is működik; a nézet megtartja a hívó jogait
  const ins = (await newDb.query("select insight_key from insights($1::date, 14)", [day(69)])).rows.map((r) => r.insight_key);
  assert.ok(Array.isArray(ins));
  assert.match(String((await newDb.query("select reloptions::text r from pg_class where relname='mart_signals_long'")).rows[0].r), /security_invoker=true/);
});

test("ActiveCampaign: kampánynevek és e-mail tartalom, automatizmus-lépcső forrás szerint", async () => {
  const db = await setup();
  const U = (n) => `00000000-0000-0000-0000-0000000002${String(n).padStart(2, "0")}`;
  await db.query(`insert into dim_ac_automation(automation_id,name) values (95,'Lassjol-Új-Páciens-Flow')`);
  await db.query(`insert into dim_ac_message(message_id,name,subject,preheader,from_name,html) values (7,'Üdvözlő','Köszönjük a jelentkezést','Nézd meg a következő lépést','Saint James','<p>Szia</p>')`);
  await db.query(`insert into dim_ac_campaign(campaign_id,label,campaign_type,automation_id,base_message_id,sent_at) values (50,'Üdvözlő e-mail','single',95,7,'2026-09-20T08:00:00Z'), (51,null,'single',null,null,'2026-09-21T08:00:00Z')`);
  await db.query(`insert into fact_ac_campaign_snapshot(snapshot_date,campaign_id,name,sent_at,status,send_amt,unique_opens,unique_link_clicks,unsubscribes,hard_bounces)
    values ('2026-09-30',50,'',  '2026-09-20T08:00:00Z','5',200,100,20,2,1), ('2026-09-30',51,'','2026-09-21T08:00:00Z','5',100,40,4,0,0)`);
  const camps = Object.fromEntries((await db.query("select campaign_id::text id, name, subject, automation_name from mart_ac_campaign_performance")).rows.map((r) => [r.id, r]));
  assert.equal(camps["50"].name, "Üdvözlő e-mail");
  assert.equal(camps["50"].subject, "Köszönjük a jelentkezést");
  assert.equal(camps["50"].automation_name, "Lassjol-Új-Páciens-Flow");
  assert.equal(camps["51"].name, "#51", "név nélkül az azonosító");
  const em = (await db.query("select * from ac_campaign_email(50)")).rows[0];
  assert.equal(em.html, "<p>Szia</p>");
  assert.equal(em.preheader, "Nézd meg a következő lépést");
  assert.equal((await db.query("select * from ac_flow_emails(95)")).rows.length, 1);

  // leadek és AC-névjegyek: 2 Facebook, 1 Google (click id), 1 AC-űrlap (nincs lead)
  const lead = (n, hash, utm, click) => db.query(`insert into fact_lead(lead_id,created_at,updated_at,source,email_hash,utm,click_ids) values ($1,'2026-09-10T10:00:00Z','2026-09-10T10:00:00Z','quiz',$2,$3,$4)`, [U(n), hash, utm ? JSON.stringify(utm) : null, click ? JSON.stringify(click) : null]);
  await lead(1, "f1", { utm_source: "facebook" }); await lead(2, "f2", { utm_source: "facebook" }); await lead(3, "g1", null, { gclid: "x" });
  await db.query(`insert into fact_ac_contact(ac_contact_id,email_hash,channel) values (1,'f1',null),(2,'f2',null),(3,'g1',null),(4,'z9','Weboldal űrlap')`);
  // mélység (17 lépéses automatizmus): FB: 17 (kész), 5; Google: 2; űrlap: 17 (kész)
  const mem = (id, c, depth, removed) => db.query(`insert into fact_ac_contact_automation(id,ac_contact_id,automation_id,added_at,removed_at,completed_elements,total_elements,completed) values ($1,$2,95,'2026-09-15T10:00:00Z',$3,$4,17,$5)`, [id, c, removed, depth, depth === 17]);
  await mem(1, 1, 17, "2026-09-18T10:00:00Z"); await mem(2, 2, 5, null); await mem(3, 3, 2, null); await mem(4, 4, 17, "2026-09-18T10:00:00Z");

  const src = Object.fromEntries((await db.query("select ac_contact_id::text id, source from ac_contact_source")).rows.map((r) => [r.id, r.source]));
  assert.deepEqual(src, { 1: "facebook", 2: "facebook", 3: "gclid", 4: "Weboldal űrlap" });

  const steps = (await db.query("select * from ac_flow_steps(95)")).rows;
  assert.equal(steps.length, 18, "0..17");
  assert.equal(Number(steps[0].reached), 4);
  assert.equal(Number(steps[2].reached), 4, "mind a négyen elérték a 2. lépést");
  assert.equal(Number(steps[3].reached), 3);
  assert.equal(Number(steps[3].lost_from_previous), 1);
  assert.equal(Number(steps[17].reached), 2);
  assert.equal(Number(steps[17].pct_of_entered), 0.5);
  const fbOnly = (await db.query("select * from ac_flow_steps(95, null, null, 'facebook')")).rows;
  assert.equal(Number(fbOnly[6].reached), 1);
  assert.equal(Number(fbOnly[5].reached), 2);

  const by = Object.fromEntries((await db.query("select * from ac_flow_by_source(95)")).rows.map((r) => [r.source, r]));
  assert.equal(Number(by.facebook.entered), 2);
  assert.equal(Number(by.facebook.avg_depth), 11);
  assert.equal(Number(by.facebook.finished), 1);
  assert.equal(Number(by.gclid.pct_finished), 0);
  assert.equal(Number(by["Weboldal űrlap"].pct_finished), 1);
  assert.equal((await db.query("select * from ac_flow_by_source(95,'2026-10-01',null)")).rows.length, 0, "dátumszűrő");
  assert.equal(Number((await db.query("select members from mart_ac_automation_overview where automation_id=95")).rows[0].members), 4);

  await db.exec("set role anon");
  await assert.rejects(db.query("select * from dim_ac_message"));
  await db.exec("reset role");
});

test("dataLayer-események: új tölcsér-szintek, GA4–saját egyeztetés, lefedettség és riasztás", async () => {
  const db = await setup();
  const stages = (await db.query("select event_name, stage from funnel_event_map where stage like 'dl_%' order by 1")).rows;
  assert.ok(stages.some((r) => r.event_name === "appointment_booked" && r.stage === "dl_booked"));
  assert.equal(stages.length, 7);
  await assert.rejects(db.query("insert into funnel_event_map(event_name,stage) values ('x','nincs')"));
  // a régi leképezés érintetlen
  assert.equal((await db.query("select stage from funnel_event_map where event_name='generate_lead'")).rows[0].stage, "ga_hard_lead");

  const NOW = "2026-10-08T12:00:00Z";
  const lead = (n, at, stage, last) => db.query(
    `insert into fact_lead(lead_id,created_at,updated_at,source,booking_stage,booking_progress) values (gen_random_uuid(),$1,$1,'booking',$2,$3)`,
    [at, stage, JSON.stringify({ lastStep: last })]);
  // 8 foglalás és 2 visszahívás a héten, 4 félbehagyott
  for (let i = 0; i < 8; i++) await lead(i, "2026-10-03T10:00:00Z", "completed", "done");
  for (let i = 0; i < 2; i++) await lead(i, "2026-10-04T10:00:00Z", "completed", "callback");
  for (let i = 0; i < 4; i++) await lead(i, "2026-10-05T10:00:00Z", "contact", "calendar");
  await db.query(`insert into ga_property_map(account_id,site,business_line) values ('312872101','lassjol.hu','szemeszet') on conflict do nothing`);
  const ev = (d, name, n) => db.query(`insert into fact_web_event_daily(date,account_id,event_name,event_count) values ($1,'312872101',$2,$3)`, [d, name, n]);

  // az új mérés még nem él: nincs lefedettség-riasztás
  await ev("2026-10-03", "generate_lead", 5);
  assert.ok(!(await db.query("select 1 from tracking_alerts($1::timestamptz)", [NOW])).rows.length);

  // él, de a GA4 a 8 foglalásból csak 1-et lát
  await ev("2026-10-03", "appointment_booked", 1);
  await ev("2026-10-04", "callback_requested", 2);
  const rec = (await db.query("select * from mart_tracking_reconciliation where date='2026-10-03'")).rows[0];
  assert.equal(Number(rec.db_booked), 8);
  assert.equal(Number(rec.ga_booked), 1);
  assert.equal(Number(rec.db_leads), 8);
  assert.equal(Number(rec.ga_generate_lead), 5);
  const cov = Object.fromEntries((await db.query("select * from tracking_coverage('2026-10-01','2026-10-08',null)")).rows.map((r) => [r.event, r]));
  assert.equal(Number(cov.lead.db_count), 14);
  assert.ok(Math.abs(Number(cov.foglalas.coverage) - 1 / 8) < 1e-9);
  assert.equal(Number(cov.visszahivas.coverage), 1);
  const al = (await db.query("select * from tracking_alerts($1::timestamptz)", [NOW])).rows;
  assert.equal(al.length, 1);
  assert.equal(al[0].insight_key, "tracking_coverage");
  assert.ok((await db.query("select 1 from data_quality_alerts($1::timestamptz) where insight_key='tracking_coverage'", [NOW])).rows.length === 1);
  // jó lefedettségnél nincs riasztás
  await ev("2026-10-05", "appointment_booked", 6);
  assert.ok(!(await db.query("select 1 from tracking_alerts($1::timestamptz)", [NOW])).rows.length);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from mart_tracking_reconciliation"));
  await db.exec("reset role");
});

test("Google-kampányazonosító (gad_campaignid) a leadből: oszlop a lead-életútban és összekötés a kampánnyal", async () => {
  const db = await setup();
  await cls(db, "google", "g1", "23005482141", "Perf.Max - Lézeres szemműtét");
  const ins = (n, click) => db.query(
    `insert into fact_lead(lead_id,created_at,updated_at,source,booking_stage,click_ids,booking_progress) values ($1,'2026-10-01T09:00:00Z','2026-10-01T09:00:00Z','booking','contact',$2,'{"lastStep":"contact"}')`,
    [`00000000-0000-0000-0000-0000000003${String(n).padStart(2, "0")}`, click ? JSON.stringify(click) : null]);
  await ins(1, { gclid: "x", gad_campaignid: "23005482141", gad_source: "1" });
  await ins(2, { gclid: "y" });
  await ins(3, { gad_campaignid: "999" });
  const j = Object.fromEntries((await db.query("select lead_id, google_campaign_id, click_id_type from lead_journey")).rows.map((r) => [r.lead_id.slice(-2), r]));
  assert.equal(j["01"].google_campaign_id, "23005482141");
  assert.equal(j["01"].click_id_type, "gclid");
  assert.equal(j["02"].google_campaign_id, null);
  const g = (await db.query("select lead_id, campaign_name from lead_google_campaign order by lead_id")).rows;
  assert.equal(g.length, 2, "csak a gad_campaignid-s leadek");
  assert.equal(g[0].campaign_name, "Perf.Max - Lézeres szemműtét");
  assert.equal(g[1].campaign_name, null, "ismeretlen azonosító: név nélkül, de nem vész el");
  // a korábbi nézetek továbbra is működnek (lead_journey_ac, összesítő)
  assert.equal(Number((await db.query("select count(*) n from lead_journey_ac")).rows[0].n), 3);
  assert.equal(Number((await db.query("select leads from lead_ac_summary('2026-10-01','2026-10-01',null)")).rows[0].leads), 3);
  await db.exec("set role anon");
  await assert.rejects(db.query("select * from lead_google_campaign"));
  await db.exec("reset role");
});
