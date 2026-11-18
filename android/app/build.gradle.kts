plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.file_share"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.example.file_share"
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}
flutter { source = "../.." }

dependencies {
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
            java.net.URL(
                "https://raw.githubusercontent.com/sammyZi/pdf-tools/6a48d60ccbbaca4dd18840b9d85f00d44b51f311/app/src/main/assets/docaligner_lc100.onnx"
            ).openConnection().apply {
                connectTimeout=25000
                readTimeout=60000
            }.getInputStream().use { input ->
                temporary.outputStream().use { input.copyTo(it) }
            }
            check(temporary.length()==4757043L) {
                "DocAligner model size verification failed"
            }
            if(modelPath.exists())modelPath.delete()
            check(temporary.renameTo(modelPath)) {
                "Could not install DocAligner model in Android assets"
            }
        }finally{if(temporary.exists())temporary.delete()}
    }
}
tasks.named("preBuild") { dependsOn(syncDocAlignerModel) }
