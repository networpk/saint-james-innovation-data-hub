-- Az apply_conversion_roles (0035) javítása: a platform_leads oszlop numeric(12,2), a konverziók összege 4 tizedes, ezért a tört értékű sorok
-- (Google adatvezérelt attribúció) minden futásnál „eltérőnek" látszottak, és feleslegesen újraíródtak (~250 sor/futás, értékváltozás nélkül).
-- Mostantól a kemény összeget 2 tizedesre kerekítve hasonlítja és írja. A soft számot (extra.soft_conversions) a korábbi módon, nem kerekítve őrizzük.
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0035 után fut. Nem ír át adatot, csak a függvényt cseréli.

create or replace function public.apply_conversion_roles(p_from date, p_to date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with agg as (
    select date, platform, account_id, campaign_id, adset_id, ad_id,
           round(coalesce(sum(conversions) filter (where role = 'hard'), 0), 2) as hard,
           coalesce(sum(conversions) filter (where role = 'soft'), 0) as soft
    from conversion_action_resolved
    where date between p_from and p_to
    group by 1, 2, 3, 4, 5, 6
  )
  update fact_ad_performance_daily t
     set platform_leads = a.hard,
         extra = coalesce(t.extra, '{}'::jsonb) || jsonb_build_object('soft_conversions', a.soft)
    from agg a
   where t.date = a.date and t.platform = a.platform and t.account_id = a.account_id and t.campaign_id = a.campaign_id
     and t.adset_id = a.adset_id and t.ad_id = a.ad_id
     and (t.platform_leads is distinct from a.hard
          or (t.extra ->> 'soft_conversions') is distinct from a.soft::text);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.apply_conversion_roles(date, date) from public, anon, authenticated;
grant execute on function public.apply_conversion_roles(date, date) to service_role;
