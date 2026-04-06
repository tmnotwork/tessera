import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.sukimastudy.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sukimastudy.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// ビルド出力が LOCALAPPDATA のため、Flutter が APK を認識できるようプロジェクトの build にコピーする。
// doLast だけだと Flutter Gradle プラグイン側の設定と順序が競り、コピーが走らないことがあるため finalizedBy で最後に実行する。
val copyReleaseApkForFlutterCli by tasks.registering {
    description = "Flutter CLI が探す build/app/outputs/flutter-apk/app-release.apk へ同期"
    group = "build"
    doLast {
        val buildDir = layout.buildDirectory.get().asFile
        val flutterApk = File(buildDir, "outputs/flutter-apk/app-release.apk")
        val agpApk = File(buildDir, "outputs/apk/release/app-release.apk")
        val src = when {
            flutterApk.isFile -> flutterApk
            agpApk.isFile -> agpApk
            else -> throw org.gradle.api.GradleException(
                "Release APK が見つかりません: $flutterApk または $agpApk"
            )
        }
        val destDir = File(rootProject.projectDir.parentFile, "build/app/outputs/flutter-apk")
        destDir.mkdirs()
        src.copyTo(File(destDir, "app-release.apk"), overwrite = true)
    }
}

afterEvaluate {
    tasks.named("assembleRelease").configure {
        finalizedBy(copyReleaseApkForFlutterCli)
    }
}
