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
