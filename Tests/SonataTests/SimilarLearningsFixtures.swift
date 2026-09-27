// Memory bodies from 2026-09-26, copied verbatim EXCEPT for pseudonyms. This
// repo is public, so personal details are replaced: family names ("Robin",
// "Casey"), a home path, a session id, and two health-related words (swapped
// for "ELL" and "focus"). The algorithm only sees tokens, and
// SimilarLearningsCorpusStats maps each substitute to the live-corpus count of
// the word it replaced, so the replay still reproduces the incident.
//   3983d3a7, 54293ef2, 6b37fc93: picture-book "reusable techniques" (PSAL hash route,
//     Instagram, Maps photos)
//   21aba24c, 67aa526c: discovery "reusable techniques" (MySchools admissions, Maps
//     depart-at URL, hijacked Open Data websites)
//   1a721afc: picture-books completion summary; cc02ec02: a guide-column decision
//     (stored as type=decision; the tests replay it as a learning)

enum SimilarLearningsFixtures {
    struct Fixture {
        let id: String
        let createdAt: Int64
        let content: String
    }

    static let psalTechniquesBatch1 = Fixture(
        id: "3983d3a794a74bf2bfa3743f0ed6c8d9",
        createdAt: 1790438242500,
        content: #"""
        Picture-book batch 1 (AAS + BSGE) shipped 2026-09-26. Facts: AAS baseball home field = Whitey Ford Field, Astoria (from the PSAL 2025-26 schedule; PSAL school #30470; coach William Carey Jr.). BSGE (PSAL #30540) has NO baseball. Both are in their own buildings.
        Techniques that worked:
        - An Instagram post page (/p/<id>/) opened logged out in a Sonata web session gives full-resolution carousel slides (~2400px); click the aria-label="Next" button one evaluate call at a time, because async evaluate returns an unsupported type. The profile grid login-walls after 12 posts.
        - PSAL team pages use hash URLs: team-profile.aspx#006/<schoolId> (006 = baseball). Click a season link, then read the schedule rows for the home location.
        - NYC Parks photos at full size: /photo_gallery/full_size/<id>.jpg.
        - YouTube oEmbed titles need the watch URL fully encoded. Channel RSS feeds: /feeds/videos.xml?channel_id=UC... When a thumbnail is just a logo, the auto frames at hq1/hq2/hq3.jpg often show real footage.
        - Squarespace CDN serves WebP originals; filenames with spaces 404 on their CDN when a page's own gallery is broken.
        - ImageMagick montage contact sheets make visual verification cheap. The worker shell is zsh, so run array code under bash -c.
        """#
    )

    static let psalTechniquesBatch2 = Fixture(
        id: "54293ef2aad94afd838b9d198e24aea6",
        createdAt: 1790438466498,
        content: #"""
        2026-09-26 Picture Book batch 2 (Robin HS guide) done by sona-worker-3: envstudies (30 img / 2 vid) and beacon (30 img / 4 vid), both approved by Sona (session-5e5510140e0e0e0e). Reusable techniques for later batches:
        (1) PSAL team page: psal.org/profiles/team-profile.aspx#006/<psal school id>/<season year>. 006 = baseball. Find the id on the sport page's school links (#NNNNN). It's a hash route, so reload after changing the hash. The schedule's Location column gives the home field.
        (2) Educational Networks school sites (eChalk-style) keep their best photos in the home-page rotating_images slider (1300–1400px). /apps/album/ is often empty.
        (3) Google Maps photos: in a Sonata web session, click the "Photo of …" button and collect lh3 gps-cs-s URLs, then append =w1600-h1200.
        (4) Wikimedia Commons 'td (date)' photo series cover NYC park ball fields. Good for home-field slides.
        (5) Instagram team accounts are readable without login in a Sonata web session, but only at 640px via signed URLs. Confirm team identity by matching post dates to the PSAL schedule.
        Review rulings from Sona: official team Instagram photos are OK even with score overlays. Videos from individual or personal YouTube channels get DROPPED; put their URLs in notes for Casey.
        Pitfalls: WebSearch is hook-blocked and DuckDuckGo HTML returns a 202 bot challenge. In zsh, "$f[0]" subscripts the string, which hung magick identify; don't use it. Record W-L by counting the schedule, not by eyeballing it (I got both records wrong the first time).
        Beacon baseball: Blue Demons, 3A Western, coach John Sarci, 2026 9-5 regular season plus 1-1 playoffs, home field DeWitt Clinton Park. HSES baseball: Eagles, 1A Manhattan Central, 2026 4-10, home games at Randall's Island Sunken Meadow Field 21.
        """#
    )

    static let psalTechniquesBatch8 = Fixture(
        id: "6b37fc93e73f4a8b8eff9125de45094d",
        createdAt: 1790438864558,
        content: #"""
        Picture Book batch 8 (2026-09-26, foresthill + maspeth) — learnings:
        1. PSAL home fields and records: open psal.org/profiles/team-profile.aspx#006/<schoolid> (006 = baseball; Maspeth = 28585, Forest Hills = 28511) in a Sonata web session with an isolated partition. Then use a synchronous XHR from inside the page to /SportDisplay.svc/getTeamScheduleAny?csports='006'&season=<yr> &schoolid='<id>'. Curl alone gets redirected to the login page because the session cookie is needed. The rows carry cschoolh (home school), clocation, cwinner/closer and cleague (P = playoff).
        2. Maspeth baseball home field: Mafera Park Baseball-01 in Ridgewood (2026, record 8-8). Forest Hills plays on its own on-campus field.
        3. Instagram logged-out: https://www.instagram.com/p/<shortcode>/media/?size=l returns the 1080px original via a plain curl GET (a HEAD request gets 405).
        4. Edlio school sites: old albums are often purged. Insta360 360° tour pages expose og:image covers at 720-1104px.
        5. The Educational Networks video poster is <file>.mp4_ph720.jpg (1280x720); the default .mp41.jpg is only 240px.
        6. The Google Maps photo panel in a background webview loads only its first ~6 photos (lazy-loading doesn't fire).
        7. zsh: "$f[0]" in magick identify is a zsh array subscript, not a frame index — use "${f}[0]".
        """#
    )

    static let discoveryQueensTechniques = Fixture(
        id: "21aba24c1ffd4d0e859cf524acb20c48",
        createdAt: 1790460903070,
        content: #"""
        Discovery/queens shipped 2026-09-26. Reusable techniques:
        (1) MySchools program admissions data is in hidden DOM. Read document.body.textContent and parse per program "<Name> (<code>)Admissions General Education Students With Disabilities … Seats and Demand Last Year N Applications Per Seat N Seats N Applicants … Priority groups (…offers…) … Admissions Method …". The GE numbers show by default; clicking every <label> whose text is "Students With Disabilities" switches all panels to SWD synchronously, so you can re-parse in the same evaluate.
        (2) Google Maps transit with a fixed departure time: /maps/dir/<lat,lng>/<lat,lng>/data=!4m6!4m5!2m3!6e0!7e2!8j<unixSecondsAsIfUTC>!3e3?hl=en. Read innerText after "Copy link". The second evaluate after navigating is reliable; the first may return empty.
        (3) The website fields in NYC Open Data dataset 8b6c-7uty (2021 HS directory) are stale, and some domains are HIJACKED (clanyc.org → gambling, wcbryanths.org → spam). Always take school websites from current MySchools links and verify the page title.
        Queens reality check: few strong ≤60-min options from Astoria beyond the already-covered list. Forest Hills (MELS / Queens Metro) runs 67–71 min.
        """#
    )

    static let discoveryManhattanSouthTechniques = Fixture(
        id: "67aa526ca4a64d8489972984d5dc8d03",
        createdAt: 1790461256720,
        content: #"""
        2026-09-26: Discovery slice manhattan-south (Robin HS guide) shipped by sona-worker-3, and Sona sent shipit. Candidates, best first: Manhattan Village Academy (02M439; every SWD applicant got an offer), School of the Future (02M413; baseball 14-4, 100% SWD grad), NYC Museum School (02M414), AFSE (02M546; open admission), UA Maker (02M282), NYC iSchool (02M376; online-heavy, an focus risk).
        REUSABLE TECHNIQUES:
        (1) MySchools JSON API: https://www.myschools.nyc/en/api/v2/schools/process/1/<DBN>/?page=1& → programs[].demand_last_year.{general_education,students_with_disabilities}.{applications_per_seat,seats,applicants}, program_priority_groups[] with GE/SWD offer counts, selection_criteria[], independent_website, sports_boys, total_enrollment. No auth needed.
        (2) InsideSchools stats in static HTML: regex "<n>% <label> <m>% Citywide Average" gives school n and citywide m.
        (3) The InfoHub class-size xlsx can be read in Node by unzipping and parsing sharedStrings plus sheet XML. The "MS HS Average" tab is sheet 3 and PTR is sheet 5. Blended/online schools report giant sections, so don't publish those averages.
        (4) Google Maps depart-at URL: data=!4m6!4m5!2m3!6e0!7e2!8j<local time encoded as a UTC epoch>!3e3.
        (5) Websites in the 2021 open-data directory can be hijacked; take them from MySchools and verify the page title.
        """#
    )

    static let pictureBooksComplete = Fixture(
        id: "1a721afcf44642178b95a660e7a8b616",
        createdAt: 1790439670920,
        content: #"""
        Robin HS Picture Books COMPLETE (2026-09-26): 23 per-school slideshow artifacts (616 photos, 97 videos) published to 4A (d_tag picture-book-<id>), each linked from a "📸 Picture Book" button on its school card in the main guide. Pipeline in /Users/casey/.sonata/session/session14/picture-books/: 11 Sona workers gathered <id>/manifest.json + img/ per BRIEF.md; review-sheet.sh <id> (contact sheet); build-picture-book.mjs <id> (ImageMagick auto-orient/strip, data-URI JPEG, auto size tiers to fit 4A's 4 MiB publish limit); link-picture-book.mjs <id> <url> <photos> <videos> (idempotent button + links.json). Lessons: `magick montage` writes the LAST argument (my first attempt overwrote 3 source images — use @list file); sips ignores EXIF orientation; 4A publish max 4 MiB/payload; PSAL home fields/schedules are reachable via PSAL's schedule API in a Sonata web session (getTeamScheduleAny). Rulings: personal/family YouTube channels excluded (links given to Casey), official team IG accounts OK, student full names in images dropped/cropped. Baseball scorecard: East Side powerhouse (city champs 2015/2024/2026), Beacon, Sinatra (13-1, Whitey Ford Field Astoria), Baruch (2022 champs, 2026 1A finalist), AAS (Whitey Ford Field), Forest Hills own field; Millennium = John Jay Campus team in Park Slope Brooklyn.
        """#
    )

    static let unrelatedColumnDecision = Fixture(
        id: "cc02ec0260a241b1af7c90455c923d47",
        createdAt: 1790457898015,
        content: #"""
        Robin HS guide (2026-09-26): per Casey, ELL info = one "ELL Sat." column in the master table + detail on cards (no ⚠️/⭐ flags). Metric: % of parents of students with disabilities who say the school works to achieve ELL goals (2024-25 NYC School Survey via InsideSchools; citywide 91%); cards show that + "enough services" (citywide 90%). Data pulled by scratchpad ell-survey.mjs → ell-survey.json; build-table.js reads it. Verified DBNs incl. Orchard 01M292 and RR Green 02M580 (01M515/02M313 are other schools). Values: BSGE 100, Orchard 92→(goals 92), UNHS 95, Forest Hills 95, RR Green 97, East Side 94, Middle College 94, Maspeth 93, NYC Lab 92, Env Studies 90, Eleanor 90, Info Tech 90, Bard 90, HSTAT 89, Millennium 88, AAS 84, Essex 84, Baruch 80, Landmark 80, Sinatra 80, Harbor 76, Clinton 58, Beacon 49. Old card "ELL Satisfaction" numbers were a different, broader question and were replaced.
        """#
    )
}
