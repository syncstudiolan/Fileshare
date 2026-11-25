# The Flutter release build uses R8. Certain Google ML Kit segmentation
# registrars are loaded reflectively by Firebase component discovery. Without
# their public no-argument constructors R8 can make a release-only native
# NullPointerException while debug builds still work.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
  public <init>();
}
-keep class com.google.mlkit.vision.segmentation.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_segmentation.** { *; }
-keepclassmembers class * implements com.google.firebase.components.ComponentRegistrar {
  public <init>();
}

# Android-only advanced PDF scanning and local OCR.
# OpenCV's Java Native Interface expects stable Java method signatures.
-keep class org.opencv.** { *; }
-keep class com.google.mlkit.vision.text.** { *; }

# PDFBox-Android's JPEG-2000 (JPX) codec is OPTIONAL, not shipped by default.
# Its original JP2Android artifact is JCenter-only; do not add an unavailable
# dependency or suppress unrelated R8 problems. PDFBox logs an unsupported-JPX
# warning when such an image is encountered. Other PDF features remain intact.
-dontwarn com.gemalto.jp2.JP2Decoder
-dontwarn com.gemalto.jp2.JP2Encoder

# JNI entry point name must remain stable.
-keep class com.sammyi57.pdftools.DscRustBridge { *; }

# BC registers JCA algorithm implementations by class-name strings, which
# are not ordinary static call sites. Preserve provider mappings and SPI
# implementation names/constructors in the minified signed APK.
-keep class org.bouncycastle.jce.provider.BouncyCastleProvider { *; }
-keep class org.bouncycastle.jcajce.provider.**$Mappings { *; }
-keep class org.bouncycastle.jcajce.provider.digest.** { *; }
-keep class org.bouncycastle.jcajce.provider.asymmetric.rsa.** { *; }
-keep class org.bouncycastle.jcajce.provider.asymmetric.ec.** { *; }
-keep class org.bouncycastle.jcajce.provider.asymmetric.dsa.** { *; }
-keep class org.bouncycastle.jcajce.provider.asymmetric.edec.** { *; }
-keep class org.bouncycastle.jcajce.provider.asymmetric.x509.CertificateFactory { *; }
-keep class org.bouncycastle.jcajce.util.** { *; }
