-- Kampány↔forgalom párosítás javítása + a hiányzó kampánybesorolási szabályok.
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0027 (szerepkörök) után fut. Nem töröl és nem ír át meglévő adatot.
--
-- Probléma (éles audit, 90 nap): a GA4 munkameneteket/eseményeket a kampány LEGUTÓBBI neve szerint kötöttük a hirdetéshez.
-- A két legnagyobb szemészeti Google-kampányt átnevezték (okt. 9.), a hirdetések UTM-je viszont a régi nevet viseli, ezért a Google fizetett
-- munkameneteinek 34%-a (18 482 / 53 925) nem párosult kampányhoz (Perf.Max lézeres: 655 helyett ~10 977 munkamenet, 76 helyett ~836 soft lead).
-- Megoldás: (1) a párosítás a kampány MINDEN eddigi nevét használja (a hirdetési adatból, automatikusan),
--           (2) kézi alias-tábla a kézzel írt / rövidített UTM-nevekre, (3) a hiányzó besorolási szabályok.
-- A költés, kattintás és platform lead nem érintett (azok a hirdetési platformból jönnek); az oszlopok és a nézetek oszloplistája változatlan.

-- 1) Kézi alias: egy GA4 kampánynév (ékezet- és kisbetű-érzéketlenül) → egy hirdetési kampány azonosítója.
create table if not exists public.campaign_utm_alias (
  platform text not null check (platform in ('meta', 'google', 'tiktok')),
  alias_norm text not null,            -- sj_norm(GA4 kampánynév): kisbetű, ékezet nélkül
  campaign_id text not null,
  note text,
  created_at timestamptz not null default now(),
  primary key (platform, alias_norm)
);
alter table public.campaign_utm_alias enable row level security;
revoke all on public.campaign_utm_alias from anon;
grant select, insert, update, delete on public.campaign_utm_alias to authenticated;
grant all on public.campaign_utm_alias to service_role;

drop policy if exists alias_member_read on public.campaign_utm_alias;
create policy alias_member_read on public.campaign_utm_alias for select to authenticated
  using (public.is_member(auth.uid()));
drop policy if exists alias_editor_write on public.campaign_utm_alias;
create policy alias_editor_write on public.campaign_utm_alias for all to authenticated
  using (public.can_edit(auth.uid())) with check (public.can_edit(auth.uid()));

-- 2) Egy kampány minden ismert neve: jelenlegi + a hirdetési adatban valaha látott + kézi alias.
-- Egy régi név nem "lopható el": ha egy másik kampány JELENLEGI neve, az a másik kampányé marad.
create or replace view public.campaign_name_match as
with cur as (
  select c.platform, c.campaign_id, sj_norm(c.campaign_name) as name_norm
  from campaign_class c
  where c.campaign_name is not null and c.campaign_name <> ''
), hist as (
  select f.platform, f.campaign_id, sj_norm(f.campaign_name) as name_norm
  from fact_ad_performance_daily f
  where f.campaign_name is not null and f.campaign_name <> ''
  group by 1, 2, 3
), allnames as (
  select platform, campaign_id, name_norm, 'current'::text as src from cur
  union all
  select h.platform, h.campaign_id, h.name_norm, 'history'
  from hist h
  where not exists (select 1 from cur x where x.platform = h.platform and x.name_norm = h.name_norm and x.campaign_id <> h.campaign_id)
  union all
  select a.platform, a.campaign_id, a.alias_norm, 'alias' from campaign_utm_alias a
)
select platform, campaign_id, name_norm, min(src) as src
from allnames
group by platform, campaign_id, name_norm;

-- 3) A kampány-tölcsér: a név szerinti párosítás a kampány összes ismert nevére megy; az azonosító szerinti rész változatlan.
-- A név szerinti sorok előbb kampányazonosítóra összegződnek, így nem lehet sorsokszorozódás (a költés nem duplázódik).
create or replace view mart_campaign_funnel_daily as
with ad as (
  select f.date, f.platform, f.account_id, f.campaign_id,
         sum(f.spend) as spend, sum(f.impressions) as impressions, sum(f.clicks) as clicks,
         sum(f.platform_leads) as platform_leads
  from fact_ad_performance_daily f group by 1,2,3,4
), web as (
  select w.date, m.platform, w.campaign as raw_campaign, sj_norm(w.campaign) as cname,
         sum(w.sessions) as sessions, sum(w.users) as users, sum(w.engaged_sessions) as engaged_sessions,
         sum(w.engagement_seconds) as engagement_seconds
  from fact_web_daily w join platform_source_map m on m.ga_source = lower(w.source)
  where w.campaign <> '' group by 1,2,3,4
), ev as (
  select e.date, m.platform, e.campaign as raw_campaign, sj_norm(e.campaign) as cname,
         sum(e.event_count) filter (where fm.stage = 'soft_lead') as soft_leads,
         sum(e.event_count) filter (where fm.stage = 'ga_hard_lead') as ga_hard_leads
  from fact_web_event_daily e
  join platform_source_map m on m.ga_source = lower(e.source)
  join funnel_event_map fm on fm.event_name = e.event_name
  where e.campaign <> '' group by 1,2,3,4
), web_by_name as (
  select w.date, w.platform, n.campaign_id,
         sum(w.sessions) as sessions, sum(w.users) as users, sum(w.engaged_sessions) as engaged_sessions,
         sum(w.engagement_seconds) as engagement_seconds
  from web w join campaign_name_match n on n.platform = w.platform and n.name_norm = w.cname
  where w.raw_campaign <> n.campaign_id
  group by 1,2,3
), ev_by_name as (
  select e.date, e.platform, n.campaign_id,
         sum(e.soft_leads) as soft_leads, sum(e.ga_hard_leads) as ga_hard_leads
  from ev e join campaign_name_match n on n.platform = e.platform and n.name_norm = e.cname
  where e.raw_campaign <> n.campaign_id
  group by 1,2,3
), j as (
  select ad.*, c.campaign_name, c.business_line, c.category, c.subcategory
  from ad left join campaign_class c on c.platform = ad.platform and c.account_id = ad.account_id and c.campaign_id = ad.campaign_id
)
select j.date, j.platform, j.account_id, j.campaign_id, j.campaign_name, j.business_line, j.category, j.subcategory,
       j.spend, j.impressions, j.clicks, j.platform_leads,
       coalesce(wn.sessions,0) + coalesce(wi.sessions,0) as sessions,
       coalesce(wn.users,0) + coalesce(wi.users,0) as users,
       coalesce(wn.engaged_sessions,0) + coalesce(wi.engaged_sessions,0) as engaged_sessions,
       coalesce(wn.engagement_seconds,0) + coalesce(wi.engagement_seconds,0) as engagement_seconds,
       coalesce(en.soft_leads,0) + coalesce(ei.soft_leads,0) as soft_leads,
       coalesce(en.ga_hard_leads,0) + coalesce(ei.ga_hard_leads,0) as ga_hard_leads
from j
-- név szerint (a kampány bármely ismert nevére)
left join web_by_name wn on wn.date = j.date and wn.platform = j.platform and wn.campaign_id = j.campaign_id
left join ev_by_name  en on en.date = j.date and en.platform = j.platform and en.campaign_id = j.campaign_id
-- azonosító szerint (változatlan)
left join web wi on wi.date = j.date and wi.platform = j.platform and wi.raw_campaign = j.campaign_id
left join ev  ei on ei.date = j.date and ei.platform = j.platform and ei.raw_campaign = j.campaign_id;

-- 4) Az illeszkedetlen forgalom listája: ugyanaz a mérce, mint a tölcsérben (bármely ismert név vagy azonosító).
create or replace view mart_web_campaign_unmatched as
select w.date, m.platform, w.campaign, w.source, w.medium, sum(w.sessions) as sessions
from fact_web_daily w join platform_source_map m on m.ga_source = lower(w.source)
where w.campaign <> '' and w.campaign not in ('(not set)','(direct)','(organic)','(referral)','(cross-network)')
  and not exists (select 1 from campaign_name_match n where n.platform = m.platform and n.name_norm = sj_norm(w.campaign))
  and not exists (select 1 from campaign_class c where c.platform = m.platform and c.campaign_id = w.campaign)
group by 1,2,3,4,5;

alter view public.campaign_name_match set (security_invoker = on);
alter view mart_campaign_funnel_daily set (security_invoker = on);
alter view mart_web_campaign_unmatched set (security_invoker = on);
revoke all on public.campaign_name_match from anon;
grant select on public.campaign_name_match to authenticated, service_role;
revoke all on mart_campaign_funnel_daily, mart_web_campaign_unmatched from anon;
grant select on mart_campaign_funnel_daily, mart_web_campaign_unmatched to authenticated;

-- 5) Kézi alias-ok az audit alapján (a nyers GA4-név a ténylegesen futó hirdetési kampányra mutat). Szerkeszthető, törölhető.
insert into public.campaign_utm_alias (platform, alias_norm, campaign_id, note) values
  ('meta',   'lassjol - rle',                           '120243705267400714', 'LASSJOL - RLE - Traffic: rövidített UTM-név (~1 060 munkamenet / 90 nap)'),
  ('meta',   'lassjol - smile - awr',                   '120247468553290714', 'LASSJOL - SMILE - AWR - REACH: rövidített UTM-név, a futási időszak egyezik (júl. 21 – aug. 7.)'),
  ('meta',   'lassjol - rle laser new videos - traffic','120242733596670714', 'LASSJOL - RLE + LASER NEW Videos - Traffic: a "+" jel nélkül'),
  ('google', 'brand',                                   '21797908973',        'GSN - Brand /konvmax: kézzel írt UTM (~21 munkamenet)')
on conflict (platform, alias_norm) do nothing;

-- 6) Besorolási szabályok a besorolatlan kampányokra (a meglévő szabályok előbb illeszkednek, ezek csak a maradékot fogják).
-- Egy szabály csak egyszer jön létre (jegyzet-kulcs alapján), az újrafuttatás nem duplikál.
insert into public.campaign_mapping_rule (priority, platform, name_pattern, only_business_line, business_line, category, subcategory, note)
select v.priority, v.platform, v.name_pattern, v.only_bl, v.business_line, v.category, v.subcategory, v.note
from (values
  (15, 'tiktok', 'Olvasoszemuveg%',   null::text, 'szemeszet', null::text, null::text, '0034: Olvasószemüveg (TikTok) → szemészet'),
  (44, null,     '%Olvasoszemuveg%',  'szemeszet', null,       'General',  'Olvasószemüveg', '0034: szemészet / Olvasószemüveg'),
  (45, null,     '%Conversion%',      'szemeszet', null,       'General',  'Konverzió', '0034: szemészet / Konverzió (CONVERSION)'),
  (46, null,     '% CV %',            'szemeszet', null,       'General',  'Konverzió', '0034: szemészet / Konverzió (CV)'),
  (61, null,     '%Conversion%',      'eszteika_plasztika', null, 'Esztétika / plasztika', 'Konverzió', '0034: esztétika / Konverzió (CONVERSION)'),
  (62, null,     '% CV %',            'eszteika_plasztika', null, 'Esztétika / plasztika', 'Konverzió', '0034: esztétika / Konverzió (CV)')
) as v(priority, platform, name_pattern, only_bl, business_line, category, subcategory, note)
where not exists (select 1 from public.campaign_mapping_rule r where r.note = v.note);
