-- A GA4-audit szerint a Meta-forgalom egy része a kampány AZONOSÍTÓJÁVAL érkezik (utm_campaign={{campaign.id}}),
-- más része a kampány nevével. A kampány↔forgalom összekötés ezért név ÉS azonosító szerint is illeszt.
-- Bizonyíték: 30 nap alatt a Lassjol.hu-n ~1 150, a saintjameshungary.hu-n ~5 250 munkamenet érkezett azonosítóval.

create or replace view mart_campaign_funnel_daily as
with ad as (
  select f.date, f.platform, f.account_id, f.campaign_id,
         sum(f.spend) as spend, sum(f.impressions) as impressions, sum(f.clicks) as clicks,
         sum(f.platform_leads) as platform_leads
  from fact_ad_performance_daily f group by 1,2,3,4
), web as (
  select w.date, m.platform, w.campaign as raw_campaign, sj_norm(w.campaign) as cname,
         sum(w.sessions) as sessions, sum(w.users) as users, sum(w.engaged_sessions) as engaged_sessions,
         sum(w.engagement_seconds) as engagement_seconds
  from fact_web_daily w join platform_source_map m on m.ga_source = lower(w.source)
  where w.campaign <> '' group by 1,2,3,4
), ev as (
  select e.date, m.platform, e.campaign as raw_campaign, sj_norm(e.campaign) as cname,
         sum(e.event_count) filter (where fm.stage = 'soft_lead') as soft_leads,
         sum(e.event_count) filter (where fm.stage = 'ga_hard_lead') as ga_hard_leads
  from fact_web_event_daily e
  join platform_source_map m on m.ga_source = lower(e.source)
  join funnel_event_map fm on fm.event_name = e.event_name
  where e.campaign <> '' group by 1,2,3,4
), j as (
  select ad.*, c.campaign_name, c.business_line, c.category, c.subcategory, sj_norm(c.campaign_name) as cname_norm
  from ad left join campaign_class c on c.platform = ad.platform and c.account_id = ad.account_id and c.campaign_id = ad.campaign_id
)
select j.date, j.platform, j.account_id, j.campaign_id, j.campaign_name, j.business_line, j.category, j.subcategory,
       j.spend, j.impressions, j.clicks, j.platform_leads,
       coalesce(wn.sessions,0) + coalesce(wi.sessions,0) as sessions,
       coalesce(wn.users,0) + coalesce(wi.users,0) as users,
       coalesce(wn.engaged_sessions,0) + coalesce(wi.engaged_sessions,0) as engaged_sessions,
       coalesce(wn.engagement_seconds,0) + coalesce(wi.engagement_seconds,0) as engagement_seconds,
       coalesce(en.soft_leads,0) + coalesce(ei.soft_leads,0) as soft_leads,
       coalesce(en.ga_hard_leads,0) + coalesce(ei.ga_hard_leads,0) as ga_hard_leads
from j
-- név szerint (a név-alapú sor nem lehet egyszerre azonosító: a kettő nem fed át)
left join web wn on wn.date = j.date and wn.platform = j.platform and wn.cname = j.cname_norm and wn.raw_campaign <> j.campaign_id
left join ev  en on en.date = j.date and en.platform = j.platform and en.cname = j.cname_norm and en.raw_campaign <> j.campaign_id
-- azonosító szerint
left join web wi on wi.date = j.date and wi.platform = j.platform and wi.raw_campaign = j.campaign_id
left join ev  ei on ei.date = j.date and ei.platform = j.platform and ei.raw_campaign = j.campaign_id;

create or replace view mart_web_campaign_unmatched as
select w.date, m.platform, w.campaign, w.source, w.medium, sum(w.sessions) as sessions
from fact_web_daily w join platform_source_map m on m.ga_source = lower(w.source)
where w.campaign <> '' and w.campaign not in ('(not set)','(direct)','(organic)','(referral)','(cross-network)')
  and not exists (select 1 from campaign_class c where c.platform = m.platform
                  and (sj_norm(c.campaign_name) = sj_norm(w.campaign) or c.campaign_id = w.campaign))
group by 1,2,3,4,5;

-- A GA4-property → üzletág hozzárendelés javítása (a saintjameshungary.hu property forgalma a SAINTJAMESHUNGARY Meta-kampányokból
-- és a 556-030-7472 (esztétika) Google-fiók kampányaiból áll).
update ga_property_map set business_line = 'eszteika_plasztika', note = 'saintjameshungary.hu – esztétika/plasztika (audit alapján)'
where account_id = '490259280' and business_line is null;

alter view mart_campaign_funnel_daily set (security_invoker = on);
alter view mart_web_campaign_unmatched set (security_invoker = on);
revoke all on mart_campaign_funnel_daily, mart_web_campaign_unmatched from anon;
grant select on mart_campaign_funnel_daily, mart_web_campaign_unmatched to authenticated;
