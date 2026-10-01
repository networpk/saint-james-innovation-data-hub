# Változásnapló – Saint James Innovation Data Hub

Visszamenőleg összeállítva a git előzményekből és a Lovable-feladatok (PART) sorrendjéből. Minden dátum 2026. szeptember 30. – október 1. Az adatbázis-migrációk a `db/migrations/` mappában vannak, a tesztek a `db/tests/` mappában (jelenleg 22 sikeres teszt).

A „Lovable" jelölésű pontok a Hub projektben (UI és szerveroldali útvonalak) készülnek; a migrációkat a Lovable a rögzített commitból, ellenőrzőösszeggel futtatja.

## [Várakozik / folyamatban]
- **Dokirex:** megjelent/lemondott állapot és bevétel – a Dokirex válaszára vár (`docs/dokirex-kerdesek.md`).
- **Forrás-attribúció a foglaló appban:** az utolsó vizsgálatkor 0 leadnek volt UTM-je vagy click id-ja; a lassjol.hu GTM-szkriptjét ellenőrizni kell.
- **Meta-hirdetések UTM-címkéi:** a szemészeti költés kb. 15%-ánál, az esztétikai hirdetéseken szinte mindenhol hiányzik az `utm_campaign`.
- **Lovable PART 13–15:** „Ma/Tegnap" előbeállítás, ActiveCampaign réteg felülete, e-mail megtekintő és automatizmus-lépcső, teljesítmény-javítás.
- **Windsor:** a próbaidő lejárta előtt fizetős csomag kell.

## Foglaló: dataLayer-események (Lovable foglaló projekt, `b49a357`) – publikálásra vár
- Új `bookingTracking.ts`: csak az időpontfoglaló flow küld eseményt (`lead_created`, `appointment_booked`, `callback_requested`, lépés-események), `lead_id` és személyes adat nélkül, csak a `lassjol.hu` és `www.lassjol.hu` felé; a `booking-lead` válasza `created` jelzőt kapott. A kérdőív nem küld eseményt.
- A szülőoldali GTM-listener: `integrations/lassjol-parent/gtm-booking-events-listener.html`; dokumentáció és GTM-útmutató: `docs/foglalo-tracking-es-gtm-utmutato.md`.

## [0020] Ütemezett feladatok hibáira riasztás – `db/migrations/0020_cron_alerts.sql`
- Élő ellenőrzéskor kiderült, hogy az `ingest-leads`, `ingest-ac`, `ingest-alerts` és `ingest-seo` cron-hívások elbuknak („unknown ingest route"), így a leadek és az ActiveCampaign-adatok nem frissültek. Az új riasztás a `cron.job_run_details` hibáit figyeli.

## [0019] Google-kampányazonosító a leadből – `db/migrations/0019_google_campaign_id.sql`
- A Google automatikus címkézése az URL-be teszi a `gad_campaignid` paramétert; a `sj-attribution` szkript átadja a foglalónak, a Hub a leadet ezzel köti a Google-kampányhoz (`lead_journey.google_campaign_id`, `lead_google_campaign`), `utm_campaign` nélkül is.

## [0018] dataLayer-események és mérés-egyeztetés – `db/migrations/0018_datalayer_events.sql`
- A foglaló új eseményei (`appointment_booked`, `callback_requested`, lépés-események) bekerülnek a tölcsérbe.
- Napi egyeztetés a saját adatbázis és a GA4 között, lefedettség-mutató és riasztás (a GA4 hozzájárulás-függő, a saját adatbázis marad az igazság).

## [0017] ActiveCampaign: e-mail tartalom és automatizmus-lépcső – `db/migrations/0017_ac_emails_flow.sql`
- Kiküldött e-mailek tartalma (tárgy, előnézeti szöveg, HTML) és a kampányok valódi nevei (`campaign_label`), a `#434`-szerű azonosítók helyett.
- Automatizmus-lépcső: hányan jutnak el az n. lépésig, forrás szerinti bontásban (`ac_flow_steps`, `ac_flow_by_source`), az automatizmus e-mailjeivel (`ac_flow_emails`).
- Az AC nem ad lépésneveket, ezért a lépések sorszámmal szerepelnek.

## [0016] Teljesítmény – `db/migrations/0016_performance.sql`
- Az `insights()` több mint egy percig futott. Ok: a korrelációs motor minden jelpárt kiszámolt, és a jel-nézetet többször olvasta, a márka-kulcsszó téma kétszer számolódott.
- Javítás: a jel-nézet egyszer fut, a hatás-szabály csak a releváns jelpárokat számolja, a személyszintű lead-keresés indexet kapott. Az eredmény azonos a régivel (teszttel igazolva).

## [0015] ActiveCampaign réteg – `bc588c5`
- Névjegyek hash alapján a leadhez kötve (e-mail nem tárolódik), automatizmus-előrehaladás, kampány-arányok, három új riasztás (lead az AC-n kívül, elakadt tagságok, magas visszapattanás).
- Egészségügyi mezők nem kerülnek át.
- Első élő futás: 27 948 névjegy, 50 480 automatizmus-tagság; a 301 elmúlt 30 napi leadből 296 megvan az ActiveCampaignben.

## [0014] Lead-életút – `19dfd7c`
- Alkalmassági leadek és időpontfoglalások szétválasztva; végigvitte / félbehagyta / visszahívást kért; lépésenkénti idő; kvíz-lead és foglalás összekötése személy szintjén.
- Lovable PART 12.

## [0013] Értesítési központ – `ffb3a4c`
- Riasztások életciklussal (új, látta, elhalasztva, megoldva), duplikálás-védelem, várakozási idő, adatminőségi ellenőrzések, kézbesítési sor.
- Lovable PART 11: adatbázis, óránkénti frissítés és napi összefoglaló kész; az első futáskor 38 riasztás. A harang és a panel felülete építés alatt.

## [0012] SEO / Ahrefs – `1c9554f`
- Pillanatképek, CTR-görbe alapú lehetőségek (gyors nyeremény, fizetett–szerves átfedés, SEO-rés, kannibalizáció), minden üzletágon átívelő keresés (`entity_lookup`).
- Lovable PART 7: első betöltés 143 kulcsszó, 56 oldal (kb. 2 000 API-egység).
- Korlát: az Ahrefs a Windsoron át nem ad kulcsszó-ötleteket.

## [Dokirex – terv] – `413cd6c`
- A Dokirex API-dokumentáció elolvasva (read-only): nincs állapot-lekérdező végpont, a `LastID` jelentése nem dokumentált. Levélvázlat és megoldási terv a `docs/dokirex-kerdesek.md` fájlban.

## [0011] Kulcsszó-értékelés – `8bb9df1`
- Magyarázható döntés (folytasd / figyeld / csökkentsd / állítsd le / kevés adat) kulcsszavanként, heti előzménnyel.

## [0010] Keresés, kifejezések, téma-idővonal – `097c7ae`
- Kulcsszó- és keresésikifejezés-összesítő, globális keresés, téma-idővonal, GA4 mikro-események a tölcsérben.

## [0009] Kampány-összekötés azonosítóval – `440eb8a`
- A Meta kampány a GA4-hez név és azonosító alapján is illeszkedik (a UTM-ellenőrzés során derült ki); a GA4 tulajdonság üzletági besorolása javítva.

## [0008] Forrás szerinti konverzió – `a8131a6`
- Minden GA4 forrás (szerves és direkt is) a forrás-nézetben, események duplázás nélkül.

## [0007] Téves riasztás javítása – `0122d4a`
- Nem keletkezik „kattintás és látogatás eltér" riasztás, ha nincs betöltött GA4 adat (élő futáson derült ki).

## [0004–0006] Elemzési réteg (v2) – `8458750`, `1075f16`, `30c692c`
- Tölcsér, lemorzsolódás, kohorsz, téma-réteg, korrelációs motor késleltetéssel, kreatív-lista (Pareto, fáradás), kampány–forgalom összekötés, 13 szabályú észrevétel-motor, jogosultságok (csak bejelentkezett olvas).
- Hibajavítások útközben: korrelációs négyzetgyök hiba, azonos családú jelek kizárása.
- Lovable PART 1–6 és a 90 napos visszatöltés.

## [0001–0002] Alapok – `c2c1b8d`, `b8083f4`…`513c6eb`
- Tény-táblák (hirdetési teljesítmény, leadek, események, foglalások), KPI-célok, betöltő váz, koncepció, architektúra, ütemterv és heti riport terve.
- A Windsor-csatlakozók (Meta, Google, TikTok, GA4, Ahrefs) feltérképezve; az egészségügyi korlátozás miatt nincs Meta Pixel és konverziós visszacsatolás, csak saját mérés (`20e51ed`).

## Foglaló app (Lovable, külön projekt)
- Attribúció (`a_*` paraméterek és `postMessage`, utolsó érintés, 90 napos lejárat), strukturált Dokirex-azonosító, eseménynapló, `hub-export` végpont a Hubnak (PII nélkül). Szkript és GTM-kód: `integrations/lassjol-parent/` (`a69d2f2`, `cfdf1f1`, `ed71032`).

## Felület (Hub, Lovable)
- TikTok előnézetek tartós képekkel (PART 8), globális keresés javítása üzletág-váltással (PART 10), HU/EN nyelvváltó, kulcsszó-oldal historikus előzménnyel és döntésekkel.
