# Data Hub v2 – a Google Ads és a Meta Ads együttes mélysége, és amit egyik sem ad

Ez a dokumentum rögzíti, mit építünk, mire támaszkodik (ellenőrzötten), és mi nem megoldható. A kódot az `db/migrations/0004–0006` tartalmazza, teszteltük (`db/tests`, 10 teszt).

## 1. Ellenőrzött adatforrások (Windsor, éles lekérdezéssel)
| Terület | Mit kapunk | Megjegyzés |
|---|---|---|
| Meta hirdetés | név, **szöveg (body/title)**, **előnézeti kép**, CTA, **megosztható előnézeti link**, kreatív-azonosító, státusz, költés, megjelenés, kattintás, elérés, gyakoriság, **3 mp-es videólejátszás**, post-elköteleződés, **landing page view**, minőségi/elköteleződési/konverziós **rangsor**, kampány- és hirdetéscsoport-költségkeret, licitstratégia, cél | a miniatűr-URL-ek lejárnak (alá vannak írva), ezért naponta frissítjük; a rangsor kis volumennél „UNKNOWN" |
| Meta bontások | elhelyezés, kor, nem, eszköz, óra | csak riport, a célzás 18–65 fix |
| Google keresési kampány | **kulcsszó**, keresési kifejezés, költés, megjelenés, kattintás, konverzió, **megjelenési részesedés** (elvesztve költségkeret vs. rangsor miatt), minőségi mutató | csak keresési (GSN) kampányok |
| Google Performance Max | kampány/eszközcsoport szint | **nincs kulcsszó, nincs keresési kifejezés** – ez a Google korlátja |
| Google beállítások | licitstratégia (pl. MAXIMIZE_CONVERSIONS, TARGET_SPEND), napi költségkeret, cél-CPA, csatornatípus | stratégia-felismeréshez |
| TikTok | kampány, hirdetés, szöveg, CTA, státusz, like/komment/megosztás/követés, átlagos lejátszási idő, költség/eredmény | nincs miniatűr-URL, nincs hirdetéscsoport-mező |
| GA4 | látogató, munkamenet, elkötelezett munkamenet, nézet, elköteleződési idő, **csatorna/forrás/médium/kampány**, belépő oldal, események | a GA4 `kampány` **pontosan a hirdetési kampány neve** → név szerint összekötjük a hirdetéssel |
| Ahrefs | szerves kulcsszó, pozíció, forgalom, volumen | csak a domain által rangsorolt kulcsszavakra |

## 2. A tölcsér és a lemorzsolódás minden szinten
Megjelenés → kattintás → (kattintás→látogató veszteség) → munkamenet → elkötelezett munkamenet → **soft lead** (GA4 `soft_conv_foglaljon`) → foglaló megnyitva → lépésenként (Elérhetőség, Választás, Kezelés, Naptár, Megerősítés) → **hard lead** → **foglalás** (Dokirex-azonosító) → (megjelent / lemondta: Dokirex-státusz, amint a végpont megvan).
- Külön nézet: **kvíz-tölcsér** (lépésenkénti elérés), **hol hagyták abba** a foglalók, **lépésenkénti idő**, **kohorsz** (hány % foglal 1/3/7/14/30 napon belül), **mikor érkeznek** a leadek (óra × nap).
- A tölcsér szűrhető üzletágra, kategóriára, alkategóriára, platformra, kampányra, témára; időszak-összehasonlítással.

## 3. Korrelációk
Jelek (napi): költés / kattintás / megjelenés platformonként, Google keresési és brand megjelenés/kattintás, látogatók csatornánként, soft lead, hard lead, foglalás. A motor **késleltetett** (0–14 nap) korrelációt számol, **hétköznap-hatás kiszűrésével**, n-nel és t-statisztikával, a triviális (egymást tartalmazó) párok nélkül. **Tesztelve:** a beültetett 3 napos késleltetést megtalálja, a zajt nem.
Megfelelő óvatosság: a korreláció **feltáró jelzés**, nem ok-okozat; sok pár vizsgálatánál véletlen egyezés is előfordul – ezért a felület mutatja a mintaszámot és a szignifikanciát.

## 4. Kreatívok
Lista (előnézeti kép, szöveg, CTA, kampány, téma, státusz), mutatók: költés, megjelenés, elérés, gyakoriság, CTR, CPC, CPM, **hook rate** (3 mp-es lejátszás / megjelenés), elköteleződési ráta, platform-lead, költség/lead, rangsorok; **Pareto** (melyik hirdetések adják a kattintások 85%-át – ahogy az Excelben kérték); **fáradás-jelzés** (CTR esik, gyakoriság nő); bontások (elhelyezés, kor, nem, eszköz).

## 5. Észrevételek (insights) – szabályalapú, bizonyítékkal és teendővel
pazarló kulcsszó · költségkeret-korlátos, hatékony kampány · rangsor-korlátos kampány · CPC-ugrás · kreatív-fáradás · gyenge kreatív a saját kampányához képest · kattintás→látogató veszteség · **követés-kiesés** (van költés, nincs mért látogató) · költés-anomália · foglalási lépés-szivárgás · új kulcsszó-lehetőség (konvertáló keresési kifejezés) · költségkeret-változás · Meta/TikTok→Google brand „halo” kapcsolat. A küszöbök szerkeszthetők (`insight_threshold`).

## 6. Amit a mostani mérés nem tud – és a két beállítás, ami ezt megoldja
1. **A lead még nem köthető a kampányhoz/kulcsszóhoz/kreatívhoz.** A foglaló csak azt látja, ami az URL-ben van. A Meta-hirdetéseknél a GA4 kampánynév alapján a UTM már beállított (kampánynév), de a hirdetés (kreatív) és a hirdetéscsoport nincs benne; a Google automatikus címkézés csak `gclid`-et ad.
   - **Meta (hirdetés szintű URL-paraméterek):** `utm_source=facebook&utm_medium=cpc&utm_campaign={{campaign.name}}&utm_content={{ad.id}}&utm_term={{adset.name}}`
   - **Google Ads (fiókszintű „Final URL suffix", előnyben a követősablonnal szemben, mert nem írja át az átirányítást):** `utm_source=google&utm_medium=cpc&utm_campaign={campaignid}&utm_content={creative}&utm_term={keyword}` (a Google ValueTrack-ben nincs kampánynév, ezért azonosító; a Hub a kampány-azonosítót nevesíti)
   - **TikTok:** `utm_source=tiktok&utm_medium=cpc&utm_campaign=__CAMPAIGN_NAME__&utm_content=__CID_NAME__`
   Ezután a lead a kampányon túl **kulcsszóhoz és kreatívhoz** is köthető (kulcsszó → hard lead → foglalás). Figyelem: a Google automatikus címkézés és a kézi UTM együtt is használható, de ellenőrizni kell, hogy a GA4 jelentések ne változzanak („felülírás engedélyezése" beállítás).
2. **Dokirex-státusz** (megjelent / lemondta / bevétel) a végpont ismeretében köthető be.

## 7. Korlátok (őszintén)
- Performance Max: nincs kulcsszó-szint.
- A Meta gyakorisága és elérése **nem összeadható** több napra (egyedi elérés); a Hub a napi értékekből becsül, és jelzi.
- A korreláció nem bizonyít ok-okozatot.
- Az esztétika/plasztika kategóriák még nincsenek meghatározva.
- A Windsor-fiók jelenleg próbaidőszakon van (30 nap): fizetős csomag kell a folyamatos betöltéshez.


## 8. Teendők a lead-attribúcióhoz (sorrend!)
1. A foglaló app publikálása (Lovable) – hogy a böngészős attribúció élessé váljon.
2. A GTM-snippet a lassjol.hu-n (`integrations/lassjol-parent/gtm-custom-html.html`).
3. Hirdetési URL-paraméterek: Meta (hirdetésenként), Google Ads (fiókszinten, „Final URL suffix"), TikTok (hirdetésenként). A Google „felülírás engedélyezése" (manuális címkézés felülírja az automatikusat) **maradjon kikapcsolva**, hogy a GA4 kampánynevei ne változzanak.
4. Próba: `https://lassjol.hu/?utm_source=teszt&utm_medium=cpc&utm_campaign=TESZT&utm_content=teszt1&utm_term=teszt2` → foglaló, Elérhetőség lépés belső e-mail-címmel → a lead sorában a `utm` mezőben jelenjenek meg az értékek (a próba-leadet utána törölni).
