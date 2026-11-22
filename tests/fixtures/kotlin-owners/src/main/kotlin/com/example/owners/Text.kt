package com.example.owners

/** Spaces become dashes. A top-level function: its JVM owner is `TextKt`. */
fun slug(s: String): String = s.replace(' ', '-')

class Units {
    companion object {
        /** A whole number of units. `@JvmStatic` in a companion object: its owner is `Units`. */
        @JvmStatic
        fun parse(s: String): Long = s.trim().toLong()
    }
}
