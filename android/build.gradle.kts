// 仓库顺序：**阿里云镜像在前，官方源在后**。
//
// 为什么（2026-10-08 实测）：本项目所在网络**访问 dl.google.com 会 TLS 握手失败**
// （`Remote host terminated the handshake`），而 `maven.aliyun.com/repository/google` 可达，
// 于是离线缓存里缺的 androidx 依赖（例如 `androidx.annotation:1.9.1`）根本下不下来、
// `flutter build apk` 直接失败。把镜像放前面：镜像命中就用镜像，没有的仍会回落到官方源，
// 对能正常访问 google() 的环境**没有任何副作用**（只是多一次命中镜像的查询）。
val aliyunGoogle = "https://maven.aliyun.com/repository/google"
val aliyunPublic = "https://maven.aliyun.com/repository/public"

allprojects {
    repositories {
        maven(aliyunGoogle)
        maven(aliyunPublic)
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
