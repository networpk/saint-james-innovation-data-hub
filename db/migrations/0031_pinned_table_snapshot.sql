-- 0031: kitűzött táblázat-pillanatkép (kind='table') a pinned_report táblán. A 0029 után fut, újrafuttatható.
-- Élő jelentésnél (kind='live') a tool kötelező, pillanatképnél (kind='table') a snapshot kötelező.
-- Az RLS-szabályok nem változnak: a lead_level oszlop a pillanatképre is érvényes.

alter table public.pinned_report add column if not exists kind text not null default 'live';
alter table public.pinned_report add column if not exists snapshot jsonb;
alter table public.pinned_report alter column tool drop not null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pinned_report_kind_check') then
    alter table public.pinned_report
      add constraint pinned_report_kind_check check (kind in ('live', 'table'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pinned_report_kind_payload_check') then
    alter table public.pinned_report
      add constraint pinned_report_kind_payload_check check (
        (kind = 'live' and tool is not null) or (kind = 'table' and snapshot is not null)
      );
  end if;
end $$;
