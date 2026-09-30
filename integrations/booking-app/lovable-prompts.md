# Lovable promptok – Saint James ALkalmassági app (`4e4a2d01-684a-4dbb-90a6-86ff4f8271e0`)

> Ezeket **még nem küldtük el** a Lovable-nek (kreditet fogyaszt és éles appot módosít). Jóváhagyás után küldhetők sorban, külön-külön, és mindegyik után érdemes kipróbálni az appot.
> Előfeltétel: a `lassjol-parent/sj-attribution.js` scriptben a `bookingOrigins` kitöltése az app valódi origin-jével.

## 1. prompt – Adatbázis (migráció)

```
Add a database migration to the leads funnel. Use the SQL in this message verbatim (create a migration file).
Do not change existing RLS policies on `leads`. Do not expose quiz_answers, booking notes, birth date, sex or TAJ in any new view.

<az 0001_attribution_and_events.sql tartalma; a `hub_reader` szerepkör külön, kézzel futtatandó: 0002_hub_reader_role.sql>
```

## 2. prompt – Attribúció rögzítése

```
Capture marketing attribution and store it on the lead.

Context: this app is embedded as an iframe on https://lassjol.hu. The parent page runs a script that (a) appends query params to the iframe URL prefixed with `a_` (a_utm_source, a_utm_medium, a_utm_campaign, a_utm_content, a_utm_term, a_fbclid, a_gclid, a_wbraid, a_gbraid, a_ttclid, a_ga_cid, a_host) and (b) sends a window.postMessage({type:"sj-attribution", v:1, first:{params,referrer,landing,ts}, last:{...}, ga_client_id, parent_host}). The app can also ask for it with window.parent.postMessage({type:"sj-attribution-request"}, "<PARENT_ORIGIN>").

Implement:
1. `src/lib/attribution.ts`: on first load read the `a_*` query params, then listen for the postMessage (accept ONLY from the allowed parent origin `https://lassjol.hu` and `https://www.lassjol.hu`, check event.origin strictly), and also send the `sj-attribution-request` message once on mount. Merge results, persist in localStorage (key `sj-attribution`) and expose `getAttribution()` returning { utm, clickIds, firstTouch, landingUrl, referrer, gaClientId, parentHost }. Whitelist keys, cap each value at 200 chars. Never throw if storage is unavailable.
2. Send this attribution in the `booking-lead` Edge Function calls (`draft` and `complete`) and in the quiz lead submission. In `booking-lead` validate/whitelist the fields again server-side and write them to the new `leads` columns: utm, click_ids, first_touch, landing_url, referrer, ga_client_id, parent_host. Only set these when the lead has none yet (never overwrite first-touch data with empty values).
3. Also store the quiz session id (localStorage `sj-quiz-session-id`) in `leads.quiz_session_id` when present.
4. Do NOT add any tracking pixels, analytics scripts or third-party requests to the app. Do not send any of this to any third party.
```

## 3. prompt – Strukturált Dokirex azonosító

```
Store the Dokirex booking id in a structured way.

Currently `createBooking` returns `elojegyzesId` and BookingContainer only writes it into the free-text `note`. Change this:
1. `completeBookingLead` must also send `dokirexBookingId` (number or null) and the `booking-lead` `complete` action must save it to `leads.dokirex_booking_id` and into `booking_details.dokirex = { elojegyzesId, status: "booked", bookedAt: <ISO> }` (the admin LeadsTable already reads `booking_details.dokirex.elojegyzesId` and `.status`). Keep the note as it is.
2. If the Dokirex booking succeeded but saving the lead fails, retry the save up to 3 times with backoff before showing an error, and never call the Dokirex book endpoint twice.
3. Show the stored Dokirex id in the admin LeadsTable from `dokirex_booking_id` if `booking_details.dokirex` is missing (older rows).
```

## 4. prompt – Eseménynapló

```
Add a server-side event log for the booking funnel using the new `lead_events` table.

In `booking-lead` (service role) insert a row into `lead_events` for: the existing `progress` calls (event "step_view", step = lastStep, meta = { secondsOnLastStep }), a `draft` with submitted=false ("contact_saved"), `complete` ("booking_confirmed"), and callback requests ("callback_requested"). Also log "booking_failed" when the client reports a Dokirex error (add a small `event` action for that, whitelisted event names only, no free text, no PII in meta). Do not log names, emails, phones, health answers or notes.
```

## Utólagos ellenőrzés (minden prompt után)

- Nyisd meg az iframe-et a lassjol.hu-n egy `?utm_source=test&utm_campaign=test&fbclid=abc` URL-lel → küldj be egy teszt leadet → a `leads` sorban ott legyen az `utm`, `click_ids`, `landing_url`.
- Teszt foglalás után `dokirex_booking_id` ki legyen töltve.
- Egy nem engedélyezett domainről beágyazva (vagy konzolból küldött hamis `postMessage`) az attribúció ne íródjon át.
