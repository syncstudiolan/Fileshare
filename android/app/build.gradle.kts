import java.security.MessageDigest
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20"
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.20"
}

android {
    namespace = "com.example.file_share"
    compileSdk = 36
    compileSdkExtension = 19
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.example.file_share"
        minSdk = maxOf(24, flutter.minSdkVersion)
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // A single ARM64 test package; do not bundle unused emulators/32-bit native code.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }
    packaging {
        jniLibs {
            excludes += setOf("lib/x86_64/**", "lib/armeabi-v7a/**", "lib/x86/**")
        }
    }
    // A stable release key comes from GitHub Actions encrypted secrets.
    // Fail rather than silently ship a debug-signed production app.
    signingConfigs {
        create("production") {
            storeFile = file(System.getenv("FILE_SHARE_KEYSTORE_FILE")
                ?: "missing-production-release-key.jks")
            storePassword = System.getenv("FILE_SHARE_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("FILE_SHARE_KEY_ALIAS")
            keyPassword = System.getenv("FILE_SHARE_KEY_PASSWORD")
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("production")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        optIn.addAll(
            "androidx.compose.material.ExperimentalMaterialApi",
            "androidx.compose.material3.ExperimentalMaterial3Api",
            "androidx.compose.foundation.ExperimentalFoundationApi",
            "androidx.compose.animation.ExperimentalSharedTransitionApi"
        )
    }
}
flutter { source = "../.." }

dependencies {
    // Upstream sammyZi/pdf-tools Compose/CameraX/viewer dependencies (Android only).
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.navigation:navigation-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    implementation("dev.chrisbanes.haze:haze:1.7.0")
    implementation("androidx.camera:camera-core:1.6.0")
    implementation("androidx.camera:camera-camera2:1.6.0")
    implementation("androidx.camera:camera-lifecycle:1.6.0")
    implementation("androidx.camera:camera-view:1.6.0")
    implementation("com.google.zxing:core:3.5.3")
    implementation("androidx.pdf:pdf-compose:1.0.0-alpha18")
    implementation("androidx.pdf:pdf-document-service:1.0.0-alpha18")
    implementation("com.google.android.gms:play-services-auth:22.0.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    // Android-only PDF processing; not included in Windows/macOS bundles.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // DSC revocation transport: enforce public DNS results on the actual socket.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("org.opencv:opencv:4.12.0")
}

// The DocAligner asset is committed to THIS File Share repository.
// Android builds must never fetch model binaries from another developer's repo.
val modelPath = file("src/main/assets/docaligner_lc100.onnx")
val verifyBundledDocAlignerModel = tasks.register("verifyBundledDocAlignerModel") {
    inputs.file(modelPath)
    doLast {
        check(modelPath.isFile && modelPath.length() == 4757043L) {
            "The bundled DocAligner model is missing or has an invalid length"
        }
        val digest = MessageDigest.getInstance("SHA-1")
        digest.update(("blob " + modelPath.length()).toByteArray())
        digest.update(byteArrayOf(0))
        modelPath.inputStream().use { input ->
            val bytes = ByteArray(65536)
            while (true) {
                val count = input.read(bytes)
                if (count < 0) break
                digest.update(bytes, 0, count)
            }
        }
        val sha = digest.digest().joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
        check(sha == "0215be79853f05ce3f389e5a554604e61249c3b0") {
            "Bundled DocAligner model integrity check failed"
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyBundledDocAlignerModel) }

// Explicit local NDK integration for the DSC draft. No workflow is triggered.
// Enable with -PfileshareDscRust=true after installing Rust/cargo-ndk.
val includeDscRust = providers.gradleProperty("fileshareDscRust").map { it == "true" }.orElse(false)
if (includeDscRust.get()) {
    val dscRustDir = layout.projectDirectory.dir("../dsc-rust")
    // AGP 9 rejects Provider objects in the legacy SourceSet API. Resolve
    // the Flutter-redirected build directory to a File, and wire dependencies explicitly.
    val generatedDsc = layout.buildDirectory.dir("generated/dscRust/jniLibs").get().asFile
    val buildDscRust = tasks.register<Exec>("buildDscRust") {
        workingDir(dscRustDir.asFile)
        commandLine("bash", "build-android.sh", generatedDsc.absolutePath)
        inputs.files(fileTree(dscRustDir.asFile) { include("Cargo.toml", "Cargo.lock", "src/**", "build-android.sh", ".cargo/**") })
        inputs.files(fileTree(rootProject.projectDir.parentFile.resolve("third_party/pdfcraft-dsc-reference/crates/sign")) { include("Cargo.toml", "src/**") })
        outputs.dir(generatedDsc)
    }
    android.sourceSets.getByName("main").jniLibs.srcDir(generatedDsc)
    tasks.named("preBuild") { dependsOn(buildDscRust) }
    tasks.matching { it.name.startsWith("merge") &&
        (it.name.endsWith("JniLibFolders") || it.name.endsWith("NativeLibs"))
    }.configureEach { dependsOn(buildDscRust) }
}
