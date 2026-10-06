-- Asszisztens-beszélgetések: utolsó aktivitás szerinti rendezés, mappák (egymásba ágyazhatók), kitűzés, archiválás.
-- Csak a Lovable Cloud (Supabase) adatbázisra való; a meglévő assistant_conversation és assistant_message táblákra épül.
-- A mappák személyesek (nincs megosztott mappa). Törléskor a mappa tartalma a szülő mappába kerül, nem törlődik.

create table if not exists public.assistant_folder (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  parent_id uuid references public.assistant_folder (id) on delete set null,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  color text check (color is null or char_length(color) <= 20),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_assistant_folder_user on public.assistant_folder (user_id, parent_id, position);
-- Azonos szinten (azonos szülő alatt) nem lehet két azonos nevű mappa.
create unique index if not exists uq_assistant_folder_name
  on public.assistant_folder (user_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)));

alter table public.assistant_conversation
  add column if not exists last_activity_at timestamptz,
  add column if not exists last_opened_at timestamptz,
  add column if not exists folder_id uuid references public.assistant_folder (id) on delete set null,
  add column if not exists pinned boolean not null default false,
  add column if not exists archived_at timestamptz;

-- A meglévő beszélgetéseknél az utolsó aktivitás az utolsó üzenet ideje (üres beszélgetésnél a létrehozás ideje).
update public.assistant_conversation c
set last_activity_at = coalesce((select max(m.created_at) from public.assistant_message m where m.conversation_id = c.id), c.created_at)
where c.last_activity_at is null;
alter table public.assistant_conversation alter column last_activity_at set default now();
alter table public.assistant_conversation alter column last_activity_at set not null;

create index if not exists idx_assistant_conversation_list
  on public.assistant_conversation (user_id, archived_at, pinned desc, last_activity_at desc);
create index if not exists idx_assistant_conversation_folder on public.assistant_conversation (folder_id);

-- Új üzenet: a beszélgetés utolsó aktivitása frissül (a felület rendezése erre épül).
create or replace function public.assistant_touch_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.assistant_conversation set last_activity_at = greatest(coalesce(last_activity_at, new.created_at), new.created_at)
  where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists assistant_message_touch on public.assistant_message;
create trigger assistant_message_touch after insert on public.assistant_message
  for each row execute function public.assistant_touch_conversation();

-- Mappa-védelem: a szülő a saját mappa legyen, ne legyen kör, és legfeljebb 6 szint mély lehessen.
create or replace function public.assistant_folder_guard()
returns trigger language plpgsql set search_path = public as $$
declare cur uuid; depth integer := 1;
begin
  new.updated_at := now();
  if new.parent_id is null then return new; end if;
  if new.parent_id = new.id then raise exception 'A mappa nem lehet a saját szülője.'; end if;
  cur := new.parent_id;
  while cur is not null loop
    if cur = new.id then raise exception 'A mappa nem helyezhető a saját almappájába.'; end if;
    if not exists (select 1 from public.assistant_folder f where f.id = cur and f.user_id = new.user_id) then
      raise exception 'A szülő mappa nem található.';
    end if;
    depth := depth + 1;
    if depth > 6 then raise exception 'A mappák legfeljebb 6 szint mélyek lehetnek.'; end if;
    select f.parent_id into cur from public.assistant_folder f where f.id = cur;
  end loop;
  return new;
end $$;
drop trigger if exists assistant_folder_guard on public.assistant_folder;
create trigger assistant_folder_guard before insert or update of parent_id, user_id, name on public.assistant_folder
  for each row execute function public.assistant_folder_guard();

-- Mappa törlése: az almappák és a beszélgetések a szülő mappába kerülnek (a legfelső szintre, ha nincs szülő).
create or replace function public.assistant_folder_before_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.assistant_folder set parent_id = old.parent_id where parent_id = old.id;
  update public.assistant_conversation set folder_id = old.parent_id where folder_id = old.id;
  return old;
end $$;
drop trigger if exists assistant_folder_before_delete on public.assistant_folder;
create trigger assistant_folder_before_delete before delete on public.assistant_folder
  for each row execute function public.assistant_folder_before_delete();

-- A beszélgetés csak a saját mappájába kerülhet.
create or replace function public.assistant_conversation_folder_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.folder_id is not null and not exists (
    select 1 from public.assistant_folder f where f.id = new.folder_id and f.user_id = new.user_id) then
    raise exception 'A mappa nem található.';
  end if;
  return new;
end $$;
drop trigger if exists assistant_conversation_folder_guard on public.assistant_conversation;
create trigger assistant_conversation_folder_guard before insert or update of folder_id on public.assistant_conversation
  for each row execute function public.assistant_conversation_folder_guard();

alter table public.assistant_folder enable row level security;
revoke all on public.assistant_folder from anon;
grant select, insert, update, delete on public.assistant_folder to authenticated;
grant all on public.assistant_folder to service_role;
drop policy if exists folder_owner_all on public.assistant_folder;
create policy folder_owner_all on public.assistant_folder for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
