# Saint James Innovation Data Hub

Backend, adatmodell és integrációk (a UI Lovable-ben készül). Koncepció: [`docs/koncepcio.md`](docs/koncepcio.md), foglaló-app integráció: [`docs/idopontfoglalo-integracio.md`](docs/idopontfoglalo-integracio.md).

## Állapot
| Elem | Állapot |
|---|---|
| Foglaló app: migráció, attribúció, Dokirex-azonosító | Lovable-ben elkészült / készül (publikálni kell!) |
| `integrations/lassjol-parent/sj-attribution.js` | kész, **még nincs telepítve** a lassjol.hu-ra |
| `db/migrations/0001_core.sql` (Hub séma) | kész, tiszta adatbázison tesztelve |
| Ingestion: Meta + Google napi teljesítmény, leadek | kész, **éles kulccsal még nem futtatva** |
| Ingestion: TikTok, GA4, organikus social, Ahrefs, Dokirex-státusz | még nincs |
| Javaslatmotor, agent, API, dashboard | még nincs |

## Futtatás
```
cp .env.example .env     # töltsd ki
npm install
npm run migrate          # db/migrations alkalmazása a HUB_DB_URL adatbázisra
npm run ingest -- ads --days 30
npm run ingest -- leads
npm run typecheck && npm test
```
Ajánlott ütemezés: `ads` óránként/naponta (az utolsó 7 napot újratölti, mert a platformok utólag korrigálnak), `leads` 15 percenként.

## Mit kell tudni
- A `spend` a Windsor `spend` mezője (Meta: fiók pénznemében, Google: fiók pénznemében) – pénznem-egyeztetés még hátra van.
- A kampányok üzletág/pillér/formátum besorolása a `campaign_mapping` táblában él; a meglévő kampánynevek (pl. `LASSJOL - SMILE - AO`, `SAINTJAMESHUNGARY - Traffic`) nem követnek egységes konvenciót, ezért ezt egyszer fel kell tölteni.
- `mart_lead_journey.hours_lead_to_booking` jelenleg `updated_at − created_at` közelítés; pontosabb lesz a `lead_events` (`booking_confirmed`) alapján.
