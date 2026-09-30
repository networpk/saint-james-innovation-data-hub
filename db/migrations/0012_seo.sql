-- 0012: Ahrefs (SEO) adatok + fizetett/szerves összevetés + egy név/kulcsszó "teljes képe" minden üzletágon át.
-- Ahrefs-azonosítók (Windsor): 323 = lassjol.hu (szemészet), 324 = saintjameshungary.hu (esztétika / plasztika).

create table if not exists seo_domain_map (
  account_id text primary key,
  site text not null,
  business_line text,
  note text
);
insert into seo_domain_map (account_id, site, business_line, note) values
  ('323', 'lassjol.hu', 'szemeszet', 'Ahrefs projekt: lassjol.hu'),
  ('324', 'saintjameshungary.hu', 'eszteika_plasztika', 'Ahrefs projekt: saintjameshungary.hu')
on conflict do nothing;

-- Heti pillanatkép a domain szerves kulcsszavairól (az Ahrefs csak az aktuális állapotot adja, az előzményt mi építjük).
create table if not exists fact_seo_keyword_snapshot (
  snapshot_date date not null,
  account_id text not null,
  keyword text not null,
  keyword_country text not null default '',
  best_position numeric(6,1),
  best_position_url text,
  search_volume bigint,
  keyword_traffic numeric(12,2),
  cpc_usd numeric(10,2),
  keyword_difficulty numeric(6,1),
  is_branded boolean, is_informational boolean, is_commercial boolean, is_navigational boolean, is_transactional boolean, is_local boolean,
  serp_target_positions_count int,
  loaded_at timestamptz not null default now(),
  primary key (snapshot_date, account_id, keyword, keyword_country)
);
create index if not exists idx_seo_kw_kw on fact_seo_keyword_snapshot (keyword, snapshot_date);

create table if not exists fact_seo_page_snapshot (
  snapshot_date date not null,
  account_id text not null,
  page_url text not null,
  page_traffic numeric(12,2),
  page_keywords int,
  top_keyword text,
  top_keyword_position numeric(6,1),
  top_keyword_volume bigint,
  url_rating numeric(6,1),
  referring_domains int,
  loaded_at timestamptz not null default now(),
  primary key (snapshot_date, account_id, page_url)
);

create table if not exists fact_seo_overview_daily (
  date date not null,
  account_id text not null,
  organic_traffic numeric(12,2),
  organic_keywords int,
  organic_keywords_top3 int,
  paid_traffic numeric(12,2),
  paid_keywords int,
  domain_rating numeric(6,1),
  backlinks bigint,
  referring_domains int,
  loaded_at timestamptz not null default now(),
  primary key (date, account_id)
);

-- Pozíció -> várható kattintási arány (becslés, szerkeszthető): a "ha a 3. helyre kerülne" számításhoz.
create table if not exists seo_ctr_curve (
  rank_pos int primary key,
  ctr numeric(6,4) not null
);
insert into seo_ctr_curve (rank_pos, ctr) values
  (1,0.30),(2,0.16),(3,0.10),(4,0.07),(5,0.05),(6,0.04),(7,0.03),(8,0.025),(9,0.02),(10,0.018),
  (11,0.01),(12,0.009),(13,0.008),(14,0.007),(15,0.006),(16,0.005),(17,0.004),(18,0.004),(19,0.003),(20,0.003)
on conflict do nothing;

insert into insight_threshold (key, value, note) values
  ('seo_min_volume', 50, 'SEO-lehetőség: minimális havi keresési volumen'),
  ('seo_overlap_min_spend', 5000, 'fizetett-szerves átfedés: minimális 30 napos költés (Ft)'),
  ('seo_gap_min_conv', 1, 'SEO-rés: a fizetett kulcsszó minimális konverziója')
on conflict do nothing;

-- A legfrissebb pillanatkép domainenként + a fizetett Google-adat ugyanarra a kulcsszóra (az elmúlt 30 napban).
create or replace view mart_seo_keyword_latest as
with last as (select account_id, max(snapshot_date) as d from fact_seo_keyword_snapshot group by 1),
paid as (
  select sj_norm(keyword_text) as nk, sum(spend) as paid_spend, sum(clicks) as paid_clicks, sum(impressions) as paid_impressions, sum(conversions) as paid_conversions
  from mart_keyword_daily where date >= current_date - 30 group by 1
)
select s.snapshot_date, s.account_id, m.site, m.business_line, s.keyword, s.keyword_country, s.best_position, s.best_position_url,
       s.search_volume, s.keyword_traffic, s.cpc_usd, s.keyword_difficulty,
       s.is_branded, s.is_informational, s.is_commercial, s.is_navigational, s.is_transactional, s.is_local, s.serp_target_positions_count,
       kt.topic, p.paid_spend, p.paid_clicks, p.paid_impressions, p.paid_conversions
from fact_seo_keyword_snapshot s
join last l on l.account_id = s.account_id and l.d = s.snapshot_date
left join seo_domain_map m on m.account_id = s.account_id
left join keyword_topic kt on kt.keyword_text = s.keyword
left join paid p on p.nk = sj_norm(s.keyword);

-- SEO-lehetőségek és átfedések, szabályalapúan, becsült értékkel (a CTR-görbe becslés).
create or replace function seo_opportunities(p_business_line text default null)
returns table (kind text, severity text, business_line text, site text, keyword text, rank_pos numeric, search_volume bigint,
               url text, paid_spend numeric, paid_conversions numeric, est_extra_visits numeric, title text, detail text, recommendation text)
language sql stable as $$
  with k as (
    select l.*, coalesce((select ctr from seo_ctr_curve where rank_pos = least(greatest(round(l.best_position)::int, 1), 20)), 0.002) as cur_ctr,
           (select ctr from seo_ctr_curve where rank_pos = 3) as top3_ctr
    from mart_seo_keyword_latest l
    where p_business_line is null or l.business_line = p_business_line
  )
  -- 1) Gyors nyeremény: a 4.–20. helyen álló, érdemi volumenű, kereskedelmi/helyi szándékú kulcsszó
  select 'quick_win', 'opportunity', k.business_line, k.site, k.keyword, k.best_position, k.search_volume, k.best_position_url,
         k.paid_spend, k.paid_conversions,
         round(k.search_volume * greatest(k.top3_ctr - k.cur_ctr, 0), 0),
         format('„%s”: %s. hely, havi %s keresés', k.keyword, round(k.best_position), k.search_volume),
         format('Ha a 3. helyre kerülne, becsülten +%s látogató/hó (a kattintási arány becslés).', round(k.search_volume * greatest(k.top3_ctr - k.cur_ctr, 0))),
         'Erősítsd a keresésre optimalizált oldalt (cím, tartalom, belső linkek, külső hivatkozások). Nézd meg, hogy a rangsoroló oldal valóban a legmegfelelőbb-e.'
  from k
  where k.best_position between 4 and 20 and k.search_volume >= thr('seo_min_volume')
    and (coalesce(k.is_commercial, false) or coalesce(k.is_transactional, false) or coalesce(k.is_local, false))
  union all
  -- 2) Fizetett-szerves átfedés: a szerves 1–3. hely mellett is költünk rá
  select 'paid_organic_overlap', 'info', k.business_line, k.site, k.keyword, k.best_position, k.search_volume, k.best_position_url,
         k.paid_spend, k.paid_conversions, null::numeric,
         format('„%s”: szerves %s. hely, mégis %s Ft fizetett költés', k.keyword, round(k.best_position), round(k.paid_spend)),
         format('%s kattintás és %s konverzió a fizetett oldalon az elmúlt 30 napban.', k.paid_clicks, round(coalesce(k.paid_conversions, 0), 1)),
         'Ellenőrizd, szükséges-e a fizetett jelenlét (pl. védekezés a versenytárs ellen, külön hirdetésszöveg). Ha nem, csökkentheted a licitet; a szerves találat részben átveszi a forgalmat.'
  from k
  where k.best_position <= 3 and k.paid_spend >= thr('seo_overlap_min_spend')
  union all
  -- 3) SEO-rés: a fizetett kulcsszó konvertál, de szervesen alig jelenik meg
  select 'seo_gap', 'opportunity', l.business_line, l.site, l.keyword, l.best_position, l.search_volume, l.best_position_url,
         l.paid_spend, l.paid_conversions, null::numeric,
         format('„%s”: konvertál a fizetett hirdetésben, szervesen a %s. helyen áll', l.keyword, round(l.best_position)),
         format('%s Ft fizetett költés, %s konverzió (30 nap); havi volumen: %s.', round(l.paid_spend), round(l.paid_conversions, 1), l.search_volume),
         'Érdemes szerves tartalomra is építeni erre a kifejezésre: külön oldal vagy erősebb belső/külső hivatkozás.'
  from mart_seo_keyword_latest l
  where (p_business_line is null or l.business_line = p_business_line)
    and l.paid_conversions >= thr('seo_gap_min_conv') and l.best_position > 10
  union all
  -- 4) Kannibalizáció: ugyanarra a kulcsszóra több saját oldal rangsorol
  select 'cannibalization', 'warning', k.business_line, k.site, k.keyword, k.best_position, k.search_volume, k.best_position_url,
         k.paid_spend, k.paid_conversions, null::numeric,
         format('„%s”: %s saját oldal versenyez ugyanazért a kulcsszóért', k.keyword, k.serp_target_positions_count),
         'A találatok megoszlása gyengítheti a pozíciót.',
         'Válaszd ki a fő oldalt, a többit irányítsd át vagy kapcsold össze belső linkkel, és különítsd el a tartalmukat.'
  from k where coalesce(k.serp_target_positions_count, 0) > 1 and k.search_volume >= thr('seo_min_volume')
$$;

-- Egy név / kulcsszó / szolgáltatás TELJES képe, MINDEN üzletágban (nem szűri az aktuális üzletág-szűrő):
-- fizetett kulcsszó, keresési kifejezés, szerves helyezés, kampány, hirdetés, oldal.
create or replace function entity_lookup(p_q text, p_from date default (current_date - 90), p_to date default (current_date - 1), p_limit int default 15)
returns table (kind text, business_line text, label text, site text, metrics jsonb)
language sql stable as $$
  with q as (select sj_norm(trim(p_q)) as n)
  select * from (
    (select 'paid_keyword'::text, k.business_line, k.keyword_text, null::text,
            jsonb_build_object('spend', round(sum(k.spend)), 'impressions', sum(k.impressions), 'clicks', sum(k.clicks), 'conversions', round(sum(k.conversions), 2),
                               'campaigns', count(distinct k.campaign_name), 'category', max(k.category), 'subcategory', max(k.subcategory))
       from mart_keyword_daily k, q where q.n <> '' and sj_norm(k.keyword_text) like '%' || q.n || '%' and k.date between p_from and p_to
       group by k.business_line, k.keyword_text order by sum(k.spend) desc limit p_limit)
    union all
    (select 'search_term', s.business_line, s.search_term, null::text,
            jsonb_build_object('spend', round(sum(s.spend)), 'impressions', sum(s.impressions), 'clicks', sum(s.clicks), 'conversions', round(sum(s.conversions), 2))
       from mart_search_term_daily s, q where q.n <> '' and sj_norm(s.search_term) like '%' || q.n || '%' and s.date between p_from and p_to
       group by s.business_line, s.search_term order by sum(s.clicks) desc limit p_limit)
    union all
    (select 'organic_keyword', l.business_line, l.keyword, l.site,
            jsonb_build_object('position', l.best_position, 'url', l.best_position_url, 'volume', l.search_volume, 'traffic', l.keyword_traffic,
                               'cpc_usd', l.cpc_usd, 'snapshot', l.snapshot_date, 'paid_spend_30d', round(coalesce(l.paid_spend, 0)))
       from mart_seo_keyword_latest l, q where q.n <> '' and sj_norm(l.keyword) like '%' || q.n || '%'
       order by l.search_volume desc nulls last limit p_limit)
    union all
    (select 'seo_page', m.business_line, p.page_url, m.site,
            jsonb_build_object('traffic', p.page_traffic, 'keywords', p.page_keywords, 'top_keyword', p.top_keyword, 'top_position', p.top_keyword_position, 'top_volume', p.top_keyword_volume)
       from fact_seo_page_snapshot p join seo_domain_map m on m.account_id = p.account_id, q
       where q.n <> '' and (sj_norm(p.page_url) like '%' || q.n || '%' or sj_norm(p.top_keyword) like '%' || q.n || '%')
         and p.snapshot_date = (select max(snapshot_date) from fact_seo_page_snapshot)
       order by p.page_traffic desc nulls last limit p_limit)
    union all
    (select 'campaign', c.business_line, c.campaign_name, null::text, jsonb_build_object('platform', c.platform, 'category', c.category, 'subcategory', c.subcategory)
       from campaign_class c, q where q.n <> '' and sj_norm(c.campaign_name) like '%' || q.n || '%' order by c.campaign_name limit p_limit)
    union all
    (select 'ad', null::text, coalesce(a.ad_name, a.ad_id), null::text, jsonb_build_object('platform', a.platform, 'title', left(a.title, 120), 'status', a.status)
       from dim_ad a, q where q.n <> '' and sj_norm(concat_ws(' ', a.ad_name, a.title, a.body)) like '%' || q.n || '%' order by a.ad_name limit p_limit)
  ) x
$$;

do $$
declare f text;
begin
  foreach f in array array['seo_opportunities(text)', 'entity_lookup(text,date,date,int)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['seo_domain_map','fact_seo_keyword_snapshot','fact_seo_page_snapshot','fact_seo_overview_daily','seo_ctr_curve'] loop
    execute format('alter table public.%I enable row level security', f);
    execute format('revoke all on public.%I from anon', f);
    execute format('drop policy if exists "auth read %1$s" on public.%1$I', f);
    execute format('create policy "auth read %1$s" on public.%1$I for select to authenticated using (true)', f);
  end loop;
  execute 'drop policy if exists "auth write seo_ctr_curve" on public.seo_ctr_curve';
  execute 'create policy "auth write seo_ctr_curve" on public.seo_ctr_curve for all to authenticated using (true) with check (true)';
  execute 'alter view public.mart_seo_keyword_latest set (security_invoker = on)';
  execute 'revoke all on public.mart_seo_keyword_latest from anon';
  execute 'grant select on public.mart_seo_keyword_latest to authenticated';
exception when undefined_object then null;
end $$;
