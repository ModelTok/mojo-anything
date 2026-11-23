package com.example.members;

/** A class with public members the bridge does not port: a constant and a generic method. */
public final class Limits {
    private Limits() {}

    /** A constant: part of the class's public API, which the wrapper replaces. */
    public static final int MAX = 3;

    public static int twice(int value) {
        return value * 2;
    }

    /** Generic: the bridge leaves it out of the port, but it is still a member of the class. */
    public static <T> T id(T value) {
        return value;
    }
}
