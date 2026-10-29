-- Lead-minőség / kifogási okok: a foglaló app hívási listáján a recepció által rögzített státusz és kifogási ok (hub-export, PII nélkül) a Hubban.
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0033 (lead_channel) és a 0040/0041 (lead_episode) után fut. Additív: a meglévő táblák, nézetek és
-- függvények változatlanok, a fact_lead öt új, null-ozható oszlopot kap, ha a foglaló még nem küld CRM-adatot, minden érték NULL és a Hub úgy működik, mint eddig.
--
-- Mit ad: (1) a fact_lead CRM-oszlopai (az ingest-leads tölti a hub-export mezőiből); (2) a dim_objection_reason törzstábla (kód -> magyar címke);
-- (3) a lead_episode_crm nézet: epizódonként (24 órás rögzített ablak, 0040) az utoljára kezelt rekord CRM-állapota; (4) három összesítő függvény:
-- összkép (hány beérkezett, hány kapott időpontot, hány zárult le és milyen kifogással), kifogás csatornánként, kifogás kampányonként.
-- Kohorsz: az epizódok (egyedi leadek), mint a Kampányok „Mindösszesen” sorban, így a Hub számai ugyanazt az egységet használják. A foglaló app saját statisztikája
-- egyedi telefonszám-kontaktot számol az egész időszakra, ezért a két oldal darabszáma kismértékben eltérhet (a Hub 24 óránként új epizódot nyit).
-- Lead-szintű adat nem kerül ki: a nézet nem olvasható a felületi szerepköröknek, a függvények csak darabszámot adnak (a megtekintő is látja).

-- 1) CRM-oszlopok a fact_lead-en (az ingest-leads upsertje tölti; a hub-export hiányzó mezői NULL-ként érkeznek).
alter table public.fact_lead
  add column if not exists crm_status text,
  add column if not exists crm_status_category text check (crm_status_category is null or crm_status_category in ('hivas', 'beirva', 'lezart')),
  add column if not exists objection_reason text,
  add column if not exists objection_source text check (objection_source is null or objection_source in ('valasztott', 'megjegyzesbol')),
  add column if not exists crm_updated_at timestamptz;

create index if not exists idx_fact_lead_crm_updated on public.fact_lead (crm_updated_at) where crm_status is not null;
create index if not exists idx_fact_lead_person_created on public.fact_lead ((coalesce(email_hash, phone_hash)), created_at);

-- 2) Kifogási okok törzse (a foglaló app szerkeszthető listájának tükre; az ingest-leads frissíti). Kezdő értékek: ugyanaz a lista, mint a foglalóban,
-- hogy a címkék a betöltés előtt is magyarul jelenjenek meg. A kód stabil, a címke változhat.
create table if not exists public.dim_objection_reason (
  key text primary key,
  label text not null,
  position integer not null default 0,
  is_primary boolean not null default false,
  active boolean not null default true,
  loaded_at timestamptz not null default now()
);
insert into public.dim_objection_reason (key, label, position, is_primary, active) values
  ('teves',        'Tévesen jelentkezett',                         10, true,  true),
  ('tavolsag',     'Nagy a távolság',                              20, true,  true),
  ('draga',        'Drága / az ár nem megfelelő',                  30, true,  true),
  ('nem_aktualis', 'Meggondolta magát / most nem aktuális',        40, true,  true),
  ('orvosi',       'Orvosi ok / nem alkalmas',                     50, true,  true),
  ('mashol',       'Máshol intézi',                                60, false, true),
  ('idopont',      'Nem megfelelő az időpont / nincs szabad hely', 70, false, true),
  ('tajekozodott', 'Csak tájékozódott',                            80, false, true),
  ('egyeb',        'Egyéb',                                        90, false, true)
on conflict (key) do nothing;
-- GRANT/REVOKE az RLS bekapcsolása előtt (Lovable-szabály).
revoke all on public.dim_objection_reason from public, anon;
grant select on public.dim_objection_reason to authenticated;
grant all on public.dim_objection_reason to service_role;
alter table public.dim_objection_reason enable row level security;
drop policy if exists objection_reason_member_read on public.dim_objection_reason;
create policy objection_reason_member_read on public.dim_objection_reason for select to authenticated
  using (public.is_member(auth.uid()));

-- 3) Epizódonkénti CRM-állapot: az epizód 24 órás ablakába eső rekordok közül az utoljára kezelt (legnagyobb crm_updated_at) számít.
-- Személykulcs nélküli epizód = egyetlen rekord. A nézet személy-szintű, ezért csak a függvények (security definer) és a service_role olvassa.
create or replace view public.lead_episode_crm as
select e.first_lead_id, e.first_at, e.day, e.business_line, e.person_key, e.booked, e.channel, e.channel_label, e.source_known,
       m.crm_status, m.crm_status_category, m.objection_reason, m.objection_source, m.crm_updated_at,
       (select j.utm_campaign from public.lead_journey j where j.lead_id = e.first_lead_id) as utm_campaign
from public.lead_episode e
left join lateral (
  select l.crm_status, l.crm_status_category, l.objection_reason, l.objection_source, l.crm_updated_at
  from public.fact_lead l
  where l.crm_status is not null
    and ((e.person_key is not null
          and coalesce(l.email_hash, l.phone_hash) = e.person_key
          and l.business_line = e.business_line
          and l.created_at >= e.first_at
          and l.created_at < e.first_at + interval '24 hours')
      or (e.person_key is null and l.lead_id = e.first_lead_id))
  order by l.crm_updated_at desc nulls last, l.lead_id
  limit 1
) m on true;
revoke all on public.lead_episode_crm from public, anon, authenticated;
grant select on public.lead_episode_crm to service_role;

-- 4) Összkép. kind: summary (osszes, beirva, lezart, folyamatban, nincs_statusz) | reason (okonként, plusz nincs_ok) | meta (megjegyzesbol).
-- „Nem foglalt” = lezárt státuszú VAGY kifogási okkal rendelkező epizód; a pct_of_closed ehhez viszonyít. per_10: 10 beérkezett leadből hány (egy tizedes).
create or replace function public.lead_objection_summary(p_from date, p_to date, p_business_line text default null)
returns table (kind text, key text, label text, episodes integer, pct_of_all numeric, pct_of_closed numeric, per_10 numeric, sort_order integer)
language sql stable security definer set search_path = public as $$
  with s as (
    select c.*
    from public.lead_episode_crm c
    where public.is_member(auth.uid())
      and c.day between p_from and p_to
      and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or c.business_line = p_business_line)
  ), t as (
    select count(*)::int as total,
           (count(*) filter (where crm_status_category = 'lezart' or objection_reason is not null))::int as not_booked
    from s
  ), rows as (
    select 'summary'::text as kind, 'osszes'::text as key, 'Összes beérkezett'::text as label, (select total from t) as n, 10 as pos
    union all select 'summary', 'beirva', 'Időpontot kapott (beírva)', (count(*) filter (where crm_status_category = 'beirva'))::int, 20 from s
    union all select 'summary', 'lezart', 'Lezárt', (count(*) filter (where crm_status_category = 'lezart'))::int, 30 from s
    union all select 'summary', 'folyamatban', 'Folyamatban', (count(*) filter (where crm_status_category = 'hivas'))::int, 40 from s
    union all select 'summary', 'nincs_statusz', 'Még nincs státusz', (count(*) filter (where crm_status is null))::int, 50 from s
    union all select 'summary', 'nem_foglalt', 'Nem foglalt (lezárt vagy kifogással)', (select not_booked from t), 60
    union all
    select 'reason', s.objection_reason, coalesce(d.label, s.objection_reason), count(*)::int, 100 + coalesce(d.position, 900)
    from s left join public.dim_objection_reason d on d.key = s.objection_reason
    where s.objection_reason is not null
    group by s.objection_reason, d.label, d.position
    union all
    select 'reason', 'nincs_ok', 'Nincs ok megadva', (count(*) filter (where crm_status_category = 'lezart' and objection_reason is null))::int, 999 from s
    union all
    select 'meta', 'megjegyzesbol', 'Régi megjegyzésből besorolt ok', (count(*) filter (where objection_source = 'megjegyzesbol'))::int, 1000 from s
  )
  select r.kind, r.key, r.label, r.n,
         round(100.0 * r.n / nullif((select total from t), 0), 1),
         case when r.kind = 'reason' then round(100.0 * r.n / nullif((select not_booked from t), 0), 1) end,
         round(10.0 * r.n / nullif((select total from t), 0), 1),
         r.pos
  from rows r
  where public.is_member(auth.uid())
  order by r.pos, r.n desc, r.key
$$;
revoke execute on function public.lead_objection_summary(date, date, text) from public, anon;
grant execute on function public.lead_objection_summary(date, date, text) to authenticated, service_role;

-- 5) Kifogás csatornánként. reason_key: „_osszes” (a csatorna összes epizódja), „_nem_foglalt”, okok kulcsa, „nincs_ok”.
create or replace function public.lead_objection_by_channel(p_from date, p_to date, p_business_line text default null)
returns table (channel text, channel_label text, reason_key text, reason_label text, episodes integer)
language sql stable security definer set search_path = public as $$
  with s as (
    select c.*
    from public.lead_episode_crm c
    where public.is_member(auth.uid())
      and c.day between p_from and p_to
      and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or c.business_line = p_business_line)
  )
  select x.channel, x.channel_label, x.reason_key, x.reason_label, x.n
  from (
    select s.channel, s.channel_label, '_osszes'::text as reason_key, 'Összes beérkezett'::text as reason_label, count(*)::int as n, 0 as pos
    from s group by s.channel, s.channel_label
    union all
    select s.channel, s.channel_label, '_nem_foglalt', 'Nem foglalt (lezárt vagy kifogással)',
           (count(*) filter (where s.crm_status_category = 'lezart' or s.objection_reason is not null))::int, 1
    from s group by s.channel, s.channel_label
    union all
    select s.channel, s.channel_label, s.objection_reason, coalesce(d.label, s.objection_reason), count(*)::int, 100 + coalesce(d.position, 900)
    from s left join public.dim_objection_reason d on d.key = s.objection_reason
    where s.objection_reason is not null
    group by s.channel, s.channel_label, s.objection_reason, d.label, d.position
    union all
    select s.channel, s.channel_label, 'nincs_ok', 'Nincs ok megadva',
           (count(*) filter (where s.crm_status_category = 'lezart' and s.objection_reason is null))::int, 999
    from s group by s.channel, s.channel_label
  ) x
  where x.n > 0 or x.reason_key in ('_osszes', '_nem_foglalt')
  order by x.channel, x.pos, x.n desc
$$;
revoke execute on function public.lead_objection_by_channel(date, date, text) from public, anon;
grant execute on function public.lead_objection_by_channel(date, date, text) to authenticated, service_role;

-- 6) Kifogás kampányonként (az epizód első rekordjának utm_campaign értéke; a kampány-hozzárendelés a Hub meglévő névillesztése szerint a felületen történik).
-- Csak a p_limit legtöbb nem foglalt epizódot hozó kampány jön vissza, a többi „(egyéb kampányok)” alatt összevonva.
create or replace function public.lead_objection_by_campaign(p_from date, p_to date, p_business_line text default null, p_limit integer default 15)
returns table (campaign text, reason_key text, reason_label text, episodes integer)
language sql stable security definer set search_path = public as $$
  with s as (
    select c.*, coalesce(nullif(c.utm_campaign, ''), '(nincs kampány)') as camp
    from public.lead_episode_crm c
    where public.is_member(auth.uid())
      and c.day between p_from and p_to
      and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or c.business_line = p_business_line)
  ), ranked as (
    select camp, row_number() over (order by count(*) filter (where crm_status_category = 'lezart' or objection_reason is not null) desc, count(*) desc, camp) as rk
    from s group by camp
  ), g as (
    select case when r.rk <= greatest(p_limit, 1) then s.camp else '(egyéb kampányok)' end as camp_g, s.*
    from s join ranked r on r.camp = s.camp
  )
  select x.campaign, x.reason_key, x.reason_label, x.n
  from (
    select g.camp_g as campaign, '_osszes'::text as reason_key, 'Összes beérkezett'::text as reason_label, count(*)::int as n, 0 as pos from g group by g.camp_g
    union all
    select g.camp_g, '_nem_foglalt', 'Nem foglalt (lezárt vagy kifogással)',
           (count(*) filter (where g.crm_status_category = 'lezart' or g.objection_reason is not null))::int, 1 from g group by g.camp_g
    union all
    select g.camp_g, g.objection_reason, coalesce(d.label, g.objection_reason), count(*)::int, 100 + coalesce(d.position, 900)
    from g left join public.dim_objection_reason d on d.key = g.objection_reason
    where g.objection_reason is not null
    group by g.camp_g, g.objection_reason, d.label, d.position
    union all
    select g.camp_g, 'nincs_ok', 'Nincs ok megadva',
           (count(*) filter (where g.crm_status_category = 'lezart' and g.objection_reason is null))::int, 999 from g group by g.camp_g
  ) x
  where x.n > 0 or x.reason_key in ('_osszes', '_nem_foglalt')
  order by x.campaign, x.pos, x.n desc
$$;
revoke execute on function public.lead_objection_by_campaign(date, date, text, integer) from public, anon;
grant execute on function public.lead_objection_by_campaign(date, date, text, integer) to authenticated, service_role;
