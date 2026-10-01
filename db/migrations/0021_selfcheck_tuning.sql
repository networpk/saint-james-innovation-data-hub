-- Önellenőrzés: a migrációk által létrehozandó objektumok megvannak-e (pl. a 0018 egyszer kimaradt a Hubból, és csak később derült ki).
-- Riasztás-hangolás: a click_session_gap a GA4 hozzájárulás miatt eleve alulmér, ezért magasabb küszöb kell, hogy ne ez adja a riasztások felét.

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
    ('0020','cron_alerts','function')
  )
  select e.migration, e.object_name, e.kind,
         case e.kind
           when 'relation' then to_regclass('public.' || e.object_name) is not null
           else exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname = e.object_name)
         end
  from expected e order by e.migration, e.object_name;
$$;

-- Csak a hiányzók, riasztásként (a data_quality_alerts-be a 0021 nem nyúl; az Admin oldalon és a napi ellenőrzésben hívható).
create or replace function schema_missing()
returns table (migration text, object_name text, kind text)
language sql stable security definer set search_path = public as $$
  select migration, object_name, kind from schema_selfcheck() where not present;
$$;

-- Hangolás: ritkább, jelentősebb riasztás.
update insight_threshold set value = 300, note = coalesce(note, '') where key = 'click_session_min_clicks';
update insight_threshold set value = 0.35, note = coalesce(note, '') where key = 'click_session_ratio';

revoke execute on function schema_selfcheck(), schema_missing() from public, anon;
grant execute on function schema_selfcheck(), schema_missing() to authenticated;
