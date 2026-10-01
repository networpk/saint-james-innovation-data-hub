-- Lead-életút: az „elküldte az adatait" és a „végigvitte" szétválasztva.
-- Korábban a `completed` állapot (az első képernyő Küldése) „foglalt" kimenetnek számított, pedig a foglaló a Küldésnél már lezárja a leadet.
-- Új kimenetek (foglalási lead):
--   foglalt          – időpontot foglalt (Dokirex-azonosító vagy „Kész" lépés)
--   visszahivas      – visszahívást kért
--   adatok_elkuldve  – elküldte az adatait (lead), de nem vitte végig
--   felbehagyta      – nem küldte el az adatait (csak a vázlat mentődött)
-- „Végigvitte" = foglalt + visszahívás. Személy-szinten (e-mail/telefon hash) a legjobb kimenetel számít.

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
      when l.dokirex_booking_id is not null or l.booking_progress->>'lastStep' = 'done' then 'foglalt'
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
      and (b2.dokirex_booking_id is not null or b2.booking_progress->>'lastStep' = 'done')
      and b2.created_at >= l.created_at
  ) nb on l.source = 'quiz'
  left join lateral (
    select max(z.created_at) as created_at from fact_lead z
    where l.source = 'booking' and coalesce(z.email_hash, z.phone_hash) = coalesce(l.email_hash, l.phone_hash)
      and z.source = 'quiz' and z.created_at <= l.created_at
  ) pq on l.source = 'booking'
) b;

-- Összesítő: sor-szintű (korábbi oszlopok) és személy-szintű számok (új oszlopok a végén).
drop function if exists lead_journey_summary(date, date, text);
create function lead_journey_summary(p_from date, p_to date, p_bl text default null)
returns table (
  quiz_leads bigint, quiz_leads_booked_later bigint, booking_starts bigint, booked bigint, abandoned bigint, callbacks bigint,
  completion_rate numeric, median_seconds_booked numeric, median_seconds_abandoned numeric, median_hours_quiz_to_booking numeric,
  rows_submitted bigint, rows_finished bigint,
  people_started bigint, people_submitted bigint, people_finished bigint, people_booked bigint, people_callbacks bigint,
  people_submitted_unfinished bigint, people_not_submitted bigint, submit_rate numeric, finish_rate numeric
) language sql stable as $$
  with j as (
    select * from lead_journey
    where day between p_from and p_to and (p_bl is null or p_bl = 'mind' or business_line = p_bl)
  ), p as (
    select coalesce(person_key, lead_id::text) as pk, max(outcome_rank) as best
    from j where lead_type = 'idopontfoglalas' group by 1
  ), pp as (
    select count(*) as started,
           count(*) filter (where best >= 2) as submitted,
           count(*) filter (where best >= 3) as finished,
           count(*) filter (where best = 4) as booked,
           count(*) filter (where best = 3) as callbacks,
           count(*) filter (where best = 2) as submitted_unfinished,
           count(*) filter (where best = 1) as not_submitted
    from p
  ), r as (
    select
      count(*) filter (where lead_type = 'alkalmassagi') as quiz_leads,
      count(*) filter (where lead_type = 'alkalmassagi' and later_booking_at is not null) as quiz_booked_later,
      count(*) filter (where lead_type = 'idopontfoglalas') as starts,
      count(*) filter (where outcome = 'foglalt') as booked,
      count(*) filter (where outcome = 'felbehagyta') as abandoned,
      count(*) filter (where outcome = 'visszahivas') as callbacks,
      count(*) filter (where lead_type = 'idopontfoglalas' and submitted) as rows_submitted,
      count(*) filter (where lead_type = 'idopontfoglalas' and finished) as rows_finished,
      percentile_cont(0.5) within group (order by total_seconds) filter (where outcome = 'foglalt') as med_booked,
      percentile_cont(0.5) within group (order by total_seconds) filter (where outcome in ('felbehagyta', 'adatok_elkuldve')) as med_aband,
      percentile_cont(0.5) within group (order by hours_to_booking) filter (where lead_type = 'alkalmassagi' and later_booking_at is not null) as med_quiz
    from j
  )
  select r.quiz_leads, r.quiz_booked_later, r.starts, r.booked, r.abandoned, r.callbacks,
         r.rows_finished::numeric / nullif(r.starts, 0), r.med_booked, r.med_aband, r.med_quiz,
         r.rows_submitted, r.rows_finished,
         pp.started, pp.submitted, pp.finished, pp.booked, pp.callbacks, pp.submitted_unfinished, pp.not_submitted,
         pp.submitted::numeric / nullif(pp.started, 0), pp.finished::numeric / nullif(pp.submitted, 0)
  from r, pp;
$$;

-- Lépésenként: a „booked" csoport a valódi foglalások, az „abandoned" a nem végigvittek (elküldte az adatait, de nem fejezte be + nem küldte el).
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
         count(distinct s.lead_id) filter (where s.outcome in ('felbehagyta', 'adatok_elkuldve')),
         (select count(*) from j where j.outcome in ('felbehagyta', 'adatok_elkuldve') and j.last_step = bs.step),
         percentile_cont(0.5) within group (order by s.secs) filter (where s.outcome = 'foglalt'),
         percentile_cont(0.5) within group (order by s.secs) filter (where s.outcome in ('felbehagyta', 'adatok_elkuldve'))
  from booking_step bs left join s on s.step = bs.step
  group by bs.ord, bs.step, bs.label order by bs.ord;
$$;

-- Mérés-egyeztetés: a „lead" a Küldéssel elküldött adat, a foglalás pedig a valódi foglalás.
create or replace view mart_tracking_reconciliation with (security_invoker = true) as
with db as (
  select day as date, business_line,
         count(*) filter (where lead_type = 'idopontfoglalas' and submitted) as db_leads,
         count(*) filter (where outcome = 'foglalt') as db_booked,
         count(*) filter (where outcome = 'visszahivas') as db_callbacks
  from lead_journey group by 1,2
), ga as (
  select e.date, coalesce(m.business_line, 'besorolatlan') as business_line,
         sum(e.event_count) filter (where e.event_name = 'generate_lead') as ga_generate_lead,
         sum(e.event_count) filter (where e.event_name = 'appointment_booked') as ga_booked,
         sum(e.event_count) filter (where e.event_name = 'callback_requested') as ga_callbacks
  from fact_web_event_daily e left join ga_property_map m on m.account_id = e.account_id
  where e.event_name in ('generate_lead', 'appointment_booked', 'callback_requested')
  group by 1,2
), k as (select date, business_line from db union select date, business_line from ga)
select k.date, k.business_line,
       coalesce(db.db_leads, 0) as db_leads, coalesce(ga.ga_generate_lead, 0) as ga_generate_lead,
       coalesce(db.db_booked, 0) as db_booked, coalesce(ga.ga_booked, 0) as ga_booked,
       coalesce(db.db_callbacks, 0) as db_callbacks, coalesce(ga.ga_callbacks, 0) as ga_callbacks
from k left join db on db.date = k.date and db.business_line = k.business_line
       left join ga on ga.date = k.date and ga.business_line = k.business_line;

revoke execute on function lead_journey_summary(date, date, text) from public, anon;
grant execute on function lead_journey_summary(date, date, text) to authenticated;
