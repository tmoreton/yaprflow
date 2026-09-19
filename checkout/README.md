# Yaprflow website, checkout, and private downloads

This directory contains the redesigned landing page, policies, support, Stripe checkout, and private Mac download flow in one Vercel project: `tmoretons-projects/yaprflow-checkout`.

The redesigned website and enabled live Stripe checkout are published at `https://yaprflow.com/`, with the US $7.99 one-time price verified. The active release points to the signed and notarized Mac 5.1.3 installer with the matching icon. Google and Meta tracking are enabled by default when no saved choice exists, with changes available through **Cookie settings** and no automatic bottom bar. The original site is preserved in `../docs/`. The existing refund-contact policy remains published; an optional fixed refund window is awaiting the user's preference and is not a launch blocker. No real live purchase has been made during verification.

## Current setup — September 19, 2026

Production deployment `dpl_DP3RWYm7YQ98V2JcgjyDKscz5YvM` is READY at `https://yaprflow-checkout-jtgywi97w-tmoretons-projects.vercel.app` and aliased to `yaprflow.com`. It publishes the channel-specific purchase and update disclosure: direct purchases receive the private Stripe download and Sparkle updates, while Mac App Store purchases and updates are handled by Apple. The public policies page was fetched after deployment and contains both disclosures. A bounded production error-log scan found no records in the checked 15-minute window. The valid empty Sparkle feed remains available for the direct edition, and the OpenAI Realtime microphone demo remains enabled.

Live Production settings are `CHECKOUT_ENABLED=true`, `CHECKOUT_BASE_URL=https://yaprflow.com`, and `BLOB_PATHNAME=releases/yaprflow-5.1.3.dmg`. Public `/api/config` verifies `enabled: true`, `mode: "live"`, price `{amount: 799, currency: "usd", formatted: "$7.99"}`, `downloadReady: true`, and `voiceDemoAvailable: true`. The live product is `prod_VHf8LJ6S6B1Rk6`, and the live Price ID is `price_1UH5oDAlzJZxFihrxO8VSy8p`.

All six public smoke checks passed: enabled live price/configuration, version 5.1.3 metadata, Google/Meta code hashes, www redirects, the private confirmation redirect and cookie flow, and unauthorized status/download denial. Clicking **Buy Yaprflow — $7.99** on the public site opened live Stripe-hosted checkout titled Yaprflow, showing **Yaprflow for Mac — Founding lifetime license**, a one-time $7.99 subtotal, address-dependent tax, and card/wallet options. No personal or card details were entered, and no payment was submitted. The deployment command exited successfully and confirmed READY and the apex alias. A final bounded error-log scan returned no records over 15 minutes (limit 50). Paid live delivery and vendor analytics dashboard receipt remain unverified.

The local prebuilt Production build passed. It generated six Node.js 24 API functions with zero environment-override keys, the correct project and Production target, the intended canonical www redirect, and public output excluding credentials and installers. Runtime Production settings can therefore be updated before deploying that output. The latest full suite passed 77 website tests and 33 shared app tests. Universal optimized Release builds passed for both Mac schemes; bundle inspection confirmed that only the direct edition contains and links Sparkle. A bounded error-log scan of the final OpenAI deployment returned no error records after its successful synthetic-microphone session.

The native update is Mac only. Yaprflow 5.1.3 (build 9) is signed, notarized, stapled, and accepted by Gatekeeper, with arm64 and x86_64 support and all ten Mac icon sizes matching the website artwork. Its private uploaded DMG passed a full-file size and checksum comparison, and unauthenticated access returned 403. Production points to that artifact for the new deployment; paid live delivery remains unverified. The original 5.1.0 installer is preserved.

Namecheap DNS was saved and rechecked: apex A `216.150.1.1`, and `www` CNAME `49cac89f54e8a17a.vercel-dns-016.com`. Google DNS-over-HTTPS returns those records. TLS checks pass for both domains, and the current public smoke checks verify www redirects to the apex. The old GitHub Pages A records were removed; existing mail forwarding and SPF were preserved.

Stripe test configuration:

| Item | Value |
| --- | --- |
| Account | `acct_1UH567AlzJZxFihr` |
| Product | `prod_VHeTX1PgSVML61` |
| One-time price | `price_1UH5AmAlzJZxFihrPl3Kt2XQ` |
| Amount | US $7.99 |
| Sandbox product tax code | `txcd_10202001` — downloadable non-recreational software, personal use |

With the user's approval, the test Stripe key was saved as a Vercel **Preview Secret**. Preview also has `STRIPE_PRICE_ID`, `CHECKOUT_ENABLED=true`, `BLOB_PATHNAME`, and `BLOB_READ_WRITE_TOKEN` configured. Secret values are not stored in this repository.

Latest verified sandbox Preview: https://yaprflow-checkout-86xb5tpyo-tmoretons-projects.vercel.app/ — deployment READY, with the Meta integration and cookie delivery route included. That historical baseline passed all 73 automated tests and the build; the subsequent no-automatic-bar change passed 32 focused tests. The latest full-suite result is 77 passing tests plus the build.

A $7.99 sandbox purchase completed through Stripe Managed Payments on the earlier `yaprflow-checkout-izzvhj3ct-tmoretons-projects.vercel.app` Preview. A fictional New York billing address produced $0.71 test tax ($8.70 total); no real charge was made. The confirmation page verified payment and revealed the download. Before payment, status returned HTTP 202 and download returned HTTP 403. After payment, the download endpoint returned HTTP 303 and the signed Blob URL delivered all 490,720,322 bytes with the expected SHA-256. The unsigned Blob URL returned HTTP 403.

On the latest Preview, Chrome followed that paid sandbox purchase's legacy confirmation link through a server redirect to clean `/confirmation.html` before HTML loaded. The page verified the paid test purchase and exposed only `/api/download`, without a query, as its download link. Declining optional cookies and returning to the clean confirmation page preserved purchase access. Direct deployed API checks passed: missing purchase cookie returned status 403; the completion route returned 303 to exactly `/confirmation.html` with the expected secure 30-day cookie; that cookie returned paid test status 200 without analytics data, and download returned 303 to the expected signed private Blob host. The new signed URL was not followed; the complete-file checksum result above is from the earlier verification.

Chrome automation showed a blocked navigation when following the file link in the earlier file test; file delivery was independently verified through the same paid endpoint. Browser tooling also blocked access to Chrome's internal downloads page, so a normal manual browser download remains a final release check. See `VERIFICATION.md` for details. The user confirmed the US $7.99 one-time live price, plus applicable tax, and explicitly asked to fix the disabled checkout. We retained the existing published refund-contact wording and told the user; the user has not selected that wording or answered the optional fixed-window question. Stripe's dashboard shows email verification and Activate products as Complete, while the Managed Payments setup guide shows Not Started; those observations alone do not establish complete merchant setup.

The optional browser microphone demo has a hidden Production `OPENAI_API_KEY` and streams through OpenAI Realtime with `gpt-4o-transcribe`. A synthetic-microphone browser check reached “Live — speak naturally” without recording room audio. The session stops automatically after ten seconds. The prerecorded video and the native app's local dictation do not need this credential.

## Local development

Use a current Node.js version that supports `--env-file-if-exists`, then run these commands from this directory:

```sh
npm ci
cp .env.example .env.local
npm start
```

`.env.local` is ignored by Git. Fill it with test credentials only when testing payments locally. The development server in `scripts/dev.mjs` serves the website and API handlers at `http://127.0.0.1:4173`; `PORT` can select another port. Set `CHECKOUT_BASE_URL` to the matching local origin if you change the port.

With credentials absent, the landing page still loads and displays checkout as unavailable. The purchase button becomes available only after `/api/config` confirms a valid active one-time Stripe price, payment mode, checkout origin, and private-download configuration. Displayed prices are updated from Stripe, and test checkout is clearly labeled.

## Build and public files

`npm run build` runs `scripts/build.mjs` and creates `public/`, which is the Vercel static output directory. The build copies only this explicit allowlist:

- `index.html`, `confirmation.html`, `support.html`, `appcast.xml`
- `checkout.js`, `confirmation.js`, `analytics.js`, `meta-pixel.js`, `analytics.css`, `styles.css`
- `assets/`, `policies/`, `robots.txt`, `sitemap.xml`

Asset directories reject hidden files, symlinks, and unexpected extensions. Source, environment files, and private installers are excluded. Vercel deploys the `api/` handlers separately; the static output alone does not implement checkout.

`appcast.xml` is the public Sparkle 2 update feed for the paid website edition.
The Mac App Store edition excludes Sparkle and receives updates from Apple.
The committed feed has no
release enclosure until an updater-enabled archive has been uploaded to its
final HTTPS location. Publish the archive before replacing this feed with the
output from `../scripts/prepare-sparkle-update.sh`; otherwise installed apps
could discover an update they cannot download.

The old `/privacy.html` route redirects to `/policies/#privacy`. The landing page, purchase confirmation, policies, and support share the new branding. Files under `assets/brand/` include the matching website favicon and icon artwork applied to the signed and notarized Mac 5.1.3 build. Its private upload is verified and configured in the active checkout release. The original 5.1.0 installer remains preserved.

Public pages use `yaprflow.com` canonical URLs. `robots.txt` allows the website, excludes API routes, and links to a sitemap containing only the landing page, policies, and support. The private confirmation page retains its separate `noindex` metadata and response header and is absent from the sitemap.

## Purchase and download flow

1. `GET /api/config` reports checkout availability, test/live mode, the configured Stripe price, and browser-demo availability.
2. The landing page submits `POST /api/checkout`. The server creates a one-time Stripe Checkout Session for one copy of that price.
3. Stripe returns to `/api/complete?session_id={CHECKOUT_SESSION_ID}`. The server stores the private checkout reference in a purchase cookie and redirects to clean `/confirmation.html` before any page tags can load. Legacy confirmation URLs containing a session query are redirected through the same server flow before HTML is served.
4. `GET /api/status` uses the purchase cookie and checks the session with Stripe, including its payment mode, product marker, quantity, allowed Price ID, completion, and paid status.
5. `GET /api/download` repeats the purchase verification, then redirects to a URL valid for five minutes for the fixed installer in a **private** Vercel Blob store.

The integration follows the account’s Managed Payments defaults; it does not override payment methods, tax handling, or merchant settings. The sandbox product has an eligible software category; review the live product category and merchant setup before launch. Delayed payment methods remain pending and cannot download until Stripe reports paid.

The production cookie is `__Host-yaprflow-purchase`: host-only, `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, and a 30-day maximum age. It holds the private Stripe checkout reference, which remains inaccessible to browser JavaScript; payment status and download access are rechecked with Stripe. Status and download calls use the cookie, so the clean confirmation page and its download link do not expose session references or presigned Blob URLs to tags. Local HTTP development uses the separate `yaprflow-purchase-dev` cookie only on loopback dev/test origins.

The cookie lets the purchaser return to `/confirmation.html` in the same browser for 30 days. If it expires, is cleared, or the customer changes browser or host, support at `tim@yaprflow.com` can help using the email from checkout. Optional consent changes leave this necessary purchase cookie intact. Its expiry does not limit use of the installed app. The page and API responses use `no-store` and `no-referrer`; the page is excluded from indexing. Stripe retains the payment record; no Yaprflow account or in-app sign-in is needed.

The cookie delivery flow and Meta integration are included in Preview and Production. The paid-purchase checks were performed in the sandbox Preview: browser checks verified the legacy-link redirect, clean confirmation address, paid test status, query-free download link, and purchase access after optional consent was declined. Preview API checks verified the cookie attributes, exact clean redirect, `no-store`/`no-referrer` response headers, cookie-based paid status, and signed private-download redirect. The redirected file was not downloaded again; the earlier full-file checksum test used the previous session-query flow. Production checkout is now enabled, and public smoke checks pass for confirmation routing/cookies and unauthorized access denial. No paid live purchase or download has been performed.

## Environment configuration

Configure Preview and Production separately and redeploy after changes.

| Variable | Purpose |
| --- | --- |
| `STRIPE_SECRET_KEY` | Stripe test key in Preview; a verified live key in Production when sales are approved. Store as a Vercel Secret. |
| `STRIPE_PRICE_ID` | The active one-time Price ID used for new sessions. It must belong to the same Stripe mode as the key. |
| `CHECKOUT_ENABLED` | Exactly `true` enables new checkout sessions when all other settings and the Stripe price are valid. Unset or `false` keeps checkout disabled. |
| `STRIPE_ALLOWED_PRICE_IDS` | Optional comma-separated previous Price IDs whose paid purchasers should retain access. The current Price ID is always included. |
| `CHECKOUT_BASE_URL` | Canonical HTTPS origin for checkout redirects. Required in Production; use the actual origin that serves these handlers. Local development permits HTTP on localhost. |
| `BLOB_PATHNAME` | Fixed private installer path. Active Production uses the verified `releases/yaprflow-5.1.3.dmg`. |
| `BLOB_READ_WRITE_TOKEN` | Token for the private Blob store. Keep server-side and never commit it. |
| `OPENAI_API_KEY` | Server credential for the website microphone demo. Configured as a hidden Production secret; unrelated to customers' native-app AI provider keys. |

In Vercel Preview, leave `CHECKOUT_BASE_URL` unset to use the deployment-specific `https://${VERCEL_URL}` automatically. The fallback accepts a validated `*.vercel.app` hostname only when `VERCEL_ENV=preview`. It does not replace the explicit Production origin. An explicit `CHECKOUT_BASE_URL` overrides the Preview fallback.

The optional browser demo sends audio to OpenAI after microphone permission; it is separate from the native app's local transcription. Its credential stays on the server. The demo has same-origin checks and per-instance request limits, and its data handling is described in `policies/index.html`.

## Optional website analytics and marketing

The existing GA4 measurement ID is `G-0FTBJXMCSM`, recovered from `docs/index.html` at commit `7931bd783ca02333b01cde36a442e2a22281a119` after its removal in commit `9972ede021c3902528889f4ca60395566c560998`. Google Analytics confirms account `392393866`, YaprFlow property `534290536`, web stream `14419117042`, and stream URL `https://yaprflow.com`.

Both integrations run only on `yaprflow.com` and `www.yaprflow.com`; local development, Vercel aliases, and Preview hosts send no tracking events. Google Analytics and Meta Marketing are enabled by default when no saved tracking choice exists. Existing explicit choices, including opt-outs and Analytics-only settings, are respected; malformed settings or a storage-read error leave tracking off. The initial default is not persisted as a user-made choice.

The choices panel stays hidden on page load. Visitors can open **Cookie settings** in the footer: **Turn off tracking** disables both categories, **Analytics only** enables Google and disables Meta, and **Allow all** enables both. Explicit choices are saved in local storage. Turning a category off clears its optional cookies and reloads, leaving the necessary purchase cookie intact. The default-enabled state is a website setting, not a claim that a visitor opted in. Google advertising signals and `ad_storage`, `ad_user_data`, and `ad_personalization` remain denied even when Meta is enabled. The production-host, private-URL, and test-purchase guards are unchanged.

The user explicitly chose to keep Google's automatic **Enhanced Measurement enabled**. It can collect additional interactions and related metadata, so collection is not restricted to the site's custom events. Google's existing email redaction remains enabled. Saved query-parameter redaction covers `session_id`, `vercel-blob-delegation`, `vercel-blob-signature`, `client_secret`, `payment_intent`, `token`, and `signature`.

The page views sent by our code use a canonical page path without queries, fragments, or referrers. Custom event parameters come from a fixed allowlist:

| Event | Meaning |
| --- | --- |
| `offer_click` | Visitor selects an offer link. |
| `demo_video_start` | Prerecorded app demonstration starts. |
| `demo_video_complete` | Prerecorded app demonstration reaches its end. |
| `begin_checkout` | A live checkout begins. Test checkout is excluded. |
| `purchase` | The server has verified a paid live Stripe purchase. Uses a one-way hashed transaction ID, net purchase value, tax, and currency. |
| `download_click` | The download button is clicked after a paid purchase is verified. |

The custom events exclude email addresses, microphone audio, transcripts, checkout session IDs, and private download URLs. Automatic events remain governed by the enabled Google stream settings and configured redaction. Purchase deduplication uses in-memory state for the current page and a stable hashed `transaction_id` for GA to recognize repeated purchases. No purchase reference is persisted in local storage; a later visit can retry reporting if Google was blocked on the first visit. Explicit tracking choices remain in local storage; the default is not written as a choice. A `download_click` records intent, not proof that the file finished downloading.

The user supplied Meta Pixel `1391229936449100`. Its advertising cookies support ad measurement and attribution. The deployed `meta-pixel.js` integration disables Meta `autoConfig` and advanced matching, sends fixed event fields, and has no static `noscript` tracker that could bypass tracking settings.

| Meta event | Trigger and fields |
| --- | --- |
| `PageView` | Base event while Marketing tracking is enabled. |
| `ViewContent` | Landing-page view while Marketing tracking is enabled. |
| `InitiateCheckout` | An enabled live checkout submission is accepted. |
| `Purchase` | Server-verified paid live purchase; actual net value, currency, and stable hashed transaction `eventID`. |

Meta events exclude raw email, audio, transcripts, checkout session IDs, and private download URLs. Repeated purchase events are limited by memory during the page session and the stable Meta `eventID`; this is not a guarantee of exactly-once reporting. The cookie redirect removes the checkout reference before tags load, and the download button uses the first-party endpoint rather than exposing the signed Blob URL in the DOM.

Tracking totals depend on saved settings and browser or content-blocker behavior. Stripe payment records remain the source of truth for sales. Google configuration and saved redaction settings have been inspected: all seven Enhanced Measurement switches remain on, site-search keys are `q,s,search,query,keyword` with no additional keys, and Google's redaction preview masked the tested checkout and signature values. Actual event receipt in Google Analytics and Meta Events Manager remains unverified. Record production receipt separately from code and settings-interface checks.

Earlier browser checks confirmed all three settings buttons fit at 390 pixels without horizontal overflow. **Analytics only** and **Allow all** persisted across reloads. Local pages loaded neither vendor tag even after **Allow all**, as required by the production-host restriction. Those historical checks preceded the default-enabled update. That update's deployed files were verified against the tested release, and Chrome on the public apex loaded both expected vendor script URLs with the choices panel hidden. Browser initialization does not establish receipt in either vendor's dashboard.

## Mac installer status

The signed universal Mac app 5.1.3 (build 9) includes the website-matching icon at all ten required sizes. Apple accepted both the app and DMG for notarization; both are stapled and Gatekeeper accepted. The app mounted from the DMG passed deep, strict signature verification, stapler validation, and Gatekeeper assessment. It contains arm64 and x86_64 architectures. This is a Mac-only release.

- Local file: `../build/yaprflow-5.1.3.dmg`.
- Private Blob pathname: `releases/yaprflow-5.1.3.dmg` in `yaprflow-private-downloads`.
- Size: 490,758,636 bytes.
- SHA-256: `0620cbf859ff03337b440faae30b920dc35924d0666bfa6f05d8191bad75b13b`.

The full uploaded file was downloaded to `/private/tmp/yaprflow-5.1.3-published.dmg`; its size and SHA-256 match the local release. An unauthenticated GET returned 403. Active Production uses that new path. These checks establish the uploaded artifact's integrity; no paid live purchase or customer download was performed.

The private store is `yaprflow-private-downloads`. The preserved and previously verified Yaprflow 5.1.0 Mac release is:

- Local file: `../build/yaprflow-5.1.0.dmg` (approximately 468 MB).
- Private Blob pathname: `releases/yaprflow-5.1.0.dmg`.
- SHA-256: `faa407edac77777bf841be06b195ecbaee6ee24df28fbc0228c518c4ac708720`.
- macOS 14 or later; universal Intel and Apple silicon build.

The local DMG signature, stapled notarization, and Gatekeeper assessment passed fresh checks on September 18, 2026; the exported app also passed deep, strict signature verification. The file retrieved through the completed sandbox purchase matched the same checksum.

Keep the installer private. Do not copy it into `assets/` or `public/`, publish it as a public GitHub release asset, or link directly to a Blob URL on the landing page.

## Verification and launch

Run `npm test` for the purchase checks, handlers, website behavior, and browser-demo language configuration. Run `npm run build` to verify the publishable static output.

For each release, complete the browser flow in a Preview deployment using Stripe test payment details:

- Confirm the page shows test mode and the Stripe price.
- Verify an unpaid or invalid session cannot download the installer.
- Complete test checkout, return to the confirmation page, and download the app.
- Compare the downloaded SHA-256 with the value above; check installation guidance.
- Check cancellation, unavailable checkout, and payment-status retry behavior.

Do not promote the sandbox deployment to Production: deployments retain their environment configuration. Create a fresh Production deployment with verified live credentials instead.

The user asked to fix the disabled checkout. We chose to retain the existing published refund-contact wording while the optional fixed-window question remains unanswered, and informed the user. This does not record a user selection of refund terms. A fixed refund window can be added after the user chooses one. The Production release is complete: READY and publicly aliased, with all six public smoke checks and live Stripe checkout-page browser verification passing. The Mac 5.1.3 private artifact is fully checksum-verified and configured for delivery. No customer payment or paid live download was performed, and actual GA/Meta dashboard event receipt remains unverified. The website's offer and metadata reflect US $7.99 plus applicable tax; update those alongside Stripe if the public price changes later. Do not expose the sandbox configuration as the live checkout.

## Releasing an update

Build, sign, and notarize a new DMG with the repository's `scripts/release.sh`. Upload it under a new versioned pathname in the private Blob store, verify unauthenticated access is denied, update `BLOB_PATHNAME`, and redeploy. Record the new checksum and repeat the paid-download verification.

Existing paid sessions receive the configured current installer while their Price ID remains current or appears in `STRIPE_ALLOWED_PRICE_IDS`. Mac 5.1.3 has completed signing, notarization, artifact verification, and private upload, and is configured in the active Production checkout release. A real paid live delivery has not been exercised.
