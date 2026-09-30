import { connect } from "./db.js";
import { ingestAdPerformance, PLATFORMS, type PlatformKey } from "./jobs/adPerformance.js";
import { ingestLeads } from "./jobs/leads.js";

const isoDay = (d: Date) => d.toISOString().slice(0, 10);
const daysAgo = (n: number) => isoDay(new Date(Date.now() - n * 864e5));

/**
 * Használat:
 *   npm run ingest -- ads [--days 7] [--from YYYY-MM-DD --to YYYY-MM-DD] [--platform meta|google]
 *   npm run ingest -- leads
 */
const [job, ...rest] = process.argv.slice(2);
const flag = (n: string) => { const i = rest.indexOf(`--${n}`); return i >= 0 ? rest[i + 1] : undefined; };

const hub = connect(process.env.HUB_DB_URL, "HUB_DB_URL");
try {
  if (job === "ads") {
    const key = process.env.WINDSOR_API_KEY;
    if (!key) throw new Error("WINDSOR_API_KEY nincs beállítva");
    const to = flag("to") ?? isoDay(new Date());
    const from = flag("from") ?? daysAgo(Number(flag("days") ?? 7)); // 7 nap: a platformok utólag is korrigálnak
    const only = flag("platform") as PlatformKey | undefined;
    for (const p of Object.keys(PLATFORMS) as PlatformKey[]) {
      if (only && only !== p) continue;
      await ingestAdPerformance(hub, key, p, from, to);
    }
  } else if (job === "leads") {
    const app = connect(process.env.APP_DB_URL, "APP_DB_URL");
    try { await ingestLeads(hub, app); } finally { await app.end(); }
  } else {
    console.error("Ismeretlen feladat. Használat: ads | leads");
    process.exitCode = 1;
  }
} finally {
  await hub.end();
}
