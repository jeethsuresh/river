#![recursion_limit = "256"]

#[cfg(target_os = "android")]
mod android;
pub mod api;
mod core;
mod frb_generated;
