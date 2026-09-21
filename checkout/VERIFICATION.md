# Production release verification

Last updated: September 21, 2026

## Active release

- Public site: `https://yaprflow.com/`
- Vercel deployment: `dpl_EMgachodbuFJsaf3MHauxLMbd3n5`
- Deployment URL: `https://yaprflow-checkout-r2nkgmci0-tmoretons-projects.vercel.app`
- Direct Mac app: Yaprflow 5.2.7, build 20, universal Intel and Apple silicon
- Private installer: `releases/yaprflow-5.2.7.dmg`
- Installer size: 493,879,246 bytes
- Installer SHA-256: `4520528deccecea9c039f8d4766f2296624dedaf11d048999b2f2b29701a5058`
- Mac App Store package: `../build/app-store/5.2.7-20/export/yaprflow.pkg`
- Mac App Store package size: 498,470,511 bytes
- Mac App Store package SHA-256: `b2a71e179a616d57d63896c5b72abf8fa9a98a1cdd6e74bf86de8b6794a0f6d0`
- iOS App Store archive: `../build/ios-app-store/1.0.0-7/export/yaprflow-iOS.ipa`
- iOS App Store archive size: 485,517,862 bytes
- iOS App Store archive SHA-256: `d21002e8aef0548d9ae2fe06cbb05b59885976898c4e857d4b43acebcaa93ae5`

## Native app checks

- The direct app and DMG were signed with Developer ID, accepted by Apple's notarization service, stapled, and accepted by Gatekeeper.
- The direct app notarization submission ID is `1d3e32df-052b-4017-af21-7b58f2ca09f4`; the DMG submission ID is `3d0c7f14-f729-4343-8afe-2eb96614bb8b`.
- The private Blob upload was downloaded through a short-lived private URL and matched the local file's full size and SHA-256. Anonymous download access remains denied.
- Both Mac release schemes compiled as universal `arm64` and `x86_64` applications. The direct edition contains Sparkle; the Mac App Store edition excludes it.
- The paired TestFlight release gate exported and verified the signed macOS 5.2.7 build 20 package and iOS 1.0.0 build 7 archive. Neither candidate was uploaded to App Store Connect.
- The iOS meeting-store smoke test passed.
- All 56 shared Swift tests passed.

## Sparkle checks

- The direct edition includes Sparkle and requires both archive and feed signatures.
- The first updater-enabled release was 5.1.4. The production feed is intentionally empty because no newer public Sparkle update has been published, and the empty feed carries a verified EdDSA signature.
- The private EdDSA key remains outside the repository. The repository contains only the public key.
- The 5.2.7 installer stays behind paid checkout. A future Sparkle update requires a separately reachable signed asset or an entitlement-aware update service.

## Website and checkout checks

- The full website suite passed: 99 tests, zero failures. The production build completed with the pinned Vercel CLI and the project's Node.js runtime.
- Production deployment `dpl_EMgachodbuFJsaf3MHauxLMbd3n5` is READY and aliased to `https://yaprflow.com/`.
- Public `/api/config` reports live mode, the US $7.99 one-time price, `downloadReady: true`, and `voiceDemoAvailable: true`.
- The public page reports software version 5.2.7 and shows the optional newsletter choice.
- Checkout has no mandatory terms checkbox or acceptance gate. The offer links directly to the published terms and 14-day refund policy.
- A same-origin live checkout request returned HTTP 303 to Stripe Checkout; no payment was submitted.
- `/api/download` returned HTTP 403 without a verified purchase, and `/api/redeem?token=invalid` returned HTTP 403.
- `/api/webhook` returned HTTP 400 without a Stripe signature, confirming the production endpoint is configured and validating signed events rather than returning a setup error.
- The active production environment uses `BLOB_PATHNAME=releases/yaprflow-5.2.7.dmg`.
- The Resend sender domain `yaprflow.com` is verified. The live Stripe destination `we_1UIAdhAlzJZxFihraErWdoUj` is active for `checkout.session.completed` and `checkout.session.async_payment_succeeded`.
- All production fulfillment settings are present in Vercel, including Stripe webhook verification, Resend delivery, signed recovery links, the verified sender, support reply-to, and the dedicated newsletter segment.
- The site accurately states that paid buyers receive both immediate browser access and an emailed private cross-device recovery link.

## Remaining production observations

- On the next ordinary purchase, confirm exactly one transactional email arrives, open its private link on another browser or Mac, and verify the installer becomes available only after Stripe payment verification. Do not replay the earlier refunded live purchase for this check.
- Repeat test checkout once with the optional newsletter box selected and once without it. Confirm only the opted-in address enters the Resend newsletter segment and verify unsubscribe behavior.
- Confirm purchase and conversion events arrive in Google Analytics and Meta Events Manager. The deployed scripts and server-side guards are tested, but dashboard receipt is not verified.
- Confirm Stripe payout, tax-registration, receipt-email, statement-descriptor, support, and dispute settings before increasing ad spend.
- Upload both current TestFlight candidates together and complete App Store Connect agreements, banking, tax, Digital Services Act status, metadata, screenshots, review contact, TestFlight checks, and review submission.
- Have qualified counsel review the customer EULA, refund language, privacy disclosure, PolyForm source-license boundaries, and regional consumer-law requirements before broad international sales.

No secret keys, checkout session links, or signed private download URLs are stored in this report.
