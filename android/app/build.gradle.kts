plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ws_scrcpy_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.ws_scrcpy_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
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

    packaging {
        jniLibs {
            // 不剥离 .so 里的调试符号。**这不是风格偏好，是 CI 能不能构建的前提**：
            //   · 本项目没有原生代码，.so 全是 Flutter 引擎的（上游发布时已经 strip 过），
            //     再 strip 一次的收益≈0；
            //   · 而 AGP 的 `stripReleaseDebugSymbols` 固定调用 **NDK 里的 llvm-strip**
            //     （`ndk/<版本>/toolchains/llvm/prebuilt/<host>/bin/llvm-strip`）；
            //   · 我们的 CI 里只有 NDK **标记文件**、没有真 NDK
            //     （为什么要标记见 docs/ci.md 第八个坑；真 NDK 约 1GB 且在连不通的 dl.google.com 上），
            //     于是那个任务会以 "A problem occurred starting process ... llvm-strip" 直接挂。
            // 列成 **/*.so 后该任务没有可处理的目标 → 不再调用 llvm-strip。
            // 代价：APK 里保留引擎库自带的符号（引擎库本来就是 stripped 的，实测体积无感）。
            keepDebugSymbols += "**/*.so"
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
