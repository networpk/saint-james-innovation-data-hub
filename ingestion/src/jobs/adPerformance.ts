import type pg from "pg";
import { upsertRows, withRun } from "../db.js";
import { fetchWindsor, type WindsorRow } from "../windsor.js";

/** Platformonkénti Windsor-mezők (get_fields-szel ellenőrizve: facebook, google_ads). */
export const PLATFORMS = {
  meta: {
    connector: "facebook",
    fields: ["date", "account_id", "account_name", "campaign_id", "campaign", "adset_id", "adset_name", "ad_id", "ad_name",
      "spend", "impressions", "clicks", "reach", "frequency", "actions_lead"],
    leadField: "actions_lead",
    extra: ["reach", "frequency"],
  },
  google: {
    connector: "google_ads",
    fields: ["date", "account_id", "account_name", "campaign_id", "campaign", "ad_group_id", "ad_group_name",
      "spend", "impressions", "clicks", "conversions"],
    leadField: "conversions",
    extra: [],
  },
} as const;

export type PlatformKey = keyof typeof PLATFORMS;

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : Number(v) || 0);
const str = (v: unknown) => (v == null ? "" : String(v));

export function mapRow(platform: PlatformKey, r: WindsorRow) {
  const cfg = PLATFORMS[platform];
  const extra: Record<string, unknown> = {};
  for (const k of cfg.extra) if (r[k] != null) extra[k] = r[k];
  return {
    date: str(r.date).slice(0, 10),
    platform,
    account_id: str(r.account_id),
    campaign_id: str(r.campaign_id),
    adset_id: platform === "meta" ? str(r.adset_id) : str(r.ad_group_id),
    ad_id: platform === "meta" ? str(r.ad_id) : "",
    account_name: str(r.account_name) || null,
    campaign_name: str(r.campaign) || null,
    adset_name: (platform === "meta" ? str(r.adset_name) : str(r.ad_group_name)) || null,
    ad_name: platform === "meta" ? str(r.ad_name) || null : null,
    spend: num(r.spend),
    impressions: num(r.impressions),
    clicks: num(r.clicks),
    platform_leads: num(r[cfg.leadField]),
    extra,
  };
}

export async function ingestAdPerformance(
  db: pg.Pool, apiKey: string, platform: PlatformKey, dateFrom: string, dateTo: string,
): Promise<void> {
  await withRun(db, `ad_performance:${platform}`, { from: dateFrom, to: dateTo }, async () => {
    const cfg = PLATFORMS[platform];
    const rows = await fetchWindsor(apiKey, { connector: cfg.connector, fields: [...cfg.fields], dateFrom, dateTo });
    const mapped = rows.filter((r) => r.date && r.campaign_id).map((r) => mapRow(platform, r));
    // Azonos kulcsú sorok összevonása (Google: ad group szinten több sor is jöhet ugyanarra a kulcsra).
    const merged = new Map<string, ReturnType<typeof mapRow>>();
    for (const m of mapped) {
      const key = [m.date, m.platform, m.account_id, m.campaign_id, m.adset_id, m.ad_id].join("|");
      const prev = merged.get(key);
      if (!prev) merged.set(key, m);
      else { prev.spend += m.spend; prev.impressions += m.impressions; prev.clicks += m.clicks; prev.platform_leads += m.platform_leads; }
    }
    return upsertRows(db, "fact_ad_performance_daily", [...merged.values()],
      ["date", "platform", "account_id", "campaign_id", "adset_id", "ad_id"]);
  });
}
