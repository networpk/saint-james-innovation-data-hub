-- Időpontfoglaló app (Supabase) – attribúció, strukturált Dokirex azonosító, eseménynapló, Hub-export nézet.
-- Az appban (Lovable) kell lefuttatni migrációként. Egészségügyi adat (quiz_answers, megjegyzés, születési dátum) NEM kerül a nézetbe.

alter table public.leads
  add column if not exists utm jsonb,
  add column if not exists click_ids jsonb,
  add column if not exists first_touch jsonb,
  add column if not exists landing_url text,
  add column if not exists referrer text,
  add column if not exists ga_client_id text,
  add column if not exists parent_host text,
  add column if not exists business_line text not null default 'szemeszet',
  add column if not exists quiz_session_id uuid,
  add column if not exists dokirex_booking_id bigint;

create index if not exists idx_leads_dokirex_booking_id on public.leads (dokirex_booking_id);
create index if not exists idx_leads_quiz_session_id on public.leads (quiz_session_id);

create table if not exists public.lead_events (
  id bigserial primary key,
  lead_id uuid references public.leads(id) on delete cascade,
  session_id uuid,
  event text not null,
  step text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_lead_events_lead on public.lead_events (lead_id, created_at);
alter table public.lead_events enable row level security;
-- Írás csak service role-lal (Edge Function); nincs policy a felhasználóknak.

-- Hub-export nézet: PII nélkül, hash-elt azonosítókkal.
create or replace view public.leads_export as
select
  l.id as lead_id,
  l.created_at,
  l.updated_at,
  l.source,
  l.booking_stage,
  l.result_type,
  l.business_line,
  l.booking_details->>'treatment' as treatment,
  l.booking_details->>'doctor' as doctor,
  l.booking_details->>'date' as booking_date,
  l.booking_details->>'time' as booking_time,
  l.utm,
  l.click_ids,
  l.first_touch,
  l.landing_url,
  l.referrer,
  l.ga_client_id,
  l.parent_host,
  l.quiz_session_id,
  l.dokirex_booking_id,
  l.booking_progress,
  encode(extensions.digest(lower(trim(l.email)), 'sha256'), 'hex') as email_hash,
  encode(extensions.digest(regexp_replace(l.phone, '[^0-9+]', '', 'g'), 'sha256'), 'hex') as phone_hash
from public.leads l;

-- A nézet a leads tábla RLS-ét megkerüli (owner jogával fut), ezért a publikus API-szerepkörök NEM érhetik el.
revoke all on public.leads_export from anon, authenticated;
