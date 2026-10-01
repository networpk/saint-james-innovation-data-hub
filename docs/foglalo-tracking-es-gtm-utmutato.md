# Időpontfoglaló: mérés (dataLayer) és GTM-beállítási útmutató

Verzió: 2026. október 1. A foglaló alkalmazás kódja: Lovable projekt „Saint James ALkalmassági", commit `b49a357`. A szülőoldali listener: `integrations/lassjol-parent/gtm-booking-events-listener.html`.

---

## 1. Mi épült be az időpontfoglalóba

### Működés röviden
A foglaló a `lassjol.hu` oldalba ágyazott iframe-ben fut (`saintjamesalkalamssagi.lovable.app/idopont`). A foglalóban keletkező eseményeket egy közös modul (`src/lib/bookingTracking.ts`) küldi el `postMessage`-szel a szülőoldalnak (`https://lassjol.hu` és `https://www.lassjol.hu`). A szülőoldalon a GTM-ben futó listener ezeket a saját `dataLayer`-ébe teszi, innen kezelhetők a GA4, a Google Ads és (jóváhagyással) más címkék.

```
FOGLALÓ (iframe, lovable.app)  --postMessage-->  lassjol.hu GTM listener  -->  window.dataLayer  -->  GTM címkék
```

### Az események

| Esemény | Mikor indul | Extra mező | Konverzió? |
|---|---|---|---|
| `booking_step_view` | az 1–5. képernyő megjelenésekor (1 = elérhetőség, 2 = választás, 3 = kezelés, 4 = naptár, 5 = megerősítés) | `step` | nem |
| **`lead_created`** | az 1. képernyőn a **Küldés** után, **ha a háttér sikeresen mentette** az adatokat (név, e-mail, telefon, két kötelező jelölőnégyzet), és az új lead | – | **igen (lead)** |
| `booking_path_selected` | „Időpontot foglalok" választás | `path: "online_booking"` | nem |
| **`callback_requested`** | a visszahívás kérése **sikeres rögzítés után** | – | igen (külön, másodlagos) |
| `service_selected` | vizsgálat kiválasztva | – | nem |
| `appointment_slot_selected` | időpont kiválasztva | – | nem |
| **`appointment_booked`** | a foglalás a **Dokirexben ténylegesen létrejött** (azonosítót kapott) | – | **igen (foglalás)** |
| `booking_thankyou_view` | a köszönő képernyő megjelenésekor | `result: "appointment"` vagy `"callback"` | nem |

Minden esemény tartalmazza: `source: "saint_james_booking"`, `event`, `flow_id`.

### Fontos szabályok (amit a kód betart)
- **Lead pontosan egyszer:** a `lead_created`, az `appointment_booked` és a `callback_requested` folyamatonként (`flow_id`) legfeljebb egyszer indul. A `lead_created`-et a háttér is jelzi: a `booking-lead` függvény válaszában a `created: true` csak új lead beszúrásakor szerepel. Egy már meglévő (összevont) leadnél nincs új esemény.
- **A köszönő képernyők nem lead-események.** A 2–5. képernyő sem hoz létre új leadet.
- **Nincs személyes adat.** A dataLayerbe csak ezek kerülhetnek: `source`, `event`, `flow_id`, `step`, `path`, `result`. Nincs név, e-mail, telefon, születési dátum, nem, megjegyzés, vizsgálat neve, időpont, orvos és **nincs `lead_id`** sem. A modul és a szülőoldali listener is szűri ezt.
- **A kérdőív (alkalmassági teszt) nem küld eseményt.** Csak az időpontfoglaló flow mérődik.
- **Hibatűrő:** minden követő hívás `try/catch`-ben fut, egy hiba nem akaszthatja meg a foglalást.
- **A `flow_id`** egy véletlen azonosító, böngészőmunkamenetenként (`sessionStorage`), nem köthető személyhez.

### Mi nem változott
A foglalási folyamat, a Dokirex-hívások, az ActiveCampaign-szinkron, a lead létrehozása és összevonása és a felület.

### Függőségek
1. A frontend legyen publikálva (ellenőrzés: az `/idopont` oldalon a böngésző konzoljában `window.dataLayer` listát ad, benne `booking_step_view`).
2. A `booking-lead` háttérfüggvény legyen élesítve a `created` mezővel. Ha ez a régi verzió, a `lead_created` **soha nem indul** (a többi esemény igen).
3. A GTM-ben fusson **mindkét** tag: `sj-attribution` (a UTM-átadó) és a **Lovable Booking – iframe event listener**.

---

## 2. GTM-beállítási útmutató

Cél: a három fő esemény (lead, foglalás, visszahívás) és a lépés-események mérése GA4-ben és a Google Adsben, a foglaló dataLayer-eseményeire építve. A GTM-et mindig **Preview módban** teszteld, a közzététel előtt.

### 2.1 Előfeltételek
- Megvan a GA4 „Google tag" (konfiguráció) a lassjol.hu GTM-konténerében. A lenti GA4-eseménycímkék erre hivatkoznak.
- A **listener-tag** (Custom HTML) létezik: Trigger = **Initialization – All Pages** (vagy azok az oldalak, ahol a foglaló van). Csak egyszer legyen a weboldalon (ne GTM és Elementor egyszerre).
- A régi, köszönőoldal-alapú lead-konverzió **ki lesz kapcsolva** a 2.7 pont szerint.

### 2.2 Változók (Variables → User-Defined → Data Layer Variable)
Hozd létre ezeket (Data Layer Version 2):

| Név | Data Layer változó neve |
|---|---|
| `DLV - flow_id` | `flow_id` |
| `DLV - step` | `step` |
| `DLV - path` | `path` |
| `DLV - result` | `result` |

### 2.3 Eseményindítók (Triggers → New → Custom Event)
Típus: **Custom Event**, „Ez az esemény pontos egyezés" (nincs regex). Nevek:

| Trigger neve | Eseménynév |
|---|---|
| `CE - Lovable - Lead Created` | `lead_created` |
| `CE - Lovable - Appointment Booked` | `appointment_booked` |
| `CE - Lovable - Callback Requested` | `callback_requested` |
| `CE - Lovable - Step View` | `booking_step_view` |
| `CE - Lovable - Path Selected` | `booking_path_selected` |
| `CE - Lovable - Service Selected` | `service_selected` |
| `CE - Lovable - Slot Selected` | `appointment_slot_selected` |
| `CE - Lovable - Thank You View` | `booking_thankyou_view` |

### 2.4 GA4-eseménycímkék (Tags → New → Google Analytics: GA4 Event)
A konfigurációs címke mezőben a lassjol.hu GA4 Google tagje.

| Címke neve | GA4 eseménynév | Eseményparaméterek | Trigger |
|---|---|---|---|
| `GA4 - generate_lead (Lovable)` | `generate_lead` | `flow_id` = `{{DLV - flow_id}}` | Lead Created |
| `GA4 - appointment_booked` | `appointment_booked` | `flow_id` | Appointment Booked |
| `GA4 - callback_requested` | `callback_requested` | `flow_id` | Callback Requested |
| `GA4 - booking_step_view` | `booking_step_view` | `step` = `{{DLV - step}}`, `flow_id` | Step View |
| `GA4 - booking_path_selected` | `booking_path_selected` | `path` = `{{DLV - path}}` | Path Selected |
| `GA4 - service_selected` | `service_selected` | `flow_id` | Service Selected |
| `GA4 - appointment_slot_selected` | `appointment_slot_selected` | `flow_id` | Slot Selected |
| `GA4 - booking_thankyou_view` | `booking_thankyou_view` | `result` = `{{DLV - result}}` | Thank You View |

- A lépés-események funnel-elemzésre valók (nem konverziók).
- **Consent:** minden címkénél a Beállítások → Haladó beállítások → Hozzájárulás-ellenőrzés legyen bekapcsolva az `analytics_storage` feltétellel (ha a consent-megoldás ezt használja).
- A paraméterek GA4-ben csak akkor láthatók riportban, ha az Admin → Egyéni definíciók alatt felveszed őket (`step`, `path`, `result`, `flow_id`).

### 2.5 Kulcseseménynek jelölés GA4-ben
GA4 → Admin → **Events** (Események) → jelöld **Key event**-nek (kulcsesemény):
- `generate_lead`
- `appointment_booked`
- `callback_requested` (ha másodlagosként akarod követni)

Az események csak az első beérkezés után jelennek meg a listában; ehhez egy teszt-esemény kell.

### 2.6 Google Ads konverziók (Google Ads → Goals → Conversions)
Az alábbiakhoz Google Ads Conversion Tracking címkék kellenek a GTM-ben (Conversion ID és Conversion Label a konverziós műveletből):

| Konverziós művelet | Trigger | Megjegyzés |
|---|---|---|
| Lead | Lead Created | **Elsődleges** (Primary) |
| Appointment Booked | Appointment Booked | külön, saját érték nélkül (vagy a szokásos érték) |
| Callback | Callback Requested | **Másodlagos** (Secondary), hogy ne duplázza a leadet |

- A konverziós címkék consent-feltétele: `ad_storage`.
- **Egészségügyi hirdetés:** a konverziós adatok megosztása egészségügyi hirdetőknél jogi kérdés is. A beállítás előtt egyeztess a klinika adatvédelmi felelősével. Személyes adatot (e-mail, telefon) ne adj át a címkének.

### 2.7 A régi lead-konverzió kikapcsolása (dupla mérés ellen)
Előtte nézd meg:
- Van-e régi GTM-trigger a köszönőoldalra, amely `generate_lead` eseményt vagy Google Ads Lead konverziót küld? (Triggers → keress: thank, köszön, `generate_lead`.)
- Van-e a Google Adsben olyan Lead konverziós művelet, amelyet a régi köszönőoldal-címke tölt?

Ha igen, kapcsold ki (szüneteltesd) a régi címkét, miután az új működik. Különben ugyanaz az ember kétszer számítana leadnek (egyszer a `lead_created`, egyszer a köszönőoldalon).

### 2.8 Meta (csak a jóváhagyás után)
A fejlesztői dokumentáció szerinti leképezés: `lead_created` → standard `Lead`; `appointment_booked` → egyedi `AppointmentBooked`; `callback_requested` → egyedi `CallbackRequested`.
- Jelenleg **nincs Meta Pixel** a konténerben, ehhez először a Pixel alapkódját is fel kell venni GTM-ben.
- Csak hozzájárulás (`ad_storage`) után és **személyes adat nélkül** küldd.
- Egy klinika foglalási eseménye egészségügyi érzékeny jelzés, ezért ezt a jogi jóváhagyás után kapcsold be.

### 2.9 Tesztelés (Preview + DebugView)
1. GTM → **Preview** → add meg a `lassjol.hu` foglalót tartalmazó oldalát.
2. Nyisd meg ugyanazt az oldalt a Tag Assistant ablakban, és a foglalóban menj végig a lépéseken a **saját teszt e-mail-címeddel** (név: `TESZT …`).
3. A Tag Assistant bal oldali eseménylistáján az üzenetek (`booking_step_view`, `lead_created`, …) mint Custom Event jelennek meg, a címkék a „Tags Fired" listában.
4. GA4 → Admin → **DebugView**: itt látszanak a megérkezett események valós időben.

**Elvárt eredmények:**

| Teszt | Lépések | Elvárt |
|---|---|---|
| A – lead, kilépés | 1. képernyő kitöltés, Küldés, 2. képernyő, bezárás | 1× `lead_created`, 0× `callback_requested`, 0× `appointment_booked` |
| B – visszahívás | 1. képernyő, Küldés, „Visszahívást kérek" | 1× `lead_created`, 1× `callback_requested`, `booking_thankyou_view` (result = callback) |
| C – teljes foglalás | 1.–5. képernyő, sikeres foglalás | 1× `lead_created`, `booking_path_selected`, `service_selected`, `appointment_slot_selected`, 1× `appointment_booked`, `booking_thankyou_view` (result = appointment) |
| D – hibás első űrlap | érvénytelen adat vagy hálózati hiba | 0× `lead_created` |
| E – dupla kattintás | kétszer gyors Küldés | 1× `lead_created` |

**Figyelem a tesztekkel:**
- A B teszt valódi visszahívási kérés (a munkatársak megkapják), a C teszt valódi Dokirex-foglalás. Ezeket csak egyeztetve futtasd, vagy hagyd ki.
- Minden teszt egy valódi leadet hoz létre, és az ActiveCampaignbe is kerül (a „félbehagyott" lista szinkron be van kapcsolva). Utána töröld a leadet az admin felületen és a névjegyet az ActiveCampaignben.

### 2.10 Közzététel és visszaállás
1. GTM → **Submit** → adj verziónevet („Booking dataLayer + GA4 események").
2. Közzététel után az első órában figyeld a GA4 valós idejű riportot.
3. **Visszaállás:** GTM → Versions → az előző verzió → Publish. A foglaló működésére ez nincs hatással (a foglaló csak üzeneteket küld).

---

## 3. Hibaelhárítás

| Tünet | Valószínű ok | Teendő |
|---|---|---|
| Nincs egyetlen esemény sem a Preview-ban | a listener-tag nem fut, vagy rossz origin | ellenőrizd a tag triggerét (Initialization – All Pages) és a `BOOKING_ORIGINS` értékét (`https://saintjamesalkalamssagi.lovable.app`) |
| A foglaló konzolján van `window.dataLayer`, de a szülőn nincs | a szülő `www` / nem `www` eltérés vagy másik oldalra van beágyazva | a foglaló mindkét `lassjol.hu` címre küld; nézd meg, nem másik domainről fut-e az oldal |
| Van `booking_step_view`, de nincs `lead_created` | a `booking-lead` függvény régi verzió (nincs `created`), vagy a lead már létezett (összevonás) | élesítsd a függvényt; új e-mail-címmel próbáld újra |
| Duplán mért lead a GA4-ben | a régi `generate_lead` trigger is él | kapcsold ki a régit (2.7) |
| Események vannak a Preview-ban, de nincs a GA4-ben | consent letiltja, vagy a GA4 címke nincs a Google taghez kötve | nézd a Tag Assistant „Consent" fület; hozzájárulás nélküli látogatónál nem mérünk |
| A GA4-ben kevesebb a lead, mint a saját adatbázisban | normális: a hozzájárulás nélküli látogatók nem mérődnek (kb. 30–60% kiesés) | a saját adatbázis az igazság; a Hub megmutatja a lefedettséget |

---

## 4. A mérés a Data Hubban
- A saját adatbázis (`leads`, `lead_events`) a lead és foglalás **igazsága**, a hozzájárulástól függetlenül. A Hub ebből számol.
- A Hub egyeztetést mutat a saját adatok és a GA4 között (`mart_tracking_reconciliation`, `tracking_coverage`), és riaszt, ha a GA4 a foglalások 30%-ánál kevesebbet lát, miután az új események már mérnek.
- A forrás szerinti bontáshoz (melyik hirdetésből jött a lead) a **`sj-attribution`** tag szükséges: ez adja át az UTM-eket és click azonosítókat a foglalónak. A GA4 `lead_created`/`generate_lead` események a forrást a szülőoldali munkamenetből kapják.
