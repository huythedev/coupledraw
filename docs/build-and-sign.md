# Build and sign

[Back to README](../README.md)

## Build on a Mac

Install the full Xcode 16 or later. Open the included `CoupleDraw.xcodeproj` and choose the **CoupleDraw** scheme; no package manager is needed for the iOS app. A simulator build can be made with `sh tools/build-on-mac.sh` or **Product → Run**. In Xcode select **Product → Test** for the Swift tests.

For your own iPhone, add your Apple Account in **Xcode → Settings → Accounts**. Select the CoupleDraw app and CoupleDrawWidget targets, enable automatic signing, choose the same Team, and set unique compatible bundle IDs, such as `com.yourname.CoupleDraw` and `com.yourname.CoupleDraw.Widget`. Connect and trust the iPhone, choose it as the destination, and use **Product → Run**. Use iOS 17 or later. The default project leaves Push Notifications off so a Personal Team can provision it. Both app and widget need appropriate signing; the widget is embedded by the app target.

## Unsigned IPA

The [Releases page](https://github.com/huythedev/coupledraw/releases) contains the latest successful main-branch unsigned IPA. GitHub Actions also provides an artifact for every push. Successful builds on main create a `build-<run number>` Release, while a `v...` tag gets a versioned Release.

To build it yourself from the repository root:

```sh
sh tools/build-unsigned-ipa-on-mac.sh
```

The script uses a full Xcode installation, builds iPhoneOS Release with code signing off, verifies that the widget is embedded, and writes `dist/CoupleDraw-unsigned.ipa`. If only Command Line Tools are selected, the script uses `/Applications/Xcode.app` if present. For a different location, set `XCODE_APP_PATH=/path/to/Xcode.app` for that invocation. A simulator build is not an installable iPhone IPA.

**Unsigned means not installable yet.** Sign the app and its embedded `PlugIns/CoupleDrawWidget.appex` with matching IDs and provisioning profiles. The example IDs in the built IPA are `com.example.CoupleDraw` and `com.example.CoupleDraw.Widget`; replace both. An ad-hoc code signature without Apple provisioning is not enough for a normal iPhone.

## Sign a Release IPA

The simplest path for your own device is the Xcode **Product → Run** flow above. To sign a downloaded IPA, obtain a certificate with its private key (`.p12`) and separate app and widget `.mobileprovision` profiles for your IDs. Development or Ad Hoc profiles must include that iPhone. Keep the private key, password, and profiles out of the repository and public file-sharing sites.

For example, on a Mac with [zsign](https://github.com/zhlynn/zsign), unpack the unsigned IPA, set the IDs, and sign both bundles with their matching profiles:

```sh
mkdir signing-work
unzip -q CoupleDraw-unsigned.ipa -d signing-work
plutil -replace CFBundleIdentifier -string com.yourname.CoupleDraw signing-work/Payload/CoupleDraw.app/Info.plist
plutil -replace CFBundleIdentifier -string com.yourname.CoupleDraw.Widget signing-work/Payload/CoupleDraw.app/PlugIns/CoupleDrawWidget.appex/Info.plist
zsign -k certificate.p12 -p "$P12_PASSWORD" \
  -m app.mobileprovision -m widget.mobileprovision \
  -o CoupleDraw-signed.ipa signing-work/Payload/CoupleDraw.app
```

Confirm that the signed IPA still contains the widget and that **both** bundle IDs, entitlements, and embedded profiles match the intended Team and device. Install through Xcode **Devices and Simulators**, Apple Configurator, or another installer compatible with your profiles. If using an on-device signing tool, import the certificate and both profiles and inspect the resulting app and widget IDs. To preserve local drawings across upgrades, keep the same Team and app ID.

See [Apple's registered-device distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices). Direct APNs requires a Push-capable Apple Developer Program team and correctly provisioned Push entitlements; see [server setup](server.md#optional-direct-apns).
