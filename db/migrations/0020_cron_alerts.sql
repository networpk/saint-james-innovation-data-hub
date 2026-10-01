-- Ütemezett feladatok (pg_cron) hibáira riasztás. Háttér: a betöltők hibái az ingestion_run naplóba kerülnek, de ha a cron-hívás
-- már indulás előtt elbukik (pl. ismeretlen útvonal), ott nincs sor, és a hiba hosszú ideig észrevétlen marad.

insert into insight_threshold (key, value, note) values
  ('cron_fail_min', 2, 'ütemezett feladat: ennyi sikertelen futás az elmúlt 3 órában riasztást ad')
on conflict (key) do nothing;

create or replace function cron_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('cron.job_run_details') is null or to_regclass('cron.job') is null then return; end if;
  return query
  select 'cron_failing'::text, 'critical'::text, 'cron'::text, f.jobname::text, f.jobname::text,
         format('Az „%s” ütemezett feladat hibázik: %s sikertelen futás az elmúlt 3 órában', f.jobname, f.n),
         left(coalesce(f.msg, 'ismeretlen hiba'), 300),
         jsonb_build_object('failures', f.n, 'last_failure', f.last_at),
         'Nézd meg a hibaüzenetet (cron.job_run_details); amíg a feladat nem fut, a hozzá tartozó adatok elavulnak.',
         f.n::numeric
  from (
    select j.jobname, count(*) as n, max(d.start_time) as last_at, (array_agg(d.return_message order by d.start_time desc))[1] as msg
    from cron.job_run_details d join cron.job j on j.jobid = d.jobid
    where d.status = 'failed' and d.start_time >= p_now - interval '3 hours'
    group by j.jobname
  ) f
  where f.n >= thr('cron_fail_min');
end $$;

insert into alert_rule (insight_key, label, enabled, notify, cooldown_days) values
  ('cron_failing', 'Ütemezett feladat hibázik', true, true, 1)
on conflict (insight_key) do nothing;

create or replace function data_quality_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language sql stable as $$
  select * from data_quality_core(p_now)
  union all select * from ac_alerts(p_now)
  union all select * from tracking_alerts(p_now)
  union all select * from cron_alerts(p_now);
$$;

revoke execute on function cron_alerts(timestamptz) from public, anon;
