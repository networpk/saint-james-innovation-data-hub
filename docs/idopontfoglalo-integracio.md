# Időpontfoglaló app ↔ Data Hub integráció

Forrás: `networpk/saintjamesalkalamssagi` (Lovable, Vite + React + Supabase + Edge Functions), a `cd83dae` commit alapján átnézve (csak olvasás, az appon nem módosítottunk semmit).

## 1. Mit csinál ma az app (ténylegesen a kódból)

**Két tölcsér, egy `leads` tábla** (`source` oszlop különbözteti meg őket):
1. **Alkalmassági kvíz** (`/`) – eredménytípusok: Lencsecsere, Lézerműtét, ICLR, Lézer+Lencse, Nem alkalmas. Anonim munkamenet-követés a `quiz_sessions` táblában (lépés, eredmény, befejezett-e; szándékosan PII nélkül).
2. **Időpontfoglaló** (`/idopont`) – lépések: `contact → choice → treatment → calendar → confirm → done / callback`.

**Foglalási folyamat:**
- `booking-lead` Edge Function: `draft` (elérhetőség mentése azonnal, félbehagyás esetére is), `progress` (melyik lépésen tart, lépésenkénti másodperc – PII nélkül), `complete` (kezelés, orvos, dátum, idő).
- `dokirex` Edge Function: bejelentkezik a **Dokirex API-ra** (`api-v2.dokirex.hu`; az „DocuRex” = Dokirex), kezelések és szabad időpontok lekérése (csak *Szemészet*, max. 14 nap), majd **foglalás (`book`)** → `elojegyzesId`.
- `sync-activecampaign`: a leadeket ActiveCampaign listákba szinkronizálja (kvíz / foglalás / félbehagyott foglalás külön lista, tag, mezők).
- Admin felület: leads tábla, statisztika, kvíz-analitika, szerepkörök (admin/staff/viewer).

**`leads` tábla releváns mezői:** `id, name, phone, email, result_type, source, quiz_answers, booking_stage (contact|completed), booking_details (JSON: treatment, doctor, date, time, durationMinutes, note, submittedAt), booking_progress (JSON: lastStep, stepSeconds, totalSeconds), synced_to_ac, created_at, updated_at`.

## 2. Hiányosságok a Data Hub szempontjából (prioritás szerint)

| # | Hiány | Hatás | Súlyosság |
|---|---|---|---|
| 1 | **Nincs UTM / fbclid / gclid / ttclid / referrer / GA4 client ID rögzítés.** A kódban sehol nem olvassa ki az URL-paramétereket, és nincs Meta Pixel / gtag sem. | A lead **nem kapcsolható hirdetéshez** → nincs kampány-, pillér-, kreatív-szintű foglalás-attribúció. Ez az egész hub értékének a feltétele. | **Kritikus** |
| 2 | **A Dokirex `elojegyzesId` nincs strukturáltan a leaden.** Csak a `booking_details.note` szabad szövegébe kerül (`"Dokirex előjegyzés: 12345"`) és egy log-sorba. Az admin UI `booking_details.dokirex.{status, elojegyzesId}` szerkezetet olvas, de a betöltött kódban nem találtam, ami ezt írná. | A lead↔foglalás összekötés törékeny (szövegből kellene kiparszolni). Nincs Dokirex-státusz (megjelent / lemondta) sem visszacsatolva. | **Magas** |
| 3 | Kevés eseményszintű napló: csak az utolsó lépés és a lépésenkénti idő van meg, időbélyeges eseménysor nincs. | A lemorzsolódás lépésenként számolható, de az időbeli lefolyás (mikor, hányadszor tért vissza) nem. | Közepes |
| 4 | A kvíz és a foglaló **két külön azonosító-világ** (`quiz_sessions.session_id` vs `leads.id`); nincs kapcsolat a kvízmunkamenet és a később foglaló lead között. | A „kvíz → foglalás” út nem követhető (a kvíz-lead-ek külön sorok). | Közepes |
| 5 | Nincs szerver oldali konverzió-visszajelzés (Meta CAPI / Google Enhanced Conversions). | A platformok nem tudnak valódi foglalásra optimalizálni. | Később |
| 6 | A `leads` RLS: bármely *authenticated* felhasználó olvashat/módosíthat (régi policy; a szerepkörök később jöttek). | A Hub olvasó-fiókja ne „authenticated” általános user legyen, hanem külön, szűk jogú szerepkör. | Biztonsági |

> Adatvédelmi megjegyzés: az app kvíz-válaszokat (`quiz_answers`: szemüveg-dioptria, terhesség stb.) és a foglalásnál születési dátumot/nemet/megjegyzést kezel – **egészségügyi jellegű adat**. A Hub-ba ezek **nem** kerülnek át; csak a kezelés-kategória, eredménytípus és a hash-elt azonosító.

## 3. Célállapot: lead-életút

```
Hirdetés (Meta/Google/TikTok)
   │  kattintás: utm_*, fbclid/gclid/ttclid
   ▼
Weboldal → Foglaló/Kvíz app  ──(1) attribúció rögzítése az első betöltéskor
   │
   ├─ quiz_sessions ── lépések, eredmény
   ├─ leads (draft → completed) ── attribúció + booking_progress
   │
   ▼
Dokirex foglalás  ──(2) elojegyzesId strukturáltan a leaden
   │
   ▼
Dokirex státusz (megjelent / lemondta)  ──(3) Hub kérdezi le időszakosan
   │
   ▼
Data Hub: fact_lead, fact_lead_event, fact_booking, fact_lead_booking_link
```

## 4. Módosítási lista az appban (Lovable)

**A. Attribúció-rögzítés (kritikus)**
- Új kliens modul (`src/lib/attribution.ts`): az **első** oldalbetöltéskor kiolvassa `utm_source, utm_medium, utm_campaign, utm_content, utm_term, fbclid, gclid, ttclid, wbraid, gbraid`, `document.referrer`, landing URL, és elmenti `localStorage`-ba (first-touch megőrzése, + last-touch külön). Kvíz és foglaló is ugyanazt használja.
- **A foglaló iframe-ben fut → a paramétereket a szülő oldalnak kell átadnia** (iframe `src` query + `postMessage` origin-ellenőrzéssel) – lásd 6.1. Ehhez a szülő oldalra is kell egy kis script (GTM).
- Új `leads` oszlopok (migráció): `utm jsonb`, `click_ids jsonb`, `landing_url text`, `referrer text`, `ga_client_id text`, `fbp text`, `fbc text`, `site text`, `business_line text`, `first_touch_at timestamptz`.
- `booking-lead` és a kvíz lead-beküldés kapja meg és tárolja ezeket (whitelistezett kulcsok, hossz-korlát).
- GA4 `client_id`/`session_id` és Meta `_fbp/_fbc` átvétele a szülő oldaltól (a pixel/GA4 a szülő oldalon fut, nem az iframe-ben) – részletek a 6.1 fejezetben.

**B. Dokirex azonosító strukturáltan (magas)**
- A `complete` hívásnál a `dokirex` válasz `elojegyzesId`-ját ne csak a `note`-ba írjuk, hanem `booking_details.dokirex = { elojegyzesId, status: "booked", bookedAt }` formában (ezt az admin UI már így várja) **és** külön oszlopba: `leads.dokirex_booking_id bigint` (indexelve).
- A `BookingContainer` jelenleg a foglalás *után* hívja a `completeBookingLead`-et – a hibaág kezelése kell (ha a Dokirex foglalás sikerült, de a mentés nem, próbálja újra / jelezzen).

**C. Eseménynapló**
- Új tábla `lead_events (id, lead_id, session_id, event, step, meta jsonb, created_at)`; a `booking-lead progress` hívás mellé egy sor. Események: `funnel_view, contact_submitted, treatment_selected, slot_selected, booking_confirmed, booking_failed, callback_requested`.

**D. Kvíz ↔ foglalás összekötés**
- A kvíz `sessionId`-t a foglaló lead is kapja (`leads.quiz_session_id`), ha ugyanabból a böngészőből jön.

**E. Hub-hozzáférés (lásd 5.)**
- Külön, read-only Postgres szerepkör/nézetek, vagy webhook – lásd alább.

## 5. Hogyan kapcsolódik a Data Hub

**Elsődleges: pull a Supabase-ből (egyszerű, robusztus)** – a Hub ütemezett feladata olvassa:
- `leads_export` **nézet** (PII nélkül/hash-elve): `lead_id, created_at, updated_at, source, booking_stage, result_type, treatment, doctor, booking_date, booking_time, utm…, click_ids…, landing_url, referrer, ga_client_id, email_hash, phone_hash, dokirex_booking_id, booking_progress`.
- `lead_events`, `quiz_sessions` (már PII-mentes).
- Hitelesítés: külön szűk jogú szerepkör vagy service-kulcs a Hub szerver oldalán (soha nem a böngészőben); a nézetekre RLS.
- A `email_hash`/`phone_hash`: `sha256(lower(trim(email)))`, telefon E.164-re normalizálva – ugyanez kell majd a Meta CAPI/Google Enhanced Conversions-höz is.

**Kiegészítő: push webhook** az időkritikus eseményekre (pl. `booking_confirmed`) egy aláírt `POST /ingest/lead-event` végpontra – csak ha közel valós idejű riport kell.

**Dokirex oldal:** a Hub a meglévő Dokirex API-t olvassa a `dokirex_booking_id`-k státuszáért (megjelent/lemondta, bevétel, ha elérhető). Itt nyitott kérdés, hogy az API mit ad vissza (lásd 6.).

## 6. Tisztázott és nyitott kérdések

**Tisztázva**
- **Beágyazás: iframe** a weboldalon → lásd 6.1 (ez meghatározza az attribúció-átadás módját).
- **A weboldalon van Meta Pixel és GA4** – ezek a *szülő oldalon* futnak, nem az iframe-ben (az iframe-ben jelenleg nincs pixel/gtag) → lásd 6.1.
- **Két üzletág, ugyanaz a Saint James márka:** szemészet és esztétika/plasztika → a modellben `business_line` dimenzió kell (lásd 6.2).

**Frissítés (legutóbbi egyeztetés)**
- **Hatókör: egyelőre csak a szemészet.** Az esztétika/plasztika később jön; a `business_line` dimenziót ezért most is felvesszük (alapérték: `szemeszet`), de nem építünk hozzá külön forrást. Ezzel a 3. nyitott kérdés lezárva.
- **GA4 már be van kötve a Windsorban** (két property: saintjameshungary.hu, Lassjol.hu). Ez az *aggregált* weboldali riportot adja. A **lead-szintű** összekötéshez (melyik GA4 session → melyik lead) továbbra is kell a `client_id`/`session_id` átadása az iframe-nek (6.1), de ez már csak kiegészítő jel, nem blokkoló.
- **Lovable-kapcsolat él.** A workspace-ben két releváns projekt van: **Saint James ALkalmassági** (a foglaló/kvíz app, `4e4a2d01-…`, ugyanaz, mint a GitHub-repó) és **Saint James Clarity** (`02b7b4cd-…`, szemészeti landing oldal). A Clarity oldalon **nincs Pixel/GA4, nincs iframe, és az űrlapja csak demó** (nem küld sehová) – tehát a valódi, Pixelt/GA4-et futtató weboldal (ahova az iframe be van ágyazva) nem ez; valószínűleg a saintjameshungary.hu / lassjol.hu CMS-e. Ezt még egyeztetni kell.

**Még nyitott**
1. **Dokirex API – státusz és bevétel.** Az appban csak a kezelés-lista, a szabad időpont és a foglalás hívás szerepel; a státusz-végpont létezését a Dokirex dokumentációjában vagy a szállítónál kell ellenőrizni (keresendő: előjegyzés lekérdezése `elojegyzesId` alapján, státusz: megjelent/lemondva/nem jelent meg, számla/bevétel). Amíg ez nincs meg, a Hub a foglalásig (nem a megjelenésig) tud követni.
2. **Melyik domain/üzletág melyik?** A Windsor-ban két weboldal van (*saintjameshungary.hu*, *lassjol.hu*), és két Google Ads fiók (*Saint James*, *Saint James Vision and Aesthetics Center*). Kérlek add meg a pontos megfeleltetést: domain → üzletág → Meta/Google/GA4 fiók.
3. ~~Az esztétika/plasztika üzletág leadjei honnan érkeznek?~~ (későbbi fázis) Az app **kizárólag szemészeti** időpontokat kínál (a `dokirex` függvény fixen csak a „Szemészet” szakrendelést listázza). Ha az esztétika is ebbe az iframe-be megy, vagy külön űrlap/foglaló van, az másik adatforrás, és külön be kell kötni.
4. Az iframe-et beágyazó oldalakat (WordPress/egyéb CMS?) ki tudjuk-e egészíteni egy kis script-tel (tag manager)?
5. Egészségügyi jellegű mezők (`quiz_answers`, foglalási megjegyzés) kizárása a Hub-exportból – jóváhagyod?
6. Az app Supabase projektje külön marad a Hub-étól? (Javaslat: igen, a Hub pull-lal olvassa.)

### 6.1 Iframe + Pixel/GA4: hogyan jusson át az attribúció

Az iframe külön origin, ezért **nem látja** a szülő oldal URL-jét, UTM-jeit, cookie-jait, és a szülő Meta Pixel/GA4 sem fut benne. Emiatt az attribúciót a szülő oldalnak kell átadnia:

1. **Szülő oldali kis script** (Google Tag Manager-ből, ha van, különben közvetlenül): az oldalbetöltéskor kiolvassa az URL-ből `utm_*, fbclid, gclid, ttclid, wbraid, gbraid`, a `document.referrer`-t, a landing URL-t, az **`_fbp` és `_fbc` cookie-t** (Meta), a **GA4 `client_id`-t és `session_id`-t** (`_ga`, `_ga_<ID>`), és first-touch elv szerint elmenti a szülő domain `localStorage`-ába/cookie-jába.
2. **Átadás az iframe-nek – két módon együtt (redundancia):**
   - az iframe `src`-jéhez hozzáfűzi a paramétereket (`/idopont?utm_source=…&fbclid=…&ga_cid=…&fbp=…`) – ez megbízható, még ha a `postMessage` el is késik;
   - `postMessage` üzenet (`{type:"sj-attribution", …}`), amelyet az app csak az engedélyezett szülő origin-ekről fogad el (origin-ellenőrzés kötelező).
3. **Az app oldalán** az `attribution.ts` modul először a query-paramétereket olvassa, aztán a `postMessage`-et, és a `leads` sorral együtt menti.
4. **Platform-konverziók nincsenek.** Egészségügyi hirdetésnél a Meta felé nem küldünk Pixel/CAPI konverziót (a célzás és a mérés is korlátozott, és egészségügyi adat nem mehet platformnak). A mérés kizárólag first-party: UTM + click ID + saját lead + Dokirex foglalás, a Hubban összekötve.
5. **`_fbp/_fbc` átadása nem szükséges**, csak az UTM-ek, `fbclid`/`gclid` és (opcionálisan) a GA4 `client_id`.
6. **Hozzájárulás (consent):** a Pixel/GA4 használata és az azonosítók tárolása cookie-hozzájáruláshoz kötött. A szülő script csak akkor adhat át `_fbp/_fbc/client_id` értéket, ha a látogató a marketing/analitika sütiket elfogadta – az UTM-ek (nem személyes) átadhatók.

### 6.2 Üzletág-dimenzió

- Új dimenzió: `dim_business_line` (`szemeszet`, `eszteika_plasztika`), amelyet **minden tény** megkap: hirdetés (kampány → üzletág mapping), lead (`leads.business_line`, az app/iframe állítja be), foglalás, organikus poszt, GA4 property, Ahrefs domain.
- A dashboard elsődleges szűrője legyen az üzletág; a két üzletág külön KPI-célokat és külön pillér-listát kaphat.
- A kampánynév-konvencióba bekerül: `SJ_{ÜZLETÁG}_{platform}_{cél}_{pillér}_…` (pl. `SJ_SZEM_META_LEAD_LASER_…`, `SJ_ESZT_GADS_LEAD_…`).

## 6.3 Elkészült kész anyagok (ebben a repóban)

- `integrations/lassjol-parent/sj-attribution.js` – a **lassjol.hu**-ra (GTM Custom HTML) kerülő script; a `bookingOrigins` még kitöltendő az app valódi origin-jével.
- `integrations/booking-app/0001_attribution_and_events.sql` – migráció: attribúciós oszlopok, `dokirex_booking_id`, `lead_events`, `leads_export` nézet, read-only `hub_reader` szerepkör.
- `integrations/booking-app/lovable-prompts.md` – négy, sorban küldendő Lovable-prompt (még **nincs elküldve**).

## 7. Javasolt sorrend

1. **A + B** (attribúció + strukturált Dokirex azonosító) – kis, jól körülhatárolt Lovable-módosítás, azonnal elkezd gyűlni az értékes adat.
2. `leads_export` nézet + Hub-oldali ingestion.
3. **C + D** (eseménynapló, kvíz-összekötés).
4. Dokirex státusz-szinkron.
5. (Elvetve) Szerver oldali platform-konverziók – egészségügyi korlátozások miatt nem alkalmazzuk.

**Fontos:** az 1. lépés *után* érkező leadekre lesz attribúciónk; a meglévő leadek (UTM nélkül) csak becsülhetők (időablak + GA4/Windsor adatok alapján), ezért érdemes az 1. lépést minél előbb élesíteni.
