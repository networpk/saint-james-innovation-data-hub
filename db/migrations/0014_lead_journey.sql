-- Lead-életút: az alkalmassági (kvíz) leadek és az időpontfoglalások szétválasztva; ki hagyta félbe, ki vitte végig,
-- hol akadt el, mennyi időt töltött lépésenként; és a két lead összekötése ugyanannak a személynek (hash alapján).

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
  extract(epoch from (l.created_at - pq.created_at)) / 3600 as hours_since_quiz
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

-- Összesítő az adott időszakra (és opcionálisan üzletágra).
create or replace function lead_journey_summary(p_from date, p_to date, p_bl text default null)
returns table (
  quiz_leads bigint, quiz_leads_booked_later bigint, booking_starts bigint, booked bigint, abandoned bigint, callbacks bigint,
  completion_rate numeric, median_seconds_booked numeric, median_seconds_abandoned numeric, median_hours_quiz_to_booking numeric
) language sql stable as $$
  select
    count(*) filter (where lead_type = 'alkalmassagi'),
    count(*) filter (where lead_type = 'alkalmassagi' and later_booking_at is not null),
    count(*) filter (where lead_type = 'idopontfoglalas'),
    count(*) filter (where outcome = 'foglalt'),
    count(*) filter (where outcome = 'felbehagyta'),
    count(*) filter (where outcome = 'visszahivas'),
    (count(*) filter (where outcome = 'foglalt'))::numeric / nullif(count(*) filter (where lead_type = 'idopontfoglalas'), 0),
    percentile_cont(0.5) within group (order by total_seconds) filter (where outcome = 'foglalt'),
    percentile_cont(0.5) within group (order by total_seconds) filter (where outcome = 'felbehagyta'),
    percentile_cont(0.5) within group (order by hours_to_booking) filter (where lead_type = 'alkalmassagi' and later_booking_at is not null)
  from lead_journey
  where day between p_from and p_to and (p_bl is null or p_bl = 'mind' or business_line = p_bl);
$$;

-- Lépésenként: hányan jutottak el, és mennyi időt töltöttek ott a végigvitt és a félbehagyott foglalók.
create or replace function lead_step_time(p_from date, p_to date, p_bl text default null)
returns table (ord int, step text, label text, reached_booked bigint, reached_abandoned bigint, dropped_here bigint,
               median_seconds_booked numeric, median_seconds_abandoned numeric)
language sql stable as $$
  with j as (
    select * from lead_journey
    where lead_type = 'idopontfoglalas' and day between p_from and p_to and (p_bl is null or p_bl = 'mind' or business_line = p_bl)
  ), s as (
    select j.lead_id, j.outcome, j.last_step, e.key as step, nullif(e.value, '')::numeric as secs
    from j, lateral jsonb_each_text(j.step_seconds) e
  )
  select bs.ord, bs.step, bs.label,
         count(distinct s.lead_id) filter (where s.outcome = 'foglalt'),
         count(distinct s.lead_id) filter (where s.outcome = 'felbehagyta'),
         (select count(*) from j where j.outcome = 'felbehagyta' and j.last_step = bs.step),
         percentile_cont(0.5) within group (order by s.secs) filter (where s.outcome = 'foglalt'),
         percentile_cont(0.5) within group (order by s.secs) filter (where s.outcome = 'felbehagyta')
  from booking_step bs left join s on s.step = bs.step
  group by bs.ord, bs.step, bs.label order by bs.ord;
$$;

-- Egy lead részletes idővonala a részletező panelhez: események, lépésidők és a személy többi leadje.
create or replace function lead_timeline(p_lead_id uuid)
returns table (ts timestamptz, kind text, label text, step text, seconds numeric, detail jsonb)
language sql stable as $$
  with l as (select * from lead_journey where lead_id = p_lead_id)
  select l.created_at, 'lead', case l.lead_type when 'alkalmassagi' then 'Alkalmassági kérdőív leadje' else 'Időpontfoglalás indult' end,
         null::text, null::numeric, jsonb_build_object('outcome', l.outcome, 'utm_source', l.utm_source, 'utm_campaign', l.utm_campaign)
  from l
  union all
  select e.created_at, 'event', e.event, e.step, nullif(e.meta->>'secondsOnLastStep', '')::numeric, e.meta
  from fact_lead_event e where e.lead_id = p_lead_id
  union all
  select o.created_at, 'related', case o.lead_type when 'alkalmassagi' then 'Ugyanaz a személy: alkalmassági lead' else 'Ugyanaz a személy: időpontfoglalás' end,
         null::text, null::numeric, jsonb_build_object('lead_id', o.lead_id, 'outcome', o.outcome)
  from l join lead_journey o on o.person_key = l.person_key and o.lead_id <> l.lead_id
  order by 1;
$$;

-- Napi bontás a diagramokhoz.
create or replace view mart_lead_journey_daily with (security_invoker = true) as
select day, business_line, lead_type, outcome, count(*) as leads,
       percentile_cont(0.5) within group (order by total_seconds) as median_seconds
from lead_journey group by 1,2,3,4;

revoke all on lead_journey, mart_lead_journey_daily from anon;
grant select on lead_journey, mart_lead_journey_daily to authenticated;
revoke execute on function lead_journey_summary(date, date, text), lead_step_time(date, date, text), lead_timeline(uuid) from public, anon;
grant execute on function lead_journey_summary(date, date, text), lead_step_time(date, date, text), lead_timeline(uuid) to authenticated;
