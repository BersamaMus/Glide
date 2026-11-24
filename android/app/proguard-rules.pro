# Release builds are shrunk and renamed by R8. ML Kit's subject segmentation
# (the editor's Background, stickers, 3D) runs in a module Google Play
# services downloads, which talks to these classes by their own names, and
# ML Kit wires its parts together at start-up by class: renamed or dropped,
# finding a subject fails ("Attempt to read from field ... on a null object
# reference"), or, kept only in part, the app won't start ("Unsatisfied
# dependency for component"). So all of ML Kit is kept as it is.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
