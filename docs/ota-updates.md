# Over-the-air updates: TestFlight + (optional) Xcode Cloud

Goal: get new Stone builds onto a phone without plugging into the Mac every
time. Apple's signing model makes **some** Apple-blessed step unavoidable —
there is no way to distribute a signed iOS build to a phone that skips Apple
entirely. The practical shape of the solution:

```
source change --> build (signed) --> upload to App Store Connect --> TestFlight --> phone (OTA)
                     ^
                     |
         either the Mac (scripts/testflight-upload.sh, one command)
         or Xcode Cloud (build triggered from source, no Mac needed
         for *routine* builds — see "Xcode Cloud" below for the catch)
```

Once a build lands in App Store Connect and is added to a TestFlight testing
group, updating the phone is just opening the TestFlight app and tapping
Update — genuinely over the air, no cable, no laptop. Everything above that
line (getting a build *into* App Store Connect) is what this doc and
`scripts/testflight-upload.sh` cover.

Steps are marked:
- **[APPLE ACCOUNT]** — only doable by the person holding the Apple ID / App
  Store Connect role for this project (currently `jkridner@beagleboard.org`,
  team `BWWLLRK896` per `ios/project.yml`). Web UI or Xcode UI, one-time.
- **[SCRIPT]** — automated by `scripts/testflight-upload.sh`, repeatable.
- **[VERIFY]** — probably already true given the existing project state, but
  worth confirming once rather than assuming.

## 1. One-time App Store Connect setup

These are unavoidable manual steps — Apple requires a human to click through
account-level setup; none of it can be scripted or delegated to this repo.

1. **[VERIFY] Apple Developer Program enrollment.** `ios/project.yml` already
   pins `DEVELOPMENT_TEAM: BWWLLRK896`, which only exists if enrollment
   ($99/year, renews annually) is already active — this is presumably already
   done. Confirm at https://developer.apple.com/account if unsure.
2. **[APPLE ACCOUNT] Register the App ID (bundle id) for distribution**, if
   not already registered — Certificates, Identifiers & Profiles > Identifiers
   > `+`. Bundle ID: `com.stone.app` (must be **explicit**, not wildcard, to
   be App-Store-eligible). In practice `xcodebuild archive
   -allowProvisioningUpdates` with `CODE_SIGN_STYLE: Automatic` (already set
   in `ios/project.yml`) will auto-register this the first time it archives,
   the same way `scripts/run-on-device.sh` already auto-manages the
   *development* profile — but if that fails, register it by hand first.
3. **[APPLE ACCOUNT] Create the App Store Connect app record.**
   App Store Connect > Apps > `+` > New App.
   - Platform: iOS
   - Name: "Stone" (must be globally unique across the App Store; add a
     suffix if taken — this cannot be checked without an account session)
   - Primary language, SKU (any unique string, e.g. `stone-ios`), and the
     bundle ID `com.stone.app` registered in step 2.
   - This step **cannot be automated or skipped** — App Store Connect
     rejects an upload for a bundle ID that has no app record yet, so this
     has to exist before the first `testflight-upload.sh` run.
4. **[APPLE ACCOUNT] Create a TestFlight Internal Testing group.**
   App Store Connect > Stone > TestFlight tab > Internal Testing > `+`.
   - Internal testers must already be Users on the App Store Connect team
     (Users and Access > `+`, role App Manager or above is enough to test).
     Add `jkridner@beagleboard.org` (or whichever Apple ID the phone uses)
     as a team user first if it isn't already one, then add it to the group.
   - Internal testing has **no Beta App Review wait** — a build becomes
     installable within minutes of finishing processing. This is the right
     choice for "just get it on my own phone"; it's capped at 100 testers,
     all of whom must be team members.
   - (External testing groups exist for testers outside the team — anyone
     with an email — but the *first* build to a given version needs a Beta
     App Review, ~24–48h. Not needed for solo/internal use; mentioned here
     in case testers beyond the account holder are ever wanted.)
   - Check "Enable automatic distribution" on the group so every successful
     upload reaches testers without a manual "add build to group" click.
5. **[APPLE ACCOUNT, one-time] Install the TestFlight app** on the phone and
   accept the internal-tester invite email — after that, updates just show
   up in TestFlight.

None of steps 1–5 can be done from this checkout or by an agent — they all
require an authenticated App Store Connect session tied to the account.

## 2. Build path A — the Mac, one command

`scripts/testflight-upload.sh` (added by this change) archives, signs, and
uploads in a single call:

```
scripts/testflight-upload.sh
```

What it does, mirroring the existing `scripts/run-on-device.sh` conventions:
- Bumps `CFBundleVersion` to a UTC timestamp (`YYYYMMDDHHMM`) for the
  duration of the build only, then restores `Info.plist` on exit (success or
  failure) — App Store Connect rejects re-uploading a build number it has
  already seen for the same version, so every upload needs a fresh one, and
  a timestamp avoids needing any committed/shared counter state.
- `xcodebuild archive` for `generic/platform=iOS`, Release configuration,
  with `-allowProvisioningUpdates` — same automatic-signing mechanism
  `run-on-device.sh` already relies on, just producing a **Distribution**
  identity instead of a **Development** one (Xcode's automatic signing picks
  the right cert type for the build action).
- Writes a throwaway `ExportOptions.plist` with `destination: upload`, which
  makes `xcodebuild -exportArchive` perform the App Store Connect upload
  directly — no separate `altool`/Transporter step.

**Prerequisite, already true if `run-on-device.sh` works on this Mac:** the
Apple ID for team `BWWLLRK896` must be signed in under Xcode > Settings >
Accounts, with an active App Store Connect role (App Manager or above) —
that's what `-allowProvisioningUpdates` uses to mint the Distribution
certificate and provisioning profile the first time, and what authenticates
the upload. This is a one-time sign-in per Mac, not a per-build step.

This is still "the Mac," but it collapses build+sign+upload to one command
instead of an Xcode UI walkthrough — a real reduction even without Xcode
Cloud, and the thing to reach for immediately.

### A note on the App Store Connect API key alternative

For fully headless signing (no Apple ID session at all, e.g. a build server),
Apple supports App Store Connect API keys (`-authenticationKeyPath
/-authenticationKeyID/-authenticationKeyIssuerID`, generated at App Store
Connect > Users and Access > Integrations — **[APPLE ACCOUNT]**, Admin role
required, key downloadable only once). Multiple current developer-forum
reports say this authentication path works for `-allowProvisioningUpdates`
but is unreliable for the `destination: upload` step specifically — Apple ID
session auth is the well-trodden path there. Since a Mac with a signed-in
Xcode is already this project's convention, `testflight-upload.sh` uses that
route rather than the API key, and doesn't need a headless build box for the
Mac path. (The API key remains genuinely useful for Xcode Cloud, see below —
Xcode Cloud manages its own signing without either mechanism.)

## 3. Build path B — Xcode Cloud (optional, removes the Mac from routine builds)

Xcode Cloud is Apple's CI, integrated with App Store Connect: it builds and
can auto-distribute to TestFlight on every push, with **no Mac involved in
routine updates** — only in the one-time setup, which has to happen inside
Xcode on a Mac (Product > Xcode Cloud > Create Workflow) because that's where
Apple's workflow editor lives.

**The catch for this project: Xcode Cloud watches a git host, not Fossil.**
It only connects to GitHub (incl. GitHub Enterprise), GitLab (incl.
self-managed), or Bitbucket (Cloud or Server) — Fossil, this project's actual
version control, is not and cannot be a source. To use Xcode Cloud, the `ios/`
tree (or the whole repo) needs a live mirror on one of those, kept current.
Fossil supports this natively:

```
fossil git export /path/to/mirror   # first run creates the git repo; re-run to sync
```

That export+push needs to run *somewhere* on every change that should trigger
a build — a cron job or hook on any always-on machine (this workbench host,
a small VPS, etc.), not necessarily the Mac. That keeps the "no laptop for
routine updates" property intact, but it's a real second moving part to build
and keep running, and it's out of scope for this ticket (no such mirror
exists yet). Treat Xcode Cloud as a documented option to adopt later, not
something wired up now.

If/when that mirror exists, the rest of the setup is:

1. **[APPLE ACCOUNT] In Xcode**, Product > Xcode Cloud > Create Workflow,
   sign in, and grant Xcode Cloud access to the mirrored repo (OAuth/App
   install flow against GitHub/GitLab/Bitbucket — **[user's account action
   on that provider too]**).
2. **[APPLE ACCOUNT]** Configure the workflow: trigger on push to the mirror
   branch, action = Archive, post-action = "TestFlight (Internal Testing)" —
   this built-in post-action uploads and distributes to the internal group
   automatically, no script needed on the Xcode Cloud side.
3. Xcode Cloud manages its own signing certificates/profiles via its App
   Store Connect integration — no API key or Apple-ID-in-Xcode dance needed
   once workflow access is granted.

**Costs/limits, verified against current Apple pricing:**
- Every Apple Developer Program membership includes **25 Xcode Cloud compute
  hours/month for free**, un-rolled-over (unused hours don't carry to the
  next month).
- Paid tiers if 25 hrs/month isn't enough: 100 hrs/mo ≈ $49.99, 250 hrs/mo ≈
  $99.99, 1000 hrs/mo ≈ $399.99, 10000 hrs/mo ≈ $3999.99 (Apple's published
  Xcode Cloud plans; subject to change, worth reconfirming at
  https://developer.apple.com/xcode-cloud/ before relying on a number here).
- For a single-scheme app this size, an archive build likely runs single-digit
  minutes, so 25 free hours/month is generous headroom for "push a few times
  a week" — the mirror-sync cadence is the actual throttle on build frequency,
  not the compute quota.

## Summary / recommendation

- Do **path A now** (`scripts/testflight-upload.sh`) — it needs zero new
  infrastructure beyond the App Store Connect setup in section 1, which is
  required either way.
- Treat **path B (Xcode Cloud)** as a later upgrade, once/if the Fossil→git
  mirror is worth building — it removes the Mac from routine builds entirely,
  at the cost of standing up and maintaining that mirror.
- Either path lands builds in the same place (App Store Connect > TestFlight
  Internal Testing), so the phone-side experience (open TestFlight, tap
  Update) is identical regardless of which produced the build.
