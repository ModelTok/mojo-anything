// Cases the final review of C++ support found: two spellings of one vector type, exceptions
// derived from standard ones, a product and a sum, and strings that are not UTF-8.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace mixed {

long sum_long(const std::vector<long> &xs);
std::int64_t sum_int64(const std::vector<std::int64_t> &xs);
std::vector<long> twice_long(const std::vector<long> &xs);
std::vector<std::int64_t> twice_int64(const std::vector<std::int64_t> &xs);
// Throws `bad_input`, a `std::invalid_argument`, for a negative number.
int check(int x);
// Throws `odd`, a `std::exception` with its own `what()`, for an odd number.
int even(int x);
double fused(double a, double b, double c);
std::size_t length(const std::string &s);

}  // namespace mixed
