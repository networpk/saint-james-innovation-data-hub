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
- Ha a foglaló iframe-ben fut (van `EmbedSettings` / `redirectTop`), a paramétereket a **szülő oldalnak** kell továbbadnia (pl. `postMessage` vagy az iframe URL-jében átadott query) – ezt a weboldal oldalon is ellenőrizni kell.
- Új `leads` oszlopok (migráció): `utm jsonb`, `click_ids jsonb`, `landing_url text`, `referrer text`, `ga_client_id text`, `site text`, `first_touch_at timestamptz`.
- `booking-lead` és a kvíz lead-beküldés kapja meg és tárolja ezeket (whitelistezett kulcsok, hossz-korlát).
- Opcionális: GA4 `client_id` kiolvasása (`_ga` cookie), ha a GA4 script be van téve; a Meta Pixel/gtag jelenlétét a weboldal oldalán kell ellenőrizni.

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

## 6. Nyitott kérdések az app kapcsán

1. **Hol van beágyazva a foglaló/kvíz?** Iframe a weboldalon (saintjameshungary.hu / lassjol.hu) vagy önálló domain? Ettől függ az UTM-átadás módja.
2. **Van Meta Pixel / GA4 / Google Tag** a weboldalon és az appban? Melyik domainen fut a GA4?
3. **Dokirex API:** van-e végpont az előjegyzés státuszához (megjelent/lemondva) és a bevételhez az `elojegyzesId` alapján? Jelenleg az app csak `listSlots`, kezelések és foglalás hívásokat használ.
4. **Melyik márkához tartozik az app** (Saint James Szemészeti Központ vs. Lassjol)? A `site` mezőt ennek megfelelően kell kitölteni.
5. A `quiz_answers` és a foglalási `megjegyzés` mezők egészségügyi adatot tartalmazhatnak – a Hub-exportból kizárjuk; jóváhagyod?
6. Az app Supabase projektje (`beqqujyijevxmejzwgmn`) a Hub Supabase-éhez képest külön marad? (Javaslat: igen, a Hub külön projekt, és pull-lal olvassa az appét.)

## 7. Javasolt sorrend

1. **A + B** (attribúció + strukturált Dokirex azonosító) – kis, jól körülhatárolt Lovable-módosítás, azonnal elkezd gyűlni az értékes adat.
2. `leads_export` nézet + Hub-oldali ingestion.
3. **C + D** (eseménynapló, kvíz-összekötés).
4. Dokirex státusz-szinkron.
5. Szerver oldali konverziók (Meta CAPI / Google).

**Fontos:** az 1. lépés *után* érkező leadekre lesz attribúciónk; a meglévő leadek (UTM nélkül) csak becsülhetők (időablak + GA4/Windsor adatok alapján), ezért érdemes az 1. lépést minél előbb élesíteni.
