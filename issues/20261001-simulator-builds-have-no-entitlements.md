# iOS simulator builds carry no entitlements, so the Keychain and every other entitlement-gated API fail there

**Status:** Open
**Systems:** host/apple/build.mjs, iOS simulator, the store (LLP 1018), Agent API
**Severity:** P1
**Author:** Claude (Opus 5.5)
**Date:** 2026-10-01
**Related:** LLP 1018 D6/D7 (kept secrets), LLP 1030 D1/D2 (host metadata, receipt), LLP 1069.006 D2 (auth callbacks and `webcredentials:`), LLP 1012 (agent stores)

## Symptom

On an iOS simulator, every Keychain write an app makes through the store
fails. The journal reads:

```
store <name> failed: keychain: keep <name>: A required entitlement is not present.
```

That is `errSecMissingEntitlement` (-34018) from `SecItemAdd`
(`vendor/ibex2/src/engine/darwin_keychain.mm`). Inside a session the
TypeScript `store` still answers from its snapshot, so the app looks
signed in. After a relaunch the secret is gone.

The kept answers (`exact.kept.*`) are files, so they do survive. The app
therefore boots into a mixed state. A resource kept as "signed in" renders
while every source that reads the secret reports "signed out", until those
resources are asked again.

Reproduce it with any app whose `app.ts` calls `store.set`:

```sh
EXACT_STORE=real bun scripts/agent.mjs ios "<press that sets a secret>" "clock settle" logs
# the journal shows `store <name> failed: … A required entitlement is not present.`
```

## Root cause

Exact assembles and signs the `.app` itself rather than through xcodebuild.
`host/apple/build.mjs` writes entitlements for device builds only:

- `entitlements(app, team, debuggable, reach)` (`build.mjs:448`) derives them
  from the provisioning profile's team. It covers `application-identifier`,
  `team-identifier`, `get-task-allow` and associated domains.
- They are written (`:1299`) and passed to `codesign` only when `device` is
  true (`:1309`: `...(device ? ['--entitlements', ent] : [])`).
- A simulator bundle is signed ad hoc with no entitlements at all. Its
  receipt records `entitlements: null` (`:1306`).

Signing the simulator bundle with entitlements does not fix this. An ad-hoc
signature whose entitlements include `application-identifier` or
`keychain-access-groups` is refused at launch: `simctl launch` reports
"Application launch … did not return a process handle nor launch error"
(POSIX 3). Restricted entitlements need a profile, and a simulator app has
none.

Xcode avoids both problems with **simulated entitlements**. For a simulator
destination it links the entitlements plist into the executable's
`__TEXT,__entitlements` section (`ld -sectcreate __TEXT __entitlements
<plist>`) and signs ad hoc without `--entitlements`. The simulator honours
the section; the check at the end of this issue confirms it for the
Keychain. Exact's build has no equivalent step.

## Why no check caught it

Agent sessions use memory stores unless `EXACT_STORE=real`
(`host/apple/src/store.rs:27-33`, by design per LLP 1012). The smokes and
the UIKit tests therefore never reach the real Keychain on a simulator.
macOS uses the login keychain, which needs no entitlement
(`darwin_keychain.mm:9-15`). Device builds are signed with a profile. So the
simulator is the one destination where the real store is broken, and it is
the one nothing exercises.

## Scope: not only the Keychain

Every entitlement-gated capability is missing on simulator builds, and each
one fails quietly:

- The Keychain (`application-identifier`, `keychain-access-groups`): the
  store's secrets, the `keepKey` pairs (LLP 1069.005), and any session
  token an app keeps.
- Associated domains: universal links (LLP 1038 D8), and the
  `webcredentials:` that an https auth callback claims (LLP 1069.006 D2,
  derived at `build.mjs:457-460`). These exist in the device entitlements
  today, and only there.
- App groups (`com.apple.security.application-groups`): containers shared
  with an extension.
- Anything an app adds later: `aps-environment`, iCloud containers, Sign in
  with Apple, HealthKit and so on.

The result is that the simulator is a weaker oracle than a device for
exactly the features a profile grants. A capability that works on a phone
can look broken in the dev loop, and the reverse can happen too.

## Suggested fix

1. **One derivation for both destinations.** `entitlements()` becomes the
   only place an app's entitlements are computed:
   - from the manifest: `host.ios.associatedDomains` and the origin;
   - from the bake's `reach`: auth callbacks;
   - from the grants: `secret.keep` / `keepKey` imply the app's Keychain
     group.

   Device builds keep signing with it. Simulator builds link the same
   dictionary through `-sectcreate __TEXT __entitlements` on the ExactIOS
   (and ExactHostIOS) link. That link happens in the `swift build`
   arguments, so `-Xlinker` flags reach it. The team prefix is the
   profile's when the machine has one; otherwise a fixed placeholder. A
   bare app id with no prefix worked in the check below. Whatever the
   prefix, it has to stay the same between builds, or the Keychain group
   changes and earlier items become unreadable.
2. **A manifest escape hatch** for what cannot be derived:
   `host.ios.entitlements`, an object merged into both destinations and
   validated against an allow-list. App groups and iCloud containers are
   the first consumers. One declaration means a simulator build and a
   device build claim the same capabilities.
3. **The receipt records what was linked.** For a simulator build,
   `entitlements` holds the simulated plist instead of `null`, so "what did
   this binary contain" stays answerable (LLP 1030 D2).
4. **A check that would have caught it.** An iOS simulator smoke step under
   `EXACT_STORE=real`:
   - set a secret, relaunch, and read it back;
   - assert no `store … failed` line in the journal.

   The UIKit suite can also assert that the built executable has a
   non-empty `__TEXT,__entitlements` section containing the app identifier.

A minimal version of (1), simulator only, with `application-identifier` and
`keychain-access-groups` both set to the app id, was verified by hand. It
was linked through `-sectcreate` in the `swift build` arguments for
`--ios` without `--device`. With it, `store.set` persisted across relaunches
on an iOS 27 simulator, and the journal reported no failure.

Done when the simulator smoke above passes, the receipt shows the linked
entitlements, and associated domains and app groups declared for a device
build also appear in a simulator build's `__TEXT,__entitlements`.
