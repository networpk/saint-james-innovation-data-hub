-- Lead-csatornák: a beküldött időpontfoglalás-leadek besorolása fizetett / organikus / direkt csatornára, a Kampányok oldal számára.
-- A besorolás a rögzített forrásadatból jön: kattintási azonosító és UTM (fizetett), különben az első érintés hivatkozója (referrer).
-- Fontos: ahol nincs rögzített forrásadat, ott a lead „Direkt / ismeretlen" (nem bizonyítottan direkt). A hivatkozó-rögzítés 2026 szeptember végén indult.
-- Lead-szintű adat nem kerül ki: az összesítő függvény csak darabszámot ad vissza (a megtekintő szerep is látja a Kampányok oldalt).

create or replace view lead_channel with (security_invoker = true) as
select j.lead_id, j.created_at, j.day, j.business_line, j.person_key, (j.outcome = 'foglalt') as booked,
       c.channel,
       case c.channel
         when 'paid' then 'Fizetett'
         when 'paid_unattributed' then 'Fizetett (azonosítatlan)'
         when 'organic_search' then 'Organikus keresés'
         when 'organic_social' then 'Organikus közösségi'
         when 'own_site' then 'Saját weboldal'
         when 'referral' then 'Egyéb hivatkozó'
         else 'Direkt / ismeretlen'
       end as channel_label,
       c.referrer_host,
       (c.channel not in ('direct')) as source_known
from lead_journey j
join fact_lead l on l.lead_id = j.lead_id
cross join lateral (
  select
    lower(regexp_replace(substring(coalesce(nullif(l.first_touch ->> 'referrer', ''), nullif(l.referrer, '')) from '^(?:[a-z]+://)?([^/:?#]+)'), '^www\.', '')) as referrer_host
) h
cross join lateral (
  select case
    when coalesce(l.click_ids, '{}'::jsonb) <> '{}'::jsonb
         or lower(coalesce(j.utm_medium, '')) in ('cpc', 'paid', 'ppc', 'paid_social', 'paid-social', 'display') then 'paid'
    when h.referrer_host ~ '(^|\.)(doubleclick\.net|googlesyndication\.com|googleadservices\.com)$' then 'paid_unattributed'
    when h.referrer_host ~ '(^|\.)(google|bing|duckduckgo|yahoo|ecosia|startpage)\.' then 'organic_search'
    when h.referrer_host ~ '(^|\.)(facebook\.com|fb\.com|instagram\.com|linkedin\.com|tiktok\.com|youtube\.com|t\.co|x\.com|twitter\.com|pinterest\.com)$' then 'organic_social'
    when h.referrer_host ~ '(^|\.)(saintjameshungary\.hu|lassjol\.hu|stjameshospital\.hu)$' then 'own_site'
    when h.referrer_host is not null and h.referrer_host <> '' then 'referral'
    else 'direct' end as channel,
    h.referrer_host as referrer_host
) c
where j.lead_type = 'idopontfoglalas' and j.submitted is true;

-- Csatornánkénti összesítő a Kampányok oldalnak (beküldött időpontfoglalás-leadek; a megtekintő is látja, csak darabszám).
create or replace function public.lead_channel_summary(p_from date, p_to date, p_business_line text default null)
returns table (channel text, channel_label text, leads integer, people integer, booked integer, source_known boolean)
language sql stable security definer set search_path = public as $$
  select c.channel, c.channel_label, count(*)::int, count(distinct c.person_key)::int,
         (count(*) filter (where c.booked))::int, bool_and(c.source_known)
  from public.lead_channel c
  where public.is_member(auth.uid())
    and c.day between p_from and p_to
    and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or c.business_line = p_business_line)
  group by c.channel, c.channel_label
  order by count(*) desc
$$;
revoke execute on function public.lead_channel_summary(date, date, text) from public, anon;
grant execute on function public.lead_channel_summary(date, date, text) to authenticated, service_role;
revoke all on lead_channel from anon;
grant select on lead_channel to authenticated;
