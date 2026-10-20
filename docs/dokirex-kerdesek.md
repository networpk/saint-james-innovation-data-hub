# Dokirex – mi kell tőlük és hogyan oldjuk meg

## Mit találtunk az API-dokumentációban (api-v2.dokirex.hu/api/api-docs)
- Minden végpont Bearer tokent kér (`POST /api/auth/login`), a token élettartama nincs leírva.
- **Foglalás állapotát olvasó végpont nincs dokumentálva.** Csak írás van: `updateElojegyzesStatus` (0 aktív, -1 ideiglenes, -2 SimplePay, -3 megerősítő e-mail, -4 jóváhagyásra vár).
- „Megjelent", „lemondta", „nem jött el" állapot nincs a doksiban.
- `insertOnlineElojegyzes` válasza: nincs leírva, hogy a `LastID` foglalás- vagy páciensazonosító.
- Számlák: `listPaciensSzamlazas` (PaciensID) és `listKiallitottSzamlak` (dátum/számlaszám) olvas, de a foglaláshoz kötés nincs leírva.
- Forrás/csatorna mező nincs, csak a `Megjegyzes` szöveg.
- A token ugyanúgy töröl és ír is, mint olvas.

## Mit kérünk a Dokirextől (levél: dev@kardi-soft.hu)

> Tárgy: Csak olvasási API-hozzáférés és állapot-lekérdezés – Saint James (időpontfoglaló integráció)
>
> Tisztelt Kardi-Soft csapat!
>
> Az online időpontfoglalónk az `insertOnlineElojegyzes` végpontot használja. Szeretnénk a foglalások sorsát (megjelent, lemondta, nem jött el) és a hozzájuk tartozó bevételt anonim, csak olvasó módon követni a marketing-elemzéshez. Kérdéseink:
>
> 1. **Csak olvasási felhasználó:** kaphatunk olyan API-felhasználót, amelyik kizárólag lekérdezhet (nem hozhat létre, nem módosíthat, nem törölhet, nem küldhet SMS-t)?
> 2. **`LastID`:** az `insertOnlineElojegyzes` válaszában a `LastID` az `ElojegyzesID` vagy a `PaciensID`? Kapunk-e mindkettőt?
> 3. **Állapot lekérdezése:** melyik végponttal kérdezhető le egy (vagy egy időszak összes) előjegyzés állapota? Milyen állapotértékek léteznek (megjelent, lemondta, nem jött el, törölt, lezárt vizit)? Kérjük a teljes listát a kódjaikkal.
> 4. **Lista végpont:** van-e olyan végpont, amely dátumtartomány (`Tol`/`Ig`) szerint minden előjegyzést visszaad az `ElojegyzesID`-val, `PaciensID`-val, szakrendeléssel, szolgáltatással, `Status`-szal, létrehozás és módosítás idejével és a `Megjegyzes` mezővel? Mi a legnagyobb megengedett időtartomány és a lapozás?
> 5. **Bevétel:** hogyan kapcsolható egy számla/fizetés az előjegyzéshez vagy a vizithez (melyik azonosító köti össze)? Kaphatunk-e végpontot, amely előjegyzésenként a számlázott nettó/bruttó összeget adja vissza?
> 6. **`runBuiltInQuery`:** ha az 3–5. pontra nincs kész végpont, kérhetünk-e Önöktől egy csak olvasó tárolt eljárást, amely `Tol`/`Ig` szerint visszaadja: `ElojegyzesID`, `PaciensID`, `Status`/megjelenés-állapot, vizit dátuma, szolgáltatás, számlázott összeg, `Megjegyzes`, módosítás ideje?
> 7. **Token és korlátok:** meddig érvényes a token, van-e lekérdezési korlát (kérés/perc)?
> 8. **Online forrás:** el tudják-e különíteni az online foglalóból érkező előjegyzéseket (pl. `Status` vagy külön mező), hogy ne kelljen a `Megjegyzes` szövegre támaszkodnunk?
>
> Köszönjük!

## Hogyan oldjuk meg a válaszuk szerint

| Amit megkapunk | Mit építünk |
|---|---|
| Csak olvasó felhasználó + állapot/lista végpont | Hub napi szinkron: `fact_booking` (ElojegyzesID, állapot, megjelenés, bevétel) összekötve a lead `dokirex_booking_id`-jával. Ebből jön a lead→foglalás→megjelent→bevétel tölcsér és a hirdetésenkénti bevétel. |
| Csak egy tárolt eljárás (`runBuiltInQuery`) | Ugyanez, az eljárás kimenetére építve. Az eljárást csak olvasónak kérjük. |
| Semmi új | A Hub csak az általunk küldött foglalásokat követi (`booked` állapot); megjelent/lemondott és bevétel nem lesz. A sikeres foglalás a mérőszám (GA4 `sikeres_foglalas`). |

Addig nem hívunk Dokirex végpontot, nem írunk bele, és a Hub nem kap Dokirex jelszót.

(Frissítés, 2026-10-20: a `builtin_getElojegyzesSzamlazas` eljárást a Dokirex elkészítette és javította; az első működő minta és a belőle adódó nyitott kérdések a `docs/dokirex-szamlazas-minta.md` fájlban vannak. A hívást csak a felhasználó jóváhagyásával, csak olvasásra használjuk.)

## Időpont módosítása a hívásnaplóból (2026-10-20, a recepció kérésére)

Ma a rendszer a Dokirex-ből olvas (kezelések, szabad időpontok, számlázási eljárás) és új előjegyzést ír (`insertOnlineElojegyzes`).

**Javítás (2026-10-20):** a nyilvános API-leírásban (`api-docs-json`) van `updateElojegyzes`, `deleteElojegyzes`, `updateElojegyzesStatus`, `listPaciensElojegyzes` és `listElojegyzesWithDetails` is, tehát az áthelyezés és a törlés támogatott. Korábbi állításunk, hogy módosító vagy törlő végpont nincs, téves volt. A foglaló admin felületén megépült a `reschedule` művelet (`updateElojegyzes`: `ElojegyzesID`, `RendelesiNapID`, `Idopont`, `Megjegyzes`), admin és munkatárs használhatja, próbamóddal (dryRun) és szabad-időpont ellenőrzéssel. Az élő próba egy kitalált tesztpácienssel (elojegyzesId 47026) sikerült: áthelyezés másik napra, a régi időpont felszabadult, törlés után az új időpont is szabad. Nem láttuk még: valódi lead kártyáján a naplózást, és hogy a Dokirex küld-e értesítést a páciensnek áthelyezéskor.

A Dokirexnek a végpontok létezéséről már nem kell kérdezni; a lenti 3–9. kérdés (azonosító, jogosultság, értesítés, tesztkörnyezet, korlátok) továbbra is érvényes, az 1–2. kérdés helyett elég a megerősítés, hogy a `updateElojegyzes` / `deleteElojegyzes` a támogatott, tartós módja az áthelyezésnek és lemondásnak.

> Tárgy: Online előjegyzés módosítása az API-n keresztül
>
> Kedves Roberta!
>
> A recepció a saját felületünkről szeretné módosítani a már rögzített online előjegyzéseket. A nyilvános API-leírásból ezt nem tudtuk egyértelműen megállapítani, ezért az alábbiakban kérjük a segítségüket:
>
> 1. Van-e az API-ban végpont egy meglévő online előjegyzés áthelyezésére (új dátum/időpont, más rendelési nap)? Mi a pontos neve, metódusa és paraméterei?
> 2. Ha nincs: van-e előjegyzést lemondó vagy törlő végpont? Pontosan mi történik ilyenkor a foglalással (törlődik, vagy lemondott állapotba kerül)?
> 3. Melyik azonosítóval hivatkozzunk az előjegyzésre: `ElojegyzesID`, `LastID` vagy `PaciensID`? Az `insertOnlineElojegyzes` válaszában melyik a tartós előjegyzés-azonosító?
> 4. Kell-e a művelethez a rendelési nap (`RendelesiNapID`), a beavatkozás (`BeavatkozasID`) vagy az orvos/felhasználó azonosítója? Át lehet-e helyezni másik orvoshoz vagy másik beavatkozásra?
> 5. Jogosult-e erre a jelenlegi API-kulcsunk, vagy külön jogosultság/Dokirex-felhasználó kell? Naplózza-e a Dokirex, ki módosított?
> 6. Van-e végpont egy előjegyzés aktuális állapotának lekérdezésére (él-e még, mikorra szól)?
> 7. Áthelyezéskor a régi időpont azonnal felszabadul-e? Atomi-e a művelet (vagy minden lefut, vagy semmi)?
> 8. Kap-e a páciens automatikus e-mailt vagy SMS-t módosításkor vagy lemondáskor, és ez kikapcsolható-e?
> 9. Van-e tesztkörnyezet vagy tesztnaptár, és van-e korlát a hívások számára?
>
> Köszönjük!

Állapot: a szerveroldali `reschedule` művelet él és tesztelt; a hívásnapló kártyáján a kézi „átfoglalás-kérés" (piros jelölés, kézi átvezetés) elkészült, de nincs publikálva. A gomb bekötése a `reschedule` műveletre (új szabad időpont választása, próbamód, véglegesítés) és az első valódi áthelyezés a felhasználó jóváhagyására vár. Valódi páciens foglalását csak a recepció egyeztetése után mozgatjuk.
