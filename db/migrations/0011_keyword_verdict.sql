-- 0011: kulcsszó-teljesítmény kategória/alkategória szűrővel és "megéri-e folytatni?" értékeléssel + historikus (heti) idősor a tooltiphez.
-- Az értékelés szabályalapú és átlátszó; a kevés adatot nem ítéli meg (a nulla konverzió is lehet szerencse):
--   várható konverzió = kattintás × az üzletág keresési kampányainak átlagos konverziós rátája;
--   ha ez kevesebb, mint a küszöb (verdict_min_expected), akkor "kevés adat";
--   0 konverziónál az "átlagos ráta mellett ennyi kattintásból 0 konverzió" esélye exp(-várható): ha ez a küszöb alatt van
--   és a költés elég nagy, akkor "állítsd le".

insert into insight_threshold (key, value, note) values
  ('verdict_min_expected', 2.0, 'kulcsszó-értékelés: ennyi várható konverzió alatt "kevés adat"'),
  ('verdict_zero_p', 0.05, 'kulcsszó-értékelés: 0 konverzió ennyi esély alatt (átlagos ráta mellett) = "állítsd le"'),
  ('verdict_min_spend', 3000, 'kulcsszó-értékelés: ennyi költés (Ft) alatt nem javasol leállítást'),
  ('verdict_cpa_good', 1.0, 'kulcsszó-értékelés: költség/konverzió az átlag ennyi szorosa vagy kevesebb = "folytasd"'),
  ('verdict_cpa_bad', 1.75, 'kulcsszó-értékelés: költség/konverzió az átlag ennyi szorosa vagy több = "csökkentsd"'),
  ('verdict_min_conv', 2, 'kulcsszó-értékelés: "folytasd" legalább ennyi konverziótól')
on conflict do nothing;

create or replace function keyword_performance(
  p_from date, p_to date, p_prev_from date default null, p_prev_to date default null,
  p_business_line text default null, p_category text default null, p_subcategory text default null,
  p_topic text default null, p_search text default null, p_min_spend numeric default 0,
  p_limit int default 200, p_offset int default 0
) returns table (
  keyword_text text, topic text, category text, subcategory text, campaigns int,
  spend numeric, impressions bigint, clicks bigint, conversions numeric,
  ctr numeric, cpc numeric, cost_per_conversion numeric, conv_rate numeric,
  spend_prev numeric, clicks_prev bigint, conversions_prev numeric,
  verdict text, verdict_reason text, expected_conversions numeric, baseline_conv_rate numeric, baseline_cpa numeric,
  total_count bigint
) language sql stable as $$
  with base as (
    -- az üzletág összes keresési kulcsszavának átlaga az időszakban (a szűrőktől független alap)
    select sum(k.conversions) / nullif(sum(k.clicks), 0) as rate, sum(k.spend) / nullif(sum(k.conversions), 0) as cpa
    from mart_keyword_daily k
    where k.date between p_from and p_to and (p_business_line is null or k.business_line = p_business_line)
  ), cur as (
    select k.keyword_text, max(k.topic) as topic, max(k.category) as category, max(k.subcategory) as subcategory,
           count(distinct k.campaign_id)::int as campaigns, sum(k.spend) as spend, sum(k.impressions)::bigint as impressions,
           sum(k.clicks)::bigint as clicks, sum(k.conversions) as conversions
    from mart_keyword_daily k
    where k.date between p_from and p_to
      and (p_business_line is null or k.business_line = p_business_line)
      and (p_category is null or k.category = p_category)
      and (p_subcategory is null or k.subcategory = p_subcategory)
      and (p_topic is null or k.topic = p_topic)
      and (p_search is null or sj_norm(k.keyword_text) like '%' || sj_norm(p_search) || '%')
    group by k.keyword_text
  ), prev as (
    select k.keyword_text, sum(k.spend) as spend, sum(k.clicks)::bigint as clicks, sum(k.conversions) as conversions
    from mart_keyword_daily k
    where p_prev_from is not null and k.date between p_prev_from and p_prev_to
      and (p_business_line is null or k.business_line = p_business_line)
      and (p_category is null or k.category = p_category)
      and (p_subcategory is null or k.subcategory = p_subcategory)
    group by k.keyword_text
  ), v as (
    select c.*, b.rate, b.cpa, c.clicks * coalesce(b.rate, 0) as expected,
           c.spend / nullif(c.conversions, 0) as cpconv
    from cur c cross join base b
  )
  select v.keyword_text, v.topic, v.category, v.subcategory, v.campaigns,
         round(v.spend, 2), v.impressions, v.clicks, round(v.conversions, 2),
         round(v.clicks::numeric / nullif(v.impressions, 0), 5), round(v.spend / nullif(v.clicks, 0), 2),
         round(v.cpconv, 2), round(v.conversions / nullif(v.clicks, 0), 5),
         round(p.spend, 2), p.clicks, round(p.conversions, 2),
         case
           when v.clicks = 0 then 'keves_adat'
           when v.conversions = 0 and v.expected < thr('verdict_min_expected') then 'keves_adat'
           when v.conversions = 0 and exp(-v.expected) < thr('verdict_zero_p') and v.spend >= thr('verdict_min_spend') then 'allitsd_le'
           when v.conversions = 0 then 'figyeld'
           when v.conversions >= thr('verdict_min_conv') and v.cpa is not null and v.cpconv <= v.cpa * thr('verdict_cpa_good') then 'folytasd'
           when v.cpa is not null and v.cpconv >= v.cpa * thr('verdict_cpa_bad') and v.conversions >= 1 then 'csokkentsd'
           else 'figyeld'
         end,
         case
           when v.clicks = 0 then 'Nincs kattintás az időszakban.'
           when v.conversions = 0 and v.expected < thr('verdict_min_expected') then
             format('%s kattintásból az átlagos konverziós ráta mellett csak ~%s konverzió várható, ebből még nem dönthető el, hogy a 0 valódi gyengeség vagy szerencse.', v.clicks, round(v.expected, 1))
           when v.conversions = 0 and exp(-v.expected) < thr('verdict_zero_p') and v.spend >= thr('verdict_min_spend') then
             format('%s kattintás, 0 konverzió. Az átlagos ráta mellett ~%s konverzió lenne várható; ennek a nullának az esélye csak %s%%.', v.clicks, round(v.expected, 1), round(exp(-v.expected) * 100, 1))
           when v.conversions = 0 then
             format('%s kattintás, 0 konverzió, de a minta még nem elég erős a leállításhoz (várható: ~%s).', v.clicks, round(v.expected, 1))
           when v.conversions >= thr('verdict_min_conv') and v.cpa is not null and v.cpconv <= v.cpa * thr('verdict_cpa_good') then
             format('Költség/konverzió %s Ft, az átlag %s Ft; %s konverzióval.', round(v.cpconv), round(v.cpa), round(v.conversions, 1))
           when v.cpa is not null and v.cpconv >= v.cpa * thr('verdict_cpa_bad') then
             format('Költség/konverzió %s Ft, az átlag %s Ft: drágábban konvertál az átlagnál.', round(v.cpconv), round(v.cpa))
           else format('Költség/konverzió %s Ft (átlag: %s Ft), %s konverzió: még korai vagy átlagos.', round(v.cpconv), round(v.cpa), round(v.conversions, 1))
         end,
         round(v.expected, 2), round(v.rate, 5), round(v.cpa, 2),
         count(*) over ()
  from v left join prev p on p.keyword_text = v.keyword_text
  where v.spend >= p_min_spend
  order by v.spend desc, v.keyword_text
  limit p_limit offset p_offset
$$;

-- Historikus idősor egy kulcsszóra (a tooltiphez és a részletező panelhez): napi vagy heti vödrökben.
create or replace function keyword_history(p_keyword text, p_from date, p_to date, p_bucket text default 'week')
returns table (period_start date, spend numeric, impressions bigint, clicks bigint, conversions numeric, cpc numeric, ctr numeric, days_with_data int)
language sql stable as $$
  select date_trunc(case when p_bucket = 'day' then 'day' else 'week' end, k.date)::date as ps,
         round(sum(k.spend), 2), sum(k.impressions)::bigint, sum(k.clicks)::bigint, round(sum(k.conversions), 2),
         round(sum(k.spend) / nullif(sum(k.clicks), 0), 2), round(sum(k.clicks)::numeric / nullif(sum(k.impressions), 0), 5),
         count(distinct k.date)::int
  from mart_keyword_daily k
  where k.keyword_text = p_keyword and k.date between p_from and p_to
  group by 1 order by 1
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'keyword_performance(date,date,date,date,text,text,text,text,text,numeric,int,int)', 'keyword_history(text,date,date,text)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
exception when undefined_object then null;
end $$;
