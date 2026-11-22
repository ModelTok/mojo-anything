//! Kotlin's generated artifacts are Java artifacts.
//!
//! A Kotlin top-level function compiles to a static method on `<File>Kt`, and `@JvmStatic`
//! in an `object` or a `companion object` compiles to a static method on that class. Java
//! source can call both, so a Kotlin unit ported to Mojo gets the Java classes a Java unit
//! gets: the wrappers over the Foreign Function & Memory API, the native class, the codec, the
//! error mapping and the reflection driver. Keeping one generator keeps both languages in step.

pub use crate::codegen_java::{DRIVER_JAVA, ERROR_JAVA, JSON_JAVA, targets};
pub use crate::codegen_mojo_jvm::{native_class_ffm, support_files, wrappers_ffm};
