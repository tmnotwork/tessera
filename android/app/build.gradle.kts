plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.tessera"
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
        applicationId = "com.example.tessera"
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

// ビルド出力が LOCALAPPDATA のため、Flutter が APK を認識できるようプロジェクトの build にコピー
afterEvaluate {
    tasks.named("assembleRelease").configure {
        doLast {
            val apkSource = layout.buildDirectory.file("outputs/flutter-apk/app-release.apk").get().asFile
            if (apkSource.exists()) {
                val destDir = rootProject.file("../../build/app/outputs/flutter-apk")
                if (!destDir.exists()) destDir.mkdirs()
                project.copy {
                    from(apkSource)
                    into(destDir)
                }
            }
        }
    }
}
