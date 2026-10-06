-- Szerepkörök és jogosultság (Hub admin panel): admin / elemzo / megtekinto.
-- Csak a Lovable Cloud (Supabase) adatbázisra való: az `auth` séma és az `auth.uid()` kell hozzá.
-- Ez az ALAP-lépés: nem módosít meglévő RLS-szabályt, és senkinek nem ad admin jogot (az a 0028-ban, külön jóváhagyással).

do $$ begin
  if not exists (select 1 from pg_type where typname = 'app_role') then
    create type public.app_role as enum ('admin', 'elemzo', 'megtekinto');
  end if;
end $$;

-- A szerep SOHA nem a profil- vagy felhasználó-táblában van, hogy ne lehessen jogot emelni.
create table if not exists public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (user_id, role)
);
create index if not exists idx_user_roles_user on public.user_roles (user_id);

create table if not exists public.role_audit (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  actor_email text,
  target_id uuid,
  target_email text,
  action text not null,           -- role_add, role_remove, invite, disable, enable, bootstrap
  role public.app_role,
  detail jsonb not null default '{}'::jsonb
);
create index if not exists idx_role_audit_at on public.role_audit (at desc);

-- Szerepellenőrzők: SECURITY DEFINER, hogy az RLS-szabályokban rekurzió nélkül használhatók legyenek.
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

create or replace function public.can_edit(_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role in ('admin', 'elemzo'))
$$;

-- Lead-szintű adat: admin és elemző láthatja, a megtekintő nem.
create or replace function public.can_read_leads(_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role in ('admin', 'elemzo'))
$$;

-- Bármely szerep (szerep nélküli fiók semmit nem lát).
create or replace function public.is_member(_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id)
$$;

revoke execute on function public.has_role(uuid, public.app_role), public.can_edit(uuid),
  public.can_read_leads(uuid), public.is_member(uuid) from public, anon;
grant execute on function public.has_role(uuid, public.app_role), public.can_edit(uuid),
  public.can_read_leads(uuid), public.is_member(uuid) to authenticated, service_role;

-- Az utolsó admin nem törölhető és nem fokozható le adatbázis-szinten sem.
create or replace function public.prevent_last_admin()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.role = 'admin'
     and (tg_op = 'DELETE' or new.role is distinct from 'admin' or new.user_id is distinct from old.user_id)
     and not exists (select 1 from public.user_roles where role = 'admin' and id <> old.id) then
    raise exception 'Az utolsó admin jogosultsága nem vehető el.' using errcode = 'P0001';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists user_roles_last_admin on public.user_roles;
create trigger user_roles_last_admin before delete or update on public.user_roles
  for each row execute function public.prevent_last_admin();

-- RLS: olvasni a saját szerepeket (az admin mindenkiét), írni csak a szerver (service role) tud, admin-ellenőrzés után.
alter table public.user_roles enable row level security;
alter table public.role_audit enable row level security;
revoke all on public.user_roles, public.role_audit from anon, authenticated;
grant select on public.user_roles, public.role_audit to authenticated;
grant all on public.user_roles, public.role_audit to service_role;
grant usage, select on sequence public.role_audit_id_seq to service_role;

drop policy if exists "own roles read" on public.user_roles;
create policy "own roles read" on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin'));

drop policy if exists "admin read audit" on public.role_audit;
create policy "admin read audit" on public.role_audit for select to authenticated
  using (public.has_role(auth.uid(), 'admin'));

-- A meglévő felhasználók elemző jogot kapnak, hogy a későbbi szigorítás senkit ne zárjon ki.
insert into public.user_roles (user_id, role)
select id, 'elemzo' from auth.users
on conflict (user_id, role) do nothing;
