allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// OneDrive 内だと build がジャンクションの場合に Gradle のスナップショットで "not a regular file" になるため、
// ビルド出力を OneDrive 外（LOCALAPPDATA）に出す。APK は assembleRelease 後にプロジェクトの build へコピーする。
val buildRootDir: java.io.File = java.io.File(
    System.getenv("LOCALAPPDATA") ?: System.getenv("TEMP") ?: "C:\\Temp",
    "tessera_android_build"
)
rootProject.layout.buildDirectory.set(
    rootProject.layout.dir(project.provider { buildRootDir })
)
subprojects {
    project.layout.buildDirectory.set(
        rootProject.layout.dir(project.provider { java.io.File(buildRootDir, project.name) })
    )
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
