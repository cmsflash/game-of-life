import java.io.FileInputStream
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

val releaseSigningCredentials =
    mapOf(
        "keyAlias" to
            (keystoreProperties.getProperty("keyAlias")
                ?: System.getenv("ANDROID_KEY_ALIAS")).orEmpty(),
        "keyPassword" to
            (keystoreProperties.getProperty("keyPassword")
                ?: System.getenv("ANDROID_KEY_PASSWORD")).orEmpty(),
        "storeFile" to
            (keystoreProperties.getProperty("storeFile")
                ?: System.getenv("ANDROID_KEYSTORE_PATH")).orEmpty(),
        "storePassword" to
            (keystoreProperties.getProperty("storePassword")
                ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")).orEmpty(),
    )
val releaseBuildRequested =
    gradle.startParameter.taskNames.any { taskName ->
        taskName.contains("release", ignoreCase = true)
    }
val missingReleaseSigningCredentials =
    releaseSigningCredentials.filterValues { it.isBlank() }.keys

if (releaseBuildRequested) {
    if (missingReleaseSigningCredentials.isNotEmpty()) {
        throw GradleException(
            "Release signing credentials are required. Missing: " +
                missingReleaseSigningCredentials.sorted().joinToString() +
                ". Provide android/key.properties or the ANDROID_KEY_* environment variables.",
        )
    }
    val releaseKeystore = rootProject.file(releaseSigningCredentials.getValue("storeFile"))
    if (!releaseKeystore.isFile) {
        throw GradleException("Release keystore does not exist: ${releaseKeystore.absolutePath}")
    }
}

android {
    namespace = "com.cmsflash.gameoflife"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.cmsflash.gameoflife"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (missingReleaseSigningCredentials.isEmpty()) {
                keyAlias = releaseSigningCredentials.getValue("keyAlias")
                keyPassword = releaseSigningCredentials.getValue("keyPassword")
                storeFile = rootProject.file(releaseSigningCredentials.getValue("storeFile"))
                storePassword = releaseSigningCredentials.getValue("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (missingReleaseSigningCredentials.isEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
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
