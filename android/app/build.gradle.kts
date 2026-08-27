import java.net.URI

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val publicSafeBackendUrl = "https://example.invalid"
val releaseBackendUrl = providers.gradleProperty("KOEON_API_BASE_URL").orElse(publicSafeBackendUrl)
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.substringAfterLast(':').contains("release", ignoreCase = true)
}
val releaseSigningInputs = mapOf(
    "ANDROID_KEYSTORE_PATH" to providers.environmentVariable("ANDROID_KEYSTORE_PATH"),
    "ANDROID_KEY_ALIAS" to providers.environmentVariable("ANDROID_KEY_ALIAS"),
    "ANDROID_KEY_PASSWORD" to providers.environmentVariable("ANDROID_KEY_PASSWORD"),
    "ANDROID_STORE_PASSWORD" to providers.environmentVariable("ANDROID_STORE_PASSWORD"),
)

fun javaStringLiteral(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

fun validateReleaseEndpoint(value: String) {
    val uri = runCatching { URI(value) }.getOrElse { throw GradleException("Invalid release runtime endpoint") }
    if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null || uri.fragment != null) {
        throw GradleException("Release runtime endpoint must be credential-free HTTPS")
    }
    if (uri.host.equals("example.invalid", ignoreCase = true) || uri.host.endsWith(".invalid", ignoreCase = true)) {
        throw GradleException("Release runtime endpoint must not use a placeholder host")
    }
}

if (releaseTaskRequested) {
    val missing = releaseSigningInputs.filterValues { it.orNull.isNullOrBlank() }.keys
    if (missing.isNotEmpty()) throw GradleException("Missing required Android release signing input")
    validateReleaseEndpoint(releaseBackendUrl.get())
}

android {
    namespace = "com.dennomuso.koeon"
    compileSdk = 36

    signingConfigs {
        create("release") {
            storeFile = releaseSigningInputs.getValue("ANDROID_KEYSTORE_PATH").orNull?.let(::file)
            keyAlias = releaseSigningInputs.getValue("ANDROID_KEY_ALIAS").orNull
            keyPassword = releaseSigningInputs.getValue("ANDROID_KEY_PASSWORD").orNull
            storePassword = releaseSigningInputs.getValue("ANDROID_STORE_PASSWORD").orNull
        }
    }

    defaultConfig {
        applicationId = "com.dennomuso.koeon"
        minSdk = 29
        targetSdk = 36
        versionCode = 3
        versionName = "1.0.2"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            buildConfigField("String", "KOEON_BACKEND_URL", javaStringLiteral(publicSafeBackendUrl))
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
            buildConfigField("String", "KOEON_BACKEND_URL", javaStringLiteral(releaseBackendUrl.get()))
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.06.00"))
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    implementation("io.livekit:livekit-android:2.28.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.06.00"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
