# Website integration verification — 2026-09-18

Current release is complete: Production deployment `dpl_8PWF9FgXXRnYstJYyL52eBD4D8xP` is READY and aliased to `yaprflow.com`. Public configuration verifies enabled live Stripe checkout, USD 799 cents, `downloadReady: true`, and `voiceDemoAvailable: true`. A synthetic-microphone browser check opened the OpenAI Realtime session and reached “Live — speak naturally.” Fresh mobile production checks verify that the sticky offer prompt appears in earlier sections and hides at the purchase section, leaving the checkout button unobstructed. The active artifact path is `releases/yaprflow-5.1.3.dmg`. The Mac app and DMG passed signing, notarization, stapling, and Gatekeeper, and the full uploaded DMG matches its local size and checksum. No personal/card details were entered, no live payment was submitted, and no paid live delivery was performed. Actual GA/Meta dashboard event receipt remains unverified. The existing published refund-contact policy remains in effect, and the optional fixed-window preference is unanswered.

Ordinary HTTPS requests and Chrome show the redesigned `https://yaprflow.com/` page from Vercel. The initial cookie panel is hidden and both expected Google and Meta script URLs appear in the page. This verifies browser initialization, not receipt in the vendors' dashboards. Google DNS-over-HTTPS returns the correct apex A and www CNAME, while this computer's ordinary www lookup may remain cached.

Historical post-publication log check: a bounded, non-streaming query for production deployment `dpl_GU9rd9o7GwV4W63yQZRaSQ198RN3` returned zero error records over the preceding 15 minutes (limit 100).

Production website: https://yaprflow.com/ — enabled live checkout and the new Mac 5.1.3 artifact configuration are public. The www canonical redirect and private confirmation routes pass the smoke checks below.

Latest verified sandbox Preview: https://yaprflow-checkout-86xb5tpyo-tmoretons-projects.vercel.app/ — deployment READY; Meta code and the cookie delivery route are included.

The original sandbox payment/file test below used https://yaprflow-checkout-izzvhj3ct-tmoretons-projects.vercel.app/.

## Live Stripe connection and canonical release

- The user saved `STRIPE_SECRET_KEY` as a Vercel Production Secret. Secret values are not included in the repository or this report.
- Historical live-key deployment `dpl_GeDcvzGSdF6G4h6M5yYZyPVYKDAL` was READY at `https://yaprflow-checkout-cwncgeupf-tmoretons-projects.vercel.app` and served the public apex with live mode, the $7.99 price, and checkout disabled. The new release supersedes it.
- Stalled deployment `dpl_BUGE9NTuHnepw8dewUccbGYHiHZo` at `https://yaprflow-checkout-c288qfi84-tmoretons-projects.vercel.app` and the interim prebuilt deployment identified as `DCx` were canceled; CANCELED was confirmed for both.
- Final deployment `dpl_8PWF9FgXXRnYstJYyL52eBD4D8xP` is READY at `https://yaprflow-checkout-jtoglzwar-tmoretons-projects.vercel.app`. It is aliased to `yaprflow.com`, `www.yaprflow.com`, and `yaprflow-checkout.vercel.app`. Public configuration verifies `enabled: true`, `mode: "live"`, price `{amount: 799, currency: "usd", formatted: "$7.99"}`, `downloadReady: true`, and `voiceDemoAvailable: true`.
- Vercel's [Elevated Errors Triggering Deployments incident](https://www.vercel-status.com/incidents/bwkmw4hmrgmk), first posted September 18 at 20:32 UTC, delayed the release. Its observed 21:07:13 UTC update was Identified, with a fix being implemented. The final prebuilt deployment subsequently reached READY and public smoke checks passed; no claim is made here that the platform-wide incident is resolved.
- A bounded, non-streaming error-log scan of READY deployment `dpl_GeDcvzGSdF6G4h6M5yYZyPVYKDAL` returned zero error records over the preceding 15 minutes (limit 50). This is a limited runtime observation, not proof of a completed live purchase.
- The latest full suite passed 77 tests and the build. After website metadata changed to version 5.1.3, 17 frontend tests passed. Historical test counts and sandbox payment/file evidence below describe their respective earlier checks.
- Production `CHECKOUT_ENABLED=true` is now active publicly. The user explicitly asked to fix the disabled checkout. We retained the existing published refund-contact wording and informed the user; the user did not select those terms, and the optional fixed-window question remains unanswered. That preference is not a release blocker. No real live purchase or paid live download has been tested.
- Stripe's dashboard shows email verification and Activate products as Complete. The Managed Payments setup guide shows Not Started. These observations do not establish that every merchant setup requirement is complete.

## Published prebuilt release and Mac icon update

- The local Production build passed for the correct linked project and Production target. It generated six Node.js 24 API functions, each with zero environment-override keys, and the intended canonical www-to-apex redirect. Public output excludes credentials and installers.
- API configuration remains runtime-based, with no local secret value embedded in the functions. Active Production uses `BLOB_PATHNAME=releases/yaprflow-5.1.3.dmg` and `CHECKOUT_ENABLED=true`; public enabled configuration is verified.
- Apple accepted the Yaprflow 5.1.3 (build 9) Mac app and DMG for notarization. Both are signed, notarized, stapled, and Gatekeeper accepted. The mounted DMG's app passed deep, strict signature verification, stapler validation, and Gatekeeper assessment. It includes arm64 and x86_64, and all ten Mac icon assets match the website artwork. This is a Mac-only update; the original 5.1.0 artifact is preserved.
- `build/yaprflow-5.1.3.dmg` is 490,758,636 bytes, with SHA-256 `0620cbf859ff03337b440faae30b920dc35924d0666bfa6f05d8191bad75b13b`. It was uploaded to the existing private store at `releases/yaprflow-5.1.3.dmg`. An unauthenticated GET returned 403.
- Full uploaded-file integrity passed: `/private/tmp/yaprflow-5.1.3-published.dmg` is exactly 490,758,636 bytes and has the same SHA-256. This verifies the private stored artifact, separately from a paid live download, which has not been performed.
- Website metadata is 5.1.3, the final local prebuilt Production build passed, and the release is READY and publicly aliased. The historical 5.1.0 sandbox checksum and file test below are separate evidence.
- All six checks in `/private/tmp/yaprflow-production-smoke.mjs` passed against the public deployment: enabled live USD $7.99 configuration; version 5.1.3 metadata; public Google/Meta code hashes; www redirects; private confirmation redirect/cookie flow; and unauthorized status/download denial. An earlier run during domain assignment failed its initial enabled assertion because the preceding release was still serving; the final public run passed all checks.
- Browser verification passed: clicking the real **Buy Yaprflow — $7.99** button on `https://yaprflow.com/` opened live Stripe-hosted checkout titled Yaprflow. It showed **Yaprflow for Mac — Founding lifetime license**, a one-time $7.99 subtotal, address-dependent tax, and card/wallet options. No personal or card details were entered, and no payment was submitted.
- The deployment CLI exited 0 and confirmed READY and the apex alias. The final deployment's bounded runtime error scan (`level: error`, preceding 15 minutes, limit 50) returned no logs, meaning no error records in that checked window. Provisioning and public alias assignment are complete.

## Default-enabled tracking update

- The user requested Google Analytics and Meta tracking enabled by default after the no-automatic-bar production release. When no saved tracking choice exists, both categories start enabled. Explicit saved opt-outs and Analytics-only choices are preserved. Malformed stored values or a storage-read error leave tracking off, and the default is not persisted as a visitor-made choice.
- Cookie settings remains a manual footer control with no automatic prompt. The buttons are **Turn off tracking**, **Analytics only**, and **Allow all**. The production-host restriction, private-URL safeguards, test-purchase exclusion, and necessary purchase-cookie separation are unchanged. Google advertising settings stay denied.
- The default update passed 18 Google/Meta tests and 17 website regression tests, 35 relevant tests in total, plus the build. Historical Production deployment `dpl_CwM554LvnNW61QoUhxwTwxyW9xkp` reached READY at `https://yaprflow-checkout-hnr372vps-tmoretons-projects.vercel.app` and was assigned to the Production domains before the live-key deployment replaced it.
- Direct, certificate-verified HTTPS requests to the configured Vercel address for both `yaprflow.com` and `www.yaprflow.com` returned `analytics.js`, `meta-pixel.js`, and `/policies/` with SHA-256 hashes matching this release. Browser and ordinary local DNS fetches were still cached at the time of that check; ordinary apex browsing now shows the redesign. Actual tag receipt in vendor dashboards remains unverified. The production deployment evidence below describes the earlier initial publication.
- Public policy and operating documentation now state that tracking is enabled by default and can be changed through Cookie settings. This is not recorded or described as visitor consent. Actual Google Analytics and Meta Events Manager receipt remains unverified.

## Completed

- The latest full suite passed 77 tests and the build. Historical no-automatic-bar change: 32 focused frontend, Google, and Meta tests and the build passed. The preceding full implementation passed 73 tests, including checkout, settings separation, Meta events, and cookie delivery coverage; the original pre-analytics baseline passed 43 tests. The default-update check passed 35 relevant tests plus the build.
- Public build excludes environment files, backend source, and installers; asset directories reject hidden files, symlinks, and unexpected extensions.
- Local HTTP checks: landing, support, policies, legacy privacy redirect, video range delivery, and denial of package/config files including an encoded traversal attempt.
- Responsive browser checks: 390-pixel phone and 1440-pixel desktop layouts; no horizontal overflow at phone width; navigation opens/closes; video metadata loads (23.787 seconds); support and confirmation pages render without application console errors.
- Stripe sandbox product and one-time $7.99 price created in the Yaprflow account, with test key saved as a Preview Secret after explicit user approval.
- Managed Payments account defaults respected. Test-only product category: downloadable non-recreational software, personal use (`txcd_10202001`).
- Actual unpaid checkout: payment status 202/pending, download 403.
- Actual sandbox payment using Stripe’s standard test card and fictional test customer: $7.99 + $0.71 New York test sales tax = $8.70. No real money moved.
- Stripe returned to the correct preview confirmation URL; payment verified and download button displayed.
- Paid download endpoint returned 303 to a five-minute private Blob URL.
- Signed URL returned 200 and delivered 490,720,322 bytes to `/private/tmp/yaprflow-purchase-test-5.1.0.dmg`.
- Downloaded SHA-256: `faa407edac77777bf841be06b195ecbaee6ee24df28fbc0228c518c4ac708720`, matching the signed/notarized release.
- Direct unsigned Blob URL returned 403.

## Production publication

- The user approved the US $7.99 one-time price, plus applicable tax, and requested the production website and live Stripe checkout.
- Created live product `prod_VHf8LJ6S6B1Rk6` and live price `price_1UH5oDAlzJZxFihrxO8VSy8p` in the Yaprflow Stripe account. The live Price ID is saved as `STRIPE_PRICE_ID` in Vercel Production.
- The user approved and completed saving the live key as a Vercel Production Secret. The live connection, enabled checkout, price, and new Mac installer configuration are now published in the final deployment recorded above.
- Historical no-automatic-bar publication: deployment `dpl_GU9rd9o7GwV4W63yQZRaSQ198RN3` reached READY at `https://yaprflow-checkout-i372n86gz-tmoretons-projects.vercel.app`, aliased to `https://yaprflow-checkout.vercel.app`. The alias returned the redesigned landing with HTTP 200 and served analytics code with the choices panel hidden on load. That release retained the earlier tracking defaults; the subsequent default-enabled request is recorded above.
- Production uses `CHECKOUT_BASE_URL=https://yaprflow.com`, active `CHECKOUT_ENABLED=true`, and the 5.1.3 artifact path. Before the live key was connected, the initial publication's `/api/config` returned HTTP 200 with `enabled: false`, `mode: null`, `price: null`, `downloadReady: true`, and `voiceDemoAvailable: false`. That historical disabled configuration is superseded by the final public live configuration above.
- Both custom domains are attached to Vercel. Namecheap DNS changes were saved and rechecked in its UI. Google DNS-over-HTTPS returns only A `216.150.1.1` for the apex and CNAME `49cac89f54e8a17a.vercel-dns-016.com` for `www` (observed TTL 1799).
- The initial apex certificate failure was resolved: `vercel certs issue yaprflow.com` succeeded in 15 seconds. Direct TLS to `216.150.1.1` with the correct hostname validates for both `yaprflow.com` and `www.yaprflow.com`. During initial publication, `/`, `/analytics.js`, `/api/config`, `/policies/`, and `/support.html` returned HTTP 200 on each hostname. Those historical responses contained the redesigned hero, `banner.hidden=true`, and the then-unconnected configuration with `enabled: false`, `mode: null`, `price: null`, `downloadReady: true`, and `voiceDemoAvailable: false`.
- Ordinary apex HTTPS requests and Chrome now show the redesigned site. Some ordinary www lookups may still be cached; correct current DNS and direct TLS are verified. Working delivery on every browser/network is not claimed.
- The no-automatic-bar change passed 32 focused frontend/GA/Meta tests and the build. The preceding full suite passed 73 tests.

Website DNS changes saved and rechecked in Namecheap:

| Record | Previous GitHub Pages value | Saved Vercel value |
| --- | --- | --- |
| Apex `A` (`@`) | `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` | `216.150.1.1` |
| `www` CNAME | `tmoreton.github.io.` | `49cac89f54e8a17a.vercel-dns-016.com` |

The old GitHub Pages A records were removed. Existing mail forwarding and SPF were preserved. Registrar UI and Google DNS-over-HTTPS confirm the new records. Earlier local UDP/OS lookups returned cached older records; ordinary apex browsing now reaches the redesign, while some www lookups may remain cached. HTTPS is verified for both domains at the configured Vercel address.

## Analytics restoration

- Recovered the existing GA4 ID `G-0FTBJXMCSM` from `docs/index.html` in commit `7931bd783ca02333b01cde36a442e2a22281a119`; commit `9972ede021c3902528889f4ca60395566c560998` removed it. No alternative GA4, GTM, or UA IDs were found in the website history scan.
- The updated behavior enables Google and Meta by default on `yaprflow.com` and `www.yaprflow.com` when no saved choice exists, with no events on local, Vercel alias, or Preview hosts. Saved explicit settings remain authoritative. Default-enabled deployment files and browser initialization on the apex are verified; dashboard receipt remains unverified.
- Google advertising signals, advertising storage, advertising user data, and advertising personalization stay disabled. Explicit choices are kept in local storage; default values are not saved as a choice. The page views sent by our code use canonical paths without queries, fragments, or referrers; custom event fields are allowlisted.
- Implemented custom events cover offer clicks, demonstration-video starts/completions, live checkout starts, verified live purchases, and download clicks after payment verification. Purchase reporting uses a stable one-way hashed `transaction_id`, net value, tax, and currency. Repeated events are limited by in-memory state for the current page and the stable ID sent to GA; no purchase reference is persisted in local storage, allowing later visits to retry if Google was blocked. Custom events exclude email, audio, transcripts, checkout session IDs, and private URLs.
- The Google dashboard confirms account `392393866`, YaprFlow property `534290536`, web stream `14419117042`, URL `https://yaprflow.com`, and measurement ID `G-0FTBJXMCSM`. The user explicitly chose to **keep Enhanced Measurement enabled**, so automatic events remain active according to the Google stream settings; collection is not limited to custom events.
- Saved Google query-parameter redaction for `session_id`, `vercel-blob-delegation`, `vercel-blob-signature`, `client_secret`, `payment_intent`, `token`, and `signature`. Email redaction was already enabled and remains enabled.
- Google and Meta code is deployed in Preview and Production; the default-enabled Production files match the tested release. Each vendor runs only while its category is enabled and on a permitted production hostname; no tracking occurs on Vercel aliases or Preview hosts. Cookie settings opens on request rather than appearing automatically. Actual event receipt in the GA dashboard and Meta Events Manager remains unverified.
- GA counts are affected by tracking settings and blockers; Stripe remains the sales source of truth. A download-click event does not establish that a file completed downloading.

- The earlier Google-only baseline passed 56 tests and its build, including its then-opt-in behavior, preview exclusion, custom-event private-data exclusion, and analytics failure handling. The later combined baseline passed 73 tests. These historical tests do not establish automatic Google payloads or platform receipt.
- Historical browser checks covered the Google-only controls on `yaprflow-checkout-ipsz82dp3-tmoretons-projects.vercel.app`; historical combined-settings checks are recorded below.

- Reopened Google settings and verified all seven Enhanced Measurement switches remain on. Site-search keys are the defaults `q,s,search,query,keyword`, with no additional keys. The seven redaction keys persisted with Save disabled; Google's “Preview redacted data” displayed `(redacted)` for the tested `session_id`, `client_secret`, `vercel-blob-delegation`, and `vercel-blob-signature` values. This checks those sample redactions, not live event receipt.

## Meta and cookie-delivery update — deployed to Preview

- The user supplied Meta Pixel `1391229936449100` and requested `PageView`, landing-page `ViewContent`, accepted live-checkout `InitiateCheckout`, and `Purchase` only after server verification of a paid live purchase with the actual net value and currency.
- Google Analytics and Meta Marketing remain separate settings. In the default-enabled update, both are enabled when no saved choice exists; **Turn off tracking** disables both, **Analytics only** enables Google and disables Meta, and **Allow all** enables both. Existing explicit Google-only settings are preserved. Tags run only while enabled on the permitted production hostnames; local and Preview remain excluded. Google advertising settings stay denied, and Enhanced Measurement stays enabled as requested.
- The Meta integration disables `autoConfig` and advanced matching, uses fixed fields and a stable hashed purchase `eventID`, and has no static `noscript` pixel that bypasses settings. Page-session memory and the stable event ID reduce duplicate purchase reports but do not establish exactly-once delivery. The integration excludes raw email, audio, transcript text, checkout session references, and private download URLs from its events.
- The deployed Stripe return route is `/api/complete?session_id=...`. Direct checks verified a 303 redirect to exactly `/confirmation.html` and a host-only `__Host-yaprflow-purchase` cookie with `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, and `Max-Age=2592000` (30 days), plus `no-store` and `no-referrer` response headers. Legacy confirmation queries also redirect before HTML. Status/download use the cookie and recheck Stripe entitlement; presigned download URLs are never inserted into the page.
- Necessary purchase access remains separate from optional consent. Customers can return in the same browser for 30 days; if the cookie is cleared, expires, or they change browsers, support can help using their checkout email. This period does not limit the installed app. Policy and support prose now explain that behavior.
- Historical browser checks at 390 pixels showed all three then-current settings buttons fitting with no horizontal overflow. **Analytics only** and **Allow all** persisted across reloads. Neither vendor tag loaded on local pages even after **Allow all**. These checks preceded the default-enabled update and renamed off button.
- Chrome followed an existing paid sandbox purchase's legacy confirmation link through a redirect before HTML to clean `/confirmation.html`. The page showed the verified paid test message and a download link with exactly `/api/download`, without a query. After declining optional cookies, revisiting clean confirmation still verified the purchase and showed the download ready.
- Direct deployed API checks passed: status without a purchase cookie returned 403; status with the completion cookie returned 200 with `paid: true`, `mode: test`, and no analytics payload. Download with that cookie returned 303 to the expected private Blob hostname with a signed query. The signed URL was not followed, so this verifies the new delivery authorization and redirect without repeating the full-file download. The earlier complete-file checksum result remains the historical artifact verification. Receipt in Meta Events Manager and the actual GA dashboard remains unverified.

## Remaining release decisions/checks

- The existing published refund-contact policy remains in effect. A fixed 14-day or 30-day window can be added after the user's preference; this choice no longer blocks the authorized checkout release.
- Production publication, enabled live configuration, canonical www redirect, private confirmation flow, unauthorized denial, live Stripe checkout-page browser behavior, and Mac 5.1.3 private-upload integrity are verified. No release work remains pending from these checks.
- A real live charge and paid live download have not been exercised. Actual event receipt in Google Analytics and Meta Events Manager remains unverified; script initialization and code hashes do not establish platform receipt.
- Chrome automation showed ERR_BLOCKED_BY_CLIENT on the file navigation. The same paid endpoint and private file were verified independently; a normal manual browser download should be checked before release. Browser tooling refused access to chrome://downloads under its URL policy, and no workaround was used to inspect that page.
- Website microphone transcription uses a hidden Production `OPENAI_API_KEY`, OpenAI Realtime, and `gpt-4o-transcribe`. The live synthetic-microphone check passed; prerecorded video remains independent.
- The matching icon is applied in the signed, notarized Mac-only 5.1.3 build. Its verified private upload is configured in the active Production checkout release; a paid live delivery has not been exercised. The preserved 5.1.0 artifact retains its historical verification.

No secret keys, private session links, or signed download URLs are included in this report.
