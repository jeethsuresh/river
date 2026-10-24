plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKey = System.getenv("RIVER_KEYSTORE")
val releaseStorePassword = System.getenv("RIVER_STORE_PASSWORD")
val releaseAlias = System.getenv("RIVER_KEY_ALIAS")
val releaseKeyPassword = System.getenv("RIVER_KEY_PASSWORD")
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
    require(listOf(releaseKey, releaseStorePassword, releaseAlias, releaseKeyPassword).all { !it.isNullOrBlank() }) {
        "River release signing is required. Use scripts/build-android.py with the protected original key."
    }
    require(releaseAlias == "river-release") { "Use River's permanent release signing alias." }
}

android {
    namespace = "cool.gravitas.river"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cool.gravitas.river"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("riverRelease") {
            storeFile = releaseKey?.let { file(it) }
            storePassword = releaseStorePassword
            keyAlias = releaseAlias
            keyPassword = releaseKeyPassword
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("riverRelease")
        }
    }
}

flutter {
    source = "../.."
}
