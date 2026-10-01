-- A foglaló dataLayer-eseményei (lead_created, appointment_booked, callback_requested, lépés-események) a tölcsérben,
-- és egyeztetés a saját adatbázissal: a GA4 hozzájárulás-függő, ezért a saját leadszám marad az igazság, a GA4 a forrás-bontáshoz kell.

alter table funnel_event_map drop constraint if exists funnel_event_map_stage_check;
alter table funnel_event_map add constraint funnel_event_map_stage_check check (stage in
  ('soft_lead','ga_hard_lead','booking_click','form_start','booking_success','phone_click','email_click','video_start','video_complete',
   'dl_booked','dl_callback','dl_path','dl_service','dl_slot','dl_step_view','dl_thankyou'));
insert into funnel_event_map (event_name, stage, note) values
  ('appointment_booked', 'dl_booked', 'dataLayer: a foglalás a háttérben sikeresen létrejött'),
  ('callback_requested', 'dl_callback', 'dataLayer: visszahívás kérve, háttér-siker után'),
  ('booking_path_selected', 'dl_path', 'dataLayer: online foglalást választott'),
  ('service_selected', 'dl_service', 'dataLayer: vizsgálatot választott (a név nélkül)'),
  ('appointment_slot_selected', 'dl_slot', 'dataLayer: időpontot választott (az időpont nélkül)'),
  ('booking_step_view', 'dl_step_view', 'dataLayer: lépés megjelent'),
  ('booking_thankyou_view', 'dl_thankyou', 'dataLayer: köszönőoldal (nem konverzió)')
on conflict do nothing;

insert into insight_threshold (key, value, note) values
  ('track_min_coverage', 0.3, 'GA4/saját arány alatt a mérés lefedettsége gyanús (hozzájárulás vagy hibás címke)'),
  ('track_min_db', 5, 'lefedettség-ellenőrzéshez minimális saját esemény a héten')
on conflict (key) do nothing;

-- Napi egyeztetés: saját adatbázis és GA4 ugyanarra az eseményre. A GA4 generate_lead más űrlapokat is tartalmazhat.
create or replace view mart_tracking_reconciliation with (security_invoker = true) as
with db as (
  select day as date, business_line,
         count(*) filter (where lead_type = 'idopontfoglalas') as db_leads,
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

-- A GA4 lefedettség az elmúlt N napra (a hozzájárulás-torzítás becslése).
create or replace function tracking_coverage(p_from date, p_to date, p_bl text default null)
returns table (event text, db_count numeric, ga_count numeric, coverage numeric)
language sql stable as $$
  with r as (
    select * from mart_tracking_reconciliation
    where date between p_from and p_to and (p_bl is null or p_bl = 'mind' or business_line = p_bl)
  )
  select 'lead'::text, sum(db_leads), sum(ga_generate_lead), sum(ga_generate_lead) / nullif(sum(db_leads), 0) from r
  union all select 'foglalas', sum(db_booked), sum(ga_booked), sum(ga_booked) / nullif(sum(db_booked), 0) from r
  union all select 'visszahivas', sum(db_callbacks), sum(ga_callbacks), sum(ga_callbacks) / nullif(sum(db_callbacks), 0) from r;
$$;

-- Riasztás: ha az új események már mérnek, de a GA4 a saját foglalások töredékét látja.
create or replace function tracking_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable as $$
declare db_n numeric; ga_n numeric; live boolean;
begin
  select exists (select 1 from fact_web_event_daily where event_name = 'appointment_booked' and event_count > 0
                 and date >= (p_now - interval '30 days')::date) into live;
  if not live then return; end if;
  select coalesce(sum(db_booked), 0), coalesce(sum(ga_booked), 0) into db_n, ga_n
  from mart_tracking_reconciliation where date >= (p_now - interval '7 days')::date and date < (p_now)::date;
  if db_n >= thr('track_min_db') and ga_n / db_n < thr('track_min_coverage') then
    return query
    select 'tracking_coverage'::text, 'warning'::text, 'tracking'::text, 'appointment_booked'::text, 'Foglalás-mérés lefedettsége',
           format('A GA4 az elmúlt 7 napban %s foglalást mért a saját %s-ből (%s%%)', ga_n, db_n, round(100 * ga_n / db_n)),
           'A hozzájárulás (consent) nélküli látogatók nem mérődnek; alacsony arány hibás címkére vagy kiesett eseményre is utalhat.',
           jsonb_build_object('db', db_n, 'ga', ga_n),
           'Ellenőrizd a GTM-címkéket előnézet módban és a consent-beállítást; a saját adatbázis marad az igazság, a GA4 csak a forrás-bontáshoz használható.',
           db_n - ga_n;
  end if;
end $$;

insert into alert_rule (insight_key, label, enabled, notify, cooldown_days) values
  ('tracking_coverage', 'Foglalás-mérés lefedettsége', true, false, 7)
on conflict (insight_key) do nothing;

create or replace function data_quality_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language sql stable as $$
  select * from data_quality_core(p_now)
  union all select * from ac_alerts(p_now)
  union all select * from tracking_alerts(p_now);
$$;

revoke all on mart_tracking_reconciliation from anon;
grant select on mart_tracking_reconciliation to authenticated;
revoke execute on function tracking_coverage(date, date, text), tracking_alerts(timestamptz) from public, anon;
grant execute on function tracking_coverage(date, date, text) to authenticated;
