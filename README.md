# Vintage Vault: secure backend core

Status: **not production-ready.** This is step 1 (database, payments, security). Nothing here has been run
against live Supabase or PayMongo yet, and the storefront HTML is not connected to it yet.

## Set up (test mode first)
1. Create a Supabase project. Run `supabase/migrations/001_core.sql` in the SQL editor.
2. Sign up once on your site, then make that account the admin (there is no public admin sign-up):
   `insert into admins select id from auth.users where email = 'you@example.com';`
3. `supabase link --project-ref YOUR-REF`, then:
   `supabase secrets set PAYMONGO_SECRET_KEY=sk_test_... PAYMONGO_WEBHOOK_SECRET=whsk_... SITE_URL=https://your-site.vercel.app`
4. `supabase functions deploy create-checkout` and `supabase functions deploy paymongo-webhook --no-verify-jwt`
5. PayMongo dashboard, test mode: Developers > Webhooks > add
   `https://YOUR-REF.supabase.co/functions/v1/paymongo-webhook` for `checkout_session.payment.paid`; copy its signing secret into step 3.
6. Supabase Auth > Providers: enable **Google** (Google Cloud OAuth client, redirect URL from Supabase) and **Phone** (add Twilio, MessageBird or Vonage credentials).
7. Push to GitHub, import the repo in Vercel (set `SUPABASE_URL`, `SUPABASE_ANON_KEY`).
8. Going live: PayMongo live keys and GCash activation, a separate live webhook with its own secret, then test with a small real payment.

## How it protects you
- Browsers cannot create orders or change payment fields; only the server functions can.
- A piece is reserved atomically for 30 minutes, so two customers can't buy the same item.
- The webhook checks the PayMongo signature and ignores replays and duplicate events.
- A paid order never reaches Processing or Shipped unless payment is confirmed (database constraint).
- Unpaid, cancelled or abandoned checkouts release the piece after 30 minutes (`release_expired()`).
