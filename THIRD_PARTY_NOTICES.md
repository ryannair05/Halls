# Third-party notices

The AGPL-3.0-only designation applies to project-owned source. It does not replace third-party licenses.

## Vendored code and resources

- **bitchat / BTChat:** `ios/Penn State Meals/bitchat/` contains the embedded Bluetooth chat dependency from [permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat), including custom adaptations Its existing public-domain/Unlicense headers are preserved. The full notice is in [LICENSES/bitchat-Unlicense.txt](LICENSES/bitchat-Unlicense.txt). The vendored implementation is unchanged in this export.
- **Google Material Symbols:** Android resources retain their Apache-2.0 notice at [material_symbols_license.txt](android/app/src/main/assets/material_symbols_license.txt).
- **Gradle wrapper:** the wrapper scripts retain their Apache-2.0 headers. See [Gradle licensing](https://github.com/gradle/gradle/blob/master/LICENSE).
- University dining images, dietary indicators, names, and marks remain attributable to their respective providers. Retained app resources are included for the existing interface; no ownership of university marks or provider data is claimed.

## Resolved dependencies

Dependencies downloaded by the platform build tools retain their own notices and licenses, including transitive dependencies. Consult their distributions when redistributing binaries.

| Dependency | Upstream |
| --- | --- |
| SwiftSoup | https://github.com/scinfu/SwiftSoup |
| SwiftUI-WebView | https://github.com/kylehickinson/SwiftUI-WebView |
| Firebase SDKs | https://github.com/firebase/firebase-ios-sdk and https://github.com/firebase/firebase-android-sdk |
| AndroidX / Jetpack Compose | https://android.googlesource.com/platform/frameworks/support/ |
| Material Components | https://github.com/material-components/material-components-android |
| Kotlin and kotlinx.serialization | https://github.com/JetBrains/kotlin and https://github.com/Kotlin/kotlinx.serialization |
| jsoup | https://github.com/jhy/jsoup |
| Maps Compose | https://github.com/googlemaps/android-maps-compose |
| Accompanist | https://github.com/google/accompanist |
| Retrofit and Moshi | https://github.com/square/retrofit and https://github.com/square/moshi |
| Coil | https://github.com/coil-kt/coil |
| JUnit | https://github.com/junit-team/junit4 |

Google Play Services and Maps SDK use Google's applicable SDK/service terms. Apple frameworks and SF Symbols remain subject to Apple's terms. Credentials and an open-source feature unlock do not grant rights to external services.

Exact dependency selections are recorded in the iOS `Package.resolved` and Android `gradle/libs.versions.toml` files.
