# Used by JNI; R8 cannot see the calls from Rust.
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }
-keep class com.flutter_rust_bridge.river_matrix.RiverMatrixPlugin { *; }
