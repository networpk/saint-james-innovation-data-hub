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
  await db.exec(sql("0001_core.sql"));
  await db.exec(sql("0002_kpi_targets.sql"));
  await db.exec(`create table campaign_class (platform text, account_id text, campaign_id text, campaign_name text,
    business_line text, category text, subcategory text, class_source text)`);
  await db.exec(sql("0004_analytics_v2.sql"));
  await db.exec(sql("0005_creatives_insights.sql"));
  await db.exec(sql("0007_fix_click_gap.sql"));
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
