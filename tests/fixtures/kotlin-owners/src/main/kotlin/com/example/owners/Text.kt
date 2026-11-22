package com.example.owners

/** Spaces become dashes. A top-level function: its JVM owner is `TextKt`. */
fun slug(s: String): String = s.replace(' ', '-')

/**
 * The constructor is private: the wrapper replaces the whole class and has no instances, so a
 * public constructor would be a member it drops (and `gate`'s `java api` would fail).
 */
class Units private constructor() {
    companion object {
        /** A whole number of units. `@JvmStatic` in a companion object: its owner is `Units`. */
        @JvmStatic
        fun parse(s: String): Long = s.trim().toLong()
    }
}
