-- Az első adminok kiosztása. KÜLÖN, a felhasználó kifejezett jóváhagyásával futtatandó (a 0027 után).
-- Adatírás, nem séma: az adott e-mail-című fiókok admin szerepet kapnak, az eseményt a role_audit rögzíti.
-- Ha egy cím nem létezik az auth.users táblában, a sor kimarad; a lépés hibával áll meg, ha egyetlen admin sem jött létre.

with target as (
  select id, email from auth.users where lower(email) in ('peter@lemonshakers.io', 'viktor@lemonshakers.io')
), ins as (
  insert into public.user_roles (user_id, role)
  select id, 'admin' from target
  on conflict (user_id, role) do nothing
  returning user_id
)
insert into public.role_audit (actor_id, actor_email, target_id, target_email, action, role, detail)
select null, 'bootstrap', t.id, t.email, 'bootstrap', 'admin', '{"source":"0028_first_admins"}'::jsonb
from target t join ins on ins.user_id = t.id;

do $$ begin
  if not exists (select 1 from public.user_roles where role = 'admin') then
    raise exception 'Nem jött létre admin: ellenőrizd az e-mail-címeket az auth.users táblában.';
  end if;
end $$;
