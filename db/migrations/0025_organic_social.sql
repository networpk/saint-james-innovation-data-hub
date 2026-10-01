-- Organikus posztok (Instagram, később Facebook): bejegyzésenként napi pillanatkép az elérésről, megtekintésről és interakciókról.
-- Forrás: Windsor `instagram` (media_insights) és `facebook_organic` csatlakozó. Nincs személyes adat: a poszt szövege nyilvános tartalom.

create table if not exists dim_social_post (
  platform text not null check (platform in ('instagram', 'facebook')),
  post_id text not null,
  account_id text,
  permalink text,
  published_at timestamptz,
  media_type text,                -- REELS, IMAGE, CAROUSEL_ALBUM, VIDEO, STORY / photo, album, video, link (Facebook)
  caption text,
  thumbnail_url text,
  loaded_at timestamptz not null default now(),
  primary key (platform, post_id)
);
create index if not exists idx_social_post_published on dim_social_post (published_at desc);

create table if not exists fact_social_post_daily (
  snapshot_date date not null,
  platform text not null,
  post_id text not null,
  reach bigint,
  views bigint,
  likes bigint,
  comments bigint,
  saves bigint,
  shares bigint,
  interactions bigint,
  link_clicks bigint,
  avg_watch_ms numeric,
  skip_rate numeric,              -- 0..1, az első 3 mp-ben továbbgörgetők aránya (reel)
  loaded_at timestamptz not null default now(),
  primary key (snapshot_date, platform, post_id),
  foreign key (platform, post_id) references dim_social_post (platform, post_id) on delete cascade
);

-- Poszt a legfrissebb pillanatképpel; az interakció-arány az elérésre vetített interakció, a változás az előző napi pillanatképhez képest.
create or replace view mart_social_post with (security_invoker = true) as
with last as (
  select distinct on (platform, post_id) * from fact_social_post_daily order by platform, post_id, snapshot_date desc
), prev as (
  select l.platform, l.post_id, p.reach as reach_prev, p.views as views_prev
  from last l
  left join lateral (
    select f.reach, f.views from fact_social_post_daily f
    where f.platform = l.platform and f.post_id = l.post_id and f.snapshot_date <= l.snapshot_date - 1
    order by f.snapshot_date desc limit 1
  ) p on true
)
select d.platform, d.post_id, d.account_id, d.permalink, d.published_at,
       (d.published_at at time zone 'Europe/Budapest')::date as published_day,
       d.media_type, d.caption, d.thumbnail_url,
       l.snapshot_date as as_of, l.reach, l.views, l.likes, l.comments, l.saves, l.shares, l.interactions, l.link_clicks,
       l.avg_watch_ms, l.skip_rate,
       l.interactions::numeric / nullif(l.reach, 0) as interaction_rate,
       l.views::numeric / nullif(l.reach, 0) as views_per_reach,
       l.reach - pv.reach_prev as reach_change_1d,
       l.views - pv.views_prev as views_change_1d,
       (l.snapshot_date - (d.published_at at time zone 'Europe/Budapest')::date) as age_days
from dim_social_post d
left join last l on l.platform = d.platform and l.post_id = d.post_id
left join prev pv on pv.platform = d.platform and pv.post_id = d.post_id;

-- A poszt idősora (napi pillanatképek): hogyan nőtt az elérés a közzététel óta.
create or replace function social_post_trend(p_platform text, p_post_id text)
returns table (snapshot_date date, days_since_publish int, reach bigint, views bigint, interactions bigint, saves bigint, shares bigint)
language sql stable as $$
  select f.snapshot_date,
         (f.snapshot_date - (d.published_at at time zone 'Europe/Budapest')::date)::int,
         f.reach, f.views, f.interactions, f.saves, f.shares
  from fact_social_post_daily f join dim_social_post d using (platform, post_id)
  where f.platform = p_platform and f.post_id = p_post_id order by f.snapshot_date;
$$;

-- Összesítő a közzététel napja szerinti időszakra: típusonként (platform, formátum) és összesen.
create or replace function social_summary(p_from date, p_to date, p_platform text default null)
returns table (platform text, media_type text, posts bigint, total_reach bigint, total_views bigint, total_interactions bigint,
               median_reach numeric, avg_interaction_rate numeric, best_post_id text, best_post_url text, best_post_reach bigint)
language sql stable as $$
  with p as (
    select * from mart_social_post
    where published_day between p_from and p_to and reach is not null and (p_platform is null or p_platform = 'mind' or platform = p_platform)
  ), best as (
    select distinct on (platform, media_type) platform, media_type, post_id, permalink, reach
    from p order by platform, media_type, reach desc
  )
  select p.platform, p.media_type, count(*), sum(p.reach)::bigint, sum(p.views)::bigint, sum(p.interactions)::bigint,
         percentile_cont(0.5) within group (order by p.reach), avg(p.interaction_rate),
         b.post_id, b.permalink, b.reach
  from p join best b on b.platform = p.platform and b.media_type is not distinct from p.media_type
  group by p.platform, p.media_type, b.post_id, b.permalink, b.reach
  order by p.platform, count(*) desc;
$$;

do $$
declare t text;
begin
  foreach t in array array['dim_social_post','fact_social_post_daily'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('drop policy if exists "auth read %1$s" on public.%1$I', t);
    execute format('create policy "auth read %1$s" on public.%1$I for select to authenticated using (true)', t);
  end loop;
end $$;
revoke all on mart_social_post from anon;
grant select on mart_social_post to authenticated;
revoke execute on function social_post_trend(text, text), social_summary(date, date, text) from public, anon;
grant execute on function social_post_trend(text, text), social_summary(date, date, text) to authenticated;

-- Önellenőrzés bővítése
create or replace function schema_selfcheck()
returns table (migration text, object_name text, kind text, present boolean)
language sql stable security definer set search_path = public as $$
  with expected(migration, object_name, kind) as (values
    ('0012','seo_opportunities','function'), ('0012','entity_lookup','function'),
    ('0013','alert','relation'), ('0013','alert_rule','relation'), ('0013','refresh_alerts','function'), ('0013','data_quality_alerts','function'),
    ('0014','lead_journey','relation'), ('0014','lead_journey_summary','function'), ('0014','lead_timeline','function'),
    ('0015','fact_ac_contact','relation'), ('0015','lead_ac','relation'), ('0015','ac_alerts','function'),
    ('0016','mart_signals_long','relation'), ('0016','insights','function'),
    ('0017','dim_ac_message','relation'), ('0017','ac_flow_steps','function'), ('0017','mart_ac_automation_overview','relation'),
    ('0018','mart_tracking_reconciliation','relation'), ('0018','tracking_coverage','function'), ('0018','tracking_alerts','function'),
    ('0019','lead_google_campaign','relation'),
    ('0020','cron_alerts','function'),
    ('0022','http_alerts','function'), ('0022','ingestion_close_stuck','function'),
    ('0025','dim_social_post','relation'), ('0025','fact_social_post_daily','relation'), ('0025','mart_social_post','relation'), ('0025','social_summary','function'), ('0025','social_post_trend','function')
  )
  select e.migration, e.object_name, e.kind,
         case e.kind
           when 'relation' then to_regclass('public.' || e.object_name) is not null
           else exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname = e.object_name)
         end
  from expected e order by e.migration, e.object_name;
$$;
