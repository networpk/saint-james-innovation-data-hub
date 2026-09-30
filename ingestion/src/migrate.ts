import fs from "node:fs";
import path from "node:path";
import { connect } from "./db.js";

const dir = path.resolve("db/migrations");
const db = connect(process.env.HUB_DB_URL, "HUB_DB_URL");
await db.query("create table if not exists schema_migration (name text primary key, applied_at timestamptz not null default now())");
const done = new Set((await db.query("select name from schema_migration")).rows.map((r) => r.name as string));
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".sql")).sort()) {
  if (done.has(f)) continue;
  console.log("migráció:", f);
  await db.query("begin");
  try {
    await db.query(fs.readFileSync(path.join(dir, f), "utf8"));
    await db.query("insert into schema_migration (name) values ($1)", [f]);
    await db.query("commit");
  } catch (e) {
    await db.query("rollback");
    throw e;
  }
}
await db.end();
