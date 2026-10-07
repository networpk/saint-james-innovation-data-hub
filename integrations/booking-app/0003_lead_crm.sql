-- Időpontfoglaló: leadenkénti hívási státusz (CRM-szerű), hogy a recepció lássa, kit hívott fel.
-- A foglaló Lovable Cloud (Supabase) adatbázisára való. Meglévő táblát NEM módosít (a leads szabályai változatlanok).
-- Recepciós = a meglévő `staff` szerep (admin is használhatja). Írni csak a set_lead_status() függvényen át lehet, így a napló mindig konzisztens.

-- Státuszok: szerkeszthető törzstábla (a címkék később módosíthatók, új státusz felvehető).
create table if not exists public.lead_status (
  key text primary key,
  label text not null,
  category text not null check (category in ('hivas', 'beirva', 'lezart')),
  position integer not null default 0,
  is_open boolean not null default true,   -- a „Hívandó" listán marad-e
  active boolean not null default true
);

insert into public.lead_status (key, label, category, position, is_open) values
  ('hivva_1',               '1x hívva',                  'hivas',  10, true),
  ('hivva_2',               '2x hívva',                  'hivas',  20, true),
  ('hivva_3',               '3x hívva',                  'hivas',  30, true),
  ('ugyintezes_alatt',      'Ügyintézés alatt',          'hivas',  40, true),
  ('rossz_szam',            'Rossz szám',                'hivas',  50, true),
  ('email_kuldve',          'Email küldve',              'hivas',  60, true),
  ('o_fog_jelentkezni',     'Ő fog jelentkezni',         'hivas',  70, true),
  ('beirva_altalanos',      'Általánosra beírva',        'beirva', 110, false),
  ('beirva_gyerekszemeszet','Gyerekszemészetre beírva',  'beirva', 120, false),
  ('beirva_lencse',         'Lencsére beírva',           'beirva', 130, false),
  ('beirva_lezer',          'Lézerre beírva',            'beirva', 140, false),
  ('beirva_mutet',          'Műtétre beírva',            'beirva', 150, false),
  ('beirva_plasztika',      'Plasztikára beírva',        'beirva', 160, false),
  ('beirva_szemhej',        'Szemhéj beírva',            'beirva', 170, false),
  ('nem_alkalmas',          'Nem alkalmas',              'lezart', 210, false)
on conflict (key) do nothing;

-- Egy leadhez egy aktuális státusz.
create table if not exists public.lead_crm (
  lead_id uuid primary key references public.leads (id) on delete cascade,
  status_key text not null references public.lead_status (key),
  next_contact_at timestamptz,                         -- megbeszélt visszahívás időpontja (opcionális)
  note text check (note is null or char_length(note) <= 2000),
  last_contact_at timestamptz not null default now(),
  updated_by uuid,
  updated_by_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_lead_crm_status on public.lead_crm (status_key, updated_at desc);
create index if not exists idx_lead_crm_next on public.lead_crm (next_contact_at) where next_contact_at is not null;

-- Teljes előzmény: ki, mikor, mire állította át. A felhasználó törlése után is megmarad (nincs idegen kulcs a user_id-n).
create table if not exists public.lead_crm_log (
  id bigserial primary key,
  lead_id uuid not null references public.leads (id) on delete cascade,
  at timestamptz not null default now(),
  user_id uuid,
  user_name text,
  from_status text,
  to_status text not null,
  note text,
  next_contact_at timestamptz
);
create index if not exists idx_lead_crm_log_lead on public.lead_crm_log (lead_id, at desc);

-- Ki érheti el a hívási felületet: admin és recepciós (staff).
create or replace function public.crm_can_access(_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role::text in ('admin', 'staff'))
$$;

-- A státusz beállítása: csak ezen a függvényen át lehet írni. A felhasználó nevét a szerver tölti ki.
create or replace function public.set_lead_status(_lead_id uuid, _status text, _note text default null, _next_contact_at timestamptz default null)
returns public.lead_crm
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  uname text;
  prev text;
  result public.lead_crm;
begin
  if uid is null or not public.crm_can_access(uid) then
    raise exception 'Ehhez nincs jogosultságod.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.lead_status where key = _status and active) then
    raise exception 'Ismeretlen vagy inaktív státusz.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.leads where id = _lead_id and booking_stage = 'completed') then
    raise exception 'A lead nem található, vagy nem küldte el az adatait.' using errcode = 'P0002';
  end if;
  if _note is not null and char_length(_note) > 2000 then
    raise exception 'A megjegyzés legfeljebb 2000 karakter lehet.' using errcode = '22001';
  end if;

  select coalesce(nullif(btrim(p.full_name), ''), p.email, uid::text) into uname from public.profiles p where p.id = uid;
  select status_key into prev from public.lead_crm where lead_id = _lead_id;

  insert into public.lead_crm as c (lead_id, status_key, next_contact_at, note, last_contact_at, updated_by, updated_by_name, updated_at)
  values (_lead_id, _status, _next_contact_at, nullif(btrim(_note), ''), now(), uid, uname, now())
  on conflict (lead_id) do update
    set status_key = excluded.status_key,
        next_contact_at = excluded.next_contact_at,
        note = coalesce(excluded.note, c.note),
        last_contact_at = now(),
        updated_by = uid, updated_by_name = uname, updated_at = now()
  returning * into result;

  insert into public.lead_crm_log (lead_id, user_id, user_name, from_status, to_status, note, next_contact_at)
  values (_lead_id, uid, uname, prev, _status, nullif(btrim(_note), ''), _next_contact_at);
  return result;
end $$;

-- Hívási lista: csak az elküldött leadek (Küldés megnyomva); e-mail-cím nélkül (azt csak az admin látja a leads táblában).
-- Nézet-tulajdonos jogával fut, a hozzáférést a crm_can_access() szűri.
create or replace view public.lead_call_list as
select l.id as lead_id, l.name, l.phone, l.created_at, l.source, l.business_line,
       l.booking_details ->> 'treatment' as treatment,
       l.booking_details ->> 'doctor' as doctor,
       l.booking_details ->> 'date' as booking_date,
       l.booking_details ->> 'time' as booking_time,
       (l.dokirex_booking_id is not null) as has_dokirex_booking,
       c.status_key, s.label as status_label, s.category as status_category, coalesce(s.is_open, true) as is_open,
       c.next_contact_at, c.note, c.last_contact_at, c.updated_by_name, c.updated_at as status_updated_at,
       coalesce(s.position, 0) as status_position
from public.leads l
left join public.lead_crm c on c.lead_id = l.id
left join public.lead_status s on s.key = c.status_key
where l.booking_stage = 'completed' and public.crm_can_access(auth.uid());

-- Jogosultságok: írni csak a függvényen át, olvasni a nézeten át (és a naplót / törzstáblát).
alter table public.lead_status enable row level security;
alter table public.lead_crm enable row level security;
alter table public.lead_crm_log enable row level security;
revoke all on public.lead_status, public.lead_crm, public.lead_crm_log, public.lead_call_list from anon, authenticated;
grant select on public.lead_call_list to authenticated;
grant all on public.lead_status, public.lead_crm, public.lead_crm_log to service_role;
grant usage, select on sequence public.lead_crm_log_id_seq to service_role;

drop policy if exists crm_status_read on public.lead_status;
create policy crm_status_read on public.lead_status for select to authenticated using (public.crm_can_access(auth.uid()));
grant select on public.lead_status to authenticated;

drop policy if exists crm_log_read on public.lead_crm_log;
create policy crm_log_read on public.lead_crm_log for select to authenticated using (public.crm_can_access(auth.uid()));
grant select on public.lead_crm_log to authenticated;

revoke execute on function public.crm_can_access(uuid), public.set_lead_status(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.crm_can_access(uuid), public.set_lead_status(uuid, text, text, timestamptz) to authenticated, service_role;
