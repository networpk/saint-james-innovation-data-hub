# Funkciók – mit tud az Innovation Data Hub

Az alábbi lista a jelenlegi állapotot írja le, funkciónként: mire való, honnan veszi az adatot, és mire figyelj.

## Áttekintés és elemzés
- **Áttekintés (Ma / Tegnap / időszak):** költés, kattintás, lead és költség/lead üzletágak szerint (szemészet, esztétika). Forrás: Meta, Google Ads, TikTok a Windsoron át.
- **Kampányok, kreatívok, kulcsszavak:** teljesítmény szinten, kreatív-fáradás és Pareto-jelölés, kulcsszó-értékelés (folytasd / figyeld / csökkentsd / állítsd le / kevés adat) magyarázattal és heti előzménnyel.
- **Észrevételek (`insights`):** 13 szabályú motor (pazarló kulcsszó, CPC-ugrás, költségkeret-korlát, kattintás→látogató eltérés stb.), mindegyik bizonyítékkal és javaslattal.
- **Korreláció és csatorna-együttmozgás:** késleltetett összefüggés a jelek között; csak jelzés, nem bizonyíték az okságra.

## Leadek és foglalás
- **Lead-életút:** az alkalmassági (kvíz) leadek és az időpontfoglalások külön. A foglalás két szintje: **elküldte az adatait** (az első képernyő Küldése, ez a lead) és **végigvitte** (időpontot foglalt vagy visszahívást kért). Kimenetek: foglalt, visszahívást kért, elküldte az adatait de nem vitte végig, félbehagyta (nem küldte el). Egy személy (e-mail/telefon hash, e-mail nem tárolódik) egyszer számít, a legjobb kimenetelével; a sorok a listában megmaradnak. Lépésenkénti idő és lemorzsolódás.
- **Forrás-attribúció:** a lassjol.hu GTM-szkriptje átadja a foglalónak az UTM-et és a click id-kat (gclid, gbraid, ttclid, fbclid, gad_campaignid); a Hub ebből köti a leadet a hirdetéshez. Utolsó érintés, 90 nap.
- **Google-kampány a leadből:** a `gad_campaignid` alapján a lead UTM nélkül is a Google-kampányhoz kapcsolódik.

## ActiveCampaign
- Névjegyek, automatizmusok, kampányok: előrehaladás, e-mail megtekintő (tárgy, előnézeti szöveg, HTML), automatizmus-lépcső forrás szerinti bontásban, kampány-arányok. Egészségügyi mező nem kerül át.

## SEO (Ahrefs)
- Pillanatképek, CTR-görbe alapú lehetőségek (gyors nyeremény, fizetett–szerves átfedés, SEO-rés, kannibalizáció). Az Ahrefs a Windsoron át nem ad kulcsszó-ötleteket.

## Organikus posztok (Instagram, Facebook)
- Minden poszt (reel, kép, karusszel; Facebook-poszt) elérése, megtekintése, mentése, megosztása, interakció-aránya, reeleknél az átlagos nézési idő és a továbbgörgetési arány. A poszt részletében az elérés idősora a közzététel óta. Forrás: Windsor. A számok az Instagram saját késleltetésével frissülnek; nézők szerinti bontás poszt szintjén nincs.

## Mérés-ellenőrzés
- **dataLayer-események:** a foglaló (iframe) eseményei (`booking_step_view`, `lead_created`, `callback_requested`, `appointment_booked`) a lassjol.hu GTM-jén át mennek ki, `lead_id` és személyes adat nélkül.
- **Egyeztetés:** napi összevetés a saját adatbázis és a GA4 között. A GA4 hozzájárulás-függő, ezért alulmér; a saját adatbázis az igazság.

## Értesítési központ
- Riasztások életciklussal (új, látta, elhalasztva, megoldva), duplikálás-védelem, várakozási idő, napi összefoglaló. Adatminőségi ellenőrzések: elavult betöltés, betöltési hiba, forrás nélküli leadek, leadszám-visszaesés, AC-szinkron, mérés-lefedettség, hibázó ütemezett feladat, HTTP-hibás betöltő-hívás.

## Rendszer-önellenőrzés
- `schema_selfcheck()` és `schema_missing()`: kimutatja, ha egy migrációból hiányzik egy objektum.
- Megakadt betöltések automatikus lezárása (15 perc), így nem marad örökre „running" futás.

## Amit a rendszer még nem tud
- **Dokirex:** megjelent / lemondta állapot és bevétel – a Dokirex válaszára vár (`docs/dokirex-kerdesek.md`).
- **Meta konverziós visszacsatolás:** egészségügyi korlátozás miatt nincs; csak saját mérés.
- **GA4 foglalási események:** a GTM-tagek beállításáig az egyeztetés üres.
