# Yaprflow Mac checkout

This Vercel project is the purchase and private download service for the Mac app. The marketing site at `yaprflow.com` stays on GitHub Pages. The marketing site must link to this service's purchase page, never to the DMG or a public GitHub release asset.

## Flow

1. The purchase page submits a POST to `/api/checkout`. The server creates a one-time Stripe Checkout Session for the configured Price ID.
2. Stripe redirects to `/confirmation.html?session_id={CHECKOUT_SESSION_ID}`.
3. The confirmation page asks `/api/status` to verify that Stripe marks this exact product and Price ID paid.
4. `/api/download` repeats the Stripe verification, then redirects to a five-minute URL for the fixed file in a **private** Vercel Blob store.

The checkout session ID grants access to the confirmation page and must be treated as a private bearer link. The page is marked `noindex` and `no-referrer`. A customer who loses it can contact support using the email from checkout. Stripe retains the payment record; no Yaprflow customer account or database is needed for this flow.

## Production configuration

The Vercel project is `tmoretons-projects/yaprflow-checkout`. Configure these **Production** environment variables, then redeploy:

| Variable | Purpose |
| --- | --- |
| `STRIPE_SECRET_KEY` | Live secret key for the chosen Stripe business; store as a Vercel Secret. |
| `STRIPE_PRICE_ID` | Live, one-time Stripe Price ID. This is the only price used for new sessions. |
| `STRIPE_ALLOWED_PRICE_IDS` | Optional comma-separated previous Price IDs whose paid purchasers should keep access. |
| `CHECKOUT_BASE_URL` | Canonical HTTPS origin of this checkout service, currently `https://yaprflow-checkout.vercel.app`. |
| `BLOB_PATHNAME` | Fixed private DMG pathname, currently `releases/yaprflow-5.1.0.dmg`. |
| `BLOB_READ_WRITE_TOKEN` | Set automatically when the private Blob store is linked to this project. Never commit it. |

The private store is `yaprflow-private-downloads`. The uploaded `yaprflow-5.1.0.dmg` is the signed and notarized build; its SHA-256 is `faa407edac77777bf841be06b195ecbaee6ee24df28fbc0228c518c4ac708720`. Keep GitHub releases in draft while the checkout is paid. Do not publish this DMG to public GitHub Releases or put its URL on the marketing site.

## Releasing an update

Build, sign, and notarize the new DMG. Upload it to the private Blob store with a new versioned pathname, verify the unsigned Blob URL returns HTTP 403, and update `BLOB_PATHNAME` in Production. Redeploy so the new value reaches the Functions. Previous paid sessions continue to receive the current build as long as their Price ID remains in `STRIPE_ALLOWED_PRICE_IDS` (or is the current `STRIPE_PRICE_ID`).

## Verification

Run `npm test` in this directory. Before linking from the marketing site, make a Stripe test-mode purchase against a separate Preview deployment and verify that an unpaid session cannot access `/api/download`, a paid session redirects to the private DMG, and the downloaded file has the expected SHA-256. Use a live low-value purchase/refund only after the chosen business and final price are confirmed. Update `docs/privacy.html` and `docs/support.html` before opening checkout to customers.
