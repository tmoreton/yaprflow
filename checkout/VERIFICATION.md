# Production release verification

Last updated: September 21, 2026

## Active release

- Public site: `https://yaprflow.com/`
- Vercel deployment: `dpl_6WxK2jWbsW8r7ixeMP8ZwVUyAXbS`
- Deployment URL: `https://yaprflow-checkout-h405h20th-tmoretons-projects.vercel.app`
- Direct Mac app: Yaprflow 5.2.8, build 21, universal Intel and Apple silicon
- Private installer: `releases/yaprflow-5.2.8.dmg`
- Installer size: 493,890,853 bytes
- Installer SHA-256: `f92c05ffd1e28b55fe61f3c2ed6fbe7ef25b89ca3a91dd2279d50955acf54165`
- Mac App Store archive: `../build/app-store/5.2.8-21/yaprflow.xcarchive` (compiled; installer export blocked by missing Mac Installer Distribution certificate)
- iOS App Store archive: `../build/ios-app-store/1.0.0-8/export/yaprflow-iOS.ipa`
- iOS App Store archive size: 485,526,804 bytes
- iOS App Store archive SHA-256: `4049b830f23d5debde59120e5706132c8a054d88e5f1cd939a1f0fc9fcf2497e`

## Native app checks

- The direct app and DMG were signed with Developer ID, accepted by Apple's notarization service, stapled, and accepted by Gatekeeper.
- The direct app notarization submission ID is `f4b3821a-06d7-4d93-940e-6f9fb94c0b2f`; the DMG submission ID is `68e6ff28-ab22-4e04-bc93-64b2d354b0d6`.
- The private Blob upload was downloaded through a short-lived private URL and matched the local file's full size and SHA-256. Anonymous download access remains denied.
- Both Mac release schemes compiled as universal `arm64` and `x86_64` applications. The direct edition contains Sparkle; the Mac App Store edition excludes it.
- The paired TestFlight release gate compiled the macOS 5.2.8 build 21 archive and exported and verified iOS 1.0.0 build 8. The Mac installer export stopped because the required Mac Installer Distribution private certificate is missing, so neither candidate was uploaded to App Store Connect.
- The iOS meeting-store smoke test passed.
- All 59 shared Swift tests passed.

## Sparkle checks

- The direct edition includes Sparkle and requires both archive and feed signatures.
- The first updater-enabled release was 5.1.4. The production feed now offers Mac 5.2.8 build 21 and carries a verified EdDSA feed signature and signed enclosure.
- The private EdDSA key remains outside the repository. The repository contains only the public key.
- The paid 5.2.8 installer stays in the private checkout store. Its byte-identical updater copy is isolated in the unlisted public `yaprflow-sparkle-updates` store under an opaque immutable path and randomized filename. The full public object matches SHA-256 `f92c05ffd1e28b55fe61f3c2ed6fbe7ef25b89ca3a91dd2279d50955acf54165`.

## Website and checkout checks

- The full website suite passed: 99 tests, zero failures. The production build completed with the pinned Vercel CLI and the project's Node.js runtime.
- Production deployment `dpl_6WxK2jWbsW8r7ixeMP8ZwVUyAXbS` is READY and aliased to `https://yaprflow.com/`.
- Public `/api/config` reports live mode, the US $7.99 one-time price, `downloadReady: true`, and `voiceDemoAvailable: true`.
- The public page reports software version 5.2.8 and shows the optional newsletter choice.
- Checkout has no mandatory terms checkbox or acceptance gate. The offer links directly to the published terms and 14-day refund policy.
- A same-origin live checkout request returned HTTP 303 to Stripe Checkout; no payment was submitted.
- `/api/download` returned HTTP 403 without a verified purchase, and `/api/redeem?token=invalid` returned HTTP 403.
- `/api/webhook` returned HTTP 400 without a Stripe signature, confirming the production endpoint is configured and validating signed events rather than returning a setup error.
- The active production environment uses `BLOB_PATHNAME=releases/yaprflow-5.2.8.dmg`.
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
