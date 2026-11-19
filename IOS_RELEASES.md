# River iOS releases

[River iOS TestFlight](https://github.com/jeethsuresh/river/actions/workflows/river-ios-testflight.yml)
signs `cool.gravitas.river` and delivers it to App Store Connect. A push to `main`
with a new version in `client/pubspec.yaml` starts the workflow. Increase the
build number for each release and update `changelog.json` to match. To deliver
the current release or retry a failed upload, run the workflow on `main` from
Actions. Check the build in App Store Connect before retrying an interrupted
upload because Apple reserves the build number once it accepts the delivery.

## Signing setup

Use the `ios-release` GitHub environment with a deployment branch policy for
`main`. Configure these environment secrets.

- `IOS_DISTRIBUTION_P12_BASE64` holds the base64-encoded password-protected Apple
  Distribution certificate and private key exported as a `.p12`.
- `IOS_DISTRIBUTION_P12_PASSWORD` holds the password for the `.p12` export.
- `IOS_PROVISIONING_PROFILE_BASE64` holds the base64-encoded App Store
  distribution profile for `cool.gravitas.river`, with production APNs and the
  matching distribution certificate.
- `IOS_ASC_KEY_BASE64` holds the base64-encoded `.p8` for an App Store Connect
  team API key with the Developer role or another role allowed to upload builds.
- `IOS_ASC_KEY_ID` and `IOS_ASC_ISSUER_ID` identify that App Store Connect key.

On macOS, pipe base64 output from a credential file directly to GitHub.

```bash
base64 -i /path/to/file | gh secret set SECRET_NAME --env ios-release --repo jeethsuresh/river
```

Set the password and IDs through the environment settings or the interactive
`gh secret set` prompt.

## Verify delivery

The Actions summary records the version, build number, and source commit after
Apple accepts the upload. In App Store Connect, open River’s TestFlight tab and
confirm that the build finishes processing. TestFlight distribution follows the
app's existing tester group configuration.
