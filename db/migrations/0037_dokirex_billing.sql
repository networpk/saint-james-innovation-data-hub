-- Dokirex számlázás (bevétel) a Hubban. Csak a Lovable Cloud (Supabase) adatbázisra való; a 0027 (szerepkörök) és a 0030 után fut.
-- Nem töröl és nem ír át meglévő adatot (a fact_booking ma üres, a függvény csak töltéskor ír bele).
--
-- Forrás: a Dokirex `builtin_getElojegyzesSzamlazas` tárolt eljárása (a foglaló alkalmazás csak olvasó, fehérlistás exportján át).
-- Az export előjegyzésenként és szolgáltatásonként ÖSSZEGEZ, és nem tartalmaz páciens-azonosítót, nevet vagy megjegyzést.
-- A Tól/Ig a vizit napjára szűr, a sorok a vizit után még napokig módosulnak, ezért a betöltésnek visszamenőleg (kb. 90 nap) újra kell olvasnia.
-- Az online foglalóból jövő vizitek a rendelés kis részét adják; az összes bevétel szolgáltatás szerint, az online rész külön látszik.

-- 1) Számlázott összeg előjegyzésenként, szolgáltatásonként, vizit napra (rendelői helyi nap).
create table if not exists public.fact_dokirex_billing (
  elojegyzes_id bigint not null,
  visit_date date not null,
  service text not null,
  amount numeric(14,2) not null default 0,   -- a SzamlazottOsszeg összege; negatív érték (sztornó) is előfordulhat
  lines integer not null default 1,           -- az összegzett sorok száma
  dx_status integer,                          -- a Dokirex Status mezője (jelentése még tisztázandó)
  modified_at timestamptz,                    -- a legutóbbi ModositasIdeje
  loaded_at timestamptz not null default now(),
  primary key (elojegyzes_id, visit_date, service)
);
create index if not exists idx_fdb_visit on public.fact_dokirex_billing (visit_date);

revoke all on public.fact_dokirex_billing from anon;
grant select on public.fact_dokirex_billing to authenticated;
grant all on public.fact_dokirex_billing to service_role;
alter table public.fact_dokirex_billing enable row level security;

-- Előjegyzés-szintű adat: ugyanaz a szabály, mint a fact_booking-nál (admin és elemző). A megtekintő az összesítő függvényt használja.
drop policy if exists lead_read on public.fact_dokirex_billing;
create policy lead_read on public.fact_dokirex_billing for select to authenticated
  using (public.can_read_leads(auth.uid()));

-- 2) Szolgáltatás → üzletág megfeleltetés (szerkeszthető). Ami nincs benne, az „besorolatlan".
create table if not exists public.dokirex_service_map (
  service text primary key,
  business_line text not null check (business_line in ('szemeszet', 'eszteika_plasztika', 'besorolatlan')),
  note text,
  updated_at timestamptz not null default now()
);
revoke all on public.dokirex_service_map from anon;
grant select, insert, update, delete on public.dokirex_service_map to authenticated;
grant all on public.dokirex_service_map to service_role;
alter table public.dokirex_service_map enable row level security;

drop policy if exists dsm_member_read on public.dokirex_service_map;
create policy dsm_member_read on public.dokirex_service_map for select to authenticated
  using (public.is_member(auth.uid()));
drop policy if exists dsm_editor_write on public.dokirex_service_map;
create policy dsm_editor_write on public.dokirex_service_map for all to authenticated
  using (public.can_edit(auth.uid())) with check (public.can_edit(auth.uid()));

-- 3) Besorolatlan szolgáltatások (a szerkesztőnek): a számlázásban szereplő, de a megfeleltetésből hiányzó szolgáltatások.
create or replace view public.mart_dokirex_unmapped_services as
select b.service, sum(b.amount) as amount, count(distinct b.elojegyzes_id) as bookings,
       min(b.visit_date) as first_day, max(b.visit_date) as last_day
from public.fact_dokirex_billing b
where not exists (select 1 from public.dokirex_service_map m where m.service = b.service)
group by b.service;
alter view public.mart_dokirex_unmapped_services set (security_invoker = on);
revoke all on public.mart_dokirex_unmapped_services from anon;
grant select on public.mart_dokirex_unmapped_services to authenticated, service_role;

-- 4) Összesítés a felületnek és az Asszisztensnek (a megtekintő is látja, csak összesítést: nincs előjegyzés-azonosító).
-- Online = az előjegyzést az online foglalóból kaptuk (a fact_lead-ben szerepel a Dokirex-azonosítója). Egy foglaláshoz több lead-sor is
-- tartozhat ugyanazzal az azonosítóval, ezért „exists"-szel számolunk, a bevétel nem duplázódik.
create or replace function public.dokirex_revenue_summary(p_from date, p_to date, p_business_line text default null)
returns table (visit_date date, business_line text, service text, bookings integer, revenue numeric,
               online_bookings integer, online_revenue numeric)
language sql stable security definer set search_path = public as $$
  with b as (
    select f.visit_date, coalesce(m.business_line, 'besorolatlan') as bl, f.service, f.elojegyzes_id, f.amount,
           exists (select 1 from public.fact_lead l where l.dokirex_booking_id = f.elojegyzes_id) as is_online
    from public.fact_dokirex_billing f
    left join public.dokirex_service_map m on m.service = f.service
    where public.is_member(auth.uid())
      and f.visit_date between p_from and p_to
  )
  select visit_date, bl, service,
         count(distinct elojegyzes_id)::int,
         coalesce(sum(amount), 0),
         count(distinct elojegyzes_id) filter (where is_online)::int,
         coalesce(sum(amount) filter (where is_online), 0)
  from b
  where p_business_line is null or p_business_line = 'mind' or bl = p_business_line
  group by visit_date, bl, service
  order by visit_date, bl, service
$$;
revoke execute on function public.dokirex_revenue_summary(date, date, text) from public, anon;
grant execute on function public.dokirex_revenue_summary(date, date, text) to authenticated, service_role;

-- 5) A bevétel átvezetése a fact_booking-ba (a mart_lead_journey innen veszi az időpontot és az állapotot). A betöltés után hívandó.
-- Az előjegyzés összes sorát összegzi (nem csak a tartományba esőket). A meglévő időpontot és állapotot nem írja át.
-- Az állapot „unknown", mert a Dokirex Status mezőjének jelentése még nem ismert; a Status a payload-ban marad.
create or replace function public.rollup_booking_revenue(p_from date, p_to date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with ids as (
    select distinct elojegyzes_id from public.fact_dokirex_billing where visit_date between p_from and p_to
  ), agg as (
    select b.elojegyzes_id,
           min(b.visit_date) as first_visit,
           sum(b.amount) as revenue,
           max(b.dx_status) as dx_status
    from public.fact_dokirex_billing b join ids using (elojegyzes_id)
    group by b.elojegyzes_id
  ), up as (
    insert into public.fact_booking as t (dokirex_booking_id, appointment_at, status, revenue, payload, loaded_at)
    select a.elojegyzes_id, (a.first_visit::timestamp at time zone 'Europe/Budapest'), 'unknown', a.revenue,
           jsonb_build_object('source', 'billing', 'dx_status', a.dx_status), now()
    from agg a
    on conflict (dokirex_booking_id) do update
      set revenue = excluded.revenue,
          appointment_at = coalesce(t.appointment_at, excluded.appointment_at),
          payload = coalesce(t.payload, '{}'::jsonb) || excluded.payload,
          loaded_at = now()
      where t.revenue is distinct from excluded.revenue
    returning 1
  )
  select count(*) into n from up;
  return n;
end $$;
revoke execute on function public.rollup_booking_revenue(date, date) from public, anon, authenticated;
grant execute on function public.rollup_booking_revenue(date, date) to service_role;
