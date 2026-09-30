/**
 * Windsor.ai REST kliens.
 * FIGYELEM: a mezőnevek a Windsor MCP get_fields/get_data hívásokkal ellenőrzöttek (facebook, google_ads);
 * a REST végpont formátumát (connectors.windsor.ai/<connector>?api_key=...) a Windsor dokumentációja alapján használjuk,
 * éles kulccsal még ki kell próbálni.
 */
export interface WindsorQuery {
  connector: string;
  fields: string[];
  dateFrom: string;
  dateTo: string;
  accounts?: string[];
}

export type WindsorRow = Record<string, string | number | null>;

export async function fetchWindsor(apiKey: string, q: WindsorQuery): Promise<WindsorRow[]> {
  const url = new URL(`https://connectors.windsor.ai/${q.connector}`);
  url.searchParams.set("api_key", apiKey);
  url.searchParams.set("fields", q.fields.join(","));
  url.searchParams.set("date_from", q.dateFrom);
  url.searchParams.set("date_to", q.dateTo);
  if (q.accounts?.length) url.searchParams.set("select_accounts", q.accounts.join(","));

  let lastErr: unknown;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const res = await fetch(url);
      if (res.status === 429 || res.status >= 500) throw new Error(`Windsor HTTP ${res.status}`);
      if (!res.ok) throw new Error(`Windsor HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
      const json = (await res.json()) as unknown;
      const rows = Array.isArray(json) ? json : (json as { data?: unknown }).data;
      if (!Array.isArray(rows)) throw new Error("Windsor: váratlan válaszforma");
      return rows as WindsorRow[];
    } catch (e) {
      lastErr = e;
      if (e instanceof Error && /HTTP 4\d\d/.test(e.message) && !/429/.test(e.message)) throw e;
      await new Promise((r) => setTimeout(r, 2000 * 2 ** attempt));
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}
