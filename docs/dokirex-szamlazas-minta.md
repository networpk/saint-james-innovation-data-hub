# Dokirex számlázási lekérdezés – az első működő minta (2026-10-20)

Végpont: `POST /api/public/runBuiltInQuery`, `StoredProcedure = builtin_getElojegyzesSzamlazas`, `Param1 = Tól`, `Param2 = Ig` (`YYYY-MM-DD`).
A Dokirex az első hívásra „too many arguments" hibát adott, ezután javította az eljárást; az újrapróbálás HTTP 200-at ad.
A mintát a foglaló admin `billing_sample` műveletével kértük le (csak olvasás, a válaszból csak a szerkezet kerül ki, értékek nem).

## Amit a minta mutat (2026-10-13 – 2026-10-14)
- Borítékos válasz: `status`, `message`, `data`. 74 sor, 49 előjegyzés (kb. 1,5 sor előjegyzésenként: tételsorok, ezért az összeget előjegyzésenként össze kell adni).
- Oszlopok:

| Oszlop | Típus | Megjegyzés |
|---|---|---|
| `ElojegyzesID` | szám | 49 különböző érték 74 sorban |
| `PaciensID` | szám | 48 különböző érték; páciens-azonosító |
| `Status` | szám | a mintában egyetlen érték; jelentése nem ismert |
| `VizitDatuma` | dátum-szerű szöveg | 2026-10-13 07:59 – 2026-10-14 18:08 |
| `Szolgaltatas` | szöveg | 18 különböző érték |
| `SzamlazottOsszeg` | szám | 31 különböző érték; bruttó/nettó, pénznem, storno nem ismert |
| `Megjegyzes` | – | mind üres |
| `ModositasIdeje` | dátum-szerű szöveg | 2026-09-09 – 2026-10-19 |

- **A Tól/Ig a `VizitDatuma`-ra szűr**, az `Ig` a nap végéig tart (az utolsó sor 10-14 18:08). A `ModositasIdeje` messze a kért tartományon kívül is esik, tehát az nem szűrő.
- **Utólagos módosítás:** a vizit után hetekig módosulhat a sor (`ModositasIdeje` a vizit után akár napokkal későbbi), ezért a napi szinkronnak visszamenőleg is újra kell olvasnia (javaslat: az elmúlt 90 nap vizitnapjait).
- **Időzóna:** a `VizitDatuma` `Z`-s időbélyeg, de az értékek (07:59–18:08) rendelői helyi időnek látszanak. Napra bontás előtt helyi (Európa/Budapest) időként kell kezelni, különben az éjfél környékén a vizit másik napra csúszik.
- **Illeszkedés a mi foglalásainkhoz:** a 49 előjegyzésből 3 egyezik a `leads.dokirex_booking_id`-val. Az online foglalóból jövő vizitek tehát a rendelés kis részét adják (a többi telefonon, recepción stb. jön), ezért a bevétel kampányhoz kötése csak ezekre lehetséges; az egész rendelés bevétele szolgáltatás szerint összesítve jól mutatható.

## Adatkezelési javaslat
- **Tároljuk:** `ElojegyzesID`, vizit napja (helyi idő szerint), `Szolgaltatas`, `SzamlazottOsszeg` előjegyzésenként és szolgáltatásonként összegezve, `ModositasIdeje`.
- **Nem tároljuk:** `Megjegyzes` (szabad szöveg).
- **`PaciensID`:** alapból nem tároljuk. Ha a visszatérő páciensek elemzése kell, sózott hash formában vehető fel; ez a felhasználó döntése.
- Csak erre az egy tárolt eljárásra lehet hívni (fehérlista), a Hub nem kap Dokirex-hozzáférést.

## Nyitott kérdések a Dokirex felé
1. A `Status` értékeinek jelentése (a mintában 1).
2. A `SzamlazottOsszeg` bruttó vagy nettó, milyen pénznemben van, és hogyan jelenik meg a sztornó/jóváírás (negatív összeg?).
3. A `VizitDatuma` időzónája (a `Z` helyi időt takar?).
4. Van-e egyedi tételsor-azonosító a sorokhoz (jelenleg egy előjegyzés több sora csak szolgáltatás és összeg alapján különböztethető meg).
5. Sor-, időtartomány- és hívásszám-korlát.
6. A `Szolgaltatas` → szakrendelés (szemészet / esztétika / plasztika) megfeleltetéséhez kapunk-e szakrendelés-mezőt.

## Építési terv (jóváhagyásra vár)
1. **Foglaló alkalmazás:** csak olvasó, fehérlistás `billing_export` művelet a meglévő Hub-exportban (előjegyzésenként és szolgáltatásonként összegezve, `PaciensID` és `Megjegyzes` nélkül, a lead-egyezés jelzésével). Dokirex-hívás csak admin vagy titkos szolgáltatás-token mellett.
2. **Hub adatbázis (új migráció, rögzített eljárással):** `fact_dokirex_revenue_daily` (vizit napja, `ElojegyzesID`, szolgáltatás, összeg, módosítás ideje) és egy nézet a lead-egyezéssel és az üzletági besorolással.
3. **Hub betöltés:** napi szinkron + az elmúlt 90 nap visszamenőleges újraolvasása, kapcsoló mögött, alapból KI.
4. **Felület:** bevétel üzletáganként és szolgáltatásonként, és az online foglalásból származó bevétel csatornánként/kampányonként.
