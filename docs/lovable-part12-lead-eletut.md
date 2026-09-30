# PART 12 – Lead-életút (Lovable Hub projekt 526647ba-a96d-46c0-906b-867ad8f92e4)

Nem ment el (a Lovable munkaterület kreditje elfogyott). Kredit után küldhető a PART 7–11 mögé.

Migráció: `db/migrations/0014_lead_journey.sql` @ commit `19dfd7ce262038f102236225d87afa285cd7e779`, sha256 `c4feda5621cc39489b1e1b4589f318f390b6df17a9648d311b64219549a2ec1e`.

Tartalom: lead_journey nézet (lead_type alkalmassagi/idopontfoglalas; outcome alkalmassagi_kitoltve/foglalt/felbehagyta/visszahivas; lépésidők; forrás; személyszintű összekötés), lead_journey_summary(from,to,bl), lead_step_time(from,to,bl), lead_timeline(lead_id), mart_lead_journey_daily.

UI: „Lead-életút" oldal két külön szekcióval (alkalmassági leadek / időpontfoglalások), összesítő kártyák, lépésenkénti tölcsér medián idővel (végigvitt vs félbehagyott), lista kimenet-jelvénnyel és forrással, részletező panel idővonallal és „ugyanaz a személy" blokkal, kvíz-lemorzsolódás, HU/EN.
