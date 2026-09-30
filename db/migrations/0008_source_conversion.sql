-- Forrás szerinti forgalom és konverzió: MINDEN GA4 forrás (fizetett, szerves, direkt, referral),
-- a kampányhoz nem köthető forgalommal együtt. A soft lead / űrlap (GA4 hard lead) eseményei forrásonként.
-- Nem a hirdetési kampányhoz illesztett nézet (az a mart_campaign_funnel_daily), hanem a teljes GA4-kép.
create or replace view mart_source_conversion_daily as
with w as (
  select w.date, coalesce(m.business_line, 'besorolatlan') as bl, w.source, w.medium, w.campaign,
         sum(w.sessions) as sessions, sum(w.users) as users,
         sum(w.engaged_sessions) as engaged_sessions, sum(w.engagement_seconds) as engagement_seconds
  from fact_web_daily w left join ga_property_map m on m.account_id = w.account_id
  group by 1,2,3,4,5
), e as (
  select e.date, coalesce(m.business_line, 'besorolatlan') as bl, e.source, e.medium, e.campaign,
         sum(e.event_count) filter (where fm.stage = 'soft_lead') as soft_leads,
         sum(e.event_count) filter (where fm.stage = 'ga_hard_lead') as ga_hard_leads
  from fact_web_event_daily e
  join funnel_event_map fm on fm.event_name = e.event_name and fm.stage in ('soft_lead', 'ga_hard_lead')
  left join ga_property_map m on m.account_id = e.account_id
  group by 1,2,3,4,5
)
select coalesce(w.date, e.date) as date, coalesce(w.bl, e.bl) as business_line,
       coalesce(w.source, e.source) as source, coalesce(w.medium, e.medium) as medium,
       coalesce(w.campaign, e.campaign) as campaign,
       coalesce(w.sessions, 0) as sessions, coalesce(w.users, 0) as users,
       coalesce(w.engaged_sessions, 0) as engaged_sessions, coalesce(w.engagement_seconds, 0) as engagement_seconds,
       coalesce(e.soft_leads, 0) as soft_leads, coalesce(e.ga_hard_leads, 0) as ga_hard_leads
from w full join e on e.date = w.date and e.bl = w.bl and e.source = w.source and e.medium = w.medium and e.campaign = w.campaign;

alter view mart_source_conversion_daily set (security_invoker = on);
revoke all on mart_source_conversion_daily from anon;
grant select on mart_source_conversion_daily to authenticated;
