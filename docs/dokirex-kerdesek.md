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
