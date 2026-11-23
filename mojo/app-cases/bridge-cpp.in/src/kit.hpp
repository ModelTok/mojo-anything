// Every type of the C++ subset mojo-anything bridges, as free functions in namespaces.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace kit {

int add(int a, int b);
std::int64_t wide(std::int64_t a, std::int64_t b);
unsigned wrap(unsigned a, unsigned b);
std::size_t count_bytes(const std::string &s);
float half(float x);
double mean(const std::vector<double> &xs);
std::vector<int> evens(std::vector<int> xs);
std::vector<double> scale(const std::vector<double> &xs, double k);
bool is_upper(const std::string &s);
std::string shout(std::string s);
// Throws std::domain_error for a negative number.
double checked_sqrt(double x);
void touch();

namespace text {
std::string join(const std::vector<std::int64_t> &xs, const std::string &sep);
}

}  // namespace kit
