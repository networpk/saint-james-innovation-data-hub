-- Csendes hibák: (1) az invoke_ingest pg_net-hívása „sikeres" a cron szerint, akkor is, ha a betöltő 401/500-at ad vagy időtúllépés van;
-- (2) ha a futtatókörnyezet leállít egy betöltőt, az ingestion_run sora örökre „running" marad.

insert into insight_threshold (key, value, note) values
  ('http_fail_min', 2, 'pg_net: ennyi nem 2xx válasz az elmúlt 3 órában riasztást ad'),
  ('run_stuck_minutes', 15, 'betöltés: ennyi perc után a „running" futást megakadtnak tekintjük és hibásra zárjuk')
on conflict (key) do nothing;

-- A megakadt futások lezárása: error státusz, így a meglévő „Betöltési hiba" riasztás is jelez, és az elavulás-ellenőrzés sem téved.
create or replace function ingestion_close_stuck(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with c as (
    update ingestion_run
       set status = 'error', finished_at = p_now,
           error = left(coalesce(error || ' | ', '') || format('időtúllépés: a futás %s perc után sem fejeződött be (megakadt vagy leállították)', round(thr('run_stuck_minutes'))), 500)
     where status = 'running' and started_at < p_now - make_interval(mins => thr('run_stuck_minutes')::int)
    returning 1)
  select count(*) into n from c;
  return n;
end $$;

-- pg_net: nem 2xx válaszok és időtúllépések (a válasz-tábla a pg_net-é, ~6 óráig őrzi; nélküle nincs hiba).
create or replace function http_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('net._http_response') is null then return; end if;
  return query execute $q$
    select 'http_failing'::text, 'critical'::text, 'http'::text, f.code, f.code,
           format('Az ütemezett betöltő-hívások %s sikertelen választ kaptak (%s) az elmúlt 3 órában', f.n, f.code),
           left(coalesce(f.msg, 'nincs hibaüzenet'), 300),
           jsonb_build_object('failures', f.n, 'last_failure', f.last_at),
           'A cron „sikeres" jelzése csak a kérés sorba állítását jelenti. Nézd meg a net._http_response tartalmát és a betöltő útvonal naplóját (401: titok eltér, 5xx: kód- vagy időkorlát-hiba).',
           f.n::numeric
    from (
      select coalesce(r.status_code::text, 'időtúllépés') as code, count(*) as n, max(r.created) as last_at,
             (array_agg(left(coalesce(r.error_msg, r.content), 300) order by r.created desc))[1] as msg
      from net._http_response r
      where r.created >= $1 - interval '3 hours'
        and (r.timed_out or r.error_msg is not null or r.status_code is null or r.status_code not between 200 and 299)
      group by 1
    ) f
    where f.n >= thr('http_fail_min')
  $q$ using p_now;
end $$;

insert into alert_rule (insight_key, label, enabled, notify, cooldown_days) values
  ('http_failing', 'Betöltő-hívás HTTP-hibával', true, true, 1)
on conflict (insight_key) do nothing;

create or replace function data_quality_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language sql stable as $$
  select * from data_quality_core(p_now)
  union all select * from ac_alerts(p_now)
  union all select * from tracking_alerts(p_now)
  union all select * from cron_alerts(p_now)
  union all select * from http_alerts(p_now);
$$;

-- A lezárás 10 percenként fut (ha van pg_cron); hiba esetén a migráció nem bukik el.
do $$
begin
  if to_regnamespace('cron') is not null then
    begin
      perform cron.unschedule('ingestion-close-stuck') where exists (select 1 from cron.job where jobname = 'ingestion-close-stuck');
      perform cron.schedule('ingestion-close-stuck', '*/10 * * * *', 'select public.ingestion_close_stuck()');
    exception when others then
      raise notice 'ingestion-close-stuck cron nem ütemezhető: %', sqlerrm;
    end;
  end if;
end $$;

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
    ('0022','http_alerts','function'), ('0022','ingestion_close_stuck','function')
  )
  select e.migration, e.object_name, e.kind,
         case e.kind
           when 'relation' then to_regclass('public.' || e.object_name) is not null
           else exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname = e.object_name)
         end
  from expected e order by e.migration, e.object_name;
$$;

revoke execute on function ingestion_close_stuck(timestamptz), http_alerts(timestamptz) from public, anon;
grant execute on function http_alerts(timestamptz) to authenticated;
