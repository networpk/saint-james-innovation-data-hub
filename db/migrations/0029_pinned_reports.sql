-- Kitűzött jelentések a főoldalon: az Asszisztens egy eszközhívásából mentett, újrafuttatható definíció (NEM pillanatkép).
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a 0027 (szerepkörök) után fut.
-- A definíció fehérlistás eszköznevet és típusos paramétereket tárol, SQL-t soha. A futtatás mindig a hívó saját jogával megy, ezért az RLS érvényes.

create table if not exists public.pinned_report (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  scope text not null default 'personal' check (scope in ('personal', 'shared')),
  title text not null check (char_length(title) between 1 and 120),
  tool text not null,                                   -- fehérlistás eszköznév, a szerver ellenőrzi
  tool_version integer not null default 1,
  params jsonb not null default '{}'::jsonb,            -- normalizált bemenet, from/to nélkül
  period jsonb not null default '{"mode":"selected"}'::jsonb,   -- selected | last_n_days {n} | fixed {from,to}
  columns jsonb,                                        -- látható oszlopok sorrendben; null = alapértelmezett
  sort jsonb,                                           -- {key, dir}
  lead_level boolean not null default false,            -- mentéskor a szerver tölti ki
  position integer not null default 0,
  source_message_id uuid references public.assistant_message (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_pinned_report_owner on public.pinned_report (owner_id, position);
create index if not exists idx_pinned_report_shared on public.pinned_report (scope) where scope = 'shared';

-- Személyes sorrend és elrejtés (a megosztott jelentéseknél is, a közös sorokat nem írja át).
create table if not exists public.pinned_report_order (
  user_id uuid not null references auth.users (id) on delete cascade,
  report_id uuid not null references public.pinned_report (id) on delete cascade,
  position integer not null,
  hidden boolean not null default false,
  primary key (user_id, report_id)
);

alter table public.pinned_report enable row level security;
alter table public.pinned_report_order enable row level security;
revoke all on public.pinned_report, public.pinned_report_order from anon;
grant select, insert, update, delete on public.pinned_report, public.pinned_report_order to authenticated;
grant all on public.pinned_report, public.pinned_report_order to service_role;

-- Saját (személyes) jelentések: teljes kezelés. Megosztottá tenni a saját sort nem lehet (az with check ezt tiltja).
drop policy if exists pr_own_all on public.pinned_report;
create policy pr_own_all on public.pinned_report for all to authenticated
  using (owner_id = auth.uid() and scope = 'personal')
  with check (owner_id = auth.uid() and scope = 'personal');

-- Megosztott jelentések olvasása: bármely szerep, de a lead-szintűt csak az látja, aki lead-adatot olvashat.
drop policy if exists pr_shared_read on public.pinned_report;
create policy pr_shared_read on public.pinned_report for select to authenticated
  using (scope = 'shared' and public.is_member(auth.uid())
         and (not lead_level or public.can_read_leads(auth.uid())));

-- Megosztott jelentések kezelése: csak admin.
drop policy if exists pr_shared_admin on public.pinned_report;
create policy pr_shared_admin on public.pinned_report for all to authenticated
  using (scope = 'shared' and public.has_role(auth.uid(), 'admin'))
  with check (scope = 'shared' and public.has_role(auth.uid(), 'admin'));

drop policy if exists pro_own on public.pinned_report_order;
create policy pro_own on public.pinned_report_order for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.pinned_report_touch()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists pinned_report_touch on public.pinned_report;
create trigger pinned_report_touch before update on public.pinned_report
  for each row execute function public.pinned_report_touch();
