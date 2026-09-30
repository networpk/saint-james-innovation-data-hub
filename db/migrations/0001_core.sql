-- Saint James Innovation Data Hub – core séma (Postgres / Supabase)
-- Hatókör: szemészet (business_line = 'szemeszet'); az esztétika később ugyanebbe a modellbe kerül.

create table if not exists ingestion_run (
  id bigserial primary key,
  job text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running','ok','error')),
  rows_upserted integer not null default 0,
  date_from date,
  date_to date,
  error text
);

-- Kampány → üzletág / pillér / formátum besorolás (kézzel vagy UI-ból karbantartva).
create table if not exists campaign_mapping (
  platform text not null,
  campaign_id text not null,
  business_line text not null default 'szemeszet',
  pillar text,
  content_format text,
  funnel_role text check (funnel_role in ('awareness','consideration','conversion')),
  notes text,
  updated_at timestamptz not null default now(),
  primary key (platform, campaign_id)
);

-- Fizetett hirdetések napi teljesítménye (Meta, Google, TikTok) – hirdetés/hirdetéscsoport szinten.
-- A Windsor "spend" mezőjét használjuk minden platformon (azonos jelentés, azonos pénznem-kezelés).
create table if not exists fact_ad_performance_daily (
  date date not null,
  platform text not null,
  account_id text not null,
  campaign_id text not null,
  adset_id text not null default '',
  ad_id text not null default '',
  account_name text,
  campaign_name text,
  adset_name text,
  ad_name text,
  spend numeric(14,2) not null default 0,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  platform_leads numeric(12,2) not null default 0,      -- a platform által jelentett lead/konverzió (tájékoztató, nem a valós foglalás)
  extra jsonb not null default '{}'::jsonb,              -- platformspecifikus mezők (reach, frequency, stb.)
  loaded_at timestamptz not null default now(),
  primary key (date, platform, account_id, campaign_id, adset_id, ad_id)
);
create index if not exists idx_fadp_campaign on fact_ad_performance_daily (platform, campaign_id, date);

-- Nyers Windsor sorok a többi connectorhoz (GA4, organikus social, Ahrefs) – később típusos táblákba normalizálva.
create table if not exists raw_windsor (
  connector text not null,
  account_id text not null,
  date date not null,
  row_key text not null,
  payload jsonb not null,
  loaded_at timestamptz not null default now(),
  primary key (connector, account_id, date, row_key)
);

-- Leadek az időpontfoglaló appból (leads_export nézet; PII nélkül, hash-elt azonosítókkal).
create table if not exists fact_lead (
  lead_id uuid primary key,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  source text not null,
  booking_stage text,
  result_type text,
  business_line text not null default 'szemeszet',
  treatment text,
  doctor text,
  booking_date date,
  booking_time text,
  utm jsonb,
  click_ids jsonb,
  first_touch jsonb,
  landing_url text,
  referrer text,
  ga_client_id text,
  parent_host text,
  quiz_session_id uuid,
  dokirex_booking_id bigint,
  booking_progress jsonb,
  email_hash text,
  phone_hash text,
  loaded_at timestamptz not null default now()
);
create index if not exists idx_fact_lead_created on fact_lead (created_at);
create index if not exists idx_fact_lead_dokirex on fact_lead (dokirex_booking_id);
create index if not exists idx_fact_lead_utm_campaign on fact_lead ((utm->>'utm_campaign'));

create table if not exists fact_lead_event (
  source_id bigint primary key,           -- lead_events.id az appban
  lead_id uuid,
  session_id uuid,
  event text not null,
  step text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null
);
create index if not exists idx_fact_lead_event_lead on fact_lead_event (lead_id, created_at);

create table if not exists fact_quiz_session (
  session_id uuid primary key,
  payload jsonb not null,                 -- az app quiz_sessions sora (PII-mentes)
  loaded_at timestamptz not null default now()
);

-- Dokirex foglalások (státusz/bevétel később, ha az API engedi).
create table if not exists fact_booking (
  dokirex_booking_id bigint primary key,
  appointment_at timestamptz,
  status text,                            -- booked | attended | cancelled | no_show | unknown
  revenue numeric(14,2),
  payload jsonb,
  loaded_at timestamptz not null default now()
);

-- Mart nézetek ---------------------------------------------------------------

-- Napi költés kampányonként a besorolással.
create or replace view mart_spend_daily as
select
  f.date, f.platform, f.account_id, f.campaign_id,
  max(f.campaign_name) as campaign_name,
  coalesce(m.business_line, 'szemeszet') as business_line,
  m.pillar, m.content_format, m.funnel_role,
  sum(f.spend) as spend, sum(f.impressions) as impressions, sum(f.clicks) as clicks,
  sum(f.platform_leads) as platform_leads
from fact_ad_performance_daily f
left join campaign_mapping m on m.platform = f.platform and m.campaign_id = f.campaign_id
group by f.date, f.platform, f.account_id, f.campaign_id, m.business_line, m.pillar, m.content_format, m.funnel_role;

-- Lead-életút: lead + (ha van) foglalás + átfutási idő.
create or replace view mart_lead_journey as
select
  l.lead_id,
  l.created_at as lead_at,
  l.business_line,
  coalesce(l.utm->>'utm_source','(direct/ismeretlen)') as utm_source,
  l.utm->>'utm_medium' as utm_medium,
  l.utm->>'utm_campaign' as utm_campaign,
  l.utm->>'utm_content' as utm_content,
  (l.click_ids is not null and l.click_ids <> '{}'::jsonb) as has_click_id,
  l.booking_stage,
  l.treatment,
  l.dokirex_booking_id,
  b.status as booking_status,
  b.appointment_at,
  (l.booking_stage = 'completed' and l.dokirex_booking_id is not null) as is_booked,
  case when l.booking_stage = 'completed' then extract(epoch from (l.updated_at - l.created_at))/3600 end as hours_lead_to_booking,
  case when b.appointment_at is not null then extract(epoch from (b.appointment_at - l.created_at))/86400 end as days_lead_to_appointment
from fact_lead l
left join fact_booking b on b.dokirex_booking_id = l.dokirex_booking_id;

-- Adatminőség: a leadek hány %-a rendelkezik attribúcióval.
create or replace view mart_attribution_quality as
select
  date_trunc('day', created_at)::date as day,
  count(*) as leads,
  count(*) filter (where utm is not null and utm <> '{}'::jsonb) as with_utm,
  count(*) filter (where click_ids is not null and click_ids <> '{}'::jsonb) as with_click_id,
  count(*) filter (where dokirex_booking_id is not null) as with_dokirex_id
from fact_lead
group by 1;
