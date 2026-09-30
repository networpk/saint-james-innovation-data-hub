# Heti riport automatizálása – definíciók és adatforrások

Forrás: „Reports for Saint James” Excel (heti tölcsér, heti költés csatornánként és kategóriánként, KPI-célok, TOP kreatívok). Fókusz: **szemészet** (Eyes); az esztétika/plasztika ugyanebbe a modellbe később kerül.

## Egyeztetett definíciók

| Fogalom | Definíció | Adatforrás a Hubban | Állapot |
|---|---|---|---|
| **Visitors** | Weboldal-látogatók | GA4 (Windsor `googleanalytics4`), property: Lassjol.hu, saintjameshungary.hu | ingestion még nincs |
| **Soft lead** | Kattintás a weboldalon a foglalásra, **de nincs beküldés (submit)** | Feltehetően a GA4 `soft_conv_foglaljon` esemény (az elmúlt 7 napban 352 a Lassjol.hu property-n – nagyságrendileg egyezik a heti ~300 Eyes soft leaddel) | **ellenőrizendő:** ugyanezt számoljátok-e az Excelben? |
| **Hard lead** | Beküldött űrlap (submit) | Az időpontfoglaló app `leads` (beküldött: `booking_stage = 'completed'`) + GA4 `generate_lead` (44/7 nap a Lassjol.hu property-n – ez kevesebb, mint a heti ~100 Eyes hard lead, tehát a két forrás nem azonos: **ellenőrizendő**, mi számít az Excelben) | app-lead ingestion kész, GA4 nincs |
| **Booked patients** | Foglalt páciens, **bármely csatornából** (telefon, web, egyéb) | Dokirex (olvasás) | ingestion még nincs; web-foglalások az appból már azonosíthatók (`dokirex_booking_id`) |
| **Spend** | Nettó (HUF) | Windsor `spend` (Meta, Google, TikTok) | **nem biztos, hogy nettó** → egy hét összevetése az Excellel |

Következmény: a *booked patients* a telefonos foglalásokkal együtt csak a Dokirexből jön, ezért a *hard lead → booked* arány (Excel: ~50–60%) **nem a webes tölcsér tiszta konverziója** – a Hub külön mutatja a „webes hard lead → webes foglalás” arányt (az appból, pontos) és a „teljes booked” számot (Dokirex).

## A Hub heti nézete (cél)

Hetente és üzletáganként (Eyes): költés (csatorna × kategória) · visitors · soft lead · hard lead · booked · lépésarányok · benchmarkok · KPI-cél (`kpi_target`) teljesülése. Plusz: TOP kreatívok (forrás: hirdetés-szintű teljesítmény), „a forgalom 85%-át adó kreatívok” lista, Google-pozíció/kulcsszó-jelzés (Google Ads + Ahrefs).

**Még tisztázandó:** a hét kezdőnapja (az új lap *szerdától-csütörtöktől* számol: „Sep 3 – Sep 9”, a régi *hétfőtől*). A nézetet ennek megfelelően írjuk meg.

## Kategória-besorolás (a költés-lap alapján)

- **Eyes:** `General`, `SMILE`, `One Stop Shop` × (Google Ads, Meta Ads, TikTok Ads). A kreatív-csoportok: `SMILE`, `ONE STOP SHOP`, `RLE`, `LASER`.
- **Aesthetics (később):** `Featured Plastic Surgery`, `Featured Aesthetics`, `Other + Bleph` × (Google Ads, Meta Ads).
- A kampánynevek nem egységesek (pl. `LASSJOL - SMILE - AO`, `LASSJOL - ONE STOP SHOP`, `SAINTJAMESHUNGARY - Traffic`), ezért a `campaign_mapping` tábla egyszeri feltöltése szükséges (kampány-azonosító → kategória).

## Architektúra-döntés: három különálló rendszer

1. **Hub backend** – ez a repó (`saint-james-innovation-data-hub`): adatbázis, betöltők, elemzés, agent, API.
2. **Hub UI** – **új Lovable projekt** (még nem jött létre), a Hub API-ját használja.
3. **Időpontfoglaló / alkalmassági app** – a meglévő Lovable projekt (`Saint James ALkalmassági`), **csak adatforrás**; ennek módosítása az attribúció rögzítéséhez szükséges (lásd `idopontfoglalo-integracio.md`).
