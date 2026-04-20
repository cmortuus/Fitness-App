<svelte:head>
  <title>Privacy Policy — Onyx</title>
</svelte:head>

<div class="max-w-2xl mx-auto px-4 py-10 text-zinc-300">
  <a href="/welcome" class="text-sm text-zinc-500 hover:text-zinc-300">← Back</a>
  <h1 class="text-3xl font-bold mt-4 mb-2 text-zinc-100">Privacy Policy</h1>
  <p class="text-xs text-zinc-500 mb-8">Last updated: April 2026</p>

  <div class="space-y-6 text-sm leading-relaxed">
    <p>
      We try to collect as little as possible — just enough to run the app and
      keep it working.  This policy explains what data we have and what we do
      with it.
    </p>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">What we collect</h2>
      <ul class="list-disc pl-5 space-y-1">
        <li><strong>Account:</strong> username, email, hashed password.</li>
        <li><strong>Workout data:</strong> everything you log — sets, reps, weights, notes, plans, nutrition, body weight.</li>
        <li><strong>Billing:</strong> Stripe handles all payment data.  We only see whether your subscription is active and when it renews.  Your card number never touches our servers.</li>
        <li><strong>Errors & analytics:</strong> we use Sentry for error tracking and PostHog for aggregate product analytics (page views, feature usage).  You can opt out in Settings → Privacy.</li>
      </ul>
    </section>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">Who we share it with</h2>
      <p>The service providers we use, only for what they do:</p>
      <ul class="list-disc pl-5 space-y-1 mt-2">
        <li><strong>Stripe</strong> — payments</li>
        <li><strong>Resend</strong> — transactional email (verify your address, password resets)</li>
        <li><strong>Cloudflare</strong> — DNS and CDN</li>
        <li><strong>Sentry / PostHog</strong> — error + usage analytics</li>
      </ul>
      <p class="mt-2">
        We don't sell your data.  We don't share it with advertisers.  We don't
        train models on it.
      </p>
    </section>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">Your rights</h2>
      <ul class="list-disc pl-5 space-y-1">
        <li><strong>Export:</strong> download a full copy of your data anytime from Settings → Account.</li>
        <li><strong>Delete:</strong> delete your account from Settings → Account.  We erase your data and cancel any active Stripe subscription.</li>
        <li><strong>Email us:</strong> privacy@lethal.dev for anything not covered here.</li>
      </ul>
    </section>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">Data retention</h2>
      <p>
        We keep your data for as long as your account is open.  Nightly encrypted
        backups are retained for 30 days.  After account deletion, data is purged
        from backups within that window.
      </p>
    </section>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">Cookies</h2>
      <p>
        We use a small number of cookies/localStorage items to keep you signed in
        and remember your preferences.  No tracking cookies.  Analytics respects
        Do Not Track and our in-app opt-out.
      </p>
    </section>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">Changes</h2>
      <p>
        We'll email you before any material changes take effect.
      </p>
    </section>

    <section>
      <h2 class="text-lg font-semibold text-zinc-100 mb-2">Contact</h2>
      <p>privacy@lethal.dev</p>
    </section>
  </div>
</div>
