// Info.plist rows that `build.mjs`'s `infoPlist` and `macInfoPlist` write from the manifest and the grants.

/** `NSAppTransportSecurity` from `host.<platform>.appTransportSecurity` and the build's own `keys`; none of either, no key. `allowsArbitraryLoadsInWebContent` relaxes ATS for web views only (an `iframe` loads `http://` from a named host, as a browser does); a module's `URLSession` stays under ATS. */
export const transportSecurity = (section, keys = {}) => {
  const ats = { ...(section?.appTransportSecurity?.allowsArbitraryLoadsInWebContent ? { NSAllowsArbitraryLoadsInWebContent: true } : {}), ...keys };
  return Object.keys(ats).length ? { NSAppTransportSecurity: ats } : {};
};

/** A launch no link started opens at the manifest's `start_url`, as an installed web app does (W3C App Manifest): resolved
 * against the manifest's URL, on the app's declared origin when it has one, and baked when it is a place in the app (on
 * that origin) other than the root. */
export const startLocation = ({ manifest: { start_url: at }, origin: declared }) => {
  if (typeof at !== 'string' || !at) return {};
  const origin = declared ? new URL(declared).origin : 'https://exact.invalid';
  const url = new URL(at, `${origin}/manifest.json`), place = url.pathname + url.search + url.hash;
  return url.origin === origin && place !== '/' ? { ExactStartURL: place } : {};
};

/** When a downloaded update applies and how often the app checks (`deploy.activate`, `deploy.check.interval`). */
export const updateActivation = (app) => ({ ...(app.manifest.deploy?.activate ? { ExactUpdateActivate: app.manifest.deploy.activate } : {}),
  ...(app.manifest.deploy?.check?.interval != null ? { ExactUpdateCheckInterval: app.manifest.deploy.check.interval } : {}) });

/** The iOS rows for background work (LLP 1133.017 D14): `UIBackgroundModes`, the manifest's
 * `host.ios.backgroundModes` with the modes the grant lines derive (`reach.backgroundModes`), and
 * `BGTaskSchedulerPermittedIdentifiers`, the identifiers they permit after the bundle id `id`. `fetch` and `processing` come only from a grant line, so a mode has one way to be declared. `only`: the
 * manifest's modes alone, for tvOS, whose refresh is later (D17), and an App Clip, which has no background tasks. */
export function backgroundKeys(ios, reach, id, only) {
  const declared = ios.backgroundModes ?? [];
  const derived = declared.filter((mode) => mode === 'fetch' || mode === 'processing');
  if (derived.length) throw new Error(`host.ios.backgroundModes: ${derived.join(' and ')} comes from a grant line (device.background-sync, device.periodic-background-sync; LLP 1133.017 D14), not the manifest`);
  const modes = [...new Set([...declared, ...(only ? [] : reach?.backgroundModes ?? [])])];
  const tasks = only ? [] : (reach?.tasks ?? []).map((task) => `${id}.${task}`);
  return { ...(modes.length ? { UIBackgroundModes: modes } : {}), ...(tasks.length ? { BGTaskSchedulerPermittedIdentifiers: tasks } : {}) };
}
