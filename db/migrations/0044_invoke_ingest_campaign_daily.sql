-- invoke_ingest: az új 'ingest-campaign-daily' útvonal engedélyezése (a kampány-szintű napi adat betöltéséhez, kézi visszatöltéshez és a napi ütemezéshez; 0043).
-- Csak a Lovable Cloud (Supabase) adatbázisra való. A függvény többi része és a jogosultságok változatlanok (a hívás pg_net-tel, az ingest-secrettel megy).
-- A cron-ütemezést ez a migráció NEM hozza létre; azt külön, a visszatöltés és az első sikeres napi futás után vesszük fel.

create or replace function public.invoke_ingest(p_route text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_base text; v_secret text;
begin
  if p_route not in ('ingest-ads','ingest-web','ingest-google-search','ingest-ads-dim','ingest-breakdowns','ingest-leads','ingest-ac','ingest-seo','ingest-alerts','ingest-social','ingest-dokirex','ingest-campaign-daily') then
    raise exception 'unknown ingest route %', p_route;
  end if;
  select value into v_base from public.private_settings where key = 'ingest_base_url';
  select value into v_secret from public.private_settings where key = 'ingest_secret';
  if v_base is null or v_secret is null then raise exception 'ingest_base_url or ingest_secret missing'; end if;
  return net.http_post(
    url := rtrim(v_base, '/') || '/' || p_route,
    headers := jsonb_build_object('Content-Type','application/json','x-ingest-secret', v_secret),
    body := p_body, timeout_milliseconds := 150000);
end $function$;

revoke execute on function public.invoke_ingest(text, jsonb) from public, anon, authenticated;
grant execute on function public.invoke_ingest(text, jsonb) to service_role;
