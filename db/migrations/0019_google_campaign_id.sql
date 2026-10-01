-- A Google automatikus címkézése az URL-be teszi a kampány azonosítóját (gad_campaignid). A foglaló ezt a click_ids mezőben
-- tárolja; a Hub ebből köti a Google-leadet a kampányhoz, utm_campaign nélkül is.

create or replace view lead_journey with (security_invoker = true) as
select
  l.lead_id,
  l.created_at,
  (l.created_at at time zone 'Europe/Budapest')::date as day,
  l.business_line,
  case when l.source = 'quiz' then 'alkalmassagi' else 'idopontfoglalas' end as lead_type,
  case
    when l.source = 'quiz' then 'alkalmassagi_kitoltve'
    when l.booking_progress->>'lastStep' = 'callback' then 'visszahivas'
    when l.booking_stage = 'completed' then 'foglalt'
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
  -- személyszintű kapcsolat: a kvíz-lead későbbi foglalása, illetve a foglalás korábbi kvíz-leadje
  nb.booked_at as later_booking_at,
  extract(epoch from (nb.booked_at - l.created_at)) / 3600 as hours_to_booking,
  pq.created_at as prior_quiz_at,
  extract(epoch from (l.created_at - pq.created_at)) / 3600 as hours_since_quiz,
  l.click_ids->>'gad_campaignid' as google_campaign_id
from fact_lead l
left join booking_step bs on bs.step = coalesce(l.booking_progress->>'lastStep', 'contact') and l.source = 'booking'
left join fact_quiz_session q on q.session_id = l.quiz_session_id
left join lateral (
  select min(b.created_at) as booked_at from fact_lead b
  where l.source = 'quiz' and coalesce(b.email_hash, b.phone_hash) = coalesce(l.email_hash, l.phone_hash)
    and b.source = 'booking' and b.booking_stage = 'completed' and coalesce(b.booking_progress->>'lastStep', '') <> 'callback'
    and b.created_at >= l.created_at
) nb on l.source = 'quiz'
left join lateral (
  select max(z.created_at) as created_at from fact_lead z
  where l.source = 'booking' and coalesce(z.email_hash, z.phone_hash) = coalesce(l.email_hash, l.phone_hash)
    and z.source = 'quiz' and z.created_at <= l.created_at
) pq on l.source = 'booking';

-- A lead és a Google-kampány összekötése azonosító alapján (a kampány neve a campaign_class-ból).
create or replace view lead_google_campaign with (security_invoker = true) as
select j.lead_id, j.day, j.lead_type, j.outcome, j.business_line, j.google_campaign_id,
       c.campaign_name, c.account_id
from lead_journey j
left join lateral (
  select cc.campaign_name, cc.account_id from campaign_class cc
  where cc.platform = 'google' and cc.campaign_id = j.google_campaign_id order by cc.campaign_name limit 1
) c on true
where j.google_campaign_id is not null;

revoke all on lead_google_campaign from anon;
grant select on lead_google_campaign to authenticated;
