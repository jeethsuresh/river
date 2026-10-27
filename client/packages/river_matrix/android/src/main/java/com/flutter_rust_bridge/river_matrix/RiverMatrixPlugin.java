package com.flutter_rust_bridge.river_matrix;

import android.content.Context;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

/** Initializes the platform certificate verifier before Dart starts using Matrix. */
public final class RiverMatrixPlugin implements FlutterPlugin {
    private static native void initialize(Context context);

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        System.loadLibrary("river_matrix_core");
        // Rust retains the application context, never an Activity or Flutter engine.
        initialize(binding.getApplicationContext());
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {}
}
