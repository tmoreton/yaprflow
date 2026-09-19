# Production release verification

Last updated: September 19, 2026

## Active release

- Public site: `https://yaprflow.com/`
- Vercel deployment: `dpl_BR4FGoVzmaYiybtFVHQR8GcGj8g2`
- Direct app: Yaprflow 5.1.4, build 10, universal Intel and Apple silicon
- Private installer: `releases/yaprflow-5.1.4.dmg`
- Installer size: 491,696,385 bytes
- Installer SHA-256: `d155f9c7d562d54cef73a494a6cc5674173abd27425fa7b1a6289dc6dc718441`
- App Store package: `../build/app-store/5.1.4-10/export/yaprflow.pkg`
- App Store package SHA-256: `da792dd155510ba2bd39fadbb5c14e45843e6266f80e4b409567dcb2890b50c2`

## Native app checks

- The direct app and DMG were signed with Developer ID, accepted by Apple's notarization service, stapled, and accepted by Gatekeeper.
- The direct app notarization submission ID is `3965a716-302f-48fc-bfab-cdedc125f3b6`; the DMG submission ID is `b45d0355-756e-4fbb-87e1-1d8a6a84be8a`.
- The private Blob upload was downloaded through a short-lived private URL and matched the local file's full size and SHA-256. Anonymous download access remains denied.
- The App Store archive/export verifier passed. Its signed package uses the Mac App Store distribution profile and excludes Sparkle code, feed metadata, updater UI, and Sparkle installer entitlements.
- The App Store provisioning profile expires September 16, 2027.
- All 33 shared Swift tests passed.

## Sparkle checks

- The direct edition includes Sparkle 2.10.0 and requires both archive and feed signatures.
- The first updater-enabled release is 5.1.4. Its production feed is intentionally empty because no newer release exists, and the empty feed carries a verified EdDSA signature.
- The private EdDSA key remains in the macOS login Keychain and is also stored as the environment-scoped GitHub Actions secret `SPARKLE_PRIVATE_KEY` in `sparkle-release`. The repository contains only the public key.
- `.github/workflows/publish-sparkle-update.yml` accepts an existing notarized GitHub release asset, sends the private key to Sparkle through standard input, verifies the generated signatures, tests the site, and commits the new appcast to `main`.
- The 5.1.4 installer stays behind paid checkout. A later Sparkle update asset must be reachable by installed apps; without a separate entitlement service, its signed public URL can also be downloaded outside the app.

## Website and checkout checks

- The full website suite passed: 79 tests, zero failures. The production build completed with the project's Node.js 24 runtime.
- Public `/api/config` reports live mode, the US $7.99 one-time price, `downloadReady: true`, and `voiceDemoAvailable: true`.
- The public page reports software version 5.1.4.
- The published policies contain the customer license, separate source-license terms, direct/App Store update disclosures, and the 14-day direct-purchase refund policy.
- The checkout form requires explicit acceptance. The server rejects missing or cross-origin acceptance and records the terms version in Stripe Checkout metadata.
- A production checkout request with same-origin acceptance returned HTTP 303 to `checkout.stripe.com`.
- `/api/download` returned HTTP 403 without a verified purchase.
- `https://yaprflow.com/appcast.xml` serves the signed empty production feed.
- The active production environment uses `BLOB_PATHNAME=releases/yaprflow-5.1.4.dmg`.

## Checks that require an owner transaction or account action

- Complete one real live purchase in a normal browser, confirm the returned download opens, then refund the charge in Stripe. This validates receipts, tax, payment settlement, the paid cookie, and the complete delivery path with live funds.
- Confirm the purchase and conversion events arrive in Google Analytics and Meta Events Manager. Deployed scripts and server-side guards have been tested, but dashboard receipt has not.
- Confirm Stripe payout, tax-registration, receipt-email, statement-descriptor, support, and dispute settings in the live account before increasing ad spend.
- Complete App Store Connect agreements, banking, tax, Digital Services Act status, metadata, screenshots, review contact, TestFlight checks, and review submission.
- Have qualified counsel review the customer EULA, refund language, privacy disclosure, PolyForm source-license boundaries, and regional consumer-law requirements before broad international sales.

No secret keys, checkout session links, or signed private download URLs are stored in this report.
