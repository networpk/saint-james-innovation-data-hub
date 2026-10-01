-- ActiveCampaign: kiküldött e-mailek tartalma (megnézhető), kampánynevek, és az automatizmusok lépcsőnkénti
-- nézete forrás szerinti bontásban (hova jutnak el a különböző forrásból érkezett leadek).

create table if not exists dim_ac_message (
  message_id bigint primary key,
  name text,
  subject text,
  preheader text,
  from_name text,
  html text,                              -- sablon, kontaktusonként nem személyre szabott; a megjelenítő sandboxolja
  loaded_at timestamptz not null default now()
);

create table if not exists dim_ac_campaign (
  campaign_id bigint primary key,
  label text,                             -- campaign_label: a kampány neve az AC-ben
  campaign_type text,
  automation_id bigint,                   -- ha az e-mail egy automatizmus része (campaign_automation)
  series_id bigint,
  base_message_id bigint,
  sent_at timestamptz,
  loaded_at timestamptz not null default now()
);
create index if not exists idx_dim_ac_campaign_auto on dim_ac_campaign (automation_id);
create index if not exists idx_ac_ca_auto_added on fact_ac_contact_automation (automation_id, added_at);

-- A kampány-teljesítmény nevekkel és tárgyakkal bővítve (a meglévő oszlopok változatlanok, az újak a végén).
create or replace view mart_ac_campaign_performance with (security_invoker = true) as
select s.campaign_id,
       coalesce(nullif(d.label, ''), nullif(s.name, ''), '#' || s.campaign_id) as name,
       s.sent_at, s.status, s.send_amt,
       s.unique_opens, s.verified_unique_opens, s.unique_link_clicks, s.unsubscribes, s.hard_bounces, s.soft_bounces,
       s.unique_opens::numeric / nullif(s.send_amt, 0) as open_rate,
       s.verified_unique_opens::numeric / nullif(s.send_amt, 0) as verified_open_rate,
       s.unique_link_clicks::numeric / nullif(s.send_amt, 0) as click_rate,
       s.unique_link_clicks::numeric / nullif(s.unique_opens, 0) as click_to_open_rate,
       s.unsubscribes::numeric / nullif(s.send_amt, 0) as unsubscribe_rate,
       s.hard_bounces::numeric / nullif(s.send_amt, 0) as hard_bounce_rate,
       m.message_id, m.subject, m.preheader, d.campaign_type, d.automation_id, da.name as automation_name
from fact_ac_campaign_snapshot s
left join dim_ac_campaign d on d.campaign_id = s.campaign_id
left join dim_ac_message m on m.message_id = d.base_message_id
left join dim_ac_automation da on da.automation_id = d.automation_id
where s.snapshot_date = (select max(snapshot_date) from fact_ac_campaign_snapshot x where x.campaign_id = s.campaign_id);

-- Egy kiküldött e-mail tartalma a részletező nézethez (tárgy, előnézeti szöveg, HTML).
create or replace function ac_campaign_email(p_campaign_id bigint)
returns table (campaign_id bigint, name text, subject text, preheader text, from_name text, html text, sent_at timestamptz, automation_name text)
language sql stable as $$
  select p.campaign_id, p.name, p.subject, p.preheader, m.from_name, m.html, p.sent_at, p.automation_name
  from mart_ac_campaign_performance p left join dim_ac_message m on m.message_id = p.message_id
  where p.campaign_id = p_campaign_id;
$$;

-- Névjegyenként a forrás: a legelső lead UTM-forrása, különben a click id típusa, az AC „csatorna" mezője, végül „ismeretlen".
create or replace view ac_contact_source with (security_invoker = true) as
select c.ac_contact_id, f.lead_id,
       coalesce(nullif(f.utm_source, ''), f.click_id_type, nullif(c.channel, ''), 'ismeretlen') as source,
       f.business_line
from fact_ac_contact c
left join lateral (
  select j.lead_id, j.utm_source, j.click_id_type, j.business_line
  from lead_journey j where j.person_key = c.email_hash and c.email_hash is not null
  order by j.created_at asc limit 1
) f on true;

-- Lépcső: egy automatizmusban hányan jutottak el legalább az n. lépésig (az AC lépésneveket nem ad, ezért sorszám).
create or replace function ac_flow_steps(p_automation_id bigint, p_from date default null, p_to date default null, p_source text default null)
returns table (step int, reached bigint, pct_of_entered numeric, lost_from_previous bigint, exited_here bigint)
language sql stable as $$
  with m as (
    select a.completed_elements as depth, a.total_elements,
           (a.removed_at is not null or coalesce(a.completed, false)) as ended
    from fact_ac_contact_automation a
    left join ac_contact_source s on s.ac_contact_id = a.ac_contact_id
    where a.automation_id = p_automation_id
      and (p_from is null or a.added_at::date >= p_from) and (p_to is null or a.added_at::date <= p_to)
      and (p_source is null or s.source = p_source)
  ), n as (select count(*) as entered, coalesce(max(total_elements), max(depth), 0) as steps from m),
  k as (select generate_series(0, (select steps from n)) as step)
  select k.step,
         (select count(*) from m where m.depth >= k.step),
         round((select count(*) from m where m.depth >= k.step)::numeric / nullif((select entered from n), 0), 4),
         case when k.step = 0 then 0
              else (select count(*) from m where m.depth >= k.step - 1) - (select count(*) from m where m.depth >= k.step) end,
         (select count(*) from m where m.depth = k.step and m.ended)
  from k order by k.step;
$$;

-- Forrásonként: hányan léptek be az automatizmusba, mennyire jutottak el átlagosan, hányan fejezték be.
create or replace function ac_flow_by_source(p_automation_id bigint, p_from date default null, p_to date default null)
returns table (source text, entered bigint, avg_depth numeric, median_depth numeric, avg_progress numeric, finished bigint, pct_finished numeric)
language sql stable as $$
  select coalesce(s.source, 'ismeretlen'), count(*),
         round(avg(a.completed_elements), 2),
         percentile_cont(0.5) within group (order by a.completed_elements),
         round(avg(a.completed_elements::numeric / nullif(a.total_elements, 0)), 3),
         count(*) filter (where coalesce(a.completed, false) or (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements)),
         round((count(*) filter (where coalesce(a.completed, false) or (coalesce(a.total_elements, 0) > 0 and a.completed_elements >= a.total_elements)))::numeric / count(*), 4)
  from fact_ac_contact_automation a
  left join ac_contact_source s on s.ac_contact_id = a.ac_contact_id
  where a.automation_id = p_automation_id
    and (p_from is null or a.added_at::date >= p_from) and (p_to is null or a.added_at::date <= p_to)
  group by coalesce(s.source, 'ismeretlen')
  order by count(*) desc;
$$;

-- Az automatizmus e-mailjei teljesítménnyel (a campaign_automation mező alapján).
create or replace function ac_flow_emails(p_automation_id bigint)
returns table (campaign_id bigint, name text, subject text, sent_at timestamptz, send_amt int, open_rate numeric, click_rate numeric, unsubscribe_rate numeric)
language sql stable as $$
  select p.campaign_id, p.name, p.subject, p.sent_at, p.send_amt, p.open_rate, p.click_rate, p.unsubscribe_rate
  from mart_ac_campaign_performance p where p.automation_id = p_automation_id order by p.sent_at nulls last, p.campaign_id;
$$;

-- Az automatizmusok listája a választóhoz: tagok, lépésszám, utolsó 30 napi belépők.
create or replace view mart_ac_automation_overview with (security_invoker = true) as
select da.automation_id, da.name, da.status,
       count(a.id) as members, coalesce(max(a.total_elements), 0) as steps,
       count(a.id) filter (where a.added_at >= now() - interval '30 days') as entered_30d
from dim_ac_automation da left join fact_ac_contact_automation a using (automation_id)
group by da.automation_id, da.name, da.status;

-- Jogosultságok
do $$
declare t text;
begin
  foreach t in array array['dim_ac_message','dim_ac_campaign'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('drop policy if exists "auth read %1$s" on public.%1$I', t);
    execute format('create policy "auth read %1$s" on public.%1$I for select to authenticated using (true)', t);
  end loop;
end $$;
revoke all on ac_contact_source, mart_ac_automation_overview, mart_ac_campaign_performance from anon;
grant select on ac_contact_source, mart_ac_automation_overview, mart_ac_campaign_performance to authenticated;
revoke execute on function ac_campaign_email(bigint), ac_flow_steps(bigint, date, date, text), ac_flow_by_source(bigint, date, date), ac_flow_emails(bigint) from public, anon;
grant execute on function ac_campaign_email(bigint), ac_flow_steps(bigint, date, date, text), ac_flow_by_source(bigint, date, date), ac_flow_emails(bigint) to authenticated;
