import pg from "pg";

export function connect(url: string | undefined, name: string): pg.Pool {
  if (!url) throw new Error(`${name} nincs beállítva`);
  return new pg.Pool({ connectionString: url, max: 4 });
}

/** Sorok beszúrása/frissítése 500-as kötegekben. A sorok kulcsai az oszlopnevek. */
export async function upsertRows(
  db: pg.Pool,
  table: string,
  rows: Record<string, unknown>[],
  conflictCols: string[],
): Promise<number> {
  if (!rows.length) return 0;
  const cols = Object.keys(rows[0]!);
  const updateCols = cols.filter((c) => !conflictCols.includes(c));
  let total = 0;
  for (let i = 0; i < rows.length; i += 500) {
    const chunk = rows.slice(i, i + 500);
    const values: unknown[] = [];
    const tuples = chunk.map((r) => {
      const ph = cols.map((c) => {
        const v = r[c];
        values.push(v !== null && typeof v === "object" ? JSON.stringify(v) : v);
        return `$${values.length}`;
      });
      return `(${ph.join(",")})`;
    });
    const sql =
      `insert into ${table} (${cols.join(",")}) values ${tuples.join(",")} ` +
      `on conflict (${conflictCols.join(",")}) ` +
      (updateCols.length
        ? `do update set ${updateCols.map((c) => `${c}=excluded.${c}`).join(",")}, loaded_at=now()`
        : "do nothing");
    const res = await db.query(sql, values);
    total += res.rowCount ?? 0;
  }
  return total;
}

export async function withRun<T>(
  db: pg.Pool,
  job: string,
  range: { from?: string; to?: string },
  fn: () => Promise<number>,
): Promise<void> {
  const { rows } = await db.query(
    "insert into ingestion_run (job, date_from, date_to) values ($1,$2,$3) returning id",
    [job, range.from ?? null, range.to ?? null],
  );
  const id = rows[0].id as number;
  try {
    const n = await fn();
    await db.query("update ingestion_run set status='ok', finished_at=now(), rows_upserted=$2 where id=$1", [id, n]);
    console.log(`[${job}] ok, ${n} sor`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.query("update ingestion_run set status='error', finished_at=now(), error=$2 where id=$1", [id, msg.slice(0, 2000)]);
    throw e;
  }
}
