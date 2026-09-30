-- Analytics v2: forgalom (GA4), kulcsszó, keresési kifejezés, hirdetés-dimenzió, téma-réteg,
-- tölcsér / lemorzsolódás minden szinten, kohorszok, és korrelációs motor.
-- Előfeltétel: a kampány-besorolás nézet (campaign_class: platform, account_id, campaign_id, campaign_name,
-- business_line, category, subcategory, class_source) – lásd a Hub projekt kampány-besorolás migrációját.
-- RLS/jogosultság külön fájlban (0005_rls_v2.sql), mert szerepkörök csak Supabase-ben vannak.

-- ===== 1. Tény- és dimenziótáblák =====================================================

-- GA4 forgalom napi szinten forrás/médium/csatorna/kampány bontásban.
create table if not exists fact_web_daily (
  date date not null,
  account_id text not null,                 -- GA4 property
  source text not null default '',
  medium text not null default '',
  channel_group text not null default '',   -- session default channel group (Paid Search, Paid Social, Organic Search, Direct, ...)
  campaign text not null default '',
  sessions numeric(14,2) not null default 0,
  users numeric(14,2) not null default 0,
  engaged_sessions numeric(14,2) not null default 0,
  pageviews numeric(14,2) not null default 0,
  engagement_seconds numeric(16,2) not null default 0,
  loaded_at timestamptz not null default now(),
  primary key (date, account_id, source, medium, channel_group, campaign)
);

-- GA4 események (soft lead: soft_conv_foglaljon; űrlap: generate_lead; videó: video_start/progress/complete ...).
create table if not exists fact_web_event_daily (
  date date not null,
  account_id text not null,
  event_name text not null,
  source text not null default '',
  medium text not null default '',
  campaign text not null default '',
  event_count numeric(14,2) not null default 0,
  loaded_at timestamptz not null default now(),
  primary key (date, account_id, event_name, source, medium, campaign)
);

-- GA4 belépő oldalak (melyik oldalon landolnak, és mennyire elkötelezettek).
create table if not exists fact_web_landing_daily (
  date date not null,
  account_id text not null,
  landing_page text not null,
  sessions numeric(14,2) not null default 0,
  users numeric(14,2) not null default 0,
  engaged_sessions numeric(14,2) not null default 0,
  loaded_at timestamptz not null default now(),
  primary key (date, account_id, landing_page)
);

-- Google Ads kulcsszó (csak keresési kampányokban; Performance Max nem ad kulcsszót).
create table if not exists fact_keyword_daily (
  date date not null,
  account_id text not null,
  campaign_id text not null,
  ad_group_id text not null default '',
  keyword_text text not null,
  match_type text not null default '',
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  spend numeric(14,2) not null default 0,
  conversions numeric(12,2) not null default 0,
  loaded_at timestamptz not null default now(),
  primary key (date, account_id, campaign_id, ad_group_id, keyword_text, match_type)
);
create index if not exists idx_fkd_kw on fact_keyword_daily (keyword_text, date);

-- Google Ads keresési kifejezések (amit a felhasználó ténylegesen beírt).
create table if not exists fact_search_term_daily (
  date date not null,
  account_id text not null,
  campaign_id text not null,
  ad_group_id text not null default '',
  search_term text not null,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  spend numeric(14,2) not null default 0,
  conversions numeric(12,2) not null default 0,
  loaded_at timestamptz not null default now(),
  primary key (date, account_id, campaign_id, ad_group_id, search_term)
);

-- Google keresési kampányok megjelenési részesedése (elvesztett volumen: költségkeret vs. rangsor).
create table if not exists fact_google_share_daily (
  date date not null,
  account_id text not null,
  campaign_id text not null,
  search_impression_share numeric(6,4),
  search_top_impression_share numeric(6,4),
  budget_lost_share numeric(6,4),
  rank_lost_share numeric(6,4),
  loaded_at timestamptz not null default now(),
  primary key (date, account_id, campaign_id)
);

-- Hirdetés-szótár: név + szöveg (témabesoroláshoz).
create table if not exists dim_ad (
  platform text not null,
  ad_id text not null,
  ad_name text,
  body text,
  title text,
  link_url text,
  updated_at timestamptz not null default now(),
  primary key (platform, ad_id)
);

-- Kampány-beállítások napi pillanatképe (költségkeret, licit, cél) – stratégia-felismeréshez.
create table if not exists fact_campaign_setting_daily (
  date date not null,
  platform text not null,
  account_id text not null,
  campaign_id text not null,
  adset_id text not null default '',
  objective text,
  campaign_daily_budget numeric(14,2),
  adset_daily_budget numeric(14,2),
  bid_strategy text,
  loaded_at timestamptz not null default now(),
  primary key (date, platform, account_id, campaign_id, adset_id)
);

-- GA4 property → üzletág / oldal.
create table if not exists ga_property_map (
  account_id text primary key,
  site text,
  business_line text,
  note text
);
insert into ga_property_map (account_id, site, business_line, note) values
  ('312872101', 'lassjol.hu', 'szemeszet', 'Lassjol.hu – GA4'),
  ('490259280', 'saintjameshungary.hu', null, 'üzletág-hozzárendelés egyeztetendő')
on conflict do nothing;

-- Melyik GA4 esemény melyik tölcsér-szint.
create table if not exists funnel_event_map (
  event_name text primary key,
  stage text not null check (stage in ('soft_lead','ga_hard_lead','video_start','video_complete')),
  note text
);
insert into funnel_event_map (event_name, stage, note) values
  ('soft_conv_foglaljon', 'soft_lead', 'kattintás a foglalásra, beküldés nélkül'),
  ('generate_lead', 'ga_hard_lead', 'beküldött űrlap a GA4 szerint'),
  ('video_start', 'video_start', null),
  ('video_complete', 'video_complete', null)
on conflict do nothing;

-- A foglalási folyamat lépései (sorrend + címke).
create table if not exists booking_step (
  ord int primary key,
  step text not null unique,
  label text not null
);
insert into booking_step (ord, step, label) values
  (1,'contact','Elérhetőség'),(2,'choice','Választás'),(3,'treatment','Kezelés'),
  (4,'calendar','Naptár'),(5,'confirm','Megerősítés'),(6,'done','Kész'),(7,'callback','Visszahívás')
on conflict do nothing;

-- A kvíz közös lépései (elágazás előtt) – a fact_quiz_session.payload->>'furthest_order' alapján.
create table if not exists quiz_step (
  ord int primary key,
  step text not null,
  label text not null
);
insert into quiz_step (ord, step, label) values
  (0,'welcome','Üdvözlő'),(1,'age','Életkor'),(2,'amblyopia','Amblyopia'),(3,'pregnancy','Terhesség'),
  (4,'glasses','Szemüveg'),(5,'distanceDiopter','Távoli dioptria'),(6,'nearDiopter','Közeli dioptria')
on conflict do nothing;

-- ===== 2. Téma-réteg ==================================================================

create table if not exists topic (
  topic text primary key,
  label text not null,
  note text
);
insert into topic (topic, label) values
  ('lezer','Lézeres szemműtét'),('lencse','Lencsecsere / RLE'),('szurkehalyog','Szürkehályog'),
  ('smile','SMILE'),('onestop','One Stop Shop'),('brand','Brand'),('competitor','Versenytárs'),
  ('altalanos','Általános szemészet')
on conflict do nothing;

-- target: mire illeszkedik a minta (kulcsszó, keresési kifejezés, kampány, hirdetés neve/szövege).
create table if not exists topic_rule (
  id bigserial primary key,
  priority int not null,
  target text not null check (target in ('keyword','search_term','campaign','ad')),
  pattern text not null,                   -- LIKE minta, ékezet- és kisbetű-érzéketlen
  topic text not null references topic(topic) on update cascade,
  active boolean not null default true,
  note text
);
insert into topic_rule (priority, target, pattern, topic) values
  (10,'keyword','%smile%','smile'), (10,'campaign','%smile%','smile'), (10,'ad','%smile%','smile'), (10,'search_term','%smile%','smile'),
  (11,'keyword','%one stop%','onestop'), (11,'campaign','%one stop%','onestop'), (11,'ad','%one stop%','onestop'),
  (20,'keyword','%saint james%','brand'), (20,'keyword','%st james%','brand'), (20,'keyword','%lassjol%','brand'),
  (20,'search_term','%saint james%','brand'), (20,'search_term','%st james%','brand'), (20,'search_term','%lassjol%','brand'),
  (20,'campaign','%brand%','brand'),
  (30,'keyword','%sasszem%','competitor'), (30,'search_term','%sasszem%','competitor'), (30,'campaign','%competitor%','competitor'),
  (40,'keyword','%lezer%','lezer'), (40,'search_term','%lezer%','lezer'), (40,'campaign','%lezer%','lezer'), (40,'ad','%lezer%','lezer'),
  (40,'keyword','%laser%','lezer'), (40,'search_term','%laser%','lezer'), (40,'campaign','%laser%','lezer'), (40,'ad','%laser%','lezer'),
  (40,'keyword','%contoura%','lezer'), (40,'campaign','%contoura%','lezer'), (40,'ad','%contoura%','lezer'),
  (41,'keyword','%lencse%','lencse'), (41,'search_term','%lencse%','lencse'), (41,'campaign','%lencse%','lencse'), (41,'ad','%lencse%','lencse'),
  (41,'keyword','%rle%','lencse'), (41,'campaign','%rle%','lencse'), (41,'ad','%rle%','lencse'),
  (42,'keyword','%szurkehalyog%','szurkehalyog'), (42,'search_term','%szurkehalyog%','szurkehalyog'),
  (42,'campaign','%szurkehalyog%','szurkehalyog'), (42,'ad','%szurkehalyog%','szurkehalyog'),
  (90,'campaign','%altalanos%','altalanos'), (90,'keyword','%szemeszet%','altalanos')
on conflict do nothing;

-- Ékezetmentesítés nélkül is működjön (az unaccent bővítmény hiányában): egyszerű ékezet-lefordítás.
create or replace function sj_norm(t text) returns text language sql immutable as $$
  select lower(translate(coalesce(t,''), 'áéíóöőúüűÁÉÍÓÖŐÚÜŰ', 'aeiooouuuAEIOOOUUU'))
$$;

-- Első illeszkedő szabály (legkisebb priority) dönt.
create or replace function topic_for(p_target text, p_text text) returns text language sql stable as $$
  select r.topic from topic_rule r
  where r.active and r.target = p_target and sj_norm(p_text) like sj_norm(r.pattern)
  order by r.priority, r.id limit 1
$$;

create or replace view keyword_topic as
select k.keyword_text, topic_for('keyword', k.keyword_text) as topic
from (select distinct keyword_text from fact_keyword_daily) k;

create or replace view search_term_topic as
select s.search_term, topic_for('search_term', s.search_term) as topic
from (select distinct search_term from fact_search_term_daily) s;

create or replace view campaign_topic as
select c.platform, c.account_id, c.campaign_id, topic_for('campaign', c.campaign_name) as topic
from campaign_class c;

-- Hirdetés témája: a hirdetés neve + címe + szövege együtt, különben a kampányé.
create or replace view ad_topic as
select a.platform, a.ad_id,
       topic_for('ad', concat_ws(' ', a.ad_name, a.title, a.body)) as topic
from dim_ad a;

-- ===== 3. Mart nézetek ================================================================

-- Téma × nap × platform (minden fizetett csatorna, konzisztens végösszeggel).
create or replace view mart_topic_daily as
select f.date, f.platform,
       coalesce(adt.topic, ct.topic, 'besorolatlan') as topic,
       sum(f.spend) as spend, sum(f.impressions) as impressions, sum(f.clicks) as clicks,
       sum(f.platform_leads) as platform_leads
from fact_ad_performance_daily f
left join ad_topic adt on adt.platform = f.platform and adt.ad_id = f.ad_id and f.ad_id <> ''
left join campaign_topic ct on ct.platform = f.platform and ct.account_id = f.account_id and ct.campaign_id = f.campaign_id
group by 1,2,3;

-- Kulcsszó × nap, témával és kampány-besorolással.
create or replace view mart_keyword_daily as
select k.date, k.account_id, k.campaign_id, c.campaign_name, c.business_line, c.category, c.subcategory,
       k.ad_group_id, k.keyword_text, k.match_type,
       kt.topic,
       k.impressions, k.clicks, k.spend, k.conversions
from fact_keyword_daily k
left join keyword_topic kt on kt.keyword_text = k.keyword_text
left join campaign_class c on c.platform = 'google' and c.account_id = k.account_id and c.campaign_id = k.campaign_id;

create or replace view mart_search_term_daily as
select s.date, s.account_id, s.campaign_id, c.campaign_name, c.business_line,
       s.search_term, st.topic, s.impressions, s.clicks, s.spend, s.conversions
from fact_search_term_daily s
left join search_term_topic st on st.search_term = s.search_term
left join campaign_class c on c.platform = 'google' and c.account_id = s.account_id and c.campaign_id = s.campaign_id;

-- Tölcsér napi szinten üzletágonként: megjelenés -> kattintás -> látogató -> soft lead -> űrlap -> foglalás.
create or replace view mart_funnel_daily as
with ads as (
  select f.date, coalesce(c.business_line,'besorolatlan') as bl,
         sum(f.spend) as ad_spend, sum(f.impressions) as ad_impressions, sum(f.clicks) as ad_clicks
  from fact_ad_performance_daily f
  left join campaign_class c on c.platform = f.platform and c.account_id = f.account_id and c.campaign_id = f.campaign_id
  group by 1,2
), web as (
  select w.date, coalesce(m.business_line,'besorolatlan') as bl,
         sum(w.sessions) as web_sessions, sum(w.users) as web_users, sum(w.engaged_sessions) as web_engaged_sessions
  from fact_web_daily w left join ga_property_map m on m.account_id = w.account_id
  group by 1,2
), webev as (
  select e.date, coalesce(m.business_line,'besorolatlan') as bl,
         sum(e.event_count) filter (where fm.stage = 'soft_lead') as soft_leads,
         sum(e.event_count) filter (where fm.stage = 'ga_hard_lead') as ga_hard_leads
  from fact_web_event_daily e
  join funnel_event_map fm on fm.event_name = e.event_name
  left join ga_property_map m on m.account_id = e.account_id
  group by 1,2
), leads as (
  select (created_at at time zone 'Europe/Budapest')::date as date, business_line as bl,
         count(*) filter (where source = 'booking') as booking_leads_started,
         count(*) filter (where source = 'booking' and booking_stage = 'completed') as hard_leads,
         count(*) filter (where source = 'booking' and booking_stage = 'completed' and dokirex_booking_id is not null) as booked_web,
         count(*) filter (where source <> 'booking') as quiz_leads
  from fact_lead group by 1,2
), keys as (
  select date, bl from ads union select date, bl from web union select date, bl from webev union select date, bl from leads
)
select k.date, k.bl as business_line,
       coalesce(a.ad_spend,0) as ad_spend, coalesce(a.ad_impressions,0) as ad_impressions, coalesce(a.ad_clicks,0) as ad_clicks,
       coalesce(w.web_sessions,0) as web_sessions, coalesce(w.web_users,0) as web_users,
       coalesce(w.web_engaged_sessions,0) as web_engaged_sessions,
       coalesce(e.soft_leads,0) as soft_leads, coalesce(e.ga_hard_leads,0) as ga_hard_leads,
       coalesce(l.booking_leads_started,0) as booking_leads_started, coalesce(l.hard_leads,0) as hard_leads,
       coalesce(l.booked_web,0) as booked_web, coalesce(l.quiz_leads,0) as quiz_leads
from keys k
left join ads a on a.date = k.date and a.bl = k.bl
left join web w on w.date = k.date and w.bl = k.bl
left join webev e on e.date = k.date and e.bl = k.bl
left join leads l on l.date = k.date and l.bl = k.bl;

-- Csatorna-szintű forgalom és elkötelezettség (hol csúszik el a látogató minősége).
create or replace view mart_web_channel_daily as
select w.date, coalesce(m.business_line,'besorolatlan') as business_line, w.channel_group, w.source, w.medium,
       sum(w.sessions) as sessions, sum(w.users) as users, sum(w.engaged_sessions) as engaged_sessions,
       sum(w.pageviews) as pageviews, sum(w.engagement_seconds) as engagement_seconds
from fact_web_daily w left join ga_property_map m on m.account_id = w.account_id
group by 1,2,3,4,5;

-- Foglalási folyamat: lépésenként hányan jutottak el, hol esnek ki, mennyi ideig időznek.
create or replace view mart_booking_step_daily as
select (e.created_at at time zone 'Europe/Budapest')::date as day, bs.ord, e.step, bs.label,
       count(distinct e.lead_id) as leads_reached,
       percentile_cont(0.5) within group (order by nullif(e.meta->>'secondsOnLastStep','')::numeric) as median_seconds
from fact_lead_event e
join booking_step bs on bs.step = e.step
where e.event = 'step_view'
group by 1,2,3,4;

-- Hol hagyták abba a nem lezárt foglalók (utolsó elért lépés), hetente.
create or replace view mart_booking_abandon_weekly as
select date_trunc('week', l.created_at at time zone 'Europe/Budapest')::date as week,
       l.business_line,
       coalesce(l.booking_progress->>'lastStep', 'contact') as last_step,
       count(*) as leads
from fact_lead l
where l.source = 'booking' and coalesce(l.booking_stage,'') <> 'completed'
group by 1,2,3;

-- Kvíz: hányan jutottak el a közös lépésekig és a végéig (elágazás után a lépések eltérnek, ezért csak completed).
create or replace view mart_quiz_step_reach as
select date_trunc('day', (q.payload->>'started_at')::timestamptz at time zone 'Europe/Budapest')::date as day,
       qs.ord, qs.label,
       count(*) filter (where (q.payload->>'furthest_order')::int >= qs.ord) as sessions_reached,
       count(*) as sessions_started,
       count(*) filter (where (q.payload->>'completed')::boolean) as sessions_completed
from fact_quiz_session q cross join quiz_step qs
group by 1,2,3;

-- Lead -> foglalás kohorsz: az adott heti leadek hány %-a foglalt 1/3/7/14/30 napon belül.
create or replace view mart_lead_cohort_weekly as
with booked as (
  select lead_id, min(created_at) as booked_at from fact_lead_event where event = 'booking_confirmed' group by 1
)
select date_trunc('week', l.created_at at time zone 'Europe/Budapest')::date as cohort_week,
       l.business_line,
       count(*) as leads,
       count(b.booked_at) as booked,
       count(*) filter (where b.booked_at <= l.created_at + interval '1 day') as booked_d1,
       count(*) filter (where b.booked_at <= l.created_at + interval '3 days') as booked_d3,
       count(*) filter (where b.booked_at <= l.created_at + interval '7 days') as booked_d7,
       count(*) filter (where b.booked_at <= l.created_at + interval '14 days') as booked_d14,
       count(*) filter (where b.booked_at <= l.created_at + interval '30 days') as booked_d30,
       percentile_cont(0.5) within group (order by extract(epoch from (b.booked_at - l.created_at))/3600) as median_hours_to_booking
from fact_lead l left join booked b on b.lead_id = l.lead_id
where l.source = 'booking'
group by 1,2;

-- Mikor érkeznek a leadek (óra × hét napja, budapesti idő).
create or replace view mart_lead_timing as
select extract(isodow from l.created_at at time zone 'Europe/Budapest')::int as iso_dow,
       extract(hour from l.created_at at time zone 'Europe/Budapest')::int as hour,
       l.business_line,
       count(*) as leads,
       count(*) filter (where l.booking_stage = 'completed') as completed
from fact_lead l where l.source = 'booking'
group by 1,2,3;

-- ===== 4. Korrelációs motor ===========================================================

-- Napi jelek (hosszú formában): minden mutató egy (dátum, jel, érték) sor.
create or replace view mart_signals_long as
select date, 'spend_'||platform as signal, sum(spend) as value from fact_ad_performance_daily group by 1,2
union all select date, 'clicks_'||platform, sum(clicks) from fact_ad_performance_daily group by 1,2
union all select date, 'impressions_'||platform, sum(impressions) from fact_ad_performance_daily group by 1,2
union all select date, 'spend_total', sum(spend) from fact_ad_performance_daily group by 1
union all select k.date, 'google_search_impressions', sum(k.impressions) from fact_keyword_daily k group by 1
union all select k.date, 'google_search_clicks', sum(k.clicks) from fact_keyword_daily k group by 1
union all select k.date, 'google_brand_impressions', sum(k.impressions)
  from fact_keyword_daily k join keyword_topic t on t.keyword_text = k.keyword_text and t.topic = 'brand' group by 1
union all select k.date, 'google_brand_clicks', sum(k.clicks)
  from fact_keyword_daily k join keyword_topic t on t.keyword_text = k.keyword_text and t.topic = 'brand' group by 1
union all select date, 'web_sessions', sum(sessions) from fact_web_daily group by 1
union all select date, 'web_sessions_'||lower(replace(channel_group,' ','_')), sum(sessions) from fact_web_daily where channel_group <> '' group by 1,2
union all select e.date, 'soft_leads', sum(e.event_count)
  from fact_web_event_daily e join funnel_event_map m on m.event_name = e.event_name and m.stage = 'soft_lead' group by 1
union all select e.date, 'ga_hard_leads', sum(e.event_count)
  from fact_web_event_daily e join funnel_event_map m on m.event_name = e.event_name and m.stage = 'ga_hard_lead' group by 1
union all select (created_at at time zone 'Europe/Budapest')::date, 'hard_leads', count(*)
  from fact_lead where source = 'booking' and booking_stage = 'completed' group by 1
union all select (created_at at time zone 'Europe/Budapest')::date, 'booked_web', count(*)
  from fact_lead_event where event = 'booking_confirmed' group by 1;

-- Jelpárok késleltetett korrelációja: a signal_a napi értéke t-ben, a signal_b értéke t+lag napon.
-- Hétköznap-hatás kiszűrése (p_detrend): minden jelből levonjuk a hét napjának átlagát.
-- A t-statisztika a szignifikancia durva jelzése; sok pár vizsgálata miatt ez feltáró jellegű, nem bizonyíték.
create or replace function signal_correlations(
  p_from date, p_to date, p_max_lag int default 14, p_detrend boolean default true, p_min_n int default 14
) returns table (signal_a text, signal_b text, lag_days int, r numeric, n int, t_stat numeric)
language sql stable as $$
  with d as (select generate_series(p_from, p_to, interval '1 day')::date as dt),
  sig as (select distinct signal from mart_signals_long where date between p_from and p_to),
  grid as (
    select d.dt, s.signal, coalesce(l.value, 0)::numeric as v
    from d cross join sig s
    left join (select date, signal, sum(value) as value from mart_signals_long group by 1,2) l
      on l.date = d.dt and l.signal = s.signal
  ),
  adj as (
    select dt, signal,
           case when p_detrend then v - avg(v) over (partition by signal, extract(dow from dt)) else v end as x
    from grid
  ),
  lags as (select generate_series(0, p_max_lag) as lag),
  pairs as (
    select a.signal as sa, b.signal as sb, l.lag,
           corr(a.x, b.x) as r, count(*)::int as n
    from adj a
    join lags l on true
    join adj b on b.signal <> a.signal and b.dt = a.dt + l.lag
    group by a.signal, b.signal, l.lag
  )
  select sa, sb, lag, round(r::numeric, 4), n,
         round((r * sqrt((n - 2)::numeric / nullif(1 - r * r, 0)))::numeric, 2)
  from pairs
  where n >= p_min_n and r is not null
$$;

-- Páronként a legerősebb késleltetés (|r| szerint), a legerősebb kapcsolatok elöl.
create or replace function signal_correlations_best(
  p_from date, p_to date, p_max_lag int default 14, p_detrend boolean default true, p_min_n int default 14,
  p_min_abs_t numeric default 2.5
) returns table (signal_a text, signal_b text, lag_days int, r numeric, n int, t_stat numeric, r_lag0 numeric)
language sql stable as $$
  with c as (select * from signal_correlations(p_from, p_to, p_max_lag, p_detrend, p_min_n)),
  best as (select distinct on (signal_a, signal_b) * from c order by signal_a, signal_b, abs(r) desc)
  select b.signal_a, b.signal_b, b.lag_days, b.r, b.n, b.t_stat,
         (select c0.r from c c0 where c0.signal_a = b.signal_a and c0.signal_b = b.signal_b and c0.lag_days = 0) as r_lag0
  from best b
  where abs(b.t_stat) >= p_min_abs_t
  order by abs(b.r) desc
$$;
