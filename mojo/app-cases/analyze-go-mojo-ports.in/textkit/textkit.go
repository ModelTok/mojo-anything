// Package textkit is a fixture for Go units ported to Mojo (`tests/go_mojo.rs`).
package textkit

import (
	"errors"
	"strings"
)

// Echo returns s as it is.
func Echo(s string) string { return s }

// Repeat repeats s n times; n must be 0 to 8.
func Repeat(s string, n int) (string, error) {
	if n < 0 || n > 8 {
		return "", errors.New("bad count")
	}
	return strings.Repeat(s, n), nil
}

// Count is the number of bytes in s.
func Count(s string) int { return len(s) }

// Add adds two unsigned numbers, wrapping.
func Add(a uint64, b uint64) uint64 { return a + b }

// Split cuts s at each comma.
func Split(s string) []string { return strings.Split(s, ",") }

// Half is x divided by two.
func Half(x float64) float64 { return x / 2 }

// IsNeg says whether x is below zero.
func IsNeg(x float64) bool { return x < 0 }

// Pair returns s with its length.
func Pair(s string) (string, int) { return s, len(s) }
