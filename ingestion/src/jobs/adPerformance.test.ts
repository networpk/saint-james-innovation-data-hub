import test from "node:test";
import assert from "node:assert/strict";
import { mapRow } from "./adPerformance.js";

test("meta sor leképezése (valós Windsor-mintából)", () => {
  const m = mapRow("meta", {
    date: "2026-09-28", account_id: "2060753947612996", campaign_id: "120248370477920714",
    campaign: "LASSJOL - SMILE - AO", spend: 33520, impressions: 29774, clicks: 2623, actions_lead: 0,
  });
  assert.equal(m.platform, "meta");
  assert.equal(m.spend, 33520);
  assert.equal(m.adset_id, "");
  assert.equal(m.platform_leads, 0);
});

test("google sor: ad group az adset oszlopba kerül", () => {
  const m = mapRow("google", { date: "2026-09-28", account_id: "1", campaign_id: "2", ad_group_id: "3", ad_group_name: "AG", spend: "12.5", impressions: 10, clicks: 1, conversions: 2 });
  assert.equal(m.adset_id, "3");
  assert.equal(m.spend, 12.5);
  assert.equal(m.platform_leads, 2);
});
