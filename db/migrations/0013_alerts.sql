-- Értesítési központ: riasztások életciklussal (új → látta → elhalasztva → megoldva), deduplikálással,
-- adatminőségi ellenőrzésekkel és kézbesítési sorral. Az insights() kimenetére épül.

insert into insight_threshold (key, value, note) values
  ('dq_stale_hours', 36, 'betöltés: ennyi óra sikeres futás nélkül már elavultnak számít'),
  ('dq_stale_critical_hours', 72, 'betöltés: ennyi óra után kritikus'),
  ('dq_min_leads', 10, 'lead-ellenőrzésekhez minimális leadszám az ablakban'),
  ('dq_utm_gap_share', 0.5, 'lead: ekkora arány felett a forrás nélküli leadek riasztást adnak'),
  ('dq_lead_drop', 0.5, 'lead: ekkora visszaesés a megelőző 7 naphoz képest riasztást ad')
on conflict (key) do nothing;

-- Melyik észrevétel legyen riasztás, és mennyi ideig ne térjen vissza egy megoldott riasztás.
create table if not exists alert_rule (
  insight_key text primary key,
  label text not null,
  enabled boolean not null default true,
  notify boolean not null default true,
  cooldown_days int not null default 7
);
insert into alert_rule (insight_key, label, enabled, notify, cooldown_days) values
  ('tracking_outage', 'Mérés kiesett', true, true, 1),
  ('spend_anomaly', 'Szokatlan napi költés', true, true, 3),
  ('click_session_gap', 'Kattintás és látogatás eltér', true, true, 7),
  ('waste_keyword', 'Pazarló kulcsszó', true, false, 14),
  ('creative_fatigue', 'Fáradó kreatív', true, false, 14),
  ('cpc_spike', 'CPC-ugrás', true, false, 7),
  ('booking_step_leak', 'Foglalási lépés lemorzsolódás', true, false, 14),
  ('budget_limited', 'Költségkeret-korlátos kampány', false, false, 14),
  ('rank_limited', 'Rangsor-korlátos kampány', false, false, 14),
  ('creative_loser', 'Gyenge kreatív', false, false, 14),
  ('search_term_opportunity', 'Új kulcsszó-lehetőség', false, false, 14),
  ('budget_change', 'Költségkeret-változás', false, false, 7),
  ('halo_effect', 'Csatornák közti együttmozgás', false, false, 14),
  ('ingestion_stale', 'Betöltés elavult', true, true, 1),
  ('ingestion_error', 'Betöltési hiba', true, true, 1),
  ('lead_utm_gap', 'Forrás nélküli leadek', true, false, 7),
  ('lead_drop', 'Leadszám visszaesés', true, true, 3)
on conflict (insight_key) do nothing;

create table if not exists alert (
  id bigserial primary key,
  fingerprint text not null unique,
  insight_key text not null,
  severity text not null check (severity in ('critical', 'warning', 'opportunity', 'info')),
  scope_type text,
  scope_id text,
  scope_label text,
  title text not null,
  detail text,
  recommendation text,
  evidence jsonb not null default '{}'::jsonb,
  impact numeric,
  status text not null default 'open' check (status in ('open', 'seen', 'snoozed', 'resolved')),
  snoozed_until timestamptz,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  seen_at timestamptz,
  resolved_at timestamptz,
  auto_resolved boolean not null default false,
  occurrences int not null default 1,
  notified_at timestamptz,
  notified_severity text
);
create index if not exists idx_alert_status on alert (status, severity);

-- Adatminőségi ellenőrzések; ugyanolyan alakú, mint az insights().
create or replace function data_quality_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable as $$
declare
  cur_from timestamptz := p_now - interval '14 days';
  w_cur timestamptz := p_now - interval '7 days';
  w_prev timestamptz := p_now - interval '14 days';
  n_cur int; n_prev int; n_total int; n_nosrc int;
begin
  -- betöltés elavult: volt már sikeres futás, de régen
  return query
  select 'ingestion_stale'::text,
         case when extract(epoch from (p_now - l.last_ok)) / 3600 >= thr('dq_stale_critical_hours') then 'critical' else 'warning' end,
         'job'::text, l.job, l.job,
         format('A „%s” betöltés %s órája nem futott le sikeresen', l.job, round(extract(epoch from (p_now - l.last_ok)) / 3600)),
         format('Utolsó sikeres futás: %s.', to_char(l.last_ok, 'YYYY-MM-DD HH24:MI')),
         jsonb_build_object('last_ok', l.last_ok, 'hours', round(extract(epoch from (p_now - l.last_ok)) / 3600)),
         'Nézd meg az ingestion_run naplót és a Windsor kapcsolatot; amíg nem fut, a számok elavultak.',
         null::numeric
  from (select job, max(finished_at) filter (where status = 'ok') as last_ok from ingestion_run group by job) l
  where l.last_ok is not null and extract(epoch from (p_now - l.last_ok)) / 3600 >= thr('dq_stale_hours');

  -- betöltési hiba: a legutóbbi futás hibás
  return query
  select 'ingestion_error'::text, 'warning'::text, 'job'::text, r.job, r.job,
         format('A „%s” legutóbbi futása hibára futott', r.job),
         left(coalesce(r.error, 'ismeretlen hiba'), 300),
         jsonb_build_object('run_id', r.id, 'started_at', r.started_at),
         'Nézd meg a hibaüzenetet; ha Windsor-kulcs vagy kvóta, azt a beállításoknál kell javítani.',
         null::numeric
  from (select distinct on (job) job, id, status, error, started_at from ingestion_run order by job, started_at desc, id desc) r
  where r.status = 'error';

  -- forrás nélküli leadek aránya
  select count(*), count(*) filter (where (utm is null or utm = '{}'::jsonb) and (click_ids is null or click_ids = '{}'::jsonb))
    into n_total, n_nosrc
  from fact_lead where created_at >= cur_from and created_at < p_now;
  if n_total >= thr('dq_min_leads') and n_nosrc::numeric / n_total > thr('dq_utm_gap_share') then
    return query
    select 'lead_utm_gap'::text, 'warning'::text, 'leads'::text, '14d'::text, 'Leadek forrás nélkül',
           format('A leadek %s%%-ának nincs forrása (UTM vagy click id)', round(100.0 * n_nosrc / n_total)),
           format('Az elmúlt 14 napban %s leadből %s-nek nem rögzült a forrás.', n_total, n_nosrc),
           jsonb_build_object('leads', n_total, 'without_source', n_nosrc),
           'Ellenőrizd a hirdetések URL-paramétereit és a GTM-szkriptet a lassjol.hu-n; forrás nélkül a hirdetés nem köthető a leadhez.',
           null::numeric;
  end if;

  -- leadszám visszaesés (7 nap a megelőző 7 naphoz képest)
  select count(*) filter (where created_at >= w_cur and created_at < p_now),
         count(*) filter (where created_at >= w_prev and created_at < w_cur)
    into n_cur, n_prev from fact_lead where created_at >= w_prev and created_at < p_now;
  if n_prev >= thr('dq_min_leads') and n_cur <= n_prev * (1 - thr('dq_lead_drop')) then
    return query
    select 'lead_drop'::text, 'critical'::text, 'leads'::text, '7d'::text, 'Leadszám',
           format('A leadek száma %s-ról %s-ra esett (7 nap a megelőző 7 naphoz)', n_prev, n_cur),
           'Ellenőrizd, hogy a hirdetések futnak-e, és hogy a foglaló app és az export működik-e, mielőtt keresleti okot keresel.',
           jsonb_build_object('current', n_cur, 'previous', n_prev),
           'Nézd meg a költést és a látogatószámot ugyanebben az időszakban, és az app hibanaplóját.',
           (n_prev - n_cur)::numeric;
  end if;
end $$;

-- Frissítés: összegyűjti az aktuális észrevételeket, és állapotot vezet.
create or replace function refresh_alerts(p_asof date default (current_date - 1), p_window int default 14, p_now timestamptz default now())
returns table (created int, updated int, reopened int, auto_resolved int)
language plpgsql as $$
declare
  n_new int := 0; n_upd int := 0; n_reopen int := 0; n_res int := 0;
  r record; ex alert%rowtype; fp text; sev_rank int; old_rank int;
begin
  create temp table if not exists _cur (fingerprint text primary key) on commit drop;
  truncate _cur;

  for r in
    select * from (
      select i.insight_key, i.severity, i.scope_type, i.scope_id, i.scope_label, i.title, i.detail, i.evidence, i.recommendation, i.impact
      from insights(p_asof, p_window) i
      union all
      select d.insight_key, d.severity, d.scope_type, d.scope_id, d.scope_label, d.title, d.detail, d.evidence, d.recommendation, d.impact
      from data_quality_alerts(p_now) d
    ) s
    join alert_rule ar on ar.insight_key = s.insight_key and ar.enabled
  loop
    fp := r.insight_key || '|' || coalesce(r.scope_type, '') || '|' || coalesce(r.scope_id, '');
    insert into _cur values (fp) on conflict do nothing;
    select * into ex from alert where fingerprint = fp;
    sev_rank := case r.severity when 'critical' then 3 when 'warning' then 2 when 'opportunity' then 1 else 0 end;

    if not found then
      insert into alert (fingerprint, insight_key, severity, scope_type, scope_id, scope_label, title, detail, recommendation, evidence, impact, first_seen_at, last_seen_at)
      values (fp, r.insight_key, r.severity, r.scope_type, r.scope_id, r.scope_label, r.title, r.detail, r.recommendation, coalesce(r.evidence, '{}'::jsonb), r.impact, p_now, p_now);
      n_new := n_new + 1;
    else
      old_rank := case ex.severity when 'critical' then 3 when 'warning' then 2 when 'opportunity' then 1 else 0 end;
      if ex.status = 'resolved' then
        -- megoldott riasztás csak a várakozási idő után tér vissza
        if ex.resolved_at is null or p_now >= ex.resolved_at + make_interval(days => (select cooldown_days from alert_rule where insight_key = ex.insight_key)) then
          update alert set status = 'open', resolved_at = null, auto_resolved = false, seen_at = null, snoozed_until = null,
                 notified_at = null, notified_severity = null, occurrences = occurrences + 1, last_seen_at = p_now,
                 severity = r.severity, title = r.title, detail = r.detail, recommendation = r.recommendation, evidence = coalesce(r.evidence, '{}'::jsonb), impact = r.impact
           where id = ex.id;
          n_reopen := n_reopen + 1;
        end if;
      elsif ex.status = 'snoozed' and (p_now >= ex.snoozed_until or sev_rank > old_rank) then
        update alert set status = 'open', snoozed_until = null, seen_at = null, notified_at = null, notified_severity = null,
               occurrences = occurrences + 1, last_seen_at = p_now, severity = r.severity, title = r.title, detail = r.detail,
               recommendation = r.recommendation, evidence = coalesce(r.evidence, '{}'::jsonb), impact = r.impact
         where id = ex.id;
        n_reopen := n_reopen + 1;
      elsif ex.status = 'seen' and sev_rank > old_rank then
        update alert set status = 'open', seen_at = null, notified_at = null, notified_severity = null, occurrences = occurrences + 1,
               last_seen_at = p_now, severity = r.severity, title = r.title, detail = r.detail, recommendation = r.recommendation,
               evidence = coalesce(r.evidence, '{}'::jsonb), impact = r.impact
         where id = ex.id;
        n_reopen := n_reopen + 1;
      else
        update alert set last_seen_at = p_now, title = r.title, detail = r.detail, recommendation = r.recommendation,
               evidence = coalesce(r.evidence, '{}'::jsonb), impact = r.impact,
               severity = case when sev_rank > old_rank then r.severity else alert.severity end
         where id = ex.id;
        n_upd := n_upd + 1;
      end if;
    end if;
  end loop;

  -- a már nem fennálló nyitott vagy látott riasztás magától megoldódik
  update alert a set status = 'resolved', resolved_at = p_now, auto_resolved = true
   where a.status in ('open', 'seen') and not exists (select 1 from _cur c where c.fingerprint = a.fingerprint);
  get diagnostics n_res = row_count;

  return query select n_new, n_upd, n_reopen, n_res;
end $$;

-- Kézi műveletek a felületről: látta / elhalaszt (napra) / megoldva / újranyit.
create or replace function alert_set_status(p_id bigint, p_status text, p_snooze_days int default 7)
returns alert language plpgsql security definer set search_path = public as $$
declare r alert;
begin
  if p_status not in ('open', 'seen', 'snoozed', 'resolved') then
    raise exception 'ismeretlen állapot: %', p_status;
  end if;
  update alert set
    status = p_status,
    seen_at = case when p_status = 'open' then null else coalesce(seen_at, now()) end,
    snoozed_until = case when p_status = 'snoozed' then now() + make_interval(days => greatest(coalesce(p_snooze_days, 7), 1)) else null end,
    resolved_at = case when p_status = 'resolved' then now() else null end,
    auto_resolved = false
  where id = p_id returning * into r;
  return r;
end $$;

-- Számlálók a harang-ikonhoz.
create or replace function alert_counts()
returns table (unread int, critical int, warning int, other int)
language sql stable as $$
  select count(*) filter (where status = 'open')::int,
         count(*) filter (where status = 'open' and severity = 'critical')::int,
         count(*) filter (where status = 'open' and severity = 'warning')::int,
         count(*) filter (where status = 'open' and severity in ('opportunity', 'info'))::int
  from alert;
$$;

-- Postaláda: a nyitott, látott és lejárt halasztású riasztások, súlyosság szerint.
create or replace view alert_inbox with (security_invoker = true) as
select a.*, ar.label as rule_label,
       case a.severity when 'critical' then 1 when 'warning' then 2 when 'opportunity' then 3 else 4 end as severity_rank
from alert a join alert_rule ar using (insight_key)
where a.status in ('open', 'seen') or (a.status = 'snoozed' and a.snoozed_until <= now());

-- Kézbesítési sor: amit még nem küldtünk ki (kritikus azonnal, a többi napi összefoglalóba).
create or replace view alert_to_notify with (security_invoker = true) as
select a.id, a.insight_key, a.severity, a.title, a.detail, a.recommendation, a.scope_type, a.scope_label, a.first_seen_at,
       (a.severity = 'critical') as immediate
from alert a join alert_rule ar using (insight_key)
where ar.notify and a.status = 'open'
  and (a.notified_at is null or coalesce(a.notified_severity, '') <> a.severity and a.severity = 'critical');

create or replace function alerts_mark_notified(p_ids bigint[])
returns int language sql security definer set search_path = public as $$
  with u as (update alert set notified_at = now(), notified_severity = severity where id = any(p_ids) returning 1)
  select count(*)::int from u;
$$;

-- Jogosultságok: csak bejelentkezett olvas; a szabályokat szerkesztheti; az állapotot a függvényekkel lehet módosítani.
alter table alert enable row level security;
alter table alert_rule enable row level security;
revoke all on alert, alert_rule from anon;
drop policy if exists "auth read alert" on alert;
create policy "auth read alert" on alert for select to authenticated using (true);
drop policy if exists "auth read alert_rule" on alert_rule;
create policy "auth read alert_rule" on alert_rule for select to authenticated using (true);
drop policy if exists "auth write alert_rule" on alert_rule;
create policy "auth write alert_rule" on alert_rule for all to authenticated using (true) with check (true);
revoke insert, update, delete on alert from authenticated;
revoke all on alert_inbox, alert_to_notify from anon;
grant select on alert_inbox, alert_to_notify to authenticated;
revoke execute on function alert_set_status(bigint, text, int), alerts_mark_notified(bigint[]) from public, anon;
grant execute on function alert_set_status(bigint, text, int), alert_counts() to authenticated;
