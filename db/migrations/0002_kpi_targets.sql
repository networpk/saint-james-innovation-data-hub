-- Heti KPI-célok (a "Reports for Saint James" Excel "Target KPIs - Hard Leads" blokkja alapján, 2026).
create table if not exists kpi_target (
  year int not null,
  business_line text not null,          -- szemeszet | eszteika_plasztika
  segment text not null,                -- pl. 'Eyes Surgeries', 'Plastic Surgeries', 'Bleph'
  metric text not null,                 -- pl. 'hard_leads_weekly'
  target numeric(14,2) not null,
  note text,
  updated_at timestamptz not null default now(),
  primary key (year, business_line, segment, metric)
);

insert into kpi_target (year, business_line, segment, metric, target, note) values
  (2026, 'szemeszet', 'Eyes Surgeries', 'hard_leads_weekly', 182,
   'SMILE és One Stop Shop Meta: 260 000 Ft/hét nettó kampányonként; teljes heti max. 2,5 M Ft nettó; promo ajánlatok az elvesztett leadeknek remarketingként.'),
  (2026, 'eszteika_plasztika', 'Plastic Surgeries', 'hard_leads_weekly', 30,
   'Plasztikai konzultációs budget marad; arcinjekció és SkinPen: 150 000 Ft/hó nettó.'),
  (2026, 'eszteika_plasztika', 'Bleph', 'hard_leads_weekly', 8, null)
on conflict do nothing;
