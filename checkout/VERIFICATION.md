# Production release verification

Last updated: September 22, 2026

## Active release

- Public site: `https://yaprflow.com/`
- Vercel deployment: `dpl_BymG8snvXLT5Cww6atpU9AHdcymc`
- Deployment URL: `https://yaprflow-checkout-24c32d8we-tmoretons-projects.vercel.app`
- Direct Mac app: Yaprflow 5.2.12, build 25, universal Intel and Apple silicon
- Private installer: `releases/yaprflow-5.2.12.dmg`
- Installer size: 480,490,347 bytes
- Installer SHA-256: `7d78d413306fa23b86da3c9cb301e81f2c257cb74ca2e898f83a27c98dbd945f`
- Mac App Store archive: `../build/app-store/5.2.8-21/yaprflow.xcarchive` (compiled; installer export blocked by missing Mac Installer Distribution certificate)
- iOS App Store archive: `../build/ios-app-store/1.0.0-8/export/yaprflow-iOS.ipa`
- iOS App Store archive size: 485,526,804 bytes
- iOS App Store archive SHA-256: `4049b830f23d5debde59120e5706132c8a054d88e5f1cd939a1f0fc9fcf2497e`

## Native app checks

- The direct app and DMG were signed with Developer ID, accepted by Apple's notarization service, stapled, and accepted by Gatekeeper.
- The direct app notarization submission ID is `44fb108a-5e84-4cf9-9ea9-c9d7fede1f34`; the DMG submission ID is `6a68e757-46f2-499f-a5d5-701244fb8eb3`.
- The private Blob upload was downloaded through a short-lived private URL and matched the local file's full size and SHA-256. Anonymous download access remains denied.
- The 5.2.12 direct build compiled as a universal `arm64` and `x86_64` application, bundles Parakeet TDT 0.6B v3, and contains Sparkle. App Store candidates were not rebuilt for this direct-download release.
- The paired TestFlight release gate compiled the macOS 5.2.8 build 21 archive and exported and verified iOS 1.0.0 build 8. The Mac installer export stopped because the required Mac Installer Distribution private certificate is missing, so neither candidate was uploaded to App Store Connect.
- The iOS meeting-store smoke test passed.
- All 67 shared Swift tests passed.

## Sparkle checks

- The direct edition includes Sparkle and requires both archive and feed signatures.
- The first updater-enabled release was 5.1.4. The production feed now offers Mac 5.2.12 build 25 and carries a verified EdDSA feed signature and signed enclosure.
- The private EdDSA key remains outside the repository. The repository contains only the public key.
- The paid 5.2.12 installer stays in the private checkout store. Its byte-identical updater copy is isolated in the unlisted public `yaprflow-sparkle-updates` store under an opaque immutable path and randomized filename. The full public object matches SHA-256 `7d78d413306fa23b86da3c9cb301e81f2c257cb74ca2e898f83a27c98dbd945f`.

## Website and checkout checks

- The full website suite passed: 100 tests, zero failures. The production build completed with the pinned Vercel CLI and the project's Node.js runtime.
- Production deployment `dpl_BymG8snvXLT5Cww6atpU9AHdcymc` is READY and aliased to `https://yaprflow.com/`.
- A real installed Mac 5.2.6 build 19 discovered 5.2.8 through **Check Now** and displayed the signed embedded release notes and **Install Update** action.
- Public `/api/config` reports live mode, the US $7.99 one-time price, `downloadReady: true`, and `voiceDemoAvailable: true`.
- The public page reports software version 5.2.12 and shows the optional newsletter choice.
- Checkout has no mandatory terms checkbox or acceptance gate. The offer links directly to the published terms and 14-day refund policy.
- A same-origin live checkout request returned HTTP 303 to Stripe Checkout; no payment was submitted.
- `/api/download` returned HTTP 403 without a verified purchase, and `/api/redeem?token=invalid` returned HTTP 403.
- `/api/webhook` returned HTTP 400 without a Stripe signature, confirming the production endpoint is configured and validating signed events rather than returning a setup error.
- The active production environment uses `BLOB_PATHNAME=releases/yaprflow-5.2.12.dmg`.
- The Resend sender domain `yaprflow.com` is verified. The live Stripe destination `we_1UIAdhAlzJZxFihraErWdoUj` is active for `checkout.session.completed` and `checkout.session.async_payment_succeeded`.
- All production fulfillment settings are present in Vercel, including Stripe webhook verification, Resend delivery, signed recovery links, the verified sender, support reply-to, and the dedicated newsletter segment.
- The site accurately states that paid buyers receive both immediate browser access and an emailed private cross-device recovery link.

## Remaining production observations

- On the next ordinary purchase, confirm exactly one transactional email arrives, open its private link on another browser or Mac, and verify the installer becomes available only after Stripe payment verification. Do not replay the earlier refunded live purchase for this check.
- Repeat test checkout once with the optional newsletter box selected and once without it. Confirm only the opted-in address enters the Resend newsletter segment and verify unsubscribe behavior.
- Confirm purchase and conversion events arrive in Google Analytics and Meta Events Manager. The deployed scripts and server-side guards are tested, but dashboard receipt is not verified.
- Confirm Stripe payout, tax-registration, receipt-email, statement-descriptor, support, and dispute settings before increasing ad spend.
- Restore or recreate the Mac Installer Distribution private certificate, rerun the paired release gate, then upload both current TestFlight candidates together. Complete App Store Connect agreements, banking, tax, Digital Services Act status, metadata, screenshots, review contact, TestFlight checks, and review submission.
- Have qualified counsel review the customer EULA, refund language, privacy disclosure, PolyForm source-license boundaries, and regional consumer-law requirements before broad international sales.

No secret keys, checkout session links, or signed private download URLs are stored in this report.
