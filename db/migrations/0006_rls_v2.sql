-- Jogosultságok az 0004/0005 objektumokra (Supabase szerepkörökkel: anon, authenticated, service_role).
-- Elv: csak bejelentkezett felhasználó olvashat; a beállító táblákat szerkesztheti; látogató semmit nem lát.

do $$
declare t text;
begin
  -- tény- és szótártáblák: olvasás bejelentkezve
  foreach t in array array[
    'fact_web_daily','fact_web_event_daily','fact_web_landing_daily','fact_keyword_daily','fact_search_term_daily',
    'fact_google_share_daily','dim_ad','fact_campaign_setting_daily','fact_ad_ranking_daily','fact_breakdown_daily',
    'booking_step','quiz_step','topic','topic_rule','ga_property_map','funnel_event_map','platform_source_map','insight_threshold'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('drop policy if exists "auth read %1$s" on public.%1$I', t);
    execute format('create policy "auth read %1$s" on public.%1$I for select to authenticated using (true)', t);
  end loop;

  -- szerkeszthető beállító táblák
  foreach t in array array['topic','topic_rule','ga_property_map','funnel_event_map','platform_source_map','insight_threshold'] loop
    execute format('drop policy if exists "auth write %1$s" on public.%1$I', t);
    execute format('create policy "auth write %1$s" on public.%1$I for all to authenticated using (true) with check (true)', t);
  end loop;

  -- nézetek: a hívó jogaival fussanak, látogató ne érje el
  foreach t in array array[
    'keyword_topic','search_term_topic','campaign_topic','ad_topic','mart_topic_daily','mart_keyword_daily',
    'mart_search_term_daily','mart_funnel_daily','mart_web_channel_daily','mart_booking_step_daily',
    'mart_booking_abandon_weekly','mart_quiz_step_reach','mart_lead_cohort_weekly','mart_lead_timing','mart_signals_long',
    'mart_campaign_funnel_daily','mart_web_campaign_unmatched','mart_creative_daily'
  ] loop
    execute format('alter view public.%I set (security_invoker = on)', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- függvények: látogató ne hívhassa, bejelentkezett igen
revoke execute on function public.signal_correlations(date,date,int,boolean,int) from public, anon;
revoke execute on function public.signal_correlations_best(date,date,int,boolean,int,numeric) from public, anon;
revoke execute on function public.creative_performance(date,date,text,text,numeric) from public, anon;
revoke execute on function public.creative_fatigue(date,int) from public, anon;
revoke execute on function public.insights(date,int) from public, anon;
grant execute on function public.signal_correlations(date,date,int,boolean,int) to authenticated;
grant execute on function public.signal_correlations_best(date,date,int,boolean,int,numeric) to authenticated;
grant execute on function public.creative_performance(date,date,text,text,numeric) to authenticated;
grant execute on function public.creative_fatigue(date,int) to authenticated;
grant execute on function public.insights(date,int) to authenticated;
