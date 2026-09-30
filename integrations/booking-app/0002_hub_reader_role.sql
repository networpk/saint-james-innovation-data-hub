-- Kézzel futtatandó a Supabase SQL editorban (service/owner joggal) az 0001 migráció UTÁN.
-- Lovable migrációs futtatójában nem biztos, hogy szerepkört lehet létrehozni, ezért külön van.
-- A jelszót a Supabase felületén állítsd be (ALTER ROLE hub_reader PASSWORD '...'), ne a repóban.

-- Külön, csak olvasó szerepkör a Hubnak (jelszót a Supabase felületén állítsd be, ne a repóban).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'hub_reader') then
    create role hub_reader login noinherit;
  end if;
end $$;
revoke all on public.leads from hub_reader;
grant usage on schema public to hub_reader;
grant select on public.leads_export to hub_reader;
grant select on public.quiz_sessions to hub_reader;

-- RLS: a hub_reader a kvíz-munkamenetek és események olvasásához policy-t kap (mindkét tábla PII-mentes).
alter table public.quiz_sessions enable row level security;
drop policy if exists "hub_reader read quiz_sessions" on public.quiz_sessions;
create policy "hub_reader read quiz_sessions" on public.quiz_sessions for select to hub_reader using (true);
drop policy if exists "hub_reader read lead_events" on public.lead_events;
create policy "hub_reader read lead_events" on public.lead_events for select to hub_reader using (true);
grant select on public.lead_events to hub_reader;
