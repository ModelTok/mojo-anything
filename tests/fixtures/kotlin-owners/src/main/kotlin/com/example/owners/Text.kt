package com.example.owners

/** Spaces become dashes. A top-level function: its JVM owner is `TextKt`. */
fun slug(s: String): String = s.replace(' ', '-')

/**
 * Kotlin gives the class an implicit public constructor: the wrapper replaces the whole class,
 * so it keeps that constructor for callers that write `Units()`.
 */
class Units {
    companion object {
        /** A whole number of units. `@JvmStatic` in a companion object: its owner is `Units`. */
        @JvmStatic
        fun parse(s: String): Long = s.trim().toLong()
    }
}

/** A class holding an object: the object's JVM class is `Shapes$Sign`, not `Sign`. */
class Shapes {
    object Sign {
        /** -1, 0 or 1. `@JvmStatic` in a nested object: its owner is `Shapes$Sign`. */
        @JvmStatic
        fun sign(n: Long): Long = if (n < 0) -1 else if (n > 0) 1 else 0
    }
}
