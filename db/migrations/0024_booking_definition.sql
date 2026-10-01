-- A „foglalt" definíciója: az időpont rögzítése (booking_date) is foglalásnak számít, nem csak a Dokirex-azonosító.
-- Háttér: a foglaló a Dokirex-azonosítót csak 2026-09-30 óta menti el, korábban viszont a kiválasztott időpont (dátum és idő) már rögzült.
-- Így a Hub eddig 3 foglalást mutatott, miközben 44 lead időpontot rögzített (41-nek nincs azonosítója). A visszahívás nem foglalás.
-- Foglalt = Dokirex-azonosító VAGY rögzített időpont VAGY a „Kész" lépés, és nem visszahívás.

create or replace view lead_journey with (security_invoker = true) as
select b.*,
       (b.lead_type = 'alkalmassagi' or b.outcome <> 'felbehagyta') as submitted,
       (b.outcome in ('foglalt', 'visszahivas')) as finished,
       case b.outcome when 'foglalt' then 4 when 'visszahivas' then 3 when 'adatok_elkuldve' then 2 when 'felbehagyta' then 1 else 0 end as outcome_rank
from (
  select
    l.lead_id,
    l.created_at,
    (l.created_at at time zone 'Europe/Budapest')::date as day,
    l.business_line,
    case when l.source = 'quiz' then 'alkalmassagi' else 'idopontfoglalas' end as lead_type,
    case
      when l.source = 'quiz' then 'alkalmassagi_kitoltve'
      when l.booking_progress->>'lastStep' = 'callback' then 'visszahivas'
      when l.dokirex_booking_id is not null or l.booking_date is not null or l.booking_progress->>'lastStep' = 'done' then 'foglalt'
      when l.booking_stage = 'completed' then 'adatok_elkuldve'
      else 'felbehagyta'
    end as outcome,
    case when l.source = 'booking' then coalesce(l.booking_progress->>'lastStep', 'contact') end as last_step,
    case when l.source = 'booking' then bs.label end as last_step_label,
    case when l.source = 'booking' then nullif(l.booking_progress->>'secondsOnLastStep', '')::numeric end as seconds_on_last_step,
    case when l.source = 'booking' then nullif(l.booking_progress->>'totalSeconds', '')::numeric
         else extract(epoch from (l.created_at - nullif(q.payload->>'started_at', '')::timestamptz)) end as total_seconds,
    case when l.source = 'booking' then coalesce(l.booking_progress->'stepSeconds', '{}'::jsonb) else '{}'::jsonb end as step_seconds,
    l.result_type,
    l.treatment, l.doctor, l.booking_date, l.dokirex_booking_id,
    l.utm->>'utm_source' as utm_source, l.utm->>'utm_medium' as utm_medium,
    l.utm->>'utm_campaign' as utm_campaign, l.utm->>'utm_content' as utm_content,
    case when l.click_ids ? 'fbclid' then 'fbclid' when l.click_ids ? 'gclid' then 'gclid' when l.click_ids ? 'ttclid' then 'ttclid'
         when l.click_ids ? 'wbraid' or l.click_ids ? 'gbraid' then 'gclid' end as click_id_type,
    (coalesce(l.utm, '{}'::jsonb) <> '{}'::jsonb or coalesce(l.click_ids, '{}'::jsonb) <> '{}'::jsonb) as has_source,
    l.quiz_session_id,
    q.payload->>'furthest_step' as quiz_furthest_step,
    coalesce(l.email_hash, l.phone_hash) as person_key,
    nb.booked_at as later_booking_at,
    extract(epoch from (nb.booked_at - l.created_at)) / 3600 as hours_to_booking,
    pq.created_at as prior_quiz_at,
    extract(epoch from (l.created_at - pq.created_at)) / 3600 as hours_since_quiz,
    l.click_ids->>'gad_campaignid' as google_campaign_id
  from fact_lead l
  left join booking_step bs on bs.step = coalesce(l.booking_progress->>'lastStep', 'contact') and l.source = 'booking'
  left join fact_quiz_session q on q.session_id = l.quiz_session_id
  left join lateral (
    -- a kvíz-lead későbbi, valódi foglalása (nem visszahívás, nem csak elküldött adat)
    select min(b2.created_at) as booked_at from fact_lead b2
    where l.source = 'quiz' and coalesce(b2.email_hash, b2.phone_hash) = coalesce(l.email_hash, l.phone_hash)
      and b2.source = 'booking' and coalesce(b2.booking_progress->>'lastStep', '') <> 'callback'
      and (b2.dokirex_booking_id is not null or b2.booking_date is not null or b2.booking_progress->>'lastStep' = 'done')
      and b2.created_at >= l.created_at
  ) nb on l.source = 'quiz'
  left join lateral (
    select max(z.created_at) as created_at from fact_lead z
    where l.source = 'booking' and coalesce(z.email_hash, z.phone_hash) = coalesce(l.email_hash, l.phone_hash)
      and z.source = 'quiz' and z.created_at <= l.created_at
  ) pq on l.source = 'booking'
) b;

create or replace view mart_funnel_daily with (security_invoker = true) as
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
         count(*) filter (where source = 'booking' and booking_stage = 'completed' and coalesce(booking_progress->>'lastStep','') <> 'callback'
                            and (dokirex_booking_id is not null or booking_date is not null or booking_progress->>'lastStep' = 'done')) as booked_web,
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

create or replace view mart_signals_long with (security_invoker = true) as
with brand as materialized (select keyword_text from keyword_topic where topic = 'brand')
select date, 'spend_'||platform as signal, sum(spend) as value from fact_ad_performance_daily group by 1,2
union all select date, 'clicks_'||platform, sum(clicks) from fact_ad_performance_daily group by 1,2
union all select date, 'impressions_'||platform, sum(impressions) from fact_ad_performance_daily group by 1,2
union all select date, 'spend_total', sum(spend) from fact_ad_performance_daily group by 1
union all select k.date, 'google_search_impressions', sum(k.impressions) from fact_keyword_daily k group by 1
union all select k.date, 'google_search_clicks', sum(k.clicks) from fact_keyword_daily k group by 1
union all select k.date, 'google_brand_impressions', sum(k.impressions)
  from fact_keyword_daily k where k.keyword_text in (select keyword_text from brand) group by 1
union all select k.date, 'google_brand_clicks', sum(k.clicks)
  from fact_keyword_daily k where k.keyword_text in (select keyword_text from brand) group by 1
union all select date, 'web_sessions', sum(sessions) from fact_web_daily group by 1
union all select date, 'web_sessions_'||lower(replace(channel_group,' ','_')), sum(sessions) from fact_web_daily where channel_group <> '' group by 1,2
union all select e.date, 'soft_leads', sum(e.event_count)
  from fact_web_event_daily e join funnel_event_map m on m.event_name = e.event_name and m.stage = 'soft_lead' group by 1
union all select e.date, 'ga_hard_leads', sum(e.event_count)
  from fact_web_event_daily e join funnel_event_map m on m.event_name = e.event_name and m.stage = 'ga_hard_lead' group by 1
union all select (created_at at time zone 'Europe/Budapest')::date, 'hard_leads', count(*)
  from fact_lead where source = 'booking' and booking_stage = 'completed' group by 1
union all select (created_at at time zone 'Europe/Budapest')::date, 'booked_web', count(*)
  from fact_lead where source = 'booking' and booking_stage = 'completed' and coalesce(booking_progress->>'lastStep','') <> 'callback'
  and (dokirex_booking_id is not null or booking_date is not null or booking_progress->>'lastStep' = 'done') group by 1;
