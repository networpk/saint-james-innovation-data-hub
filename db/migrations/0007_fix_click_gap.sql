-- 0007: a click_session_gap észrevétel csak akkor fusson, ha az ablakban van GA4-adat
-- (korábban, betöltött GA4-forgalom nélkül minden kampányra téves riasztást adott).
-- A teljes insights() függvény cseréje; a többi szabály változatlan.

create or replace function insights(p_asof date default (current_date - 1), p_window int default 14)
returns table (
  insight_key text, severity text, scope_type text, scope_id text, scope_label text,
  title text, detail text, evidence jsonb, recommendation text, impact numeric
) language plpgsql stable as $$
declare
  cur_from date := p_asof - p_window + 1;
  prev_from date := p_asof - 2 * p_window + 1;
  prev_to date := p_asof - p_window;
begin
  -- 1) Elköltött pénz konverzió nélkül (kulcsszó)
  return query
  select 'waste_keyword', 'warning', 'keyword', k.account_id || '|' || k.campaign_id || '|' || k.keyword_text, k.keyword_text,
         format('„%s”: %s Ft költés, 0 konverzió', k.keyword_text, to_char(round(k.sp), 'FM999 999 999')),
         format('%s napon %s kattintás és %s megjelenés, konverzió nélkül.', p_window, k.cl, k.im),
         jsonb_build_object('spend', k.sp, 'clicks', k.cl, 'impressions', k.im, 'campaign_id', k.campaign_id),
         'Nézd át a találatot: negatív kulcsszó, licitcsökkentés vagy szüneteltetés. Ellenőrizd a konverzió-mérést is, mielőtt döntesz.',
         k.sp
  from (select account_id, campaign_id, keyword_text, sum(spend) as sp, sum(clicks) as cl, sum(impressions) as im, sum(conversions) as cv
        from fact_keyword_daily where date between cur_from and p_asof group by 1,2,3) k
  where k.sp >= thr('waste_min_spend') and k.cv = 0;

  -- 2) Költségkeret-korlátos, hatékony Google-kampány
  return query
  with g as (
    select s.account_id, s.campaign_id, avg(s.budget_lost_share) as bl, avg(s.search_impression_share) as sis
    from fact_google_share_daily s where s.date between cur_from and p_asof group by 1,2
  ), p as (
    select f.account_id, f.campaign_id, sum(f.spend) as sp, sum(f.platform_leads) as cv
    from fact_ad_performance_daily f where f.platform = 'google' and f.date between cur_from and p_asof group by 1,2
  ), acc as (
    select account_id, sum(spend) / nullif(sum(platform_leads), 0) as cpa
    from fact_ad_performance_daily where platform = 'google' and date between cur_from and p_asof group by 1
  )
  select 'budget_limited', 'opportunity', 'campaign', 'google|' || g.account_id || '|' || g.campaign_id, c.campaign_name,
         format('„%s”: a költségkeret miatt elveszti a megjelenések %s%%-át', c.campaign_name, round(g.bl * 100)),
         format('Költség/konverzió: %s Ft, a fiók átlaga: %s Ft.', round(p.sp / nullif(p.cv, 0)), round(acc.cpa)),
         jsonb_build_object('budget_lost_share', round(g.bl, 4), 'impression_share', round(g.sis, 4), 'spend', p.sp, 'conversions', p.cv),
         'A kampány az átlagnál olcsóbban szerez konverziót, de a keret korlátozza: érdemes emelni a napi költségkeretet (lépcsőzve, figyelve a költség/konverziót).',
         p.sp * g.bl
  from g join p using (account_id, campaign_id) join acc using (account_id)
  left join campaign_class c on c.platform = 'google' and c.account_id = g.account_id and c.campaign_id = g.campaign_id
  where g.bl >= thr('budget_lost_min') and p.cv > 0 and p.sp / p.cv <= acc.cpa;

  -- 3) Rangsor-korlátos Google-kampány (gyenge hirdetés / licit / minőség)
  return query
  select 'rank_limited', 'warning', 'campaign', 'google|' || s.account_id || '|' || s.campaign_id, c.campaign_name,
         format('„%s”: a rangsor miatt elveszti a megjelenések %s%%-át', c.campaign_name, round(avg(s.rank_lost_share) * 100)),
         format('Megjelenési részesedés átlag: %s%%.', round(avg(s.search_impression_share) * 100)),
         jsonb_build_object('rank_lost_share', round(avg(s.rank_lost_share), 4), 'impression_share', round(avg(s.search_impression_share), 4)),
         'Hirdetésszövegek, céloldal-relevancia, minőségi mutató és licit áttekintése.',
         0::numeric
  from fact_google_share_daily s
  left join campaign_class c on c.platform = 'google' and c.account_id = s.account_id and c.campaign_id = s.campaign_id
  where s.date between cur_from and p_asof
  group by s.account_id, s.campaign_id, c.campaign_name
  having avg(s.rank_lost_share) >= thr('rank_lost_min');

  -- 4) CPC-ugrás az előző ablakhoz képest
  return query
  with w as (
    select f.platform, f.account_id, f.campaign_id,
           sum(f.spend) filter (where f.date >= cur_from) as sp_c, sum(f.clicks) filter (where f.date >= cur_from) as cl_c,
           sum(f.spend) filter (where f.date between prev_from and prev_to) as sp_p, sum(f.clicks) filter (where f.date between prev_from and prev_to) as cl_p
    from fact_ad_performance_daily f where f.date between prev_from and p_asof group by 1,2,3
  )
  select 'cpc_spike', 'warning', 'campaign', w.platform || '|' || w.account_id || '|' || w.campaign_id, c.campaign_name,
         format('„%s”: a CPC %s%%-kal nőtt', c.campaign_name, round((w.sp_c / w.cl_c) / (w.sp_p / w.cl_p) * 100 - 100)),
         format('CPC: %s Ft az előző %s Ft volt (%s napos ablakok).', round(w.sp_c / w.cl_c), round(w.sp_p / w.cl_p), p_window),
         jsonb_build_object('cpc_cur', round(w.sp_c / w.cl_c, 2), 'cpc_prev', round(w.sp_p / w.cl_p, 2), 'spend_cur', w.sp_c),
         'Nézd meg, történt-e licit-, célzás- vagy kreatívváltás, illetve nőtt-e a verseny (megjelenési részesedés, árverési adatok).',
         w.sp_c - w.cl_c * (w.sp_p / w.cl_p)
  from w left join campaign_class c on c.platform = w.platform and c.account_id = w.account_id and c.campaign_id = w.campaign_id
  where w.sp_c >= thr('cpc_min_spend') and w.cl_c > 0 and w.cl_p > 0
    and (w.sp_c / w.cl_c) / (w.sp_p / w.cl_p) - 1 >= thr('cpc_spike_pct');

  -- 5) Kreatív-fáradás
  return query
  select 'creative_fatigue', 'warning', 'ad', f.platform || '|' || f.ad_id, f.ad_name,
         format('„%s”: fáradó kreatív (CTR %s%%, gyakoriság +%s%%)', f.ad_name, round(f.ctr_change * 100), round(f.freq_change * 100)),
         format('A CTR %s%%-ról %s%%-ra esett, a gyakoriság %s-ról %s-ra nőtt.', round(f.ctr_prev * 100, 2), round(f.ctr_cur * 100, 2), f.freq_prev, f.freq_cur),
         jsonb_build_object('ctr_prev', f.ctr_prev, 'ctr_cur', f.ctr_cur, 'freq_prev', f.freq_prev, 'freq_cur', f.freq_cur, 'campaign', f.campaign_name),
         'Cserélj vagy frissíts kreatívot, bővítsd a közönséget, vagy csökkentsd a költést ezen a hirdetésen.',
         f.spend_cur
  from creative_fatigue(p_asof, greatest(p_window / 2, 3)) f
  where f.ctr_change <= -thr('fatigue_ctr_drop') and f.freq_change >= thr('fatigue_freq_rise');

  -- 6) Gyenge kreatív a saját kampányához képest
  return query
  with a as (
    select m.platform, m.account_id, m.campaign_id, m.ad_id, max(m.ad_name) as ad_name, max(m.campaign_name) as campaign_name,
           sum(m.spend) as sp, sum(m.impressions) as im, sum(m.clicks) as cl
    from mart_creative_daily m where m.date between cur_from and p_asof group by 1,2,3,4
  ), cg as (select platform, account_id, campaign_id, sum(cl)::numeric / nullif(sum(im),0) as ctr, count(*) as n from a group by 1,2,3)
  select 'creative_loser', 'info', 'ad', a.platform || '|' || a.ad_id, a.ad_name,
         format('„%s”: a kampány átlagának %s%%-át hozza CTR-ben', a.ad_name, round((a.cl::numeric / a.im) / cg.ctr * 100)),
         format('CTR %s%% a kampány %s%%-ához képest, %s Ft költéssel.', round(a.cl::numeric / a.im * 100, 2), round(cg.ctr * 100, 2), round(a.sp)),
         jsonb_build_object('ctr', round(a.cl::numeric / a.im, 5), 'campaign_ctr', round(cg.ctr, 5), 'spend', a.sp, 'campaign', a.campaign_name),
         'Fontold meg a szüneteltetést, vagy tedd át a költést a jobban teljesítő kreatívokra ugyanebben a kampányban.',
         a.sp
  from a join cg using (platform, account_id, campaign_id)
  where cg.n >= 2 and a.im >= thr('creative_min_impr') and a.sp >= thr('creative_min_spend')
    and (a.cl::numeric / a.im) < cg.ctr * thr('creative_loser_ratio');

  -- 7) Kattintás -> látogató veszteség kampányonként
  return query
  select 'click_session_gap', 'warning', 'campaign', f.platform || '|' || f.account_id || '|' || f.campaign_id, max(f.campaign_name),
         format('„%s”: a kattintások csak %s%%-ából lett mért látogatás', max(f.campaign_name), round(sum(f.sessions) / nullif(sum(f.clicks), 0) * 100)),
         format('%s kattintás, %s mért látogatás (GA4).', sum(f.clicks), sum(f.sessions)),
         jsonb_build_object('clicks', sum(f.clicks), 'sessions', sum(f.sessions)),
         case when sum(f.sessions) = 0
              then 'Nincs GA4 forgalom ehhez a kampányhoz: ellenőrizd a UTM-paramétereket / a kampánynév egyezését.'
              else 'Vizsgáld a céloldal betöltési sebességét, a követőkód működését és a rossz (véletlen) kattintásokat.' end,
         sum(f.clicks) - sum(f.sessions)
  from mart_campaign_funnel_daily f
  where f.date between cur_from and p_asof
  group by f.platform, f.account_id, f.campaign_id
  having sum(f.clicks) >= thr('click_session_min_clicks') and sum(f.sessions) / nullif(sum(f.clicks), 0) < thr('click_session_ratio')
     -- csak akkor jelzünk, ha az ablakban van betöltött GA4-forgalom (különben nem a követés hibás, hanem hiányzik az adat)
     and exists (select 1 from fact_web_daily w where w.date between cur_from and p_asof);

  -- 8) Követés-kiesés: van költés, de nincs mért látogató (a teljes tegnapi és tegnapelőtti napra)
  return query
  select 'tracking_outage', 'critical', 'day', d.dt::text, d.dt::text,
         format('%s: van hirdetési költés (%s Ft), de a GA4 nem mért látogatót', d.dt, round(d.sp)),
         'A weboldal-követés kiesett vagy késik.',
         jsonb_build_object('spend', d.sp, 'sessions', d.ss),
         'Ellenőrizd a GA4 / GTM működését és a Windsor-betöltést. A költés folyik, miközben a mérés vak.',
         d.sp
  from (
    select g.dt, coalesce(a.sp, 0) as sp, coalesce(w.ss, 0) as ss
    from generate_series(p_asof - 1, p_asof, interval '1 day') g(dt)
    left join (select date, sum(spend) as sp from fact_ad_performance_daily group by 1) a on a.date = g.dt::date
    left join (select date, sum(sessions) as ss from fact_web_daily group by 1) w on w.date = g.dt::date
  ) d
  where d.sp > 0 and d.ss = 0 and exists (select 1 from fact_web_daily);

  -- 9) Költés-anomália az azonos hétköznapok átlagához képest (platformonként)
  return query
  with d as (
    select platform, date, sum(spend) as sp from fact_ad_performance_daily group by 1,2
  ), base as (
    select x.platform, avg(y.sp) as avg_sp, count(y.sp) as n
    from (select platform from d group by 1) x
    left join d y on y.platform = x.platform and y.date in (p_asof - 7, p_asof - 14, p_asof - 21, p_asof - 28)
    group by 1
  )
  select 'spend_anomaly', case when t.sp / b.avg_sp >= thr('anomaly_ratio_hi') then 'warning' else 'critical' end,
         'platform', t.platform, t.platform,
         format('%s: a napi költés az azonos napok átlagának %s%%-a', t.platform, round(t.sp / b.avg_sp * 100)),
         format('%s Ft a szokásos ~%s Ft helyett (%s).', round(t.sp), round(b.avg_sp), p_asof),
         jsonb_build_object('spend', t.sp, 'baseline', round(b.avg_sp, 2)),
         'Nézd meg a költségkeret-, licit- és státuszváltozásokat (leállt vagy elszabadult kampány?).',
         abs(t.sp - b.avg_sp)
  from d t join base b on b.platform = t.platform
  where t.date = p_asof and b.n >= 3 and b.avg_sp > 0
    and (t.sp / b.avg_sp >= thr('anomaly_ratio_hi') or t.sp / b.avg_sp <= thr('anomaly_ratio_lo'));

  -- 10) Foglalási lépés-szivárgás
  return query
  with s as (
    select bs.ord, bs.step, bs.label, sum(m.leads_reached) as reached
    from mart_booking_step_daily m join booking_step bs on bs.step = m.step
    where m.day between cur_from and p_asof and bs.ord <= 6 group by 1,2,3
  ), n as (
    select s.*, lead(s.reached) over (order by ord) as next_reached from s
  )
  select 'booking_step_leak', 'warning', 'booking_step', n.step, n.label,
         format('A foglalásban a „%s” lépésnél esik ki a legtöbb: %s%%', n.label, round((1 - n.next_reached / n.reached) * 100)),
         format('%s elérte a lépést, %s jutott tovább.', n.reached, n.next_reached),
         jsonb_build_object('reached', n.reached, 'next', n.next_reached),
         'Nézd át ezt a képernyőt (mezők száma, hibaüzenetek, telefon / mobil használhatóság), és mérd az átfutási időt.',
         n.reached - n.next_reached
  from n
  where n.next_reached is not null and n.reached >= thr('step_leak_min_leads')
    and 1 - n.next_reached / n.reached >= thr('step_leak_drop');

  -- 11) Új kulcsszó-lehetőség: konvertáló keresési kifejezés, ami nem kulcsszó
  return query
  select 'search_term_opportunity', 'opportunity', 'search_term', t.account_id || '|' || t.search_term, t.search_term,
         format('„%s”: %s konverziót hozott, de nincs saját kulcsszava', t.search_term, round(t.cv, 1)),
         format('%s kattintás, %s Ft költés.', t.cl, round(t.sp)),
         jsonb_build_object('conversions', t.cv, 'clicks', t.cl, 'spend', t.sp),
         'Vedd fel pontos / kifejezés egyezésű kulcsszóként, hogy kontrollálni tudd a licitet és a hirdetésszöveget.',
         t.cv
  from (select account_id, search_term, sum(conversions) as cv, sum(clicks) as cl, sum(spend) as sp
        from fact_search_term_daily where date between cur_from and p_asof group by 1,2) t
  where t.cv >= thr('opp_min_conv') and t.cl >= thr('opp_min_clicks')
    and not exists (select 1 from fact_keyword_daily k where sj_norm(k.keyword_text) = sj_norm(t.search_term));

  -- 12) Költségkeret-változás (kampány-beállítások pillanatképéből)
  return query
  with b as (
    select platform, account_id, campaign_id,
           (array_agg(campaign_daily_budget order by date asc))[1] as b0,
           (array_agg(campaign_daily_budget order by date desc))[1] as b1
    from fact_campaign_setting_daily
    where date between cur_from and p_asof and campaign_daily_budget is not null group by 1,2,3
  )
  select 'budget_change', 'info', 'campaign', b.platform || '|' || b.account_id || '|' || b.campaign_id, c.campaign_name,
         format('„%s”: a napi költségkeret %s%%-kal változott', c.campaign_name, round((b.b1 / b.b0 - 1) * 100)),
         format('%s -> %s (napi).', round(b.b0), round(b.b1)),
         jsonb_build_object('from', b.b0, 'to', b.b1),
         'Ellenőrizd, hogy szándékos volt-e, és figyeld a következő napok teljesítményét (Meta: tanulási fázis).',
         abs(b.b1 - b.b0)
  from b left join campaign_class c on c.platform = b.platform and c.account_id = b.account_id and c.campaign_id = b.campaign_id
  where b.b0 > 0 and abs(b.b1 / b.b0 - 1) >= thr('budget_change_pct');

  -- 13) Hatás-összefüggés: a Meta/TikTok-költés és a Google brand-keresés késleltetett együttmozgása
  return query
  select 'halo_effect', 'info', 'signal_pair', c.signal_a || '>' || c.signal_b, c.signal_a || ' → ' || c.signal_b,
         format('%s és %s együtt mozog (késleltetés: %s nap, r = %s)', c.signal_a, c.signal_b, c.lag_days, c.r),
         format('Hétköznap-hatás nélkül, %s napon át, t = %s. Jelzésértékű összefüggés, nem bizonyíték az ok-okozatra.', c.n, c.t_stat),
         jsonb_build_object('lag_days', c.lag_days, 'r', c.r, 'n', c.n, 't', c.t_stat, 'r_lag0', c.r_lag0),
         'Ha a kapcsolat tartósan fennáll, a Meta/TikTok támogatja a brand-keresést: a két csatornát együtt érdemes tervezni és értékelni.',
         abs(c.r)
  from signal_correlations_best(p_asof - 59, p_asof, 10, true, 28, 3.0) c
  where c.signal_a in ('spend_meta','spend_tiktok','impressions_meta','impressions_tiktok','clicks_meta','clicks_tiktok')
    and c.signal_b in ('google_brand_impressions','google_brand_clicks') and c.r > 0.4
  order by c.r desc limit 3;
end $$;
