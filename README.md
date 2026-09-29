# Halls

<img src="ios/Penn%20State%20Meals/Assets.xcassets/AppIcon.imageset/AppIcon.png" alt="Halls app icon" width="112" />

**Find your next meal, catch your next bus, and discover more of campus. Designed for Penn State at University Park**

Halls brings university dining menus, nutrition information, transit, and campus activities into native iOS and Android apps. Check what is being served before walking to a dining hall, filter dishes to suit your preferences, plan a plate, or see when your bus is coming.

[Website](https://swiftbyte.app/) · [Download on the App Store](https://apps.apple.com/us/app/halls-campus-dining/id6446225508) · [Get it on Google Play](https://play.google.com/store/apps/details?id=com.ryannair05.meetandeat)

The store apps are free to download. The iOS store version offers optional Halls Pro purchases; all Pro features are unlocked in this repository’s default iOS build. Originally known as  [Meet and Eat](https://onwardstate.com/2024/02/13/penn-state-sophomore-ryan-nair-creates-award-winning-meet-and-eat-app/).

## What you can do

- **Choose a meal:** browse dining menus, switch dates and meals, search dishes, and use dietary filters.
- **Know your options:** view published ingredients, allergens, nutrition, and dining hours.
- **Plan and remember meals:** build plates and keep a local meal journal.
- **Get around:** follow CATA buses, routes, and stops around Penn State University Park.
- **Explore campus:** find organizations, events, and Campus Recreation schedules.

| | iOS | Android |
| --- | --- | --- |
| Dining campuses | Penn State University Park, Barnard/Columbia dining, University of Georgia | Penn State University Park |
| Native interface | SwiftUI and UIKit | Kotlin and Jetpack Compose |
| Dining, nutrition, CATA busses, meal journal | Yes | Yes |
| Home Screen widget, Siri and Shortcuts | Yes | — |
| Minimum OS | iOS 17 | Android 12 / API 31 |

Features and appearance differ between platforms. Confirm allergy and dietary information directly with dining staff; published menus, hours, and nutrition can change. Halls is an independent project, not an official university or CATA app.

## Repository

```text
Halls/
├── ios/       # iOS app, Meals Widget, Xcode project, Swift package lockfile
├── android/   # Android app, unit tests, Gradle wrapper and dependency catalog
├── LICENSE    # GNU Affero GPL version 3
└── THIRD_PARTY_NOTICES.md
```

The platform projects remain independent. Existing internal project and package names are retained to keep source references intact. Private service configuration, signing files, internal documentation, AI tooling, original Git history, and generated release artifacts are intentionally absent.

## Build for iOS

**Requirements:** macOS, Xcode 27 with the iOS SDK, and internet access to resolve Swift packages. The app supports iOS 17 and later; compiling it requires the newer toolchain.

1. Open `ios/Penn State Meals.xcodeproj` in Xcode.
2. Allow Swift Package Manager to resolve the dependencies in `Package.resolved`.
3. Select the **Penn State Meals** scheme and an iPhone or iPad simulator.
4. Build and run. Dining and other public-data features do not require Firebase configuration.

From the repository root, a simulator build can also be made with:

```sh
xcodebuild -project "ios/Penn State Meals.xcodeproj" \
  -scheme "Penn State Meals" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For a physical device, select your own development team for **Halls** and **Meals Widget** and use your own bundle identifiers. Configure the matching App Group in both entitlement files and update `group.com.ryannair05.pennstatemeals` references in source. HealthKit, WeatherKit, and associated domains require appropriate provisioning; configure your own services/domains or remove unsupported capabilities for your local build. Live weather may be unavailable without WeatherKit access. Public-build Pro access does not provide those service entitlements.

### Optional Firebase analytics

Firebase is disabled when its configuration is absent. To enable it, register your own iOS app with Firebase, download its `GoogleService-Info.plist`, and add it to the **Halls app target’s resources** in Xcode. Keep the file at `ios/Penn State Meals/GoogleService-Info.plist`; it is ignored by Git. Do not add it to the widget. Use a real configuration downloaded from your project rather than placeholder credentials.

### Public-build Pro access

`OPEN_SOURCE_BUILD` is enabled in Debug and Release. It grants Pro feature access, avoids StoreKit entitlement refreshes and transaction listeners, and replaces purchase UI with an included-features message. It does not create or cache a fake purchase.

The StoreKit implementation is retained for developers who need it. To use that path, remove `OPEN_SOURCE_BUILD` from the project’s Swift compilation conditions and configure your own App Store Connect products or local StoreKit testing configuration. No production StoreKit configuration is included.

## Build for Android

**Requirements:** Android Studio supporting Android Gradle Plugin 9.4.1, Android SDK 37, and Java 25 for the Gradle daemon (the app targets Java/JVM 23). The checked-in Gradle wrapper uses Gradle 9.7.1; daemon toolchain provisioning is described by `gradle/gradle-daemon-jvm.properties`. Target SDK is 36 and minimum SDK is 31.

1. Open the `android/` directory in Android Studio.
2. Let Gradle sync and install any requested SDK/toolchain components.
3. Select an Android 12 or newer emulator/device and run **app**.

Alternatively, with `JAVA_HOME` and `ANDROID_HOME` configured:

```sh
cd android
./gradlew :app:assembleDebug :app:testDebugUnitTest
```

The debug APK is generated under `app/build/outputs/apk/debug/`. Android Studio can maintain your SDK path in the ignored `local.properties` file. Debug signing uses your local Android debug keystore; production signing is not included.

### Optional Google Maps and Firebase

Dining and campus features work without private configuration. The CATA screen displays an unavailable-map message until you configure Google Maps:

```sh
cd android  # from the repository root
cp secrets.properties.example secrets.properties
```

Set `MAPS_API_KEY` in `secrets.properties` to your own Maps SDK for Android key, enable that API in your Google Cloud project, and restrict the key to your application ID and signing certificate. Rebuild after changing it. An empty key keeps the map disabled.

For analytics, register your Android application in your own Firebase project and place its downloaded configuration at `android/app/google-services.json`. The Google Services plugin runs only when that file exists, and analytics calls are skipped when Firebase is unconfigured. Both configuration files are ignored by Git.

## Architecture

- **iOS dining:** actor-backed repositories load menu snapshots, cache them on disk, and derive presentation snapshots for native table views. The app, widget, and App Intents share PSU dining services. Other campuses have isolated providers.
- **iOS UI:** SwiftUI coordinates navigation and preferences alongside UIKit dining screens. Transit components use Objective-C. BTChat is a vendored external dependency.
- **Android:** Compose screens consume dining, discovery, and transit repositories through view models. The Gradle version catalog records dependency versions, and local unit tests cover parsing and behavior.

## Contributing and support

Bug reports, focused fixes, accessibility improvements, and improvements to campus data providers are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and validation commands.

For app help, visit [swiftbyte.app](https://swiftbyte.app/) or email [support@swiftbyte.app](mailto:support@swiftbyte.app). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Never include credentials, private user data, or signing files in reports or pull requests.

## License and credits

Project-owned source is licensed under the **GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE).

Third-party code and resources retain their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). University/provider names and marks belong to their respective owners. The source license does not imply endorsement or grant rights to third-party trademarks or externally supplied data.

Created by **Ryan Nair / SwiftByte LLC**.
