//! Supply Android's trust store and class loader before the SDK makes HTTPS requests.
use jni::{
    EnvUnowned,
    errors::ThrowRuntimeExAndDefault,
    jni_mangle,
    objects::{JClass, JObject},
};

#[jni_mangle("com.flutter_rust_bridge.river_matrix.RiverMatrixPlugin")]
pub fn initialize<'caller>(
    mut env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    context: JObject<'caller>,
) {
    env.with_env(|env| rustls_platform_verifier::android::init_with_env(env, context))
        .resolve::<ThrowRuntimeExAndDefault>();
}
