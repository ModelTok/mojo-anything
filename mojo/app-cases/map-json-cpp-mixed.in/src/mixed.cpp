#include "mixed.hpp"

#include <exception>
#include <stdexcept>

namespace mixed {

struct bad_input : std::invalid_argument {
    using std::invalid_argument::invalid_argument;
};

struct odd : std::exception {
    const char *what() const noexcept override
    {
        return "odd number";
    }
};

long sum_long(const std::vector<long> &xs)
{
    long sum = 0;
    for (long x : xs)
        sum += x;
    return sum;
}

std::int64_t sum_int64(const std::vector<std::int64_t> &xs)
{
    std::int64_t sum = 0;
    for (std::int64_t x : xs)
        sum += x;
    return sum;
}

std::vector<long> twice_long(const std::vector<long> &xs)
{
    std::vector<long> out;
    for (long x : xs)
        out.push_back(2 * x);
    return out;
}

std::vector<std::int64_t> twice_int64(const std::vector<std::int64_t> &xs)
{
    std::vector<std::int64_t> out;
    for (std::int64_t x : xs)
        out.push_back(2 * x);
    return out;
}

int check(int x)
{
    if (x < 0)
        throw bad_input("negative input");
    return x;
}

int even(int x)
{
    if (x % 2 != 0)
        throw odd();
    return x;
}

double fused(double a, double b, double c)
{
    return a * b + c;
}

std::size_t length(const std::string &s)
{
    return s.size();
}

}  // namespace mixed
