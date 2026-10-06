-- 2. szerepkör-migráció: RLS-szigorítás a 0027 (szerepkörök) és a 0028 (első adminok) UTÁN.
-- Csak a Lovable Cloud (Supabase) adatbázisra való.
-- Hatás: szerep nélküli fiók semmit nem lát; a megtekintő nem lát lead-szintű adatot, csak összesítést (overview_lead_counts);
-- írni csak admin/elemző tud; riasztásszabályt csak admin.
-- A betöltések service_role-lal futnak, az megkerüli az RLS-t, ezért nem érinti őket.
-- A mart_* és lead_* nézetek security_invoker-ek, így az alaptáblák szabályait követik.

-- 0) Biztonsági fék: admin nélkül nem fut (különben senki nem tudná kezelni a szerepeket).
do $$ begin
  if not exists (select 1 from public.user_roles where role = 'admin') then
    raise exception 'Nincs admin: előbb a 0028 (első adminok) fusson.';
  end if;
end $$;

-- Segéd: egy tábla ÖSSZES meglévő szabályát törli, hogy a régi „mindenki" szabály ne maradhasson meg (a szabályok összeadódnak).
create or replace function pg_temp.drop_all_policies(t text) returns void language plpgsql as $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
    execute format('drop policy %I on public.%I', p.policyname, t);
  end loop;
end $$;

-- 1) Olvasás: bármely szerep (is_member). Nem lead-szintű táblák.
do $$
declare t text;
begin
  foreach t in array array[
    'alert','booking_step','campaign_mapping','campaign_mapping_rule',
    'dim_ac_automation','dim_ac_campaign','dim_ac_message','dim_ad','dim_social_post',
    'fact_ac_automation_daily','fact_ac_campaign_snapshot','fact_ad_performance_daily',
    'fact_ad_ranking_daily','fact_breakdown_daily','fact_campaign_setting_daily',
    'fact_google_share_daily','fact_keyword_daily','fact_search_term_daily',
    'fact_seo_keyword_snapshot','fact_seo_overview_daily','fact_seo_page_snapshot',
    'fact_social_post_daily','fact_web_daily','fact_web_event_daily','fact_web_landing_daily',
    'funnel_event_map','ga_property_map','ingestion_run','insight_state','insight_threshold',
    'kpi_target','platform_source_map','quiz_step','seo_ctr_curve',
    'seo_domain_map','topic','topic_rule','alert_rule']
  loop
    perform pg_temp.drop_all_policies(t);
    execute format('create policy member_read on public.%I for select to authenticated using (public.is_member(auth.uid()))', t);
  end loop;
end $$;

-- 2) Lead-szintű és nyers adat: csak admin és elemző (can_read_leads). A megtekintő ezekből semmit nem olvas.
do $$
declare t text;
begin
  foreach t in array array['fact_lead','fact_lead_event','fact_quiz_session','fact_booking',
                           'fact_ac_contact','fact_ac_contact_automation','raw_windsor']
  loop
    perform pg_temp.drop_all_policies(t);
    execute format('create policy lead_read on public.%I for select to authenticated using (public.can_read_leads(auth.uid()))', t);
  end loop;
end $$;

-- 3) Írás: admin vagy elemző (can_edit).
do $$
declare t text;
begin
  foreach t in array array['campaign_mapping','campaign_mapping_rule','kpi_target',
                           'funnel_event_map','ga_property_map','insight_threshold',
                           'platform_source_map','seo_ctr_curve','topic','topic_rule']
  loop
    execute format('create policy editor_insert on public.%I for insert to authenticated with check (public.can_edit(auth.uid()))', t);
    execute format('create policy editor_update on public.%I for update to authenticated using (public.can_edit(auth.uid())) with check (public.can_edit(auth.uid()))', t);
    execute format('create policy editor_delete on public.%I for delete to authenticated using (public.can_edit(auth.uid()))', t);
  end loop;
end $$;

-- insight_state (Észrevételek állapota): elemző/admin írhat, a sor a sajátja.
create policy editor_insert on public.insight_state for insert to authenticated
  with check (public.can_edit(auth.uid()) and user_id = auth.uid());
create policy editor_update on public.insight_state for update to authenticated
  using (public.can_edit(auth.uid())) with check (public.can_edit(auth.uid()));

-- 4) Riasztásszabály: csak admin írhat (az olvasás a member_read).
create policy admin_write on public.alert_rule for all to authenticated
  using (public.has_role(auth.uid(), 'admin')) with check (public.has_role(auth.uid(), 'admin'));

-- 5) Asszisztens: csak lead-olvasó szerep (a /api/assistant szerveren is ellenőrzi).
drop policy if exists conv_owner_all on public.assistant_conversation;
create policy conv_owner_all on public.assistant_conversation for all to authenticated
  using (user_id = auth.uid() and public.can_read_leads(auth.uid()))
  with check (user_id = auth.uid() and public.can_read_leads(auth.uid()));

-- 6) Összesített lead-szám a megtekintőnek (Áttekintés kártyái és napi diagram), lead-szintű adat nélkül.
create or replace function public.overview_lead_counts(_from date, _to date, _business_line text default null)
returns table (day date, submitted integer, suitability integer, started integer, booked integer)
language sql stable security definer set search_path = public as $$
  select lj.day::date,
         (count(*) filter (where lj.lead_type = 'idopontfoglalas' and lj.submitted is true))::int,
         (count(*) filter (where lj.lead_type = 'alkalmassagi'))::int,
         (count(*) filter (where lj.lead_type = 'idopontfoglalas' and lj.submitted is not true))::int,
         (count(*) filter (where lj.outcome = 'foglalt'))::int
  from public.lead_journey lj
  where public.is_member(auth.uid())
    and lj.day between _from and _to
    and (_business_line is null or _business_line in ('mind', 'besorolatlan') or lj.business_line = _business_line)
  group by 1
  order by 1
$$;
revoke execute on function public.overview_lead_counts(date, date, text) from public, anon;
grant execute on function public.overview_lead_counts(date, date, text) to authenticated, service_role;

-- 7) Csak szerverről hívott definer függvény: a böngészőből ne legyen hívható.
revoke execute on function public.alerts_mark_notified(bigint[]) from public, anon, authenticated;

-- 8) Ellenőrzés: egyik érintett táblán sem maradhat „mindenki" szabály.
do $$
declare bad text;
begin
  select string_agg(tablename || '.' || policyname, ', ') into bad
  from pg_policies
  where schemaname = 'public'
    and tablename in ('alert','alert_rule','booking_step','campaign_mapping','campaign_mapping_rule','dim_ac_automation',
      'dim_ac_campaign','dim_ac_message','dim_ad','dim_social_post','fact_ac_automation_daily','fact_ac_campaign_snapshot',
      'fact_ad_performance_daily','fact_ad_ranking_daily','fact_breakdown_daily','fact_campaign_setting_daily',
      'fact_google_share_daily','fact_keyword_daily','fact_search_term_daily','fact_seo_keyword_snapshot',
      'fact_seo_overview_daily','fact_seo_page_snapshot','fact_social_post_daily','fact_web_daily','fact_web_event_daily',
      'fact_web_landing_daily','funnel_event_map','ga_property_map','ingestion_run','insight_state','insight_threshold',
      'kpi_target','platform_source_map','quiz_step','seo_ctr_curve','seo_domain_map','topic','topic_rule',
      'fact_lead','fact_lead_event','fact_quiz_session','fact_booking','fact_ac_contact','fact_ac_contact_automation','raw_windsor')
    and (coalesce(qual, '') = 'true' or coalesce(with_check, '') = 'true');
  if bad is not null then
    raise exception 'Megmaradt „mindenki" szabály: %', bad;
  end if;
end $$;

-- Nyitva hagyva, átnézendő: alert_set_status (definer, bármely szerep állíthat riasztás-állapotot), cron_alerts / http_alerts /
-- ingestion_close_stuck (definer, a riasztás-frissítés belső hívásai miatt itt nem vontuk vissza).
