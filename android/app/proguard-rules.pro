# GitVault ProGuard/R8 rules for optimized release builds

# ============ OPTIMIZATION SETTINGS ============
-optimizationpasses 5
-allowaccessmodification
-mergeinterfacesaggressively

# Enable aggressive optimization (R8 specific)
-repackageclasses 'com.giofahreza.gitvault'

# ============ KEEP RULES - Minimal ============
# Keep our main application classes only
-keep class com.giofahreza.gitvault.MainActivity { public *; }
-keep class com.giofahreza.gitvault.ime.** { *; }
-keep class com.giofahreza.gitvault.GitVaultAutofillService { *; }

# Keep data classes for Gson serialization
-keep class com.giofahreza.gitvault.ime.CredentialMetadata { *; }

# Keep Flutter (essential)
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }

# Keep AndroidX critical classes
-keep class androidx.biometric.** { *; }
-keep class androidx.recyclerview.** { *; }
-keep class androidx.appcompat.** { *; }
-keep class androidx.core.** { *; }

# Keep Gson (reflection required)
-keep class com.google.gson.** { *; }
-keep interface com.google.gson.** { *; }

# Keep classes required by reflection
-keepclasseswithmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# ============ DEBUG REMOVAL ============
# Remove all Log calls (not debug symbols)
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}

# Remove System.out calls
-assumenosideeffects class java.io.PrintStream {
    public *** println(...);
    public *** print(...);
}

# ============ ATTRIBUTE HANDLING ============
# Keep line numbers for crash reporting
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ============ COMPATIBILITY ============
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.gms.**
-dontwarn com.google.android.material.**

# ============ NATIVE METHODS ============
# Keep JNI methods
-keepclasseswithmembernames class * {
    native <methods>;
}
