import java.net.URL
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
    buildTypes {
        getByName("release") {
            // TESTING ONLY. The prior CI release was unsigned and could not install.
            // Use a separate application id to avoid signature conflicts/data loss
            // with the user's existing File Share installation.
            signingConfig = signingConfigs.getByName("debug")
            applicationIdSuffix = ".testing"
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
    // Android-only PDF processing; not included in Windows/macOS bundles.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("org.opencv:opencv:4.12.0")
}

// Pinned Apache-2.0 DocAligner LC100 model from the reviewed upstream.
// Downloaded ONLY during an Android build. No workflow is triggered by edits.
val modelPath=file("src/main/assets/docaligner_lc100.onnx")
val syncDocAlignerModel=tasks.register("syncDocAlignerModel") {
    outputs.file(modelPath)
    doLast {
        if(modelPath.exists() && modelPath.length()==4757043L)return@doLast
        modelPath.parentFile.mkdirs()
        val temporary=File(modelPath.absolutePath+".download")
        try {
            URL(
                "https://raw.githubusercontent.com/sammyZi/pdf-tools/6a48d60ccbbaca4dd18840b9d85f00d44b51f311/app/src/main/assets/docaligner_lc100.onnx"
            ).openConnection().apply {
                connectTimeout=15000
                readTimeout=30000
            }.getInputStream().use { input ->
                temporary.outputStream().use { input.copyTo(it) }
            }
            check(temporary.length()==4757043L) {
                "DocAligner model size verification failed"
            }
            // Match the upstream Git blob identity, not just a size.
            val digest=MessageDigest.getInstance("SHA-1")
            digest.update(("blob "+temporary.length()).toByteArray())
            digest.update(byteArrayOf(0))
            temporary.inputStream().use { file ->
                val bytes=ByteArray(65536)
                while(true){
                    val count=file.read(bytes)
                    if(count<0)break
                    digest.update(bytes,0,count)
                }
            }
            val gitSha=digest.digest().joinToString("") {
                "%02x".format(it.toInt() and 0xff)
            }
            check(gitSha=="0215be79853f05ce3f389e5a554604e61249c3b0") {
                "Pinned DocAligner asset failed source integrity check"
            }
            if(modelPath.exists())modelPath.delete()
            check(temporary.renameTo(modelPath)){"Cannot install DocAligner model"}
        }catch(e:java.io.IOException) {
            logger.warn("DocAligner optional download unavailable; OpenCV contour detection remains active",e)
            if(modelPath.exists() && modelPath.length()!=4757043L)modelPath.delete()
        }finally{if(temporary.exists())temporary.delete()}
    }
}
tasks.named("preBuild") { dependsOn(syncDocAlignerModel) }
