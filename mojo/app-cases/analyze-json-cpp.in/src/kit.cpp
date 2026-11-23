#include "kit.hpp"

#include <cctype>
#include <cmath>
#include <stdexcept>

namespace kit {

int add(int a, int b)
{
    return static_cast<int>(static_cast<unsigned>(a) + static_cast<unsigned>(b));
}

std::int64_t wide(std::int64_t a, std::int64_t b)
{
    return static_cast<std::int64_t>(static_cast<std::uint64_t>(a) * static_cast<std::uint64_t>(b));
}

unsigned wrap(unsigned a, unsigned b)
{
    return a - b;
}

std::size_t count_bytes(const std::string &s)
{
    return s.size();
}

float half(float x)
{
    return x / 2;
}

double mean(const std::vector<double> &xs)
{
    double sum = 0;
    for (double x : xs)
        sum += x;
    return xs.empty() ? 0 : sum / static_cast<double>(xs.size());
}

std::vector<int> evens(std::vector<int> xs)
{
    std::vector<int> out;
    for (int x : xs)
        if (x % 2 == 0)
            out.push_back(x);
    return out;
}

std::vector<double> scale(const std::vector<double> &xs, double k)
{
    std::vector<double> out;
    for (double x : xs)
        out.push_back(x * k);
    return out;
}

bool is_upper(const std::string &s)
{
    for (unsigned char c : s)
        if (std::islower(c))
            return false;
    return !s.empty();
}

std::string shout(std::string s)
{
    for (char &c : s)
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return s + "!";
}

double checked_sqrt(double x)
{
    if (x < 0)
        throw std::domain_error("negative input");
    return std::sqrt(x);
}

void touch() {}

namespace text {

std::string join(const std::vector<std::int64_t> &xs, const std::string &sep)
{
    std::string out;
    for (std::size_t i = 0; i < xs.size(); i++) {
        if (i > 0)
            out += sep;
        out += std::to_string(xs[i]);
    }
    return out;
}

}  // namespace text

}  // namespace kit
