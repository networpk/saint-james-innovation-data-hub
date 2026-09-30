-- Kreatív-szint, kampány <-> forgalom összekötés, bontások és az automatikus észrevételek (insights) motorja.
-- Előfeltételek: 0001, 0004 és a campaign_class nézet.

-- ===== 1. Bővített mutatók a hirdetés-szintű táblában ================================
alter table fact_ad_performance_daily
  add column if not exists link_clicks numeric(14,2),
  add column if not exists video_3s_plays numeric(14,2),
  add column if not exists engagements numeric(14,2),
  add column if not exists landing_page_views numeric(14,2),
  add column if not exists reach bigint,
  add column if not exists all_conversions numeric(14,2),
  add column if not exists conversions_value numeric(14,2),
  add column if not exists view_through_conversions numeric(14,2);

-- Hirdetés-szótár bővítés: előnézet, szöveg, státusz, típus.
alter table dim_ad
  add column if not exists thumbnail_url text,
  add column if not exists image_url text,
  add column if not exists preview_url text,
  add column if not exists cta_type text,
  add column if not exists creative_id text,
  add column if not exists created_time timestamptz,
  add column if not exists status text,
  add column if not exists ad_type text,
  add column if not exists ad_strength text,
  add column if not exists headlines text,
  add column if not exists campaign_id text,
  add column if not exists adset_id text;

-- Kampány-beállítások: Google licitstratégia / célzott CPA / csatornatípus is.
alter table fact_campaign_setting_daily
  add column if not exists target_cpa numeric(14,2),
  add column if not exists channel_type text;

-- Meta minőségi rangsorok hirdetésenként (Quality / Engagement / Conversion ranking).
create table if not exists fact_ad_ranking_daily (
  date date not null,
  platform text not null default 'meta',
  account_id text not null,
  ad_id text not null,
  quality_ranking text,
  engagement_rate_ranking text,
  conversion_rate_ranking text,
  loaded_at timestamptz not null default now(),
  primary key (date, platform, account_id, ad_id)
);

-- Általános bontás: elhelyezés, kor, nem, eszköz, óra, hét napja (platformonként külön lekérdezve).
create table if not exists fact_breakdown_daily (
  date date not null,
  platform text not null,
  account_id text not null,
  campaign_id text not null,
  dimension text not null,          -- placement | age | gender | device | hour | day_of_week
  value text not null,
  spend numeric(14,2) not null default 0,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  conversions numeric(14,2) not null default 0,
  loaded_at timestamptz not null default now(),
  primary key (date, platform, account_id, campaign_id, dimension, value)
);
create index if not exists idx_fbd_dim on fact_breakdown_daily (dimension, date);

-- Melyik GA4 forrás melyik hirdetési platformhoz tartozik (a GA4 kampánynév = a hirdetési kampány neve).
create table if not exists platform_source_map (
  platform text not null,
  ga_source text not null,
  primary key (platform, ga_source)
);
insert into platform_source_map (platform, ga_source) values
  ('meta','facebook'),('meta','instagram'),('meta','fb'),('meta','ig'),('google','google'),('tiktok','tiktok')
on conflict do nothing;

-- ===== 2. Kampány-szintű tölcsér: hirdetés -> kattintás -> látogató -> soft lead ======
-- A GA4 `campaign` értéke a hirdetési kampány nevével egyezik (ellenőrizve: pl. "LASSJOL - ONE STOP SHOP",
-- "GSN - Brand /konvmax"), ezért név szerint kötjük össze, ékezet- és kisbetű-érzéketlenül.
create or replace view mart_campaign_funnel_daily as
with ad as (
  select f.date, f.platform, f.account_id, f.campaign_id,
         sum(f.spend) as spend, sum(f.impressions) as impressions, sum(f.clicks) as clicks,
         sum(f.platform_leads) as platform_leads
  from fact_ad_performance_daily f group by 1,2,3,4
), web as (
  select w.date, m.platform, sj_norm(w.campaign) as cname,
         sum(w.sessions) as sessions, sum(w.users) as users, sum(w.engaged_sessions) as engaged_sessions,
         sum(w.engagement_seconds) as engagement_seconds
  from fact_web_daily w join platform_source_map m on m.ga_source = lower(w.source)
  where w.campaign <> '' group by 1,2,3
), ev as (
  select e.date, m.platform, sj_norm(e.campaign) as cname,
         sum(e.event_count) filter (where fm.stage = 'soft_lead') as soft_leads,
         sum(e.event_count) filter (where fm.stage = 'ga_hard_lead') as ga_hard_leads
  from fact_web_event_daily e
  join platform_source_map m on m.ga_source = lower(e.source)
  join funnel_event_map fm on fm.event_name = e.event_name
  where e.campaign <> '' group by 1,2,3
)
select ad.date, ad.platform, ad.account_id, ad.campaign_id, c.campaign_name, c.business_line, c.category, c.subcategory,
       ad.spend, ad.impressions, ad.clicks, ad.platform_leads,
       coalesce(w.sessions,0) as sessions, coalesce(w.users,0) as users,
       coalesce(w.engaged_sessions,0) as engaged_sessions, coalesce(w.engagement_seconds,0) as engagement_seconds,
       coalesce(ev.soft_leads,0) as soft_leads, coalesce(ev.ga_hard_leads,0) as ga_hard_leads
from ad
left join campaign_class c on c.platform = ad.platform and c.account_id = ad.account_id and c.campaign_id = ad.campaign_id
left join web w on w.date = ad.date and w.platform = ad.platform and w.cname = sj_norm(c.campaign_name)
left join ev on ev.date = ad.date and ev.platform = ad.platform and ev.cname = sj_norm(c.campaign_name);

-- Forgalom, ami egyik hirdetési kampányhoz sem köthető (elnevezési vagy UTM-hiba felderítése).
create or replace view mart_web_campaign_unmatched as
select w.date, m.platform, w.campaign, w.source, w.medium, sum(w.sessions) as sessions
from fact_web_daily w join platform_source_map m on m.ga_source = lower(w.source)
where w.campaign <> '' and w.campaign not in ('(not set)','(direct)','(organic)','(referral)')
  and not exists (select 1 from campaign_class c where c.platform = m.platform and sj_norm(c.campaign_name) = sj_norm(w.campaign))
group by 1,2,3,4,5;

-- ===== 3. Kreatívok ====================================================================
create or replace view mart_creative_daily as
select f.date, f.platform, f.account_id, f.campaign_id, f.adset_id, f.ad_id,
       coalesce(d.ad_name, f.ad_name) as ad_name, c.campaign_name, c.business_line, c.category, c.subcategory,
       coalesce(adt.topic, ct.topic) as topic,
       f.spend, f.impressions, f.clicks, f.platform_leads, f.link_clicks, f.video_3s_plays, f.engagements, f.reach
from fact_ad_performance_daily f
left join dim_ad d on d.platform = f.platform and d.ad_id = f.ad_id
left join campaign_class c on c.platform = f.platform and c.account_id = f.account_id and c.campaign_id = f.campaign_id
left join ad_topic adt on adt.platform = f.platform and adt.ad_id = f.ad_id
left join campaign_topic ct on ct.platform = f.platform and ct.account_id = f.account_id and ct.campaign_id = f.campaign_id
where f.ad_id <> '';

-- Kreatív-lista időszakra, Pareto-részesedéssel (melyik hirdetések adják a kattintások p_top_share részét).
create or replace function creative_performance(
  p_from date, p_to date, p_business_line text default null, p_platform text default null, p_top_share numeric default 0.85
) returns table (
  platform text, ad_id text, ad_name text, campaign_id text, campaign_name text, business_line text,
  category text, subcategory text, topic text, status text, thumbnail_url text, preview_url text,
  body text, title text, cta_type text,
  spend numeric, impressions bigint, clicks bigint, ctr numeric, cpc numeric, cpm numeric,
  video_3s_plays numeric, hook_rate numeric, engagements numeric, engagement_rate numeric,
  platform_leads numeric, cost_per_lead numeric, reach_sum bigint, avg_daily_frequency numeric,
  days_active int, click_share numeric, cum_click_share numeric, in_top_share boolean
) language sql stable as $$
  with a as (
    select m.platform, m.ad_id, max(m.ad_name) as ad_name, max(m.campaign_id) as campaign_id, max(m.campaign_name) as campaign_name,
           max(m.business_line) as business_line, max(m.category) as category, max(m.subcategory) as subcategory, max(m.topic) as topic,
           sum(m.spend) as spend, sum(m.impressions)::bigint as impressions, sum(m.clicks)::bigint as clicks,
           sum(coalesce(m.video_3s_plays,0)) as v3, sum(coalesce(m.engagements,0)) as eng,
           sum(m.platform_leads) as leads, sum(coalesce(m.reach,0))::bigint as reach_sum,
           count(distinct m.date) filter (where m.spend > 0)::int as days_active
    from mart_creative_daily m
    where m.date between p_from and p_to
      and (p_business_line is null or m.business_line = p_business_line)
      and (p_platform is null or m.platform = p_platform)
    group by m.platform, m.ad_id
  ), r as (
    select a.*, a.clicks::numeric / nullif(sum(a.clicks) over (), 0) as click_share,
           sum(a.clicks) over (order by a.clicks desc, a.ad_id rows between unbounded preceding and current row)::numeric
             / nullif(sum(a.clicks) over (), 0) as cum_click_share
    from a
  )
  select r.platform, r.ad_id, coalesce(d.ad_name, r.ad_name), r.campaign_id, r.campaign_name, r.business_line,
         r.category, r.subcategory, r.topic, d.status, d.thumbnail_url, d.preview_url, d.body, d.title, d.cta_type,
         round(r.spend, 2), r.impressions, r.clicks,
         round(r.clicks::numeric / nullif(r.impressions, 0), 5),
         round(r.spend / nullif(r.clicks, 0), 2),
         round(r.spend / nullif(r.impressions, 0) * 1000, 2),
         r.v3, round(r.v3 / nullif(r.impressions, 0), 5), r.eng, round(r.eng / nullif(r.impressions, 0), 5),
         r.leads, round(r.spend / nullif(r.leads, 0), 2), r.reach_sum,
         round(r.impressions::numeric / nullif(r.reach_sum, 0), 2),
         r.days_active, round(r.click_share, 5), round(r.cum_click_share, 5),
         (r.cum_click_share - r.click_share) < p_top_share
  from r left join dim_ad d on d.platform = r.platform and d.ad_id = r.ad_id
  order by r.clicks desc
$$;

-- ===== 4. Küszöbök és az észrevételek motorja ==========================================
create table if not exists insight_threshold (
  key text primary key, value numeric not null, note text
);
insert into insight_threshold (key, value, note) values
  ('waste_min_spend', 5000, 'kulcsszó: ennyi költés konverzió nélkül már jelzés (Ft az ablakban)'),
  ('budget_lost_min', 0.10, 'Google: költségkeret miatt elvesztett megjelenés-részesedés'),
  ('rank_lost_min', 0.30, 'Google: rangsor miatt elvesztett megjelenés-részesedés'),
  ('cpc_spike_pct', 0.25, 'CPC emelkedés az előző ablakhoz képest'),
  ('cpc_min_spend', 20000, 'CPC-ugrás vizsgálatához minimális költés'),
  ('fatigue_ctr_drop', 0.20, 'kreatív-fáradás: CTR-esés'),
  ('fatigue_freq_rise', 0.10, 'kreatív-fáradás: gyakoriság-emelkedés'),
  ('fatigue_min_impr', 3000, 'kreatív-fáradás: minimális megjelenés mindkét ablakban'),
  ('creative_loser_ratio', 0.5, 'kreatív CTR a kampány CTR-jének ennyi aránya alatt'),
  ('creative_min_impr', 2000, 'kreatív-értékeléshez minimális megjelenés'),
  ('creative_min_spend', 10000, 'kreatív-értékeléshez minimális költés'),
  ('click_session_min_clicks', 100, 'kattintás -> látogató veszteség vizsgálatához minimális kattintás'),
  ('click_session_ratio', 0.6, 'ennél kisebb látogató/kattintás arány jelzés'),
  ('step_leak_drop', 0.35, 'foglalási lépés lemorzsolódás jelzési küszöb'),
  ('step_leak_min_leads', 10, 'foglalási lépés: minimális elért lead'),
  ('opp_min_conv', 1, 'keresési kifejezés: minimális konverzió új kulcsszó-javaslathoz'),
  ('opp_min_clicks', 3, 'keresési kifejezés: minimális kattintás új kulcsszó-javaslathoz'),
  ('anomaly_ratio_hi', 1.6, 'napi költés az azonos hétköznap átlagához képest ennyiszeres = túlköltés'),
  ('anomaly_ratio_lo', 0.4, 'napi költés az azonos hétköznap átlagához képest ennyiszeres = kiesés'),
  ('budget_change_pct', 0.20, 'költségkeret-változás jelzése')
on conflict do nothing;

create or replace function thr(p_key text) returns numeric language sql stable as $$
  select value from insight_threshold where key = p_key
$$;

-- Kreatív-fáradás: a CTR esik, miközben a gyakoriság nő (p_window napos ablak az előzőhöz képest).
create or replace function creative_fatigue(p_asof date, p_window int default 7)
returns table (platform text, ad_id text, ad_name text, campaign_name text, impressions_cur bigint, spend_cur numeric,
               ctr_prev numeric, ctr_cur numeric, ctr_change numeric, freq_prev numeric, freq_cur numeric, freq_change numeric)
language sql stable as $$
  with w as (
    select m.platform, m.ad_id, max(m.ad_name) as ad_name, max(m.campaign_name) as campaign_name,
           sum(m.impressions) filter (where m.date > p_asof - p_window) as i_cur,
           sum(m.impressions) filter (where m.date <= p_asof - p_window) as i_prev,
           sum(m.clicks) filter (where m.date > p_asof - p_window) as c_cur,
           sum(m.clicks) filter (where m.date <= p_asof - p_window) as c_prev,
           sum(coalesce(m.reach,0)) filter (where m.date > p_asof - p_window) as r_cur,
           sum(coalesce(m.reach,0)) filter (where m.date <= p_asof - p_window) as r_prev,
           sum(m.spend) filter (where m.date > p_asof - p_window) as s_cur
    from mart_creative_daily m
    where m.date between p_asof - 2 * p_window + 1 and p_asof
    group by m.platform, m.ad_id
  )
  select platform, ad_id, ad_name, campaign_name, i_cur::bigint, round(s_cur,2),
         round(c_prev::numeric / nullif(i_prev,0), 5), round(c_cur::numeric / nullif(i_cur,0), 5),
         round((c_cur::numeric / nullif(i_cur,0)) / nullif(c_prev::numeric / nullif(i_prev,0),0) - 1, 4),
         round(i_prev::numeric / nullif(r_prev,0), 3), round(i_cur::numeric / nullif(r_cur,0), 3),
         round((i_cur::numeric / nullif(r_cur,0)) / nullif(i_prev::numeric / nullif(r_prev,0),0) - 1, 4)
  from w
  where i_cur >= thr('fatigue_min_impr') and i_prev >= thr('fatigue_min_impr')
$$;

-- Az észrevételek: szabályalapú, átlátható, bizonyítékkal és javasolt teendővel.
-- p_asof: az ablak utolsó napja (általában tegnap), p_window: az ablak hossza napokban.
create or replace function insights(p_asof date default (current_date - 1), p_window int default 14)
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable as $$
declare
  cur_from date := p_asof - p_window + 1;
  prev_from date := p_asof - 2 * p_window + 1;
  prev_to date := p_asof - p_window;
begin
  -- 1) Elköltött pénz konverzió nélkül (kulcsszó)
  return query
  select 'waste_keyword', 'warning', 'keyword', k.account_id || '|' || k.campaign_id || '|' || k.keyword_text, k.keyword_text,
         format('„%s”: %s Ft költés, 0 konverzió', k.keyword_text, to_char(round(k.sp), 'FM999 999 999')),
         format('%s napon %s kattintás és %s megjelenés, konverzió nélkül.', p_window, k.cl, k.im),
         jsonb_build_object('spend', k.sp, 'clicks', k.cl, 'impressions', k.im, 'campaign_id', k.campaign_id),
         'Nézd át a találatot: negatív kulcsszó, licitcsökkentés vagy szüneteltetés. Ellenőrizd a konverzió-mérést is, mielőtt döntesz.',
         k.sp
  from (select account_id, campaign_id, keyword_text, sum(spend) as sp, sum(clicks) as cl, sum(impressions) as im, sum(conversions) as cv
        from fact_keyword_daily where date between cur_from and p_asof group by 1,2,3) k
  where k.sp >= thr('waste_min_spend') and k.cv = 0;

  -- 2) Költségkeret-korlátos, hatékony Google-kampány
  return query
  with g as (
    select s.account_id, s.campaign_id, avg(s.budget_lost_share) as bl, avg(s.search_impression_share) as sis
    from fact_google_share_daily s where s.date between cur_from and p_asof group by 1,2
  ), p as (
    select f.account_id, f.campaign_id, sum(f.spend) as sp, sum(f.platform_leads) as cv
    from fact_ad_performance_daily f where f.platform = 'google' and f.date between cur_from and p_asof group by 1,2
  ), acc as (
    select account_id, sum(spend) / nullif(sum(platform_leads), 0) as cpa
    from fact_ad_performance_daily where platform = 'google' and date between cur_from and p_asof group by 1
  )
  select 'budget_limited', 'opportunity', 'campaign', 'google|' || g.account_id || '|' || g.campaign_id, c.campaign_name,
         format('„%s”: a költségkeret miatt elveszti a megjelenések %s%%-át', c.campaign_name, round(g.bl * 100)),
         format('Költség/konverzió: %s Ft, a fiók átlaga: %s Ft.', round(p.sp / nullif(p.cv, 0)), round(acc.cpa)),
         jsonb_build_object('budget_lost_share', round(g.bl, 4), 'impression_share', round(g.sis, 4), 'spend', p.sp, 'conversions', p.cv),
         'A kampány az átlagnál olcsóbban szerez konverziót, de a keret korlátozza: érdemes emelni a napi költségkeretet (lépcsőzve, figyelve a költség/konverziót).',
         p.sp * g.bl
  from g join p using (account_id, campaign_id) join acc using (account_id)
  left join campaign_class c on c.platform = 'google' and c.account_id = g.account_id and c.campaign_id = g.campaign_id
  where g.bl >= thr('budget_lost_min') and p.cv > 0 and p.sp / p.cv <= acc.cpa;

  -- 3) Rangsor-korlátos Google-kampány (gyenge hirdetés / licit / minőség)
  return query
  select 'rank_limited', 'warning', 'campaign', 'google|' || s.account_id || '|' || s.campaign_id, c.campaign_name,
         format('„%s”: a rangsor miatt elveszti a megjelenések %s%%-át', c.campaign_name, round(avg(s.rank_lost_share) * 100)),
         format('Megjelenési részesedés átlag: %s%%.', round(avg(s.search_impression_share) * 100)),
         jsonb_build_object('rank_lost_share', round(avg(s.rank_lost_share), 4), 'impression_share', round(avg(s.search_impression_share), 4)),
         'Hirdetésszövegek, céloldal-relevancia, minőségi mutató és licit áttekintése.',
         0::numeric
  from fact_google_share_daily s
  left join campaign_class c on c.platform = 'google' and c.account_id = s.account_id and c.campaign_id = s.campaign_id
  where s.date between cur_from and p_asof
  group by s.account_id, s.campaign_id, c.campaign_name
  having avg(s.rank_lost_share) >= thr('rank_lost_min');

  -- 4) CPC-ugrás az előző ablakhoz képest
  return query
  with w as (
    select f.platform, f.account_id, f.campaign_id,
           sum(f.spend) filter (where f.date >= cur_from) as sp_c, sum(f.clicks) filter (where f.date >= cur_from) as cl_c,
           sum(f.spend) filter (where f.date between prev_from and prev_to) as sp_p, sum(f.clicks) filter (where f.date between prev_from and prev_to) as cl_p
    from fact_ad_performance_daily f where f.date between prev_from and p_asof group by 1,2,3
  )
  select 'cpc_spike', 'warning', 'campaign', w.platform || '|' || w.account_id || '|' || w.campaign_id, c.campaign_name,
         format('„%s”: a CPC %s%%-kal nőtt', c.campaign_name, round((w.sp_c / w.cl_c) / (w.sp_p / w.cl_p) * 100 - 100)),
         format('CPC: %s Ft az előző %s Ft volt (%s napos ablakok).', round(w.sp_c / w.cl_c), round(w.sp_p / w.cl_p), p_window),
         jsonb_build_object('cpc_cur', round(w.sp_c / w.cl_c, 2), 'cpc_prev', round(w.sp_p / w.cl_p, 2), 'spend_cur', w.sp_c),
         'Nézd meg, történt-e licit-, célzás- vagy kreatívváltás, illetve nőtt-e a verseny (megjelenési részesedés, árverési adatok).',
         w.sp_c - w.cl_c * (w.sp_p / w.cl_p)
  from w left join campaign_class c on c.platform = w.platform and c.account_id = w.account_id and c.campaign_id = w.campaign_id
  where w.sp_c >= thr('cpc_min_spend') and w.cl_c > 0 and w.cl_p > 0
    and (w.sp_c / w.cl_c) / (w.sp_p / w.cl_p) - 1 >= thr('cpc_spike_pct');

  -- 5) Kreatív-fáradás
  return query
  select 'creative_fatigue', 'warning', 'ad', f.platform || '|' || f.ad_id, f.ad_name,
         format('„%s”: fáradó kreatív (CTR %s%%, gyakoriság +%s%%)', f.ad_name, round(f.ctr_change * 100), round(f.freq_change * 100)),
         format('A CTR %s%%-ról %s%%-ra esett, a gyakoriság %s-ról %s-ra nőtt.', round(f.ctr_prev * 100, 2), round(f.ctr_cur * 100, 2), f.freq_prev, f.freq_cur),
         jsonb_build_object('ctr_prev', f.ctr_prev, 'ctr_cur', f.ctr_cur, 'freq_prev', f.freq_prev, 'freq_cur', f.freq_cur, 'campaign', f.campaign_name),
         'Cserélj vagy frissíts kreatívot, bővítsd a közönséget, vagy csökkentsd a költést ezen a hirdetésen.',
         f.spend_cur
  from creative_fatigue(p_asof, greatest(p_window / 2, 3)) f
  where f.ctr_change <= -thr('fatigue_ctr_drop') and f.freq_change >= thr('fatigue_freq_rise');

  -- 6) Gyenge kreatív a saját kampányához képest
  return query
  with a as (
    select m.platform, m.account_id, m.campaign_id, m.ad_id, max(m.ad_name) as ad_name, max(m.campaign_name) as campaign_name,
           sum(m.spend) as sp, sum(m.impressions) as im, sum(m.clicks) as cl
    from mart_creative_daily m where m.date between cur_from and p_asof group by 1,2,3,4
  ), cg as (select platform, account_id, campaign_id, sum(cl)::numeric / nullif(sum(im),0) as ctr, count(*) as n from a group by 1,2,3)
  select 'creative_loser', 'info', 'ad', a.platform || '|' || a.ad_id, a.ad_name,
         format('„%s”: a kampány átlagának %s%%-át hozza CTR-ben', a.ad_name, round((a.cl::numeric / a.im) / cg.ctr * 100)),
         format('CTR %s%% a kampány %s%%-ához képest, %s Ft költéssel.', round(a.cl::numeric / a.im * 100, 2), round(cg.ctr * 100, 2), round(a.sp)),
         jsonb_build_object('ctr', round(a.cl::numeric / a.im, 5), 'campaign_ctr', round(cg.ctr, 5), 'spend', a.sp, 'campaign', a.campaign_name),
         'Fontold meg a szüneteltetést, vagy tedd át a költést a jobban teljesítő kreatívokra ugyanebben a kampányban.',
         a.sp
  from a join cg using (platform, account_id, campaign_id)
  where cg.n >= 2 and a.im >= thr('creative_min_impr') and a.sp >= thr('creative_min_spend')
    and (a.cl::numeric / a.im) < cg.ctr * thr('creative_loser_ratio');

  -- 7) Kattintás -> látogató veszteség kampányonként
  return query
  select 'click_session_gap', 'warning', 'campaign', f.platform || '|' || f.account_id || '|' || f.campaign_id, max(f.campaign_name),
         format('„%s”: a kattintások csak %s%%-ából lett mért látogatás', max(f.campaign_name), round(sum(f.sessions) / nullif(sum(f.clicks), 0) * 100)),
         format('%s kattintás, %s mért látogatás (GA4).', sum(f.clicks), sum(f.sessions)),
         jsonb_build_object('clicks', sum(f.clicks), 'sessions', sum(f.sessions)),
         case when sum(f.sessions) = 0
              then 'Nincs GA4 forgalom ehhez a kampányhoz: ellenőrizd a UTM-paramétereket / a kampánynév egyezését.'
              else 'Vizsgáld a céloldal betöltési sebességét, a követőkód működését és a rossz (véletlen) kattintásokat.' end,
         sum(f.clicks) - sum(f.sessions)
  from mart_campaign_funnel_daily f
  where f.date between cur_from and p_asof
  group by f.platform, f.account_id, f.campaign_id
  having sum(f.clicks) >= thr('click_session_min_clicks') and sum(f.sessions) / nullif(sum(f.clicks), 0) < thr('click_session_ratio');

  -- 8) Követés-kiesés: van költés, de nincs mért látogató (a teljes tegnapi és tegnapelőtti napra)
  return query
  select 'tracking_outage', 'critical', 'day', d.dt::text, d.dt::text,
         format('%s: van hirdetési költés (%s Ft), de a GA4 nem mért látogatót', d.dt, round(d.sp)),
         'A weboldal-követés kiesett vagy késik.',
         jsonb_build_object('spend', d.sp, 'sessions', d.ss),
         'Ellenőrizd a GA4 / GTM működését és a Windsor-betöltést. A költés folyik, miközben a mérés vak.',
         d.sp
  from (
    select g.dt, coalesce(a.sp, 0) as sp, coalesce(w.ss, 0) as ss
    from generate_series(p_asof - 1, p_asof, interval '1 day') g(dt)
    left join (select date, sum(spend) as sp from fact_ad_performance_daily group by 1) a on a.date = g.dt::date
    left join (select date, sum(sessions) as ss from fact_web_daily group by 1) w on w.date = g.dt::date
  ) d
  where d.sp > 0 and d.ss = 0 and exists (select 1 from fact_web_daily);

  -- 9) Költés-anomália az azonos hétköznapok átlagához képest (platformonként)
  return query
  with d as (
    select platform, date, sum(spend) as sp from fact_ad_performance_daily group by 1,2
  ), base as (
    select x.platform, avg(y.sp) as avg_sp, count(y.sp) as n
    from (select platform from d group by 1) x
    left join d y on y.platform = x.platform and y.date in (p_asof - 7, p_asof - 14, p_asof - 21, p_asof - 28)
    group by 1
  )
  select 'spend_anomaly', case when t.sp / b.avg_sp >= thr('anomaly_ratio_hi') then 'warning' else 'critical' end,
         'platform', t.platform, t.platform,
         format('%s: a napi költés az azonos napok átlagának %s%%-a', t.platform, round(t.sp / b.avg_sp * 100)),
         format('%s Ft a szokásos ~%s Ft helyett (%s).', round(t.sp), round(b.avg_sp), p_asof),
         jsonb_build_object('spend', t.sp, 'baseline', round(b.avg_sp, 2)),
         'Nézd meg a költségkeret-, licit- és státuszváltozásokat (leállt vagy elszabadult kampány?).',
         abs(t.sp - b.avg_sp)
  from d t join base b on b.platform = t.platform
  where t.date = p_asof and b.n >= 3 and b.avg_sp > 0
    and (t.sp / b.avg_sp >= thr('anomaly_ratio_hi') or t.sp / b.avg_sp <= thr('anomaly_ratio_lo'));

  -- 10) Foglalási lépés-szivárgás
  return query
  with s as (
    select bs.ord, bs.step, bs.label, sum(m.leads_reached) as reached
    from mart_booking_step_daily m join booking_step bs on bs.step = m.step
    where m.day between cur_from and p_asof and bs.ord <= 6 group by 1,2,3
  ), n as (
    select s.*, lead(s.reached) over (order by ord) as next_reached from s
  )
  select 'booking_step_leak', 'warning', 'booking_step', n.step, n.label,
         format('A foglalásban a „%s” lépésnél esik ki a legtöbb: %s%%', n.label, round((1 - n.next_reached / n.reached) * 100)),
         format('%s elérte a lépést, %s jutott tovább.', n.reached, n.next_reached),
         jsonb_build_object('reached', n.reached, 'next', n.next_reached),
         'Nézd át ezt a képernyőt (mezők száma, hibaüzenetek, telefon / mobil használhatóság), és mérd az átfutási időt.',
         n.reached - n.next_reached
  from n
  where n.next_reached is not null and n.reached >= thr('step_leak_min_leads')
    and 1 - n.next_reached / n.reached >= thr('step_leak_drop');

  -- 11) Új kulcsszó-lehetőség: konvertáló keresési kifejezés, ami nem kulcsszó
  return query
  select 'search_term_opportunity', 'opportunity', 'search_term', t.account_id || '|' || t.search_term, t.search_term,
         format('„%s”: %s konverziót hozott, de nincs saját kulcsszava', t.search_term, round(t.cv, 1)),
         format('%s kattintás, %s Ft költés.', t.cl, round(t.sp)),
         jsonb_build_object('conversions', t.cv, 'clicks', t.cl, 'spend', t.sp),
         'Vedd fel pontos / kifejezés egyezésű kulcsszóként, hogy kontrollálni tudd a licitet és a hirdetésszöveget.',
         t.cv
  from (select account_id, search_term, sum(conversions) as cv, sum(clicks) as cl, sum(spend) as sp
        from fact_search_term_daily where date between cur_from and p_asof group by 1,2) t
  where t.cv >= thr('opp_min_conv') and t.cl >= thr('opp_min_clicks')
    and not exists (select 1 from fact_keyword_daily k where sj_norm(k.keyword_text) = sj_norm(t.search_term));

  -- 12) Költségkeret-változás (kampány-beállítások pillanatképéből)
  return query
  with b as (
    select platform, account_id, campaign_id,
           (array_agg(campaign_daily_budget order by date asc))[1] as b0,
           (array_agg(campaign_daily_budget order by date desc))[1] as b1
    from fact_campaign_setting_daily
    where date between cur_from and p_asof and campaign_daily_budget is not null group by 1,2,3
  )
  select 'budget_change', 'info', 'campaign', b.platform || '|' || b.account_id || '|' || b.campaign_id, c.campaign_name,
         format('„%s”: a napi költségkeret %s%%-kal változott', c.campaign_name, round((b.b1 / b.b0 - 1) * 100)),
         format('%s -> %s (napi).', round(b.b0), round(b.b1)),
         jsonb_build_object('from', b.b0, 'to', b.b1),
         'Ellenőrizd, hogy szándékos volt-e, és figyeld a következő napok teljesítményét (Meta: tanulási fázis).',
         abs(b.b1 - b.b0)
  from b left join campaign_class c on c.platform = b.platform and c.account_id = b.account_id and c.campaign_id = b.campaign_id
  where b.b0 > 0 and abs(b.b1 / b.b0 - 1) >= thr('budget_change_pct');

  -- 13) Hatás-összefüggés: a Meta/TikTok-költés és a Google brand-keresés késleltetett együttmozgása
  return query
  select 'halo_effect', 'info', 'signal_pair', c.signal_a || '>' || c.signal_b, c.signal_a || ' → ' || c.signal_b,
         format('%s és %s együtt mozog (késleltetés: %s nap, r = %s)', c.signal_a, c.signal_b, c.lag_days, c.r),
         format('Hétköznap-hatás nélkül, %s napon át, t = %s. Jelzésértékű összefüggés, nem bizonyíték az ok-okozatra.', c.n, c.t_stat),
         jsonb_build_object('lag_days', c.lag_days, 'r', c.r, 'n', c.n, 't', c.t_stat, 'r_lag0', c.r_lag0),
         'Ha a kapcsolat tartósan fennáll, a Meta/TikTok támogatja a brand-keresést: a két csatornát együtt érdemes tervezni és értékelni.',
         abs(c.r)
  from signal_correlations_best(p_asof - 59, p_asof, 10, true, 28, 3.0) c
  where c.signal_a in ('spend_meta','spend_tiktok','impressions_meta','impressions_tiktok','clicks_meta','clicks_tiktok')
    and c.signal_b in ('google_brand_impressions','google_brand_clicks') and c.r > 0.4
  order by c.r desc limit 3;
end $$;
