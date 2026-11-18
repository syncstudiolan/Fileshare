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
                connectTimeout=15000
                readTimeout=30000
            }.getInputStream().use { input ->
                temporary.outputStream().use { input.copyTo(it) }
            }
            check(temporary.length()==4757043L) {
                "DocAligner model size verification failed"
            }
            // Match the upstream Git blob identity, not just a size.
            val digest=java.security.MessageDigest.getInstance("SHA-1")
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
