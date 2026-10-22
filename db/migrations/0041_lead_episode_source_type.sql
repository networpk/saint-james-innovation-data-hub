-- Lead-epizódok forrástípus szerinti bontása (Kampányok „Mindösszesen”): időpontfoglaló / kézi import / weboldal.
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0040 (lead_episode) után fut. Nem módosít és nem töröl adatot: a lead_episode nézet
-- egy új, utolsó oszlopot (source_type) kap, a meglévő oszlopok és függvények változatlanok; egy új összesítő függvény jön létre.
--
-- Forrástípus (fact_lead.source alapján): booking -> 'booking' (időpontfoglaló app), manual_import -> 'manual' (kézi import),
-- elementor -> 'website' (weboldal űrlap), minden más -> 'other'. Az epizód forrástípusa az epizód ELSŐ rekordjáé, így a három típus
-- összege pontosan a Mindösszesen epizódszám (nincs átfedés). Az alkalmassági (quiz) leadek a lead_channel miatt eleve nincsenek benne.
-- Lead-szintű adat nem kerül ki: az összesítő csak darabszámot ad (a megtekintő is látja).

create or replace view public.lead_episode as
with recursive base as (
  select c.lead_id, c.created_at, c.day, c.business_line, c.person_key, c.booked, c.channel, c.channel_label, c.source_known,
         f.source as src,
         coalesce(c.person_key, 'row:' || c.lead_id::text) as pk,
         row_number() over (partition by coalesce(c.person_key, 'row:' || c.lead_id::text), c.business_line order by c.created_at, c.lead_id) as rn
  from public.lead_channel c
  left join public.fact_lead f on f.lead_id = c.lead_id
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
       (array_agg(w.source_known order by (not w.source_known), w.created_at, w.lead_id))[1] as source_known,
       case (array_agg(w.src order by w.created_at, w.lead_id))[1]
         when 'booking' then 'booking'
         when 'manual_import' then 'manual'
         when 'elementor' then 'website'
         else 'other'
       end as source_type
from walk w
group by w.pk, w.business_line, w.ep_no;

-- A nézet személy-szintű (person_key), ezért csak a függvények (security definer) és a service_role olvassa.
revoke all on public.lead_episode from public, anon, authenticated;
grant select on public.lead_episode to service_role;

-- Forrástípusonkénti összesítő: epizódok (egyedi leadek), nyers rekordok, személyek, foglalt epizódok. Rendezés: időpontfoglaló, weboldal, kézi, egyéb.
create or replace function public.lead_source_episode_summary(p_from date, p_to date, p_business_line text default null)
returns table (source_type text, episodes integer, raw_leads integer, people integer, booked integer)
language sql stable security definer set search_path = public as $$
  select e.source_type, count(*)::int, sum(e.rows_in_episode)::int, count(distinct e.person_key)::int, (count(*) filter (where e.booked))::int
  from public.lead_episode e
  where public.is_member(auth.uid())
    and e.day between p_from and p_to
    and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or e.business_line = p_business_line)
  group by e.source_type
  order by case e.source_type when 'booking' then 1 when 'website' then 2 when 'manual' then 3 else 4 end
$$;
revoke execute on function public.lead_source_episode_summary(date, date, text) from public, anon;
grant execute on function public.lead_source_episode_summary(date, date, text) to authenticated, service_role;
