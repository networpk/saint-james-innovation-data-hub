-- Alkalmassági lead kiesés riasztás. Háttér: az alkalmassági kérdőív leadmentése 2026-09-22 után csendben leállt (az utolsó mentett lead 09-22),
-- miközben a kérdőív eredményoldalát továbbra is elérték a látogatók (09-29 óta 12 befejezett session). A hibát a felület nem jelezte.
-- Riasztás: ha az elmúlt 3 napban legalább N kérdőív-session eljutott az eredményig, de a mentett alkalmassági leadek aránya kicsi.

insert into insight_threshold (key, value, note) values
  ('quiz_lead_min_sessions', 5, 'alkalmassági lead-ellenőrzés: ennyi befejezett kérdőív-session az elmúlt 3 napban kell a riasztáshoz'),
  ('quiz_lead_min_ratio', 0.3, 'alkalmassági lead-ellenőrzés: ennyi lead / befejezett session arány alatt riasztás')
on conflict (key) do nothing;

create or replace function quiz_alerts(p_now timestamptz default now())
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable as $$
declare sessions_n bigint; leads_n bigint;
begin
  select count(*) into sessions_n from fact_quiz_session
  where (payload->>'completed') = 'true'
    and coalesce(nullif(payload->>'completed_at', '')::timestamptz, nullif(payload->>'started_at', '')::timestamptz) >= p_now - interval '3 days'
    and coalesce(nullif(payload->>'completed_at', '')::timestamptz, nullif(payload->>'started_at', '')::timestamptz) <= p_now;
  select count(*) into leads_n from fact_lead where source = 'quiz' and created_at >= p_now - interval '3 days' and created_at <= p_now;
  if sessions_n >= thr('quiz_lead_min_sessions') and leads_n::numeric / sessions_n < thr('quiz_lead_min_ratio') then
    return query
    select 'quiz_lead_gap'::text, 'critical'::text, 'quiz'::text, 'quiz_leads'::text, 'Alkalmassági leadek'::text,
           format('Az elmúlt 3 napban %s kérdőív ért az eredményig, de csak %s alkalmassági lead mentődött', sessions_n, leads_n),
           'A látogatók az eredményoldalt látják, de az adataik nem mentődnek el (vagy a mentés hibás). A felület ilyenkor nem jelez hibát.',
           jsonb_build_object('completed_sessions', sessions_n, 'leads', leads_n),
           'Ellenőrizd az alkalmassági kérdőív leadmentését (jogosultságok, RLS, a mentő kód hibaüzenetei).',
           (sessions_n - leads_n)::numeric;
  end if;
end $$;

insert into alert_rule (insight_key, label, enabled, notify, cooldown_days) values
  ('quiz_lead_gap', 'Alkalmassági leadek nem mentődnek', true, true, 1)
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
  union all select * from http_alerts(p_now)
  union all select * from quiz_alerts(p_now);
$$;

revoke execute on function quiz_alerts(timestamptz) from public, anon;
