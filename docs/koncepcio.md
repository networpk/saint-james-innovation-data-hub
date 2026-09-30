# Saint James Innovation Data Hub – Koncepció, architektúra és ütemterv

> Státusz: **v0.1 – vitaindító tervezet**. A pontok, amelyeket feltételezésként kezeltünk, a 13. fejezetben vannak összegyűjtve, hogy egyeztetni lehessen róluk.
> Munkamegosztás: **UI → Lovable**, **backend, adatmodell, integrációk, agent → ez a repó**.

---

## 1. Miről szól ez az egész – egy mondatban

Egyetlen helyre összefolyatjuk a Saint James Hungary **hirdetési költés- és teljesítményadatait** (Meta, Google, később TikTok stb.), a **weboldali leadeket** és a **DocuRex foglalási adatokat**, hogy lássuk: *melyik kampány, melyik kreatív, melyik tartalmi pillér hozott ténylegesen foglalást, mennyi idő alatt és mennyiért* – majd ebből napi szintű, indokolt **javaslatokat** (pl. budgetátcsoportosítás) kapjunk, és egy **csak az adatokra támaszkodó AI-asszisztenssel** lehessen kérdezni.

**A fő üzleti érték:** a platformok a „lead"-ig látnak, mi a **foglalásig és bevételig** – ez a hiányzó láncszem, amit a hub bezár.

---

## 2. Célok és nem-célok

**Célok**
1. Egységes, megbízható „single source of truth" a social + PPC adatokra.
2. Lead → foglalás (DocuRex) összekötés, **kampány / kreatív / tartalmi pillér** szintű visszavezetéssel.
3. Konverziós **átfutási idő** (lead → foglalás) elemzése.
4. Rugalmas időhorizont és szűrés (nap/hét/hónap/YTD/YoY, platform, kampány, pillér, termék, célcsoport, stb.).
5. Napi **konstruktív javaslatok** és kontrollált **budget-optimalizálás** (jóváhagyásos folyamattal).
6. **Stratégia-felismerés** a meglévő költésekből (lásd 7. fejezet).
7. **Beépített, adat-alapú AI chat agent.**
8. Később: **versenytárs-elemzés** (Meta Ad Library stb.).

**Nem-célok (első körben)**
- Nem váltja ki a Meta Ads Manager / Google Ads felületet, csak döntéstámogató réteg.
- Nem hajt végre **jóváhagyás nélkül** költségmódosítást.
- Nem ad „általános marketing tanácsot" – az agent csak a saját adatokból válaszol.

---

## 3. Magas szintű architektúra

```
┌────────────────────────── FORRÁSOK ──────────────────────────┐
│ Meta Ads │ Google Ads │ (TikTok/LinkedIn…) │ GA4 │ Organic    │
└────────────────────────────┬─────────────────────────────────┘
                             │  Windsor.ai (connectorok + MCP/API)
                             ▼
┌─────────────────────── INGESTION RÉTEG ──────────────────────┐
│ Ütemezett pull (óránként/naponta) + backfill + hibakezelés    │
└──────────────┬───────────────────────────────┬───────────────┘
               │                               │
   ┌───────────▼──────────┐        ┌───────────▼───────────┐
   │ Weboldal lead-ek     │        │ DocuRex API           │
   │ (form/webhook, UTM)  │        │ (foglalások, státusz) │
   └───────────┬──────────┘        └───────────┬───────────┘
               └───────────────┬───────────────┘
                               ▼
┌──────────────────── ADATTÁRHÁZ (Postgres / BigQuery) ────────┐
│ raw  →  staging  →  core (egységes modell)  →  marts (KPI)    │
└───────┬───────────────────┬─────────────────────┬────────────┘
        │                   │                     │
┌───────▼────────┐  ┌───────▼─────────┐  ┌────────▼───────────┐
│ Elemző motor   │  │ Stratégia-      │  │ AI Agent           │
│ (attribúció,   │  │ felismerés +    │  │ (RAG/SQL tool-ok,  │
│ átfutási idő,  │  │ javaslat motor  │  │ csak saját adat)   │
│ pillér-bontás) │  │ + jóváhagyás    │  │                    │
└───────┬────────┘  └───────┬─────────┘  └────────┬───────────┘
        └───────────────────┴─────────────────────┘
                            ▼
                     REST / GraphQL API
                            ▼
                  Lovable UI (dashboard, chat)
                            ▲
        Write-back (jóváhagyás után): Windsor execute_action
        → budget / státusz módosítás a platformokon
```

**Technológiai javaslat (egyszerűen induló, skálázható):**
- **Adattár:** Supabase (Postgres) az indulásra – a Lovable natívan integrálja; ha az adatmennyiség (napi, kreatív-szintű, 89+ Meta kampány) megköveteli, a nehéz aggregációk mehetnek BigQuery-be.
- **Transzformáció:** SQL nézetek / dbt (staging → core → marts).
- **Ütemezés:** Supabase cron / Edge Functions, vagy külön worker (pl. Cloud Run job).
- **API:** Supabase Edge Functions vagy kis Node/TypeScript szolgáltatás.
- **Agent:** Claude API, tool use-zal (SQL-lekérdező tool-ok, szigorú séma), nem „szabad" webes tudással.

---

## 4. Integrációk

### 4.1 Windsor.ai – ténylegesen bekötött connectorok (ellenőrizve a Windsor fiókban)

| Connector | Fiók | Szerep a hubban |
|---|---|---|
| `facebook` (Meta Ads) | sjameshungary_hu | Fizetett Meta teljesítmény (89+ kampány) |
| `google_ads` | Saint James (149-137-6230); Saint James Vision and Aesthetics Center (556-030-7472) | Fizetett Google teljesítmény – **két fiók, külön kezelendő** |
| `tiktok` | Saint James Hospital Hungary Kft. | Fizetett TikTok |
| `facebook_organic` | Saint James Eye Clinic Budapest | Organikus Facebook: elérés, elköteleződés, posztok |
| `instagram` | saintjameshungary | Organikus Instagram + (opcionálisan) posztolás/komment write action |
| `instagram_public` | saintjameshungary | Nyilvános profil-metrikák, benchmark |
| `googleanalytics4` | saintjameshungary.hu; Lassjol.hu – GA4 | Weboldali viselkedés, session, konverziós események |
| `ahrefs` | lassjol.hu; saintjameshungary.hu | SEO: organikus kulcsszavak, pozíciók, backlinkek, versenytárs-domain adatok |

> Megjegyzés: egy márka (Saint James), **két üzletág** (szemészet és esztétika/plasztika), két weboldallal (**saintjameshungary.hu**, **lassjol.hu**) és két Google Ads fiókkal. A modellben kötelező a `business_line` és a `site` dimenzió, a szűrőkben is. A domain → üzletág megfeleltetés még egyeztetendő.

**Hogyan illeszkednek a hubba**
- **Social organikus (Facebook, Instagram)** → `fact_organic_post_daily`; a posztok is kapnak **tartalmi pillér** címkét, így a fizetett és organikus tartalom **ugyanazon pillér-tengelyen** összehasonlítható (mi működik organikusan → mit érdemes hirdetni).
- **GA4** → `fact_web_session_daily` + események (űrlap-kitöltés, foglalási lépések); a weboldali funnel és a hirdetés→lead bizonyítékok kiegészítője.
- **Ahrefs** → `fact_seo_daily` (organikus forgalom-becslés, kulcsszó-pozíciók, backlink-növekedés, top oldalak). Új felhasználás: **organikus vs. fizetett csatorna-mix**, brand-keyword kannibalizáció figyelése (PPC-költés olyan kulcsszóra, ahol már organikusan első), tartalmi rések a versenytárs-elemzéshez (9. fejezet).
- **TikTok Ads** → a meglévő ad-performance modellbe (`dim_platform = tiktok`).
- **Írási műveletek** (budget/státusz) csak a fizetett connectorokra (facebook, google_ads, tiktok) mennek, a 8. fejezet szabályai szerint. Az organikus és SEO connectorok **csak olvasásra** valók.

### 4.2 Egyéb integrációk

| Integráció | Szerep | Irány | Megjegyzés |
|---|---|---|---|
| **Időpontfoglaló app (Lovable, GitHub)** | **A weboldali leadek belépési pontja** – részletesen a 4.3 fejezetben | Olvasás (+ esetleg saját módosítás) | Kulcs a lead-életút végigkövetéséhez |
| **DocuRex API** | Foglalások, vendég/lead azonosító, státuszok, időpontok, érték | Olvasás | Meglévő API-kapcsolat. A lead→foglalás összekötés kulcsa a foglaló app által rögzített azonosító. |
| **Claude API** | Agent + javaslatmagyarázat | – | Csak strukturált, lekérdezett adatot kap. |
| **Supabase Auth** | Belépés, szerepkörök | – | Lásd 11. fejezet. |
| **Meta Ad Library / versenytárs források** | Versenytárs hirdetések | Olvasás | 2. fázis, lásd 9. fejezet. |

### 4.3 Az időpontfoglaló app bekötése – lead-életút

> **Az app átvizsgálva** (`networpk/saintjamesalkalamssagi`): részletes leírás, hiányosságok és módosítási lista → [`idopontfoglalo-integracio.md`](idopontfoglalo-integracio.md). Fő megállapítások: (0) az app **iframe-ben** fut, és **csak szemészeti** időpontokat kezel (az esztétika leadjei máshonnan jönnek, vagy még nincsenek bekötve), (1) az app jelenleg **nem rögzít UTM-et/click ID-t**, (2) a **Dokirex** (=DocuRex) `elojegyzesId` csak szabad szövegben tárolódik a leaden, (3) a Hub Supabase-pull útján olvashatja az adatokat.

**Miért kulcsfontosságú:** a weboldali leadek ezen az appon keresztül érkeznek, tehát itt dől el, hogy a hirdetés→lead→foglalás lánc **követhető-e**. Ha az app a lead létrehozásakor elmenti, honnan jött a látogató, a hub végig tudja vezetni a leadet a hirdetéstől a DocuRex foglalásig.

**Teendők az appban (Lovable/Supabase oldalon):**
1. **Attribúciós adatok rögzítése a leaden:** `utm_source/medium/campaign/content/term`, `fbclid`, `gclid`, `ttclid`, landing oldal, referrer, GA4 `client_id`, időbélyeg, márka/oldal. A paramétereket az első oldalbetöltéskor el kell menteni (cookie/localStorage), mert a foglalási folyamat több lépés.
2. **Lead-státuszok eseménynaplója** (`lead_events`): űrlap megnyitva → kitöltve → időpont kiválasztva → beküldve → DocuRex-be átadva → megerősítve / lemondva / megjelent. Ebből számolható a **lemorzsolódás lépésenként**.
3. **Stabil azonosító** a lead és a DocuRex foglalás között: az app a DocuRex hívásakor átadja/elmenti a saját `lead_id`-t, és visszamenti a DocuRex `booking_id`-t.
4. **Hirdetési konverzió-visszajelzés (később):** szerver oldali események (Meta CAPI, Google Enhanced Conversions), hogy a platformok **valódi foglalásra** optimalizáljanak, ne csak űrlapra.
5. **Személyes adatok:** a hubba e-mail/telefon csak **hash-elve** kerüljön; a klinikai jellegű (egészségügyi) adat ne kerüljön át (lásd kockázatok).

**Hogyan kapcsoljuk a hubhoz (két út, az app felépítésétől függ):**
- **A) Közös Supabase / adatbázis-olvasás:** ha az app Supabase-t használ, a hub read-only nézeteken/szerepkörön keresztül olvassa a `leads` és `lead_events` táblákat (vagy replikálja őket).
- **B) Webhook/API:** az app minden lead-eseményt egy hub-végpontra (`POST /ingest/lead-event`, aláírt kéréssel) küld. Ez lazábban csatolt, és független az app belső adatmodelljétől.
- **Javaslat:** **B** kell az eseményekhez (közel valós idejű), **A** jó a meglévő leadek egyszeri backfilljéhez.

**Mit kapunk ettől a hubban:**
- Teljes **életút-nézet** egy leadre: hirdetés → kattintás → weboldal → űrlap → DocuRex foglalás → megjelenés.
- **Lemorzsolódás-elemzés** a foglalási folyamat lépései között (melyik lépésnél vesztünk leadet, melyik pillér/kampány leadjei morzsolódnak jobban).
- Pontos **lead→foglalás átfutás** és megbízható attribúció (click ID egyezés a leaden).
- **Adatminőség-jelzés:** hány lead érkezik UTM/click ID nélkül.

---

## 5. Adatmodell (core réteg, vázlat)

**Dimenziók**
- `dim_platform` (meta, google, tiktok, facebook_organic, instagram, ga4, ahrefs)
- `dim_business_line` (szemészet, esztétika/plasztika) – **elsődleges szűrő**, minden ténytáblán
- `dim_brand_site` (saintjameshungary.hu, lassjol.hu, …)
- `dim_account`, `dim_campaign`, `dim_adset_adgroup`, `dim_ad` (kreatív)
- `dim_content_pillar` – tartalmi pillérek (pl. wellness, gasztro, romantikus, családi, rendezvény – **a tényleges listát az ügyféllel kell véglegesíteni**)
- `dim_content_type` – formátum (videó, carousel, statikus, reels, search RSA stb.)
- `dim_product` – foglalási termék/szolgáltatás
- `dim_date`

**Tények**
- `fact_ad_performance_daily` – költés, megjelenés, kattintás, CPC/CPM, platform-konverziók (nap × hirdetés).
- `fact_lead` – lead ID, időbélyeg, forrás, UTM, click ID-k (fbclid/gclid/ttclid), GA4 client ID, landing oldal, márka/oldal (**az időpontfoglaló appból**).
- `fact_lead_event` – a lead lépésenkénti eseményei (űrlap megnyitva → beküldve → DocuRexbe átadva → megjelent).
- `fact_organic_post_daily` – Facebook/Instagram posztok teljesítménye, pillér-címkével.
- `fact_web_session_daily` – GA4 session és eseményadatok.
- `fact_seo_daily` – Ahrefs: organikus forgalom, kulcsszó-pozíciók, backlinkek.
- `fact_booking` – DocuRex foglalás ID, létrehozás/érkezés időpont, státusz (megerősített/lemondott), érték.
- `fact_lead_booking_link` – a két tény összekötése + **attribúciós módszer és bizonyosság** (pl. „click ID egyezés", „e-mail egyezés", „csak UTM").
- `fact_budget_change_log` – minden budgetváltozás (kézi, javasolt, automatikus) indoklással és jóváhagyóval.
- `fact_recommendation` – javaslatok, státusz (új / elfogadva / elutasítva / lejárt), utólagos hatás.

**Kulcs származtatott mutatók:** Költés, Lead, **CPL**, Foglalás, **Költség/foglalás (CPA)**, **Lead→foglalás arány**, Foglalási bevétel, **ROAS**, **lead→foglalás átfutási idő** (medián, p75, eloszlás), foglalás→érkezés idő, lemondási arány.

### A tartalmi pillérek kulcsa: elnevezési konvenció
A pillér/kontent-szintű bontás **csak akkor megbízható, ha a hirdetések neve/UTM-je strukturált**. Javaslat:

```
SJ_{platform}_{cél}_{pillér}_{formátum}_{célcsoport}_{YYYYMM}_{azonosító}
pl.: SJ_META_LEAD_WELLNESS_VIDEO_COUPLES_202610_V03
utm_campaign = ugyanez, utm_content = kreatív azonosító
```
A meglévő ~89 Meta kampányra: **egyszeri hozzárendelési (mapping) tábla** (kampány → pillér/formátum), amit a hub UI-ból lehet karbantartani, és a hub idővel **javaslatot tesz az automatikus besorolásra** a hirdetésszöveg/kreatív alapján (jóváhagyással).

---

## 6. Attribúció és átfutási idő (a hub lelke)

1. **Match-lánc prioritás:** click ID (fbclid/gclid) → lead ID → hash-elt e-mail/telefon → UTM + időablak.
2. Minden összekötés kap egy **bizonyossági szintet** – a dashboard mutatja, mennyi a „biztos" és mennyi a „becsült" foglalás.
3. **Átfutási idő:** `foglalás_létrehozva − lead_időbélyeg`, szegmentálva (platform, pillér, termék, célcsoport). Kohorsz-nézet: „az adott heti leadek hány %-a foglalt 7/14/30/60 napon belül".
4. **Platform vs. valós:** a hub mindig mutatja egymás mellett a platform által jelentett konverziót és a DocuRex-alapú tényleges foglalást (ez gyakran nagy eltérést mutat).

---

## 7. „Manuális mód" és stratégia-felismerés

A megfogalmazás alapján ezt így értelmezzük (**erősítsd meg**): a hub a meglévő költésekből és beállításokból **felismeri, milyen stratégiával fut egy-egy kampány/platform**, és ezt címkézi.

**Mit detektálunk (heurisztika + szabályok):**
- **Licitstratégia / optimalizálási cél:** Meta (lead, forgalom, konverzió), Google (Maximize conversions, tCPA, tROAS, manual CPC) – ha a Windsor ezt a mezőt adja, onnan; különben a viselkedésből.
- **Budgetkezelés:** napi vs. élettartam budget; CBO/ABO (Meta); mennyire „kézi" a vezérlés – hány budgetmódosítás történt (változásnapló), mekkora lépésekben, milyen gyakran.
- **Költési minta:** egyenletes, hétvégi/hétközi súlyozás, szezonális hullámok, „burst" kampányok, always-on vs. kampányszerű.
- **Funnel-szerepkör:** awareness / consideration / conversion – a cél, a formátum és a mutatók eloszlása alapján.
- **Platformonkénti stratégiai profil:** pl. „Meta: 70% prospecting, 30% retargeting; Google: 80% brand-keyword".

**Eredmény:** minden kampány kap egy `strategy_profile` címkét és egy **„kézi ↔ automatizált" skálát**, amelyre a javaslatok épülnek (pl. kézi licitű kampányra más típusú javaslat jön, mint tCPA-ra).

---

## 8. Javaslat- és optimalizáló motor

**Napi futás** (pl. reggel 7:00), kimenet: rangsorolt, **indokolt, mérhető javaslatlista**.

Példa javaslattípusok:
- **Budget-átcsoportosítás:** „A *Wellness-pillér / Meta* kampány CPA-ja 32%-kal a cél alatt, 14 napja stabil → +15% napi budget (+X Ft). Forrás: *Y kampány* (CPA +40% a cél felett)."
- **Fáradó kreatív:** frekvencia ↑, CTR ↓ → csere/szünet javaslat.
- **Lassú konverziójú szegmens:** „Ennek a pillérnek az átfutása 21 nap – a 7 napos ablakon nézve alulértékeljük; ne vágd vissza."
- **Anomália:** költés-kiugrás, követés-kiesés (nincs lead X órája), CPL-szökés.
- **Szezonális jelzés:** közelgő foglalási csúcs → előzetes budgetemelés.

**Biztonsági keret a budgetmódosításhoz (kötelező):**
1. **Alapértelmezés: javaslat, emberi jóváhagyás** (egykattintásos „Alkalmaz").
2. Guardrail-ek: max. lépésköz (pl. ±20%/nap), napi/havi össz-plafon, minimum adatmennyiség (pl. ≥ N lead / X nap), tanulási fázis védelme (Meta: ne nyúljunk túl gyakran).
3. Végrehajtás a Windsor `execute_action`-jén át, **audit naplóval** (ki, mikor, mit, miért, mi volt előtte).
4. **Visszavonás** gomb / automatikus visszaállítási javaslat, ha romlik.
5. Később, opcionálisan: szabály-alapú auto-mód szigorúan korlátozott körben, külön engedéllyel.

---

## 9. Versenytárs-elemzés (2. fázis)

- **Meta Ad Library** (API/scraper-szolgáltató): a követett versenytársak aktív hirdetései, kreatívok, szövegek, indulási dátum, futási idő (hosszan futó hirdetés = valószínűleg működik), platformok.
- **Google Ads Transparency Center**, **TikTok Creative Center**, SEO/SERP-figyelés, social organikus benchmarkok (Metricool/Windsor organic).
- Funkciók: versenytárs-lista kezelése, napi/heti új hirdetések listája, kreatív-galéria, **pillér/üzenet szerinti címkézés** (AI-val), „mit hirdetnek, amit mi nem".
- **Jogi/etikai keret:** csak nyilvános, hivatalos forrásokból; ToS és GDPR szempontok ellenőrzése.

---

## 10. AI agent (chat / „talking head")

**Elv:** az agent **kizárólag a hub adataira** támaszkodik, nem találgat.
- **Tool-alapú működés:** előre definiált, biztonságos lekérdező tool-ok (`get_kpis`, `get_funnel`, `get_lead_to_booking_lag`, `get_strategy_profile`, `list_recommendations`, `compare_periods`…), nem szabad SQL a felhasználó nevében.
- **Hallucináció-védelem:** minden válasz **forrás-hivatkozással** (melyik nézet, időszak, szűrők); ha nincs adat: „erre nincs adatom".
- **Hatókör-korlát:** system prompt + tool-szűrés – általános témákra udvariasan visszautasít.
- **Jogosultság:** csak azt láthatja, amit a felhasználó.
- **Írási jog:** az agent *javasolhat* akciót, de a végrehajtás ugyanazon a jóváhagyási folyamaton megy át.
- **UI:** chat panel a dashboard mellett (kontextus-tudatos: a kiválasztott szűrők automatikusan mennek a kérdés mellé). „Talking head" (avatar/hang) **nice-to-have**, később ráépíthető (pl. ElevenLabs).

Példakérdések: „Melyik pillér hozta a legtöbb foglalást szeptemberben és milyen átlagos átfutással?", „Miért romlott a CPA a múlt héten?", „Mit csináljak ma a Meta budgettel?".

---

## 11. Adatvizualizáció és UI (Lovable – a backend által kiszolgált igények)

**Nézetek**
1. **Executive overview:** költés, lead, foglalás, CPA, ROAS, trend + előző időszak/YoY.
2. **Funnel:** megjelenés → kattintás → lead → foglalás → érkezés.
3. **Pillér/kontent nézet:** pillér × formátum mátrix (költés, lead, foglalás, CPA, átfutás).
4. **Kampány/kreatív táblázat** drill-down-nal (89+ kampányhoz szűrés, rendezés, mentett nézetek).
5. **Átfutási idő:** eloszlás-hisztogram, kohorsz-hőtérkép.
6. **Budget & pacing:** tervezett vs. tényleges költés, hónapvégi előrejelzés.
7. **Stratégia-térkép:** platformonkénti stratégiai profil.
8. **Javaslatok inbox:** elfogadás/elutasítás, hatás-követés.
9. **Adatminőség:** szinkron állapot, hiányzó UTM, nem párosított leadek.
10. **Agent chat.**
11. (Később) **Versenytárs galéria.**

**Időhorizontok:** ma/tegnap, 7/14/30/90 nap, hét/hónap/negyedév/év, YTD, egyéni tartomány; összehasonlítás előző időszakkal / tavalyival; napi/heti/havi bontás.
**Szűrők:** platform, fiók, kampány, hirdetéscsoport, kreatív, pillér, formátum, termék, célcsoport, cél (awareness/lead/conv.), státusz, attribúciós bizonyosság.

**Backend–UI szerződés:** az UI kizárólag egy **verziózott API-n** át éri el az adatot (előre aggregált „mart" nézetek + szűrő paraméterek), nem nyers adatot húz. Ez gyors UI-t és egyszerű Lovable-fejlesztést ad. **Szerepkörök:** admin / stratégia / csak olvasó / ügyfél-nézet (korlátozott).

---

## 12. Fejlesztési ütemterv

| Fázis | Tartalom | Kimenet | Becsült idő* |
|---|---|---|---|
| **0 – Discovery** | Kérdések tisztázása (13. fejezet), DocuRex API felmérése, Windsor fiókok/connectorok, pillér-lista, KPI-definíciók | Jóváhagyott specifikáció, adatszótár | 1–2 hét |
| **1 – Alapok (MVP-adat)** | Repó/infra, Supabase séma, Windsor ingestion (Meta, Google – 2 fiók, TikTok, napi szint; majd GA4, organic, Ahrefs), backfill, adatminőség-monitor | Napi frissülő `fact_ad_performance_daily` | 2–3 hét |
| **2 – Lead↔foglalás** | **Időpontfoglaló app audit és módosítás (UTM/click ID rögzítés, lead_events, webhook)**, DocuRex ingestion, match-lánc, átfutási idő, pillér-mapping tábla | Első valós „költés → foglalás" riport | 3–4 hét |
| **3 – Dashboard v1** | API + Lovable UI: overview, kampány, pillér, funnel, szűrők, időhorizontok | Használható belső dashboard | 3–4 hét (párhuzamos) |
| **4 – Intelligencia** | Stratégia-felismerés, napi javaslat motor, anomália-jelzés, javaslat-inbox | Napi ajánlások | 3–4 hét |
| **5 – AI agent** | Tool-réteg, chat UI, forrás-hivatkozás, hatókör-tesztek | Adat-alapú chat | 2–3 hét |
| **6 – Budget write-back** | Guardrail-ek, jóváhagyási folyamat, Windsor `execute_action`, audit log, visszavonás | Kontrollált budgetmódosítás | 2–3 hét |
| **7 – Versenytárs** | Ad Library ingestion, kreatív-galéria, címkézés | Versenytárs-modul | 3–4 hét |
| **8 – Finomhangolás** | Előrejelzés, auto-szabályok, ügyfél-nézet, riport-export, avatar | Érett rendszer | folyamatos |

\*Durva becslés 1–2 fős csapatra; a Discovery eredményétől függően módosul. **A Fázis 1–3 adja a legnagyobb üzleti értéket, ezt érdemes gyorsan kézbe venni.**

**Javasolt első sprint (konkrét):** Időpontfoglaló app repó átnézése (mit rögzít ma) → Supabase séma → Meta+Google napi ingestion → egy „költés/lead/CPL" nézet Lovable-ben.

---

## 13. Feltételezések és nyitott kérdések (kérlek erősítsd meg / egészítsd ki)

1. **Windsor:** a connectorok ellenőrizve (4.1). Milyen csomag van, és szükséges-e további connector (pl. LinkedIn, Bing, `facebook_leads`, Search Console)? Az „ANCP" szerintem MCP – jó?
2. **DocuRex:** milyen adatot ad vissza az API (foglalás ID, létrehozás/érkezés dátum, státusz, érték, vendég-azonosító)? Van webhook? Hogyan köthető a foglalás a weboldali lead-hez?
3. **Időpontfoglaló app:** melyik GitHub repó? Milyen backendet használ (Supabase?), mit rögzít ma a leadről (UTM, click ID)? Mindkét weboldal (saintjameshungary.hu, lassjol.hu) ezt használja? (Megválaszolva: az app Edge Function-ön át hívja a Dokirex API-t.)
4. **Tartalmi pillérek:** milyen pillérek vannak ma, és van-e egységes kampány-elnevezés? A meglévő 89+ kampányt kell-e visszamenőleg besorolni?
5. **„Konstruktív jostatok"** = *konstruktív javaslatok* (napi ajánlások)? Milyen döntésekhez kellenek elsősorban (budget, kreatívcsere, célzás)?
6. **„Manuális mód":** a 7. fejezet értelmezése helyes (stratégia-felismerés, kézi vs. automatizált kampányvezérlés)?
7. **Célértékek:** milyen CPL/CPA/ROAS célok vannak, termékenként vagy pillérenként?
8. **Budget-automatizálás:** megengedett-e valaha jóváhagyás nélküli módosítás, és milyen plafonokkal?
9. **Felhasználók:** ki használja (Saint James csapata, ügynökség, vezetőség)? Kell-e ügyfél-nézet és nyelv (HU/EN)?
10. **Adatmegőrzés és GDPR:** személyes adat (e-mail, telefon) kezelése – hash-elés, hozzáférés-szabályzat, adatfeldolgozói szerződések. **Ezt a Discovery-ben rögzíteni kell.**
11. **Versenytársak:** kik az első 5–10 követendő versenytárs?
12. **Költségkeret:** Windsor-csomag, hosting, Claude API használat várható költsége.

---

## 14. Kockázatok és kezelésük

| Kockázat | Hatás | Kezelés |
|---|---|---|
| Lead↔foglalás összekötés pontatlan | Téves döntések | Bizonyossági szint, „biztos vs. becsült" elkülönítés, UTM/click ID fegyelem |
| Következetlen kampánynevek | Pillér-bontás hibás | Mapping tábla + elnevezési konvenció + UI-ból javítható |
| Platform API-limitek / Windsor késés | Hiányos/késő adat | Újrapróbálás, szinkron-monitor, „adat frissessége" jelző |
| Hibás automatikus budgetváltoztatás | Pénzügyi kár | Jóváhagyás, guardrail-ek, audit, visszavonás |
| Agent téves válasz | Bizalomvesztés | Tool-alapú lekérdezés, forrás-hivatkozás, „nincs adat" viselkedés |
| Hosszú átfutás miatt torz friss adat | Korai leállítás | Kohorsz-nézet, „érési" jelző a friss időszakokra |
| GDPR | Jogi | Hash-elés, minimalizálás, hozzáférés-naplózás, DPA-k |

---

## 15. Példa – hogyan néz ki egy „végigvitt" eset

1. **Október 3.** – Meta „SJ_META_LEAD_WELLNESS_VIDEO_COUPLES_202610_V03" hirdetés kattintás (fbclid rögzítve) → weboldal lead űrlap.
2. A lead bekerül `fact_lead` táblába UTM-mel + fbclid-del.
3. **Október 19.** – DocuRex foglalás létrejön ugyanazzal a vendég-azonosítóval → `fact_booking`.
4. A match-lánc click ID/e-mail alapján összeköti → *bizonyosság: magas*, **átfutás: 16 nap**.
5. A hub a hirdetést a **Wellness pillér / videó / páros** szegmensbe sorolja; a pillér medián átfutása 14 nap, CPA 18 400 Ft.
6. **Október 20. reggel** a javaslat-motor szól: „Wellness/Meta CPA 27%-kal a cél alatt → +15% napi budget, forrás: *Családi/Meta statikus* (CPA +35% a cél felett)." Jóváhagyás után a Windsor `execute_action` átállítja, az audit log rögzíti.
7. A vezető megkérdezi a chatben: „Melyik pillér térült meg legjobban az elmúlt 90 napban?" – az agent a `get_kpis` tool-lal válaszol, forrás-hivatkozással.

*(A példában szereplő számok illusztratívak.)*

---

## 16. Javasolt repó-struktúra (következő lépés)

```
/docs            koncepció, adatszótár, döntésnapló
/db              migrációk, SQL nézetek (raw→staging→core→marts)
/ingestion       Windsor, DocuRex, lead webhook
/analytics       attribúció, átfutási idő, stratégia-felismerés
/recommendations javaslat-motor, guardrail-ek, write-back
/agent           tool-definíciók, prompt, tesztek
/api             a Lovable UI által használt szerződés (OpenAPI)
/competitors     (2. fázis)
```
