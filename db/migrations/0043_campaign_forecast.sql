-- Kereslet-minták és előrejelzés kampányonként: kampány-szintű napi tábla (Google Ads először, Meta/TikTok később ugyanebbe) és három függvény:
-- (1) forecast_patterns: napi (hét napja) és hónapon belüli heti minta kampányonként; (2) forecast_campaign: tényleges / várt / sáv a múltra és az előrejelzés a jövőre;
-- (3) forecast_alerts: a legutóbbi napok tartós eltérése a várttól (pl. a költségkeret hirtelen csökkentése).
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0027 (szerepkörök, is_member) után fut. Additív: meglévő tábla, nézet és függvény nem változik.
-- Nincs személyes adat: csak kampány-szintű összesítések.
--
-- Módszer (egyszerű, átlátható, a függvények a szabályt lépésenként követik):
--  * Mutató: 'demand' = megjelenés / keresési megjelenési részesedés (csak SEARCH kampányoknál, ha a részesedés legalább 10%); 'impressions' | 'clicks' | 'spend' | 'conversions';
--    'auto' = SEARCH kampányoknál 'demand', minden másnál (Performance Max stb.) 'impressions' (ott a megjelenés nem csak keresés, és a keret is alakítja).
--  * Minta: minden napot a körülötte lévő 29 nap (±14 nap) átlagához viszonyítunk (legalább 15 adatnap kell az ablakban), így a szintváltások (keret, licit, indítás) nem torzítanak.
--    Hét napja: az arányok átlaga (t-érték a hetek között). Hónapon belüli hét: 1–7., 8–14., 15–21., 22–28. nap; hónaponként átlag (legalább 4 adatnap), a hónapok átlaga és t-értéke.
--  * Előrejelzés: várt = szint × a hét napjának indexe. Szint = az előző 28 nap értéke osztva az azokra a napokra eső indexek összegével (az utolsó adatnaptól a jövőre állandó).
--    Az index az utolsó 365 nap arányaiból készül, hét napjára átlagolva és 1-re normálva. Sáv: a múltbeli tény/várt arányok 10. és 90. percentilise (utolsó 180 nap).
--  * Figyelmeztetés: a legutóbbi napok tény/várt aránya a sávon kívül van, és tartósan (legalább 3 napon) eltér.

-- 1) Kampány-szintű napi tábla. A betöltés (ingest-campaign-daily) tölti Windsor google_ads kampány-szintű napi adatából; a napi újratöltés az utolsó napokat felülírja (upsert).
create table if not exists public.fact_campaign_daily (
  date date not null,
  platform text not null,
  account_id text not null,
  campaign_id text not null,
  campaign_name text,
  channel_type text,
  spend numeric(14,2) not null default 0,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  conversions numeric(12,2) not null default 0,
  search_impression_share numeric(6,4),
  budget_lost_share numeric(6,4),
  rank_lost_share numeric(6,4),
  loaded_at timestamptz not null default now(),
  primary key (date, platform, account_id, campaign_id)
);
create index if not exists idx_fcd_campaign on public.fact_campaign_daily (platform, campaign_id, date);

-- GRANT/REVOKE az RLS bekapcsolása előtt (Lovable-szabály).
revoke all on public.fact_campaign_daily from public, anon;
grant select on public.fact_campaign_daily to authenticated;
grant all on public.fact_campaign_daily to service_role;
alter table public.fact_campaign_daily enable row level security;
drop policy if exists fact_campaign_daily_member_read on public.fact_campaign_daily;
create policy fact_campaign_daily_member_read on public.fact_campaign_daily for select to authenticated
  using (public.is_member(auth.uid()));

-- 2) Segéd: a kampány napi mutatója (a mutató feloldásával); csak tagok kapnak sort.
create or replace function public.forecast_series(p_platform text, p_campaign_id text, p_metric text default 'auto')
returns table (date date, campaign_name text, metric text, v numeric, budget_lost_share numeric, search_impression_share numeric)
language sql stable security definer set search_path = public as $$
  with c as (
    select coalesce(max(channel_type), '') as ch from public.fact_campaign_daily
    where platform = p_platform and campaign_id = p_campaign_id
  ), m as (
    select case when p_metric = 'auto' then (case when (select ch from c) = 'SEARCH' then 'demand' else 'impressions' end) else p_metric end as metric
  )
  select f.date, f.campaign_name, (select metric from m),
         case (select metric from m)
           when 'demand' then case when f.search_impression_share >= 0.10 and f.impressions > 0 then f.impressions / f.search_impression_share end
           when 'impressions' then case when f.impressions > 0 then f.impressions::numeric end
           when 'clicks' then case when f.impressions > 0 then f.clicks::numeric end
           when 'spend' then case when f.impressions > 0 then f.spend end
           when 'conversions' then case when f.impressions > 0 then f.conversions end
         end,
         f.budget_lost_share, f.search_impression_share
  from public.fact_campaign_daily f
  where f.platform = p_platform and f.campaign_id = p_campaign_id
    and f.date < (now() at time zone 'Europe/Budapest')::date   -- a mai nap még nem teljes: a sorozatba nem kerül be
    and public.is_member(auth.uid())
$$;
revoke execute on function public.forecast_series(text, text, text) from public, anon;
grant execute on function public.forecast_series(text, text, text) to authenticated, service_role;

-- 3) Minták kampányonként. kind: 'dow' (bucket 1 = hétfő … 7 = vasárnap) | 'wom' (bucket 1 = 1–7. nap … 4 = 22–28. nap).
-- idx: 1,00 = a kampány szokásos szintje; t: a minta megbízhatósága (|t| >= 3 a napi, >= 2 a heti mintánál erős); n: hetek (dow) / hónapok (wom) száma.
create or replace function public.forecast_patterns(
  p_platform text default 'google', p_from date default (current_date - 365), p_to date default current_date,
  p_metric text default 'auto', p_min_days integer default 120)
returns table (campaign_id text, campaign_name text, metric text, active_days integer, avg_per_day numeric, kind text, bucket integer, idx numeric, t numeric, n integer)
language sql stable security definer set search_path = public as $$
  with camps as (
    select f.campaign_id, max(f.campaign_name) as name, count(*) filter (where f.impressions > 0)::int as days
    from public.fact_campaign_daily f
    where public.is_member(auth.uid()) and f.platform = p_platform and f.date between p_from and p_to
    group by f.campaign_id
    having count(*) filter (where f.impressions > 0) >= p_min_days
  ), s as (
    select c.campaign_id, c.name, c.days, x.date, x.metric, x.v
    from camps c, lateral public.forecast_series(p_platform, c.campaign_id, p_metric) x
    where x.v is not null
  ), ma as (
    select s.*,
           avg(s.v) over w as m, count(*) over w as cnt
    from s
    window w as (partition by s.campaign_id order by s.date range between interval '14 days' preceding and interval '14 days' following)
  ), r as (
    select campaign_id, name, days, metric, date, v / m as ratio, v
    from ma where cnt >= 15 and m > 0 and date between p_from and p_to
  ), avgs as (
    select campaign_id, avg(v) as avg_v from r group by campaign_id
  ), dow as (
    select campaign_id, name, days, metric, 'dow'::text as kind, extract(isodow from date)::int as bucket,
           avg(ratio) as idx, case when stddev_pop(ratio) > 0 then (avg(ratio) - 1) / (stddev_pop(ratio) / sqrt(count(*))) else 0 end as t, count(*)::int as n
    from r group by campaign_id, name, days, metric, extract(isodow from date)
  ), wom_m as (
    select campaign_id, name, days, metric, extract(year from date)::int as y, extract(month from date)::int as mo,
           least((extract(day from date)::int - 1) / 7 + 1, 5) as bucket, avg(ratio) as mean_ratio, count(*) as nd
    from r group by campaign_id, name, days, metric, extract(year from date), extract(month from date), least((extract(day from date)::int - 1) / 7 + 1, 5)
  ), wom as (
    select campaign_id, name, days, metric, 'wom'::text as kind, bucket,
           avg(mean_ratio) as idx, case when stddev_pop(mean_ratio) > 0 then (avg(mean_ratio) - 1) / (stddev_pop(mean_ratio) / sqrt(count(*))) else 0 end as t, count(*)::int as n
    from wom_m where nd >= 4 and bucket <= 4
    group by campaign_id, name, days, metric, bucket
    having count(*) >= 4
  ), allp as (
    select * from dow union all select * from wom
  )
  select a.campaign_id, a.name, a.metric, a.days, round(v.avg_v, 1), a.kind, a.bucket, round(a.idx, 3), round((a.t)::numeric, 2), a.n
  from allp a join avgs v using (campaign_id)
  where public.is_member(auth.uid())
  order by a.name, a.campaign_id, a.kind, a.bucket
$$;
revoke execute on function public.forecast_patterns(text, date, date, text, integer) from public, anon;
grant execute on function public.forecast_patterns(text, date, date, text, integer) to authenticated, service_role;

-- 4) Előrejelzés egy kampányra. kind: 'history' (az utolsó p_history nap: a tény és az egy nappal korábbi szintből számolt várt érték) | 'forecast' (a következő p_horizon nap).
-- flag: 'alacsony' | 'magas' | NULL (csak a history soraiban: a tény a sávon kívül van). budget_lost_share / impression_share: a nap környezete (csak history).
create or replace function public.forecast_campaign(
  p_platform text, p_campaign_id text, p_metric text default 'auto', p_horizon integer default 28, p_history integer default 90)
returns table (date date, kind text, metric text, actual numeric, expected numeric, lo numeric, hi numeric, flag text, budget_lost_share numeric, impression_share numeric)
language sql stable security definer set search_path = public as $$
  with raw as (
    select * from public.forecast_series(p_platform, p_campaign_id, p_metric)
  ), meta as (
    select max(date) as last_day, max(metric) as metric from raw where v is not null
  ), base as (
    select raw.date, raw.v, raw.budget_lost_share, raw.search_impression_share from raw where raw.v is not null
  ), ma as (
    select b.*, avg(b.v) over w as m, count(*) over w as cnt
    from base b
    window w as (order by b.date range between interval '14 days' preceding and interval '14 days' following)
  ), idx_raw as (
    select extract(isodow from date)::int as dow, avg(v / m) as i
    from ma
    where cnt >= 15 and m > 0 and date > (select last_day from meta) - 365
    group by 1
  ), idx as (
    select dow, i / nullif(avg(i) over (), 0) as i from idx_raw
  ), days as (
    -- múltbeli napok + jövőbeli napok (a jövőben v = NULL)
    select b.date, b.v, b.budget_lost_share, b.search_impression_share, false as fut from base b
    union all
    select g::date, null, null, null, true
    from meta, generate_series(meta.last_day + 1, meta.last_day + greatest(p_horizon, 0), interval '1 day') g
    where meta.last_day is not null
  ), lv as (
    select d.*, coalesce(i.i, 1) as idx,
           sum(d.v) over w as num,
           sum(case when d.v is not null then coalesce(i.i, 1) end) over w as den
    from days d left join idx i on i.dow = extract(isodow from d.date)::int
    window w as (order by d.date range between interval '28 days' preceding and interval '1 day' preceding)
  ), lvl as (
    select lv.*, num / nullif(den, 0) as level from lv
  ), futlv as (
    -- jövőre az első jövőbeli nap szintje (az utolsó 28 adatnap) marad érvényben
    select level from lvl where fut order by date limit 1
  ), ex as (
    select date, v, fut, budget_lost_share, search_impression_share,
           case when fut then (select level from futlv) else level end * idx as expected
    from lvl
  ), resid as (
    select percentile_cont(0.10) within group (order by v / expected) as q10,
           percentile_cont(0.90) within group (order by v / expected) as q90
    from ex, meta
    where not fut and v is not null and expected > 0 and date > meta.last_day - 180
  )
  select e.date, case when e.fut then 'forecast' else 'history' end, (select metric from meta),
         e.v, round(e.expected, 2), round((e.expected * r.q10)::numeric, 2), round((e.expected * r.q90)::numeric, 2),
         case when e.fut or e.v is null or e.expected is null then null
              when e.v::float8 < e.expected::float8 * r.q10 then 'alacsony'
              when e.v::float8 > e.expected::float8 * r.q90 then 'magas' end,
         e.budget_lost_share, e.search_impression_share
  from ex e, resid r, meta
  where public.is_member(auth.uid())
    and (e.fut or e.date > meta.last_day - greatest(p_history, 1))
  order by e.date
$$;
revoke execute on function public.forecast_campaign(text, text, text, integer, integer) from public, anon;
grant execute on function public.forecast_campaign(text, text, text, integer, integer) to authenticated, service_role;

-- 5) Figyelmeztetések: kampányonként és mutatónként az utolsó p_days nap tény / várt aránya. severity: 'figyelem' (legalább 3 napon a sávon kívül és az arány <0,75 vagy >1,33).
-- A mutatók: 'auto' (kereslet / megjelenés), 'clicks', 'spend'. A „kereslet” csökkenése a piac, a kattintás vagy a költség csökkenése a mi láthatóságunk (pl. keretcsökkentés).
create or replace function public.forecast_alerts(p_platform text default 'google', p_days integer default 7, p_min_avg numeric default 5)
returns table (campaign_id text, campaign_name text, metric text, days_flagged integer, actual_sum numeric, expected_sum numeric, ratio numeric, direction text,
               avg_budget_lost_share numeric, avg_impression_share numeric, severity text)
language sql stable security definer set search_path = public as $$
  with camps as (
    select f.campaign_id, max(f.campaign_name) as name
    from public.fact_campaign_daily f
    where public.is_member(auth.uid()) and f.platform = p_platform and f.impressions > 0
    group by f.campaign_id
    having max(f.date) >= (select max(date) from public.fact_campaign_daily where platform = p_platform) - 2
       and count(*) filter (where f.impressions > 0) >= 60
  ), res as (
    select c.campaign_id, c.name, mm.m as req, x.*
    from camps c
    cross join (values ('auto'), ('clicks'), ('spend')) as mm(m)
    cross join lateral public.forecast_campaign(p_platform, c.campaign_id, mm.m, 0, p_days) x
    where x.actual is not null and x.expected is not null
  ), agg as (
    select campaign_id, name, req, max(metric) as metric,
           (count(*) filter (where flag is not null))::int as flagged,
           (count(*) filter (where flag = 'alacsony'))::int as low_n, (count(*) filter (where flag = 'magas'))::int as high_n,
           sum(actual) as a, sum(expected) as e, avg(budget_lost_share) as bl, avg(impression_share) as isr, avg(expected) as avg_exp
    from res group by campaign_id, name, req
  )
  select campaign_id, name,
         case when req = 'auto' then metric else req end,
         flagged, round(a, 1), round(e, 1), round(a / nullif(e, 0), 2),
         case when a / nullif(e, 0) < 1 then 'csökkenés' else 'növekedés' end,
         round(bl, 3), round(isr, 3),
         case when flagged >= 3 and (a / nullif(e, 0) < 0.75 or a / nullif(e, 0) > 1.33) then 'figyelem' else 'rendben' end
  from agg
  where avg_exp >= p_min_avg
  order by (case when flagged >= 3 and (a / nullif(e, 0) < 0.75 or a / nullif(e, 0) > 1.33) then 0 else 1 end), abs(ln(nullif(a / nullif(e, 0), 0))) desc nulls last, name
$$;
revoke execute on function public.forecast_alerts(text, integer, numeric) from public, anon;
grant execute on function public.forecast_alerts(text, integer, numeric) to authenticated, service_role;
