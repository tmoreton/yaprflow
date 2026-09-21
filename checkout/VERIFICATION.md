# Production release verification

Last updated: September 21, 2026

## Active release

- Public site: `https://yaprflow.com/`
- Vercel deployment: `dpl_Co8YMpdaBRCKt9YrkuGbFTmk5waL`
- Direct app: Yaprflow 5.1.4, build 10, universal Intel and Apple silicon
- Private installer: `releases/yaprflow-5.1.4.dmg`
- Installer size: 491,696,385 bytes
- Installer SHA-256: `d155f9c7d562d54cef73a494a6cc5674173abd27425fa7b1a6289dc6dc718441`
- App Store package: `../build/app-store/5.1.4-11/export/yaprflow.pkg`
- App Store package SHA-256: `08de62f591e86f8ed506da199a8b97d4a6a18f80dcc21f908aace5832006af99`

## Native app checks

- The direct app and DMG were signed with Developer ID, accepted by Apple's notarization service, stapled, and accepted by Gatekeeper.
- The direct app notarization submission ID is `3965a716-302f-48fc-bfab-cdedc125f3b6`; the DMG submission ID is `b45d0355-756e-4fbb-87e1-1d8a6a84be8a`.
- The private Blob upload was downloaded through a short-lived private URL and matched the local file's full size and SHA-256. Anonymous download access remains denied.
- The App Store archive/export verifier passed. Its signed package uses the Mac App Store distribution profile and excludes Sparkle code, feed metadata, updater UI, and Sparkle installer entitlements.
- The App Store provisioning profile expires September 16, 2027.
- Apple validated and uploaded build 11 without errors. Delivery `b44274ca-af16-4b26-b801-e11703e66eb8` reached import status `VALID`, quality-control state `VALID_BINARY`, and audience `APP_STORE_ELIGIBLE` in App Store Connect.
- All 33 shared Swift tests passed.

## Sparkle checks

- The direct edition includes Sparkle 2.10.0 and requires both archive and feed signatures.
- The first updater-enabled release is 5.1.4. Its production feed is intentionally empty because no newer release exists, and the empty feed carries a verified EdDSA signature.
- The private EdDSA key remains in the macOS login Keychain and is also stored as the environment-scoped GitHub Actions secret `SPARKLE_PRIVATE_KEY` in `sparkle-release`. The repository contains only the public key.
- `.github/workflows/publish-sparkle-update.yml` accepts an existing notarized GitHub release asset, sends the private key to Sparkle through standard input, verifies the generated signatures, tests the site, and commits the new appcast to `main`.
- The 5.1.4 installer stays behind paid checkout. A later Sparkle update asset must be reachable by installed apps; without a separate entitlement service, its signed public URL can also be downloaded outside the app.

## Website and checkout checks

- The full website suite passed: 80 tests, zero failures. The production build completed with the project's Node.js 24 runtime.
- Public `/api/config` reports live mode, the US $7.99 one-time price, `downloadReady: true`, and `voiceDemoAvailable: true`.
- The public page reports software version 5.1.4.
- The published policies contain the customer license, separate source-license terms, direct/App Store update disclosures, and the 14-day direct-purchase refund policy.
- Checkout has no mandatory terms checkbox or acceptance gate. The offer keeps a direct link to the published terms and refund policy.
- The server rejects cross-origin checkout requests and accepts a browser-verified same-site fallback when Safari omits `Origin`, without requiring a terms field or recording checkbox acceptance metadata.
- The checkout button proceeds directly to live Stripe Checkout after availability is confirmed; no payment was submitted during verification.
- The live microphone status keeps a measured 20-pixel gap below the record button, including its ready state, with no browser errors or error overlay.
- `/api/download` returned HTTP 403 without a verified purchase.
- `https://yaprflow.com/appcast.xml` serves the signed empty production feed.
- The active production environment uses `BLOB_PATHNAME=releases/yaprflow-5.1.4.dmg`.

## Checks that require an owner transaction or account action

- Verify the sending domain in Resend, create the newsletter segment, add all purchase-email environment variables, and register `/api/webhook` for `checkout.session.completed` and `checkout.session.async_payment_succeeded` in both Stripe test and live modes.
- Complete a test purchase on mobile, confirm exactly one transactional email arrives, open its private link in a desktop browser, and verify the installer becomes available only after Stripe payment verification.
- Repeat test checkout once with promotional email consent and once without it. Confirm only the opted-in address appears in the Resend newsletter segment, then verify its unsubscribe behavior before sending a campaign.
- Complete one real live purchase in a normal browser, confirm the returned download opens, then refund the charge in Stripe. This validates receipts, tax, payment settlement, the paid cookie, and the complete delivery path with live funds.
- Confirm the purchase and conversion events arrive in Google Analytics and Meta Events Manager. Deployed scripts and server-side guards have been tested, but dashboard receipt has not.
- Confirm Stripe payout, tax-registration, receipt-email, statement-descriptor, support, and dispute settings in the live account before increasing ad spend.
- Select build 11 in the intended TestFlight group, then complete App Store Connect agreements, banking, tax, Digital Services Act status, metadata, screenshots, review contact, TestFlight checks, and review submission.
- Have qualified counsel review the customer EULA, refund language, privacy disclosure, PolyForm source-license boundaries, and regional consumer-law requirements before broad international sales.

No secret keys, checkout session links, or signed private download URLs are stored in this report.
