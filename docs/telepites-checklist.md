# Élesítési checklist (ami emberi lépést igényel)

1. **Foglaló app publikálása (Lovable).** A Lovable az Edge Function-öket és az adatbázist azonnal élesíti, de a **böngészős (frontend) módosítások csak publikálás után** kerülnek fel a `saintjamesalkalamssagi.lovable.app`-ra. Publikálás előtt érdemes a preview-ban kipróbálni a foglalást.
2. **Script telepítése a lassjol.hu-ra.** `integrations/lassjol-parent/sj-attribution.js` → GTM → új *Custom HTML* tag (a tartalmat `<script>…</script>` közé téve), trigger: *All Pages*. Ellenőrzés: nyisd meg `https://lassjol.hu/?utm_source=teszt&utm_campaign=teszt&fbclid=abc` címet, majd az oldalon az iframe `src`-jében meg kell jelennie az `a_utm_source=teszt` paraméternek. Ha az iframe egy másik (egyedi) domainre kerül, a script `bookingOrigins` listáját és a Lovable app `ALLOWED_ORIGINS`-ét is bővíteni kell.
3. **Teszt lead** a lassjol.hu-n: a foglaló appban (admin) a lead sorában legyen `utm`, `click_ids`, `landing_url`. **Teszt foglalást a Dokirexben te indíts/töröld**, mi nem hozunk létre éles előjegyzést.
4. **`hub_reader` szerepkör** (`integrations/booking-app/0002_hub_reader_role.sql`) létrehozása az app adatbázisán + jelszó beállítása. Ha a Lovable Cloud nem ad közvetlen Postgres-hozzáférést, a tartalék út egy `hub-export` Edge Function tokenes végponttal (ezt még meg kell építeni).
5. **Hub környezeti változók** (`.env.example`): `HUB_DB_URL`, `WINDSOR_API_KEY`, `APP_DB_URL`. Utána: `npm run migrate`, `npm run ingest -- ads --days 30`, `npm run ingest -- leads`.
6. **Kampány-besorolás:** a `campaign_mapping` tábla feltöltése (kampány → pillér / formátum / funnel-szerep).
7. **Dokirex státusz:** kérdezd meg a szállítót / nézd a dokumentációt, van-e (nem publikus) végpont a foglalás státuszához és bevételéhez.
