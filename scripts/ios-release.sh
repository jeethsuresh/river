#!/usr/bin/env bash
set -euo pipefail

: "${IOS_DISTRIBUTION_P12_BASE64:?Set IOS_DISTRIBUTION_P12_BASE64 in the ios-release environment}"
: "${IOS_DISTRIBUTION_P12_PASSWORD:?Set IOS_DISTRIBUTION_P12_PASSWORD in the ios-release environment}"
: "${IOS_PROVISIONING_PROFILE_BASE64:?Set IOS_PROVISIONING_PROFILE_BASE64 in the ios-release environment}"
: "${RIVER_IOS_VERSION:?Expected the release version}"
: "${RIVER_IOS_BUILD:?Expected the release build number}"

bundle=cool.gravitas.river
umask 077
work=$(mktemp -d "$RUNNER_TEMP/river-ios.XXXXXX")
keychain="$work/signing.keychain-db"
project=client/ios/Runner.xcodeproj/project.pbxproj
profile_to_remove=
original_keychains=()
while IFS='"' read -r _ path _; do
  original_keychains+=("$path")
done < <(security list-keychains -d user)

cleanup() {
  if [[ -f "$work/project.pbxproj" ]]; then
    cp "$work/project.pbxproj" "$project"
  fi
  if [[ -n "$profile_to_remove" ]]; then
    rm -f "$profile_to_remove"
  fi
  if [[ -f "$keychain" ]]; then
    security list-keychains -d user -s "${original_keychains[@]}"
    security delete-keychain "$keychain"
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$work/river.mobileprovision"
printf '%s' "$IOS_DISTRIBUTION_P12_BASE64" | base64 --decode > "$work/distribution.p12"
unset IOS_PROVISIONING_PROFILE_BASE64 IOS_DISTRIBUTION_P12_BASE64
security cms -D -i "$work/river.mobileprovision" -o "$work/profile.plist"

team=$(plutil -extract TeamIdentifier.0 raw "$work/profile.plist")
uuid=$(plutil -extract UUID raw "$work/profile.plist")
[[ "$team" =~ ^[A-Z0-9]{10}$ && "$uuid" =~ ^[A-Fa-f0-9-]{36}$ ]]
plist_buddy=/usr/libexec/PlistBuddy
if [[ $("$plist_buddy" -c 'Print :Entitlements:application-identifier' "$work/profile.plist") != "$team.$bundle" ||
      $(plutil -extract Entitlements.aps-environment raw "$work/profile.plist") != production ]] ||
      plutil -extract ProvisionedDevices xml1 -o /dev/null "$work/profile.plist" 2>/dev/null ||
      [[ $(plutil -extract ProvisionsAllDevices raw "$work/profile.plist" 2>/dev/null || true) == true ]]; then
  echo 'Use a River App Store provisioning profile with production APNs.' >&2
  exit 1
fi

password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/distribution.p12" -k "$keychain" -P "$IOS_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign
unset IOS_DISTRIBUTION_P12_PASSWORD
rm -f "$work/distribution.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -F '"Apple Distribution:'
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"

profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profile_dir"
profile_path="$profile_dir/$uuid.mobileprovision"
if [[ ! -e "$profile_path" ]]; then
  profile_to_remove=$profile_path
  cp "$work/river.mobileprovision" "$profile_path"
else
  cmp "$work/river.mobileprovision" "$profile_path"
fi

# Signing settings belong to Runner only. Pods and Swift packages have their own targets.
cp "$project" "$work/project.pbxproj"
ruby -rxcodeproj - "$team" "$uuid" <<'RUBY'
team, profile = ARGV
project = Xcodeproj::Project.open('client/ios/Runner.xcodeproj')
target = project.targets.find { |target| target.name == 'Runner' }
release = target.build_configurations.find { |config| config.name == 'Release' }
release.build_settings.update(
  'CODE_SIGN_STYLE' => 'Manual',
  'CODE_SIGN_IDENTITY[sdk=iphoneos*]' => 'Apple Distribution',
  'DEVELOPMENT_TEAM' => team,
  'PROVISIONING_PROFILE_SPECIFIER' => profile
)
project.save
RUBY

env -i PATH="$PATH" HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
  xcodebuild -workspace client/ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/River.xcarchive" \
  -derivedDataPath "$work/derived" -clonedSourcePackagesDirPath "$PWD/client/build/ios/SourcePackages" \
  -disableAutomaticPackageResolution archive

python3 - "$work/export.plist" "$bundle" "$team" "$uuid" <<'PY'
import plistlib
import sys

path, bundle, team, profile = sys.argv[1:]
with open(path, 'wb') as destination:
    plistlib.dump({
        'method': 'app-store-connect',
        'destination': 'export',
        'signingStyle': 'manual',
        'signingCertificate': 'Apple Distribution',
        'provisioningProfiles': {bundle: profile},
        'teamID': team,
        'manageAppVersionAndBuildNumber': False,
    }, destination)
PY
xcodebuild -exportArchive -archivePath "$work/River.xcarchive" \
  -exportOptionsPlist "$work/export.plist" -exportPath "$work/export"

set -- "$work/export/"*.ipa
[[ $# == 1 && -f "$1" ]]
ditto -x -k "$1" "$work/ipa"
app="$work/ipa/Payload/Runner.app"
info="$app/Info.plist"
[[ $(plutil -extract CFBundleIdentifier raw "$info") == "$bundle" ]]
[[ $(plutil -extract CFBundleShortVersionString raw "$info") == "$RIVER_IOS_VERSION" ]]
[[ $(plutil -extract CFBundleVersion raw "$info") == "$RIVER_IOS_BUILD" ]]
[[ $(plutil -extract ITSAppUsesNonExemptEncryption raw -expect bool "$info") == false ]]
codesign --verify --deep --strict "$app"
codesign --display --xml --entitlements - "$app" > "$work/entitlements.plist"
[[ $(plutil -extract aps-environment raw "$work/entitlements.plist") == production ]]
mv "$1" "$RUNNER_TEMP/river-testflight.ipa"
