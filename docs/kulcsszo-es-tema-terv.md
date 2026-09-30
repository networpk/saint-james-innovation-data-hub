# Kulcsszó-szintű elemzés és téma-összekötés (Google ↔ Meta/TikTok)

## Cél
Egy kulcsszóra ránézni: mennyibe került, mekkora volt a volumen, milyen témához tartozik, és ha a Meta/TikTok hirdetések ugyanarról a témáról szólnak, azt is látni mellette, és hogy az időbeli alakulásuk összefügg-e.

## Ellenőrzött adatforrások (Windsor, éles lekérdezéssel)
| Adat | Forrás / mező | Megjegyzés |
|---|---|---|
| Google kulcsszó: költés, megjelenés, kattintás, konverzió | `google_ads`: `keyword_info_text` + `campaign`, `ad_group_*`, `spend`, `impressions`, `clicks`, `conversions` | **Csak keresési (GSN) kampányokra.** Példa (szept. 28.): „saint james” 118 megjelenés, 37 kattintás, 15 952 Ft, ~3 konverzió. |
| Google keresési kifejezések (amit a felhasználó valójában beírt) | `google_ads`: `search_term` | Ugyanez: GSN kampányokra; a Google a ritka kifejezéseket elrejti. |
| Minőségi mutató, elvesztett megjelenés | `quality_score`, `search_impression_share`, `search_top_impression_share` | külön lekérdezés (más erőforrás), a betöltő ellenőrzi |
| Meta hirdetés témája | `ad_name`, `body` (szöveg), `title`, `link_url` | a kreatív-nevek ritkán témajelzők; a szöveg jobb forrás |
| Piaci keresési volumen | Ahrefs `search_volume`, `keyword_traffic`, `best_position` | **csak azokra a kulcsszavakra, amelyekre a domain szervesen rangsorol**; 10 Ahrefs API-egység / sor |

## Fontos korlát: Performance Max
A Google-költés nagy része **Performance Max** kampányokban van (pl. *Lézeres szemműtét*: ~2,3 M Ft/30 nap, *Lencse (45+)*: ~1,44 M Ft/30 nap). Ezeknél a Google **nem ad kulcsszót és keresési kifejezést** (a mező üres). Kulcsszó-szintű költés tehát a keresési (GSN) kampányokra lesz (Brand, Competitor, Lézeres szemműtét, Általános szemészet, Pécs, stb.). A PMax-nál csak kampány/eszközcsoport-szint érhető el, de a téma-nézetben ezek is megjelennek a kampány témája szerint.

## Téma-réteg (a két platform összekötője)
- `topic`: a témák szótára (pl. Lézeres szemműtét, Lencse / RLE, Szürkehályog, SMILE, Brand, Competitor, Általános).
- `topic_rule`: szabályok, amelyek kulcsszóhoz, keresési kifejezéshez, kampányhoz, hirdetéscsoporthoz vagy Meta/TikTok hirdetéshez (név + szöveg) témát rendelnek. Mint a kampány-besorolásnál: kézi felülírás > szabály > „Besorolatlan”, ékezet- és kisbetű-érzéketlenül.
- Nézetek: `mart_topic_daily` (téma × nap × platform: költés, megjelenés, kattintás, elérés), `mart_keyword_summary` (kulcsszó × időszak).

## Felület (új oldal: „Kulcsszavak” + részletes panel)
- Keresés és szűrés: kulcsszó, kampány, kategória/alkategória, téma, egyezési típus, időszak; rendezés költés, kattintás, CPC, költség/konverzió szerint.
- Egy kulcsszó paneljén: napi grafikon, költés, megjelenés, kattintás, CTR, CPC, konverzió, minőségi mutató, elvesztett megjelenés; a téma; **„Kapcsolódó Meta/TikTok hirdetések”** ugyanarról a témáról (költés, elérés, kattintás, hirdetésnevek); és egy átfedő grafikon a kulcsszó (vagy a téma) Google-megjelenései/kattintásai és a Meta/TikTok költése/elérése között.
- **Az összefüggés jelzésértékű:** időbeli együtt mozgás (késleltetéssel is), nem bizonyíték az ok-okozatra; a felület így is jelzi.

## Döntések, amik kellenek
1. Elfogadható, hogy a PMax kampányoknál nincs kulcsszó-szint?
2. A témák listája (a fenti javaslat jó kiindulás?).
3. Kell-e a keresési kifejezések (search term) szint is (ez a legtöbbet mondó riport, de sok sor)?
4. Az Ahrefs-volumen (csak a domain által rangsorolt kulcsszavakra) kell-e, tekintve az API-egység költségét?
