-- Lead-epizódok: ugyanaz a személy ugyanazon üzletágban az epizód első rekordjától számított 24 órán belül EGY lead.
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0033 (lead_channel) után fut. Nem módosít és nem töröl semmilyen meglévő adatot vagy nézetet:
-- a lead_channel és a lead_channel_summary változatlan marad (nyers rekordszámok), az új nézet és az új függvények mellette élnek.
--
-- Miért: a foglaló app ugyanahhoz a látogatáshoz több lead-sort hozott létre (a „Küldés" után lezárt sor mellé újat, ha elveszett a leadId),
-- ezért a Kampányok „Grand total / Hub lead" a nyers rekordokat számolta (600 rekord, 480 személy a vizsgált időszakban).
-- Szabály: az epizód az első rekordnál indul; az azt követő, 24 órán belüli rekordok ugyanahhoz az epizódhoz tartoznak; az első 24 órán túli rekord
-- új epizódot indít (rögzített, nem láncolt ablak). A kulcs: személy (e-mail-hash, annak hiányában telefon-hash) + üzletág; személykulcs nélkül minden rekord külön epizód.
-- Az epizód kimenete: foglalt, ha bármelyik rekordja foglalt; a csatornája az epizód első ISMERT forrású rekordjáé (különben az elsőé), így egy epizód egy csatornához tartozik.
-- Lead-szintű adat nem kerül ki: a nézet nem olvasható a felületi szerepköröknek, az összesítő függvények csak darabszámot adnak (a megtekintő is látja).

-- 1) Epizódok. Rekurzív séta személyenként és üzletáganként, mert a rögzített 24 órás ablak nem fejezhető ki egyszerű ablakfüggvénnyel.
create or replace view public.lead_episode as
with recursive base as (
  select c.lead_id, c.created_at, c.day, c.business_line, c.person_key, c.booked, c.channel, c.channel_label, c.source_known,
         coalesce(c.person_key, 'row:' || c.lead_id::text) as pk,
         row_number() over (partition by coalesce(c.person_key, 'row:' || c.lead_id::text), c.business_line order by c.created_at, c.lead_id) as rn
  from public.lead_channel c
), walk as (
  select b.*, b.created_at as ep_start, 1 as ep_no
  from base b where b.rn = 1
  union all
  select b.*,
         case when b.created_at < w.ep_start + interval '24 hours' then w.ep_start else b.created_at end,
         case when b.created_at < w.ep_start + interval '24 hours' then w.ep_no else w.ep_no + 1 end
  from walk w
  join base b on b.pk = w.pk and b.business_line is not distinct from w.business_line and b.rn = w.rn + 1
)
select (array_agg(w.lead_id order by w.created_at, w.lead_id))[1] as first_lead_id,
       min(w.created_at) as first_at,
       (array_agg(w.day order by w.created_at, w.lead_id))[1] as day,
       w.business_line,
       (array_agg(w.person_key order by w.created_at, w.lead_id))[1] as person_key,
       bool_or(w.booked) as booked,
       count(*)::int as rows_in_episode,
       (array_agg(w.channel order by (not w.source_known), w.created_at, w.lead_id))[1] as channel,
       (array_agg(w.channel_label order by (not w.source_known), w.created_at, w.lead_id))[1] as channel_label,
       (array_agg(w.source_known order by (not w.source_known), w.created_at, w.lead_id))[1] as source_known
from walk w
group by w.pk, w.business_line, w.ep_no;

-- A nézet személy-szintű (person_key), ezért csak a függvények (security definer) és a service_role olvassa.
revoke all on public.lead_episode from public, anon, authenticated;
grant select on public.lead_episode to service_role;

-- 2) Csatornánkénti összesítő: epizódok (egyedi leadek), nyers rekordok, személyek, foglalt epizódok.
create or replace function public.lead_channel_episode_summary(p_from date, p_to date, p_business_line text default null)
returns table (channel text, channel_label text, episodes integer, raw_leads integer, people integer, booked integer, source_known boolean)
language sql stable security definer set search_path = public as $$
  select e.channel, e.channel_label, count(*)::int, sum(e.rows_in_episode)::int, count(distinct e.person_key)::int,
         (count(*) filter (where e.booked))::int, bool_and(e.source_known)
  from public.lead_episode e
  where public.is_member(auth.uid())
    and e.day between p_from and p_to
    and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or e.business_line = p_business_line)
  group by e.channel, e.channel_label
  order by count(*) desc
$$;
revoke execute on function public.lead_channel_episode_summary(date, date, text) from public, anon;
grant execute on function public.lead_channel_episode_summary(date, date, text) to authenticated, service_role;

-- 3) Grand total: a csatornák felett EGYSZER számolt epizódok, rekordok és személyek (a csatornánkénti személyszámok összege nem egyedi).
create or replace function public.lead_episode_totals(p_from date, p_to date, p_business_line text default null)
returns table (episodes integer, raw_leads integer, people integer, booked integer)
language sql stable security definer set search_path = public as $$
  select count(*)::int, coalesce(sum(e.rows_in_episode), 0)::int, count(distinct e.person_key)::int, (count(*) filter (where e.booked))::int
  from public.lead_episode e
  where public.is_member(auth.uid())
    and e.day between p_from and p_to
    and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or e.business_line = p_business_line)
$$;
revoke execute on function public.lead_episode_totals(date, date, text) from public, anon;
grant execute on function public.lead_episode_totals(date, date, text) to authenticated, service_role;
