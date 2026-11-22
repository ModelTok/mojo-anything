// Everything outside the C++ subset: each export here is refused with a reason.
#include <map>
#include <string>
#include <vector>

struct EnergyPlusData {
    double timestep = 0.25;
};

class Counter {
public:
    int bump(int n)
    {
        total += n;
        return total;
    }
    int total = 0;
};

struct Meter {
    double read() const;
};

double Meter::read() const
{
    return 1.0;
}

template <typename T>
T twice(T x)
{
    return x + x;
}

int pick(int x)
{
    return x;
}

int pick(double x)
{
    return static_cast<int>(x);
}

double step(EnergyPlusData &state, double dt)
{
    return state.timestep * dt;
}

double peek(const EnergyPlusData *state)
{
    return state->timestep;
}

void bump(int &n)
{
    n++;
}

std::string take(std::string &&s)
{
    return s;
}

const char *name()
{
    return "refused";
}

inline int fast(int x)
{
    return x;
}

constexpr int square(int x)
{
    return x * x;
}

int sizes(const std::map<std::string, int> &m)
{
    return static_cast<int>(m.size());
}

int flags(const std::vector<bool> &v)
{
    return static_cast<int>(v.size());
}

int widen(long double x)
{
    return static_cast<int>(x);
}

int total(int n, ...)
{
    return n;
}

static int hidden(int x)
{
    return x;
}

namespace {
int anonymous(int x)
{
    return hidden(x);
}
}  // namespace

int kept(int x)
{
    return anonymous(x);
}
