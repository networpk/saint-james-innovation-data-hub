-- Weboldali konverziók csatornánként (GA4-események), a Kampányok oldal "többi forrás" soraihoz azoknál az üzletágaknál, ahol a foglalás
-- még nem az időpontfoglaló alkalmazáson megy át (esztétika/plasztika: a sikeres foglalás ma a GA4 `sikeres_foglalas` eseményből látszik).
-- A szemészetnél a lead_channel_summary (0033, az időpontfoglaló leadjei) marad a forrás; az esztétikánál ez a függvény, majd az
-- online foglaló indulása után a lead_channel_summary is működik, és a felület átválthat arra.
-- Csak darabszámot ad vissza (a megtekintő szerep is látja a Kampányok oldalt). Csak a Lovable Cloud adatbázisra való (0027 után).
--
-- Csatorna a GA4 forrás/médium alapján: fizetett (cpc/paid/…), organikus keresés, organikus közösségi, e-mail, AI-asszisztens,
-- saját oldal/foglaló (saintjameshungary.hu, lassjol.hu, stjameshospital.hu, salonic.hu), egyéb hivatkozó, direkt, és "ismeretlen"
-- (a GA4 nem tudta hozzárendelni: "(not set)", "(data not available)") – az ismeretlen NEM bizonyítottan direkt.

create or replace function public.web_conversion_channels(p_from date, p_to date, p_business_line text default null)
returns table (channel text, channel_label text, booking_success integer, booking_click integer, form_start integer, source_known boolean)
language sql stable security definer set search_path = public as $$
  with ev as (
    select lower(coalesce(e.source, '')) as src, lower(coalesce(e.medium, '')) as med, e.event_count, fm.stage
    from fact_web_event_daily e
    join funnel_event_map fm on fm.event_name = e.event_name and fm.stage in ('booking_success', 'booking_click', 'form_start')
    left join ga_property_map m on m.account_id = e.account_id
    where public.is_member(auth.uid())
      and e.date between p_from and p_to
      and (p_business_line is null or p_business_line in ('mind', 'besorolatlan') or m.business_line = p_business_line)
  ), cls as (
    select ev.*,
      case
        when med in ('cpc', 'ppc', 'paid', 'paid_social', 'paid-social', 'paidsocial', 'paid_search', 'display', 'cpm') then 'paid'
        when med = 'organic' then 'organic_search'
        when med in ('email', 'e-mail', 'newsletter') then 'email'
        when med like 'ai-%' or med = 'ai_assistant' then 'ai_assistant'
        when med in ('social', 'social-network', 'social_media', 'social-media')
             or (med = 'referral' and src ~ '(^|\.)(facebook\.com|fb\.com|instagram\.com|linkedin\.com|tiktok\.com|youtube\.com|t\.co|x\.com|twitter\.com|pinterest\.com)$') then 'organic_social'
        when src ~ '(^|\.)(saintjameshungary\.hu|lassjol\.hu|stjameshospital\.hu|salonic\.hu)$' then 'own_site'
        when med = 'referral' then 'referral'
        when src = '(direct)' or med = '(none)' then 'direct'
        when src in ('(not set)', '(data not available)', '') or med in ('(not set)', '(data not available)', '') then 'unknown'
        else 'other'
      end as ch
    from ev
  )
  select ch,
         case ch
           when 'paid' then 'Fizetett (kampányokhoz rendelve)'
           when 'organic_search' then 'Organikus keresés'
           when 'organic_social' then 'Organikus közösségi'
           when 'email' then 'E-mail'
           when 'ai_assistant' then 'AI-asszisztens'
           when 'own_site' then 'Saját oldal / foglaló'
           when 'referral' then 'Egyéb hivatkozó'
           when 'direct' then 'Direkt'
           when 'unknown' then 'Ismeretlen (GA4 nem rendelte hozzá)'
           else 'Egyéb'
         end,
         coalesce(sum(event_count) filter (where stage = 'booking_success'), 0)::int,
         coalesce(sum(event_count) filter (where stage = 'booking_click'), 0)::int,
         coalesce(sum(event_count) filter (where stage = 'form_start'), 0)::int,
         (ch <> 'unknown')
  from cls
  group by ch
  order by coalesce(sum(event_count) filter (where stage = 'booking_success'), 0) desc, ch
$$;
revoke execute on function public.web_conversion_channels(date, date, text) from public, anon;
grant execute on function public.web_conversion_channels(date, date, text) to authenticated, service_role;
