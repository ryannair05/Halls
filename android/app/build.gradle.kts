import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.serialization)
    alias(libs.plugins.google.services) apply false
}

// Service configuration belongs to the contributor, never to the public repository.
if (file("google-services.json").isFile) {
    apply(plugin = "com.google.gms.google-services")
}
val localSecrets = Properties().apply {
    val secretsFile = rootProject.file("secrets.properties")
    if (secretsFile.isFile) secretsFile.inputStream().use { load(it) }
}
val mapsApiKey = localSecrets.getProperty("MAPS_API_KEY", "").trim()

android {
    namespace = "com.ryannair05.meetandeat"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.ryannair05.meetandeat"
        minSdk = 31
        targetSdk = 36
        versionCode = 7
        versionName = "1.2.2"
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
        buildConfigField("boolean", "MAPS_CONFIGURED", mapsApiKey.isNotEmpty().toString())

    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_23
        targetCompatibility = JavaVersion.VERSION_23
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        compilerOptions.jvmTarget.set(JvmTarget.JVM_23)
    }
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation("junit:junit:4.13.2")
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.material3.android)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.google.material)
    implementation(libs.androidx.material.icons.extended.android)
    implementation(libs.jsoup)
    implementation(libs.androidx.browser)
    implementation(libs.maps.compose)
    implementation(libs.accompanist.permissions)
    implementation(libs.retrofit)
    implementation(libs.moshi.kotlin)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.converter.moshi)
    implementation(libs.coil.compose)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.analytics)
    implementation(libs.coil.network.okhttp)
    implementation(libs.play.services.location)
}
