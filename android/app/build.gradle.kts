import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Glide's release key, described in android/key.properties (kept out of
// version control, as is the key it points to). Every APK on the GitHub
// releases must be signed with it, or Android won't let it update the Glide
// already installed. So a release build without a usable key.properties
// stops with an error rather than quietly signing with the debug key. To
// try out a release build anyway, set GLIDE_DEBUG_SIGNED_RELEASE=1.
val keystoreProperties = Properties()
val releaseKeyProblem: String? = run {
    val file = rootProject.file("key.properties")
    if (!file.exists()) return@run "android/key.properties is missing."
    file.inputStream().use { keystoreProperties.load(it) }
    val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) return@run "android/key.properties has no ${missing.joinToString()}."
    val store = project.file(keystoreProperties.getProperty("storeFile"))
    if (!store.exists()) return@run "The key in android/key.properties isn't there: $store"
    null
}
val debugSignedReleaseAllowed = System.getenv("GLIDE_DEBUG_SIGNED_RELEASE") == "1"

android {
    namespace = "com.bersamamus.better_image_manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Glide's identity on Android: never change it, or installed copies
        // can't be updated. (The code's package, above, keeps the old name.)
        applicationId = "com.bersamamus.glide"
        // Android 7, as the README promises. Pinned rather than following
        // Flutter's default, which can rise with a Flutter upgrade.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeyProblem == null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

// Debug builds never need the release key; only stop a release build that
// would otherwise be signed with the debug key.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { it.project == project && it.name.endsWith("Release") }
    if (buildsRelease && releaseKeyProblem != null && !debugSignedReleaseAllowed) {
        throw GradleException(
            "Can't sign a release build with Glide's key: $releaseKeyProblem " +
                "Set GLIDE_DEBUG_SIGNED_RELEASE=1 to sign it with the debug key instead (never publish that APK)."
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The editor's Background: finding a picture's subject, on the phone.
    // Through Google Play services, which downloads the model (so the app
    // stays small).
    implementation("com.google.android.gms:play-services-mlkit-subject-segmentation:16.0.0-beta1")
}
