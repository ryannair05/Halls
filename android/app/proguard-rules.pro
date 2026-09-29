# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Keep data classes used by Moshi for JSON serialization/deserialization.
# This prevents ProGuard/R8 from removing or renaming classes and their fields,
# which would break reflection-based adapters.
-keep class com.ryannair05.meetandeat.cata.** { *; }

# Dining uses Moshi reflection for Penn State's hours response and its disk
# caches. These classes must retain their constructors, fields, and Kotlin
# metadata in minified release builds.
-keep class com.ryannair05.meetandeat.dining.PennStateHoursParser$RawRecord { *; }
-keep class com.ryannair05.meetandeat.dining.PennStateHoursParser$RawHour { *; }
-keep class com.ryannair05.meetandeat.dining.PennStateHoursStore$Cache { *; }
-keep class com.ryannair05.meetandeat.dining.DayHours { *; }
-keep class com.ryannair05.meetandeat.dining.DiningHoursInterval { *; }
-keep class com.ryannair05.meetandeat.dining.DiningMealPeriod { *; }
-keep class com.ryannair05.meetandeat.dining.DiningMenuItem { *; }
-keep class com.ryannair05.meetandeat.dining.DiningMenuSection { *; }
-keep class com.ryannair05.meetandeat.dining.MenuDaySnapshot { *; }
-keep class com.ryannair05.meetandeat.dining.MenuItemDetail { *; }
-keep class com.ryannair05.meetandeat.dining.NutritionFact { *; }

# Keep the Retrofit API interface and its methods.
-keep interface com.ryannair05.meetandeat.cata.CataApi { *; }

# Keep other necessary Kotlin metadata
-keepattributes Signature
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.reflect.jvm.internal.**

# The durable, versioned meal journal uses Moshi reflection too. Keep the
# complete nested record graph; its item/detail types are covered above.
-keep class com.ryannair05.meetandeat.journal.JournalFile { *; }
-keep class com.ryannair05.meetandeat.journal.JournalMeal { *; }
-keep class com.ryannair05.meetandeat.journal.JournalItem { *; }
-keep class com.ryannair05.meetandeat.journal.PlateDraft { *; }
-keep class com.ryannair05.meetandeat.journal.PlateDraftFile { *; }
