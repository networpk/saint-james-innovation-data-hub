-- Konverziós műveletek szerepe: melyik platform-konverzió "kemény" lead (a Hub "Platform lead" mutatója),
-- melyik "soft" (kattintás, megtekintés, hívás), és melyik figyelmen kívül hagyott (duplikátum).
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0027 (szerepkörök) után fut. Nem töröl és nem ír át meglévő adatot.
--
-- Probléma (éles audit, 2026-10-19):
--  * Google Ads (esztétika): a `conversions` mutató a "Sikeres időpontfoglalás" (23) ÉS az "Időpontfoglalás kattintás" (62) műveletet is
--    beleszámolja, ezért a Hub "Platform lead" a kemény foglalás 3,7-szerese volt.
--  * Meta (SAINTJAMESHUNGARY - CONVERSION): a konverzió egyedi pixel-esemény (`actions_offsite_conversion_fb_pixel_custom`),
--    a Hub csak az `actions_lead`-et olvasta, ezért 0-t mutatott (a Meta 11-et).
--  * A hirdetési platformok a konverziókat utólag módosítják (késleltetett konverzió); a 7 napos betöltési ablak a régebbi napokat nem frissíti.
-- Megoldás: a betöltés műveletenként is eltárolja a konverziókat (fact_conversion_action_daily), a szerepet egy szerkeszthető tábla adja
-- (conversion_action_map), és az apply_conversion_roles() ebből számolja a fact_ad_performance_daily.platform_leads értékét.
-- Így minden meglévő nézet és oldal változtatás nélkül a kemény leadet mutatja, a soft szám a `extra.soft_conversions` mezőben marad.

-- 1) Szerepek. account_id/campaign_id = '' azt jelenti: bármely fiók / bármely kampány. A pontosabb szabály erősebb.
create table if not exists public.conversion_action_map (
  platform text not null check (platform in ('google', 'meta', 'tiktok')),
  account_id text not null default '',
  campaign_id text not null default '',
  action_name text not null,        -- Google: conversion_action_name; Meta: Windsor-mezőnév (pl. actions_lead)
  role text not null check (role in ('hard', 'soft', 'ignore')),
  note text,
  updated_at timestamptz not null default now(),
  primary key (platform, account_id, campaign_id, action_name)
);

-- 2) Műveletenkénti konverziók napi szinten (ugyanazon a kulcson, mint a fact_ad_performance_daily + a művelet neve).
create table if not exists public.fact_conversion_action_daily (
  date date not null,
  platform text not null,
  account_id text not null,
  campaign_id text not null,
  adset_id text not null default '',
  ad_id text not null default '',
  action_name text not null,
  conversions numeric(14,4) not null default 0,      -- a platform "Konverziók" oszlopa (csak a beszámított műveletek)
  all_conversions numeric(14,4) not null default 0,  -- minden konverzió, a nem beszámítottakat is
  loaded_at timestamptz not null default now(),
  primary key (date, platform, account_id, campaign_id, adset_id, ad_id, action_name)
);
create index if not exists idx_fcad_campaign on public.fact_conversion_action_daily (platform, campaign_id, date);

alter table public.conversion_action_map enable row level security;
alter table public.fact_conversion_action_daily enable row level security;
revoke all on public.conversion_action_map, public.fact_conversion_action_daily from anon;
grant select on public.conversion_action_map, public.fact_conversion_action_daily to authenticated;
grant insert, update, delete on public.conversion_action_map to authenticated;
grant all on public.conversion_action_map, public.fact_conversion_action_daily to service_role;

drop policy if exists cam_member_read on public.conversion_action_map;
create policy cam_member_read on public.conversion_action_map for select to authenticated
  using (public.is_member(auth.uid()));
drop policy if exists cam_editor_write on public.conversion_action_map;
create policy cam_editor_write on public.conversion_action_map for all to authenticated
  using (public.can_edit(auth.uid())) with check (public.can_edit(auth.uid()));
drop policy if exists fcad_member_read on public.fact_conversion_action_daily;
create policy fcad_member_read on public.fact_conversion_action_daily for select to authenticated
  using (public.is_member(auth.uid()));

-- 3) A feloldott szerep soronként: kampány-szintű > fiók-szintű > általános; ami sehol nincs megadva, az "soft".
create or replace view public.conversion_action_resolved as
select f.date, f.platform, f.account_id, f.campaign_id, f.adset_id, f.ad_id, f.action_name,
       f.conversions, f.all_conversions,
       coalesce((select m.role
                 from conversion_action_map m
                 where m.platform = f.platform and m.action_name = f.action_name
                   and m.account_id in (f.account_id, '') and m.campaign_id in (f.campaign_id, '')
                 order by (m.campaign_id <> '') desc, (m.account_id <> '') desc
                 limit 1), 'soft') as role,
       exists (select 1 from conversion_action_map m
               where m.platform = f.platform and m.action_name = f.action_name
                 and m.account_id in (f.account_id, '') and m.campaign_id in (f.campaign_id, '')) as mapped
from fact_conversion_action_daily f;

-- 4) Kampányonkénti napi bontás a felületnek és az Asszisztensnek: kemény / soft / összes konverzió.
create or replace view public.mart_conversion_split_daily as
select date, platform, account_id, campaign_id,
       coalesce(sum(conversions) filter (where role = 'hard'), 0) as hard_conversions,
       coalesce(sum(conversions) filter (where role = 'soft'), 0) as soft_conversions,
       coalesce(sum(all_conversions), 0) as all_conversions
from conversion_action_resolved
group by 1, 2, 3, 4;

-- 5) Besorolatlan műveletek (nincs szerepük): az elmúlt 30 napban konverziót hozó, de a táblában nem szereplő műveletek.
create or replace view public.mart_unmapped_conversion_actions as
select platform, account_id, action_name,
       sum(conversions) as conversions, sum(all_conversions) as all_conversions,
       min(date) as first_day, max(date) as last_day
from conversion_action_resolved
where not mapped and date >= current_date - 30 and (conversions > 0 or all_conversions > 0)
group by 1, 2, 3;

alter view public.conversion_action_resolved set (security_invoker = on);
alter view public.mart_conversion_split_daily set (security_invoker = on);
alter view public.mart_unmapped_conversion_actions set (security_invoker = on);
revoke all on public.conversion_action_resolved, public.mart_conversion_split_daily, public.mart_unmapped_conversion_actions from anon;
grant select on public.conversion_action_resolved, public.mart_conversion_split_daily, public.mart_unmapped_conversion_actions to authenticated, service_role;

-- 6) A szerepek alkalmazása: a fact_ad_performance_daily.platform_leads = a kemény konverziók összege, azokon a soron, amelyekre van
-- műveletenkénti adat. Ahol nincs (pl. TikTok, vagy ha a művelet-lekérdezés elmaradt), a sor változatlan marad (a platform nyers száma).
-- Idempotens: mindig a műveleti tényekből számol, nem a korábbi platform_leads értékből. A betöltés után kell hívni.
create or replace function public.apply_conversion_roles(p_from date, p_to date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with agg as (
    select date, platform, account_id, campaign_id, adset_id, ad_id,
           coalesce(sum(conversions) filter (where role = 'hard'), 0) as hard,
           coalesce(sum(conversions) filter (where role = 'soft'), 0) as soft
    from conversion_action_resolved
    where date between p_from and p_to
    group by 1, 2, 3, 4, 5, 6
  )
  update fact_ad_performance_daily t
     set platform_leads = a.hard,
         extra = coalesce(t.extra, '{}'::jsonb) || jsonb_build_object('soft_conversions', a.soft)
    from agg a
   where t.date = a.date and t.platform = a.platform and t.account_id = a.account_id and t.campaign_id = a.campaign_id
     and t.adset_id = a.adset_id and t.ad_id = a.ad_id
     and (t.platform_leads is distinct from a.hard
          or (t.extra ->> 'soft_conversions') is distinct from a.soft::text);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.apply_conversion_roles(date, date) from public, anon, authenticated;
grant execute on function public.apply_conversion_roles(date, date) to service_role;

-- 7) Kezdeti szerepek az audit alapján (szerkeszthető; az ismeretlen művelet "soft", amíg valaki át nem sorolja).
insert into public.conversion_action_map (platform, account_id, campaign_id, action_name, role, note) values
  -- Google Ads, esztétika (556-030-7472): csak a sikeres foglalás kemény lead
  ('google', '556-030-7472', '', 'Sikeres időpontfoglalás', 'hard', 'a kemény foglalás-konverzió'),
  ('google', '556-030-7472', '', 'Időpontfoglalás kattintás', 'soft', 'kattintás a foglalásra, beküldés nélkül'),
  ('google', '556-030-7472', '', 'saintjameshungary.hu (web) sikeres_foglalas', 'ignore', 'GA4-import: ugyanaz a foglalás, mint a "Sikeres időpontfoglalás" (duplikátum)'),
  -- Google Ads, szemészet (149-137-6230): a mai működés megmarad (a "Lead" a beszámított konverzió)
  ('google', '149-137-6230', '', 'Lead', 'hard', 'a beszámított konverzió (a mai Platform lead)'),
  ('google', '149-137-6230', '', 'soft_conv_foglaljon', 'soft', 'kattintás a foglalásra, beküldés nélkül'),
  ('google', '149-137-6230', '', 'Lassjol.hu – GA4 (web) generate_lead', 'soft', 'GA4-import, a platform nem számítja be; ellenőrizendő'),
  -- Meta: a natív és pixel lead kemény; az egyedi pixel-esemény alapból soft (a Traffic kampányoknál hatékonysági jel, nem konverzió)
  ('meta', '', '', 'actions_lead', 'hard', 'lead (űrlap és pixel)'),
  ('meta', '', '', 'actions_offsite_conversion_fb_pixel_custom', 'soft', 'egyedi pixel-esemény; konverziós kampánynál kampány-szintű szabály írja felül'),
  ('meta', '2060753947612996', '120249145359870714', 'actions_offsite_conversion_fb_pixel_custom', 'hard', 'SAINTJAMESHUNGARY - CONVERSION: az egyedi pixel-esemény az optimalizált konverzió (a Meta 11-et mutat)')
on conflict (platform, account_id, campaign_id, action_name) do nothing;
