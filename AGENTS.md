# TypelessMLX Local Build Notes

## Stable TCC Permissions

When rebuilding the macOS app locally, use the stable local code-signing identity:

```bash
SIGN_IDENTITY="TypelessMLX Local Code Signing" ./build-app.sh --install
```

Accessibility and Input Monitoring permissions should persist across rebuilds when all of these stay stable:

- signing identity: `TypelessMLX Local Code Signing`
- bundle identifier: `com.typelessmlx.app`
- installed app path: `/Applications/TypelessMLX.app`

Avoid normal development builds with:

```bash
ALLOW_ADHOC_SIGNING=1 ./build-app.sh --install
```

Ad-hoc signing changes the code hash across rebuilds, so macOS TCC may treat the app as a different identity and ask for Accessibility / Input Monitoring again.

Reauthorization may still be needed if the local signing certificate is regenerated, the bundle identifier changes, the app is launched from a different path such as `build/TypelessMLX.app`, or stale TCC entries need to be cleaned manually.
