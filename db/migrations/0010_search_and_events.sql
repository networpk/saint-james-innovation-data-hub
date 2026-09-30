-- 0010: kulcsszó-/kifejezés-összesítők, globális keresés, téma-idővonal, és a GA4 mikro-események a tölcsérben.
-- A GA4-ben a valódi eseménynevek (audit, 3 nap): soft_conv_foglaljon, generate_lead, idopont_foglalas_katt, book_appointment_ct,
-- form_start, sikeres_foglalas, phone_click, email_click.

-- ===== 1. Több tölcsér-szint az eseményekből ============================================
alter table funnel_event_map drop constraint if exists funnel_event_map_stage_check;
alter table funnel_event_map add constraint funnel_event_map_stage_check check (stage in
  ('soft_lead','ga_hard_lead','booking_click','form_start','booking_success','phone_click','email_click','video_start','video_complete'));
insert into funnel_event_map (event_name, stage, note) values
  ('idopont_foglalas_katt','booking_click','kattintás az időpontfoglalásra'),
  ('book_appointment_ct','booking_click','ellenőrizendő: időpontfoglalás kattintás (CT)'),
  ('form_start','form_start','űrlap megkezdve'),
  ('sikeres_foglalas','booking_success','sikeres foglalás a GA4 szerint'),
  ('phone_click','phone_click','telefonszám-kattintás'),
  ('email_click','email_click','e-mail-kattintás')
on conflict do nothing;

-- A forrás-szintű nézet új oszlopokkal bővül (az oszlopok végére, a meglévők sorrendje változatlan).
create or replace view mart_source_conversion_daily as
with w as (
  select w.date, coalesce(m.business_line, 'besorolatlan') as bl, w.source, w.medium, w.campaign,
         sum(w.sessions) as sessions, sum(w.users) as users,
         sum(w.engaged_sessions) as engaged_sessions, sum(w.engagement_seconds) as engagement_seconds
  from fact_web_daily w left join ga_property_map m on m.account_id = w.account_id
  group by 1,2,3,4,5
), e as (
  select e.date, coalesce(m.business_line, 'besorolatlan') as bl, e.source, e.medium, e.campaign,
         sum(e.event_count) filter (where fm.stage = 'soft_lead') as soft_leads,
         sum(e.event_count) filter (where fm.stage = 'ga_hard_lead') as ga_hard_leads,
         sum(e.event_count) filter (where fm.stage = 'booking_click') as booking_clicks,
         sum(e.event_count) filter (where fm.stage = 'form_start') as form_starts,
         sum(e.event_count) filter (where fm.stage = 'booking_success') as booking_success,
         sum(e.event_count) filter (where fm.stage = 'phone_click') as phone_clicks,
         sum(e.event_count) filter (where fm.stage = 'email_click') as email_clicks
  from fact_web_event_daily e
  join funnel_event_map fm on fm.event_name = e.event_name
    and fm.stage in ('soft_lead','ga_hard_lead','booking_click','form_start','booking_success','phone_click','email_click')
  left join ga_property_map m on m.account_id = e.account_id
  group by 1,2,3,4,5
)
select coalesce(w.date, e.date) as date, coalesce(w.bl, e.bl) as business_line,
       coalesce(w.source, e.source) as source, coalesce(w.medium, e.medium) as medium,
       coalesce(w.campaign, e.campaign) as campaign,
       coalesce(w.sessions, 0) as sessions, coalesce(w.users, 0) as users,
       coalesce(w.engaged_sessions, 0) as engaged_sessions, coalesce(w.engagement_seconds, 0) as engagement_seconds,
       coalesce(e.soft_leads, 0) as soft_leads, coalesce(e.ga_hard_leads, 0) as ga_hard_leads,
       coalesce(e.booking_clicks, 0) as booking_clicks, coalesce(e.form_starts, 0) as form_starts,
       coalesce(e.booking_success, 0) as booking_success, coalesce(e.phone_clicks, 0) as phone_clicks,
       coalesce(e.email_clicks, 0) as email_clicks
from w full join e on e.date = w.date and e.bl = w.bl and e.source = w.source and e.medium = w.medium and e.campaign = w.campaign;

-- ===== 2. Kulcsszó- és kifejezés-összesítők (szerveroldali, hogy a felület ne húzzon le sok ezer napi sort) =====
create or replace function keyword_summary(
  p_from date, p_to date, p_prev_from date default null, p_prev_to date default null,
  p_business_line text default null, p_search text default null, p_topic text default null,
  p_min_spend numeric default 0, p_limit int default 200, p_offset int default 0
) returns table (
  keyword_text text, topic text, campaigns int, spend numeric, impressions bigint, clicks bigint, conversions numeric,
  ctr numeric, cpc numeric, cost_per_conversion numeric, spend_prev numeric, clicks_prev bigint, conversions_prev numeric,
  total_count bigint
) language sql stable as $$
  with cur as (
    select k.keyword_text, max(k.topic) as topic, count(distinct k.campaign_id)::int as campaigns,
           sum(k.spend) as spend, sum(k.impressions)::bigint as impressions, sum(k.clicks)::bigint as clicks, sum(k.conversions) as conversions
    from mart_keyword_daily k
    where k.date between p_from and p_to
      and (p_business_line is null or k.business_line = p_business_line)
      and (p_topic is null or k.topic = p_topic)
      and (p_search is null or sj_norm(k.keyword_text) like '%' || sj_norm(p_search) || '%')
    group by k.keyword_text
  ), prev as (
    select k.keyword_text, sum(k.spend) as spend, sum(k.clicks)::bigint as clicks, sum(k.conversions) as conversions
    from mart_keyword_daily k
    where p_prev_from is not null and k.date between p_prev_from and p_prev_to
      and (p_business_line is null or k.business_line = p_business_line)
    group by k.keyword_text
  )
  select c.keyword_text, c.topic, c.campaigns, round(c.spend, 2), c.impressions, c.clicks, round(c.conversions, 2),
         round(c.clicks::numeric / nullif(c.impressions, 0), 5), round(c.spend / nullif(c.clicks, 0), 2),
         round(c.spend / nullif(c.conversions, 0), 2),
         round(p.spend, 2), p.clicks, round(p.conversions, 2),
         count(*) over ()
  from cur c left join prev p on p.keyword_text = c.keyword_text
  where c.spend >= p_min_spend
  order by c.spend desc, c.keyword_text
  limit p_limit offset p_offset
$$;

create or replace function keyword_daily(p_keyword text, p_from date, p_to date)
returns table (date date, spend numeric, impressions bigint, clicks bigint, conversions numeric)
language sql stable as $$
  select k.date, sum(k.spend), sum(k.impressions)::bigint, sum(k.clicks)::bigint, sum(k.conversions)
  from mart_keyword_daily k
  where k.keyword_text = p_keyword and k.date between p_from and p_to
  group by k.date order by k.date
$$;

create or replace function keyword_campaigns(p_keyword text, p_from date, p_to date)
returns table (campaign_id text, campaign_name text, ad_group_id text, match_type text, spend numeric, impressions bigint, clicks bigint, conversions numeric)
language sql stable as $$
  select k.campaign_id, max(k.campaign_name), k.ad_group_id, k.match_type, sum(k.spend), sum(k.impressions)::bigint, sum(k.clicks)::bigint, sum(k.conversions)
  from mart_keyword_daily k
  where k.keyword_text = p_keyword and k.date between p_from and p_to
  group by k.campaign_id, k.ad_group_id, k.match_type order by sum(k.spend) desc
$$;

create or replace function search_term_summary(
  p_from date, p_to date, p_business_line text default null, p_search text default null, p_topic text default null,
  p_limit int default 200, p_offset int default 0
) returns table (
  search_term text, topic text, campaigns int, spend numeric, impressions bigint, clicks bigint, conversions numeric,
  is_keyword boolean, total_count bigint
) language sql stable as $$
  with t as (
    select s.search_term, max(s.topic) as topic, count(distinct s.campaign_id)::int as campaigns,
           sum(s.spend) as spend, sum(s.impressions)::bigint as impressions, sum(s.clicks)::bigint as clicks, sum(s.conversions) as conversions
    from mart_search_term_daily s
    where s.date between p_from and p_to
      and (p_business_line is null or s.business_line = p_business_line)
      and (p_topic is null or s.topic = p_topic)
      and (p_search is null or sj_norm(s.search_term) like '%' || sj_norm(p_search) || '%')
    group by s.search_term
  )
  select t.search_term, t.topic, t.campaigns, round(t.spend, 2), t.impressions, t.clicks, round(t.conversions, 2),
         exists (select 1 from fact_keyword_daily k where sj_norm(k.keyword_text) = sj_norm(t.search_term)) as is_keyword,
         count(*) over ()
  from t order by t.clicks desc, t.search_term limit p_limit offset p_offset
$$;

-- Téma-idővonal: ugyanazon téma költése/elérése a Meta/TikTok/Google között + a témához tartozó Google-kulcsszavak megjelenése.
create or replace function topic_timeline(p_topic text, p_from date, p_to date)
returns table (date date, meta_spend numeric, tiktok_spend numeric, google_spend numeric, meta_impressions bigint, tiktok_impressions bigint,
               google_kw_impressions bigint, google_kw_clicks bigint, google_kw_spend numeric)
language sql stable as $$
  with d as (select generate_series(p_from, p_to, interval '1 day')::date as dt),
  t as (
    select date, sum(spend) filter (where platform = 'meta') as ms, sum(spend) filter (where platform = 'tiktok') as ts,
           sum(spend) filter (where platform = 'google') as gs,
           sum(impressions) filter (where platform = 'meta') as mi, sum(impressions) filter (where platform = 'tiktok') as ti
    from mart_topic_daily where topic = p_topic and date between p_from and p_to group by date
  ), k as (
    select date, sum(impressions) as ki, sum(clicks) as kc, sum(spend) as ks
    from mart_keyword_daily where topic = p_topic and date between p_from and p_to group by date
  )
  select d.dt, coalesce(t.ms,0), coalesce(t.ts,0), coalesce(t.gs,0), coalesce(t.mi,0)::bigint, coalesce(t.ti,0)::bigint,
         coalesce(k.ki,0)::bigint, coalesce(k.kc,0)::bigint, coalesce(k.ks,0)
  from d left join t on t.date = d.dt left join k on k.date = d.dt order by d.dt
$$;

-- Globális keresés (⌘K): kulcsszó, keresési kifejezés, kampány, hirdetés, téma – ékezet- és kisbetű-érzéketlenül.
create or replace function global_search(p_q text, p_limit int default 6)
returns table (kind text, id text, label text, sublabel text)
language sql stable as $$
  with q as (select sj_norm(trim(p_q)) as n)
  select * from (
    (select 'keyword'::text, k.keyword_text, k.keyword_text, 'Kulcsszó · ' || round(sum(k.spend))::text || ' Ft'
       from mart_keyword_daily k, q where q.n <> '' and sj_norm(k.keyword_text) like '%' || q.n || '%'
       group by k.keyword_text order by sum(k.spend) desc limit p_limit)
    union all
    (select 'search_term', s.search_term, s.search_term, 'Keresési kifejezés · ' || sum(s.clicks)::text || ' kattintás'
       from mart_search_term_daily s, q where q.n <> '' and sj_norm(s.search_term) like '%' || q.n || '%'
       group by s.search_term order by sum(s.clicks) desc limit p_limit)
    union all
    (select 'campaign', c.platform || '|' || c.account_id || '|' || c.campaign_id, c.campaign_name, 'Kampány · ' || c.platform
       from campaign_class c, q where q.n <> '' and sj_norm(c.campaign_name) like '%' || q.n || '%' order by c.campaign_name limit p_limit)
    union all
    (select 'ad', a.platform || '|' || a.ad_id, coalesce(a.ad_name, a.ad_id), 'Hirdetés · ' || a.platform
       from dim_ad a, q where q.n <> '' and sj_norm(concat_ws(' ', a.ad_name, a.title, a.body)) like '%' || q.n || '%'
       order by a.ad_name limit p_limit)
    union all
    (select 'topic', t.topic, t.label, 'Téma'
       from topic t, q where q.n <> '' and (sj_norm(t.label) like '%' || q.n || '%' or sj_norm(t.topic) like '%' || q.n || '%') limit p_limit)
  ) x
$$;

-- Jogosultságok (Supabase szerepkörökkel): látogató semmit, bejelentkezett olvashat.
do $$
declare f text;
begin
  foreach f in array array[
    'keyword_summary(date,date,date,date,text,text,text,numeric,int,int)', 'keyword_daily(text,date,date)',
    'keyword_campaigns(text,date,date)', 'search_term_summary(date,date,text,text,text,int,int)',
    'topic_timeline(text,date,date)', 'global_search(text,int)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
exception when undefined_object then
  -- szerepkörök nélküli környezet (pl. helyi teszt): a jogosultságok kihagyva
  null;
end $$;

alter view mart_source_conversion_daily set (security_invoker = on);
