-- ActiveCampaign réteg: névjegy-állapot (PII nélkül, hash alapján a leadhez kötve), automatizmus-előrehaladás,
-- kampány-teljesítmény, és ezekből riasztások. Egészségügyi mezőket (dioptria, terhesség, panasz, születési év) NEM töltünk be.

create table if not exists fact_ac_contact (
  ac_contact_id bigint primary key,
  email_hash text,                       -- a betöltő számolja: sha256(lower(trim(email))), az e-mail nem kerül tárolásra
  created_at timestamptz,
  updated_at timestamptz,
  tags text[] not null default '{}',
  channel text,                          -- „csatorna" egyedi mező
  status text,                           -- „státusz" egyedi mező
  sent_count int,
  bounced_hard boolean not null default false,
  bounced_soft boolean not null default false,
  loaded_at timestamptz not null default now()
);
create index if not exists idx_ac_contact_hash on fact_ac_contact (email_hash);

create table if not exists dim_ac_automation (
  automation_id bigint primary key,
  name text not null,
  status text,
  loaded_at timestamptz not null default now()
);

create table if not exists fact_ac_automation_daily (
  date date not null,
  automation_id bigint not null,
  entered int not null default 0,
  exited int not null default 0,
  primary key (date, automation_id)
);

create table if not exists fact_ac_contact_automation (
  id bigint primary key,                 -- contact_automation_id
  ac_contact_id bigint not null,
  automation_id bigint not null,
  raw_status text,                       -- az AC nyers állapota (a betöltő jelentse a megfigyelt értékeket)
  added_at timestamptz,
  removed_at timestamptz,
  completed_elements int,
  total_elements int,
  completed boolean,
  loaded_at timestamptz not null default now()
);
create index if not exists idx_ac_ca_contact on fact_ac_contact_automation (ac_contact_id);
create index if not exists idx_ac_ca_auto on fact_ac_contact_automation (automation_id);

create table if not exists fact_ac_campaign_snapshot (
  snapshot_date date not null,
  campaign_id bigint not null,
  name text,
  sent_at timestamptz,
  status text,
  send_amt int,
  unique_opens int not null default 0,
  verified_unique_opens int,
  unique_link_clicks int not null default 0,
  unsubscribes int not null default 0,
  hard_bounces int not null default 0,
  soft_bounces int not null default 0,
  primary key (snapshot_date, campaign_id)
);

insert into insight_threshold (key, value, note) values
  ('ac_sync_gap_hours', 3, 'AC: ennyi órán túli lead, ami még nincs az ActiveCampaignben'),
  ('ac_sync_gap_min', 3, 'AC: ennyi lead hiányzása már riasztás'),
  ('ac_stuck_days', 21, 'AC: ennyi napja aktív, be nem fejezett automatizmus-tagság „elakadt"'),
  ('ac_stuck_min', 5, 'AC: ennyi elakadt névjegy már riasztás automatizmusonként'),
  ('ac_bounce_rate', 0.02, 'AC: kampány kemény visszapattanási arány riasztási küszöbe'),
  ('ac_bounce_min_send', 500, 'AC: kampány minimális kiküldés a visszapattanás-riasztáshoz')
on conflict (key) do nothing;

-- Egy lead az ActiveCampaignben (hash alapján), a legfrissebb automatizmus-tagsággal.
create or replace view lead_ac with (security_invoker = true) as
select
  l.lead_id,
  c.ac_contact_id,
  c.created_at as ac_created_at,
  extract(epoch from (c.created_at - l.created_at)) / 3600 as hours_lead_to_ac,
  c.tags as ac_tags, c.channel as ac_channel, c.status as ac_status, c.sent_count as ac_sent_count,
  (c.bounced_hard or c.bounced_soft) as ac_bounced, c.bounced_hard as ac_bounced_hard,
  a.automation_id, da.name as automation_name, a.raw_status as automation_raw_status,
  a.added_at as automation_added_at, a.removed_at as automation_removed_at,
  a.completed_elements, a.total_elements,
  case when coalesce(a.total_elements, 0) > 0 then round(a.completed_elements::numeric / a.total_elements, 3) end as automation_progress,
  case
    when a.id is null then 'nincs'
    when coalesce(a.completed, false) or (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements) then 'befejezte'
    when a.removed_at is not null then 'kilepett'
    else 'aktiv'
  end as automation_state
from fact_lead l
left join fact_ac_contact c on c.email_hash is not null and c.email_hash = l.email_hash
left join lateral (
  select * from fact_ac_contact_automation x where x.ac_contact_id = c.ac_contact_id order by x.added_at desc nulls last, x.id desc limit 1
) a on c.ac_contact_id is not null
left join dim_ac_automation da on da.automation_id = a.automation_id;

-- A lead-életút kibővítve az e-mail oldallal.
create or replace view lead_journey_ac with (security_invoker = true) as
select j.*, a.ac_contact_id, a.ac_created_at, a.hours_lead_to_ac, a.ac_tags, a.ac_channel, a.ac_status, a.ac_sent_count,
       a.ac_bounced, a.automation_name, a.automation_state, a.completed_elements, a.total_elements, a.automation_progress,
       a.automation_added_at, a.automation_removed_at,
       (a.ac_contact_id is not null) as in_ac
from lead_journey j join lead_ac a using (lead_id);

-- Hol tartanak az automatizmusban: hány névjegy hányadik lépésnél áll, aktív vagy befejezett.
create or replace view mart_ac_automation_progress with (security_invoker = true) as
select da.automation_id, da.name, a.completed_elements, max(a.total_elements) as total_elements,
       count(*) as contacts,
       count(*) filter (where coalesce(a.completed, false) or (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements)) as finished,
       count(*) filter (where a.removed_at is not null and not (coalesce(a.completed, false) or (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements))) as exited,
       count(*) filter (where a.removed_at is null and not (coalesce(a.completed, false) or (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements))) as active
from fact_ac_contact_automation a join dim_ac_automation da using (automation_id)
group by da.automation_id, da.name, a.completed_elements;

-- Kampány-teljesítmény a legfrissebb pillanatképből. A „valós" megnyitás a verified_unique_opens, ha az AC adja.
create or replace view mart_ac_campaign_performance with (security_invoker = true) as
select s.campaign_id, s.name, s.sent_at, s.status, s.send_amt,
       s.unique_opens, s.verified_unique_opens, s.unique_link_clicks, s.unsubscribes, s.hard_bounces, s.soft_bounces,
       s.unique_opens::numeric / nullif(s.send_amt, 0) as open_rate,
       s.verified_unique_opens::numeric / nullif(s.send_amt, 0) as verified_open_rate,
       s.unique_link_clicks::numeric / nullif(s.send_amt, 0) as click_rate,
       s.unique_link_clicks::numeric / nullif(s.unique_opens, 0) as click_to_open_rate,
       s.unsubscribes::numeric / nullif(s.send_amt, 0) as unsubscribe_rate,
       s.hard_bounces::numeric / nullif(s.send_amt, 0) as hard_bounce_rate
from fact_ac_campaign_snapshot s
where s.snapshot_date = (select max(snapshot_date) from fact_ac_campaign_snapshot x where x.campaign_id = s.campaign_id);

-- Összesítő a lead-életút oldalhoz: honnan (forrás) hány lead jutott az ActiveCampaignbe, hányan haladtak és pattantak vissza.
create or replace function lead_ac_summary(p_from date, p_to date, p_bl text default null)
returns table (leads bigint, in_ac bigint, not_in_ac bigint, in_automation bigint, finished bigint, active bigint, exited bigint,
               bounced bigint, median_hours_to_ac numeric)
language sql stable as $$
  select count(*), count(*) filter (where in_ac), count(*) filter (where not in_ac),
         count(*) filter (where automation_state <> 'nincs'),
         count(*) filter (where automation_state = 'befejezte'),
         count(*) filter (where automation_state = 'aktiv'),
         count(*) filter (where automation_state = 'kilepett'),
         count(*) filter (where ac_bounced),
         percentile_cont(0.5) within group (order by hours_lead_to_ac) filter (where in_ac)
  from lead_journey_ac
  where day between p_from and p_to and (p_bl is null or p_bl = 'mind' or business_line = p_bl);
$$;

-- Az ActiveCampaign-ből jövő riasztások, ugyanolyan alakban, mint az insights().
create or replace function ac_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable as $$
declare n_gap int; n_total int;
begin
  -- csak akkor értelmezhető, ha az AC-névjegyek betöltődtek
  if exists (select 1 from fact_ac_contact) then
    select count(*) filter (where c.ac_contact_id is null), count(*)
      into n_gap, n_total
    from fact_lead l left join fact_ac_contact c on c.email_hash = l.email_hash
    where l.email_hash is not null
      and l.created_at >= p_now - interval '14 days'
      and l.created_at < p_now - make_interval(hours => thr('ac_sync_gap_hours')::int);
    if n_gap >= thr('ac_sync_gap_min') then
      return query
      select 'ac_sync_gap'::text, 'warning'::text, 'leads'::text, '14d'::text, 'Leadek az ActiveCampaignen kívül',
             format('%s lead (%s%%) nincs az ActiveCampaignben', n_gap, round(100.0 * n_gap / nullif(n_total, 0))),
             format('Az elmúlt 14 napban %s leadből %s-nek nincs párja az ActiveCampaignben; nekik nem indul levélsorozat.', n_total, n_gap),
             jsonb_build_object('leads', n_total, 'missing', n_gap),
             'Ellenőrizd a foglaló app ActiveCampaign-szinkronját (synced_to_ac) és az API-kulcsot; a hiányzó leadek nem kapnak e-mailt.',
             n_gap::numeric;
    end if;
  end if;

  -- elakadt automatizmus-tagságok
  return query
  select 'ac_stuck_contacts'::text, 'warning'::text, 'automation'::text, s.automation_id::text, s.name,
         format('„%s”: %s névjegy %s+ napja ugyanabban az automatizmusban ragadt', s.name, s.n, thr('ac_stuck_days')::int),
         format('Aktív, be nem fejezett tagság %s napnál régebbről; a leghosszabb: %s nap.', thr('ac_stuck_days')::int, s.max_days),
         jsonb_build_object('contacts', s.n, 'max_days', s.max_days),
         'Nézd meg az automatizmus várakozási lépéseit és feltételeit az ActiveCampaignben; lehet, hogy egy feltétel soha nem teljesül.',
         s.n::numeric
  from (
    select da.automation_id, da.name, count(*) as n, max(extract(day from (p_now - a.added_at)))::int as max_days
    from fact_ac_contact_automation a join dim_ac_automation da using (automation_id)
    where a.removed_at is null and not coalesce(a.completed, false)
      and not (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements)
      and a.added_at < p_now - make_interval(days => thr('ac_stuck_days')::int)
    group by da.automation_id, da.name
  ) s where s.n >= thr('ac_stuck_min');

  -- magas kemény visszapattanás a legutóbbi kampányokon
  return query
  select 'ac_bounce_rate'::text, 'warning'::text, 'campaign'::text, p.campaign_id::text, coalesce(p.name, p.campaign_id::text),
         format('Magas visszapattanás: %s%% (%s db) egy kampányon', round(100 * p.hard_bounce_rate, 1), p.hard_bounces),
         format('%s kiküldésből %s kemény visszapattanás.', p.send_amt, p.hard_bounces),
         jsonb_build_object('send_amt', p.send_amt, 'hard_bounces', p.hard_bounces),
         'Tisztítsd a listát (kemény visszapattanók eltávolítása), és ellenőrizd a feliratkozás forrását; magas arány rontja a kézbesíthetőséget.',
         p.hard_bounces::numeric
  from mart_ac_campaign_performance p
  where p.send_amt >= thr('ac_bounce_min_send') and p.hard_bounce_rate >= thr('ac_bounce_rate')
    and p.sent_at >= p_now - interval '30 days';
end $$;

-- A meglévő adatminőségi ellenőrzés kiegészítése az AC-riasztásokkal (a refresh_alerts változatlan marad).
do $$ begin
  if exists (select 1 from pg_proc where proname = 'data_quality_core') then
    null;
  else
    alter function data_quality_alerts(timestamptz) rename to data_quality_core;
  end if;
end $$;

create or replace function data_quality_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language sql stable as $$
  select * from data_quality_core(p_now)
  union all
  select * from ac_alerts(p_now);
$$;

insert into alert_rule (insight_key, label, enabled, notify, cooldown_days) values
  ('ac_sync_gap', 'Lead az ActiveCampaignen kívül', true, true, 3),
  ('ac_stuck_contacts', 'Elakadt automatizmus-tagságok', true, false, 14),
  ('ac_bounce_rate', 'Magas visszapattanás', true, false, 14)
on conflict (insight_key) do nothing;

-- Jogosultságok
do $$
declare t text;
begin
  foreach t in array array['fact_ac_contact','dim_ac_automation','fact_ac_automation_daily','fact_ac_contact_automation','fact_ac_campaign_snapshot'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('drop policy if exists "auth read %1$s" on public.%1$I', t);
    execute format('create policy "auth read %1$s" on public.%1$I for select to authenticated using (true)', t);
  end loop;
end $$;
revoke all on lead_ac, lead_journey_ac, mart_ac_automation_progress, mart_ac_campaign_performance from anon;
grant select on lead_ac, lead_journey_ac, mart_ac_automation_progress, mart_ac_campaign_performance to authenticated;
revoke execute on function lead_ac_summary(date, date, text), ac_alerts(timestamptz) from public, anon;
grant execute on function lead_ac_summary(date, date, text) to authenticated;
