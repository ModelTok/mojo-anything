# The Mojo port of `src/psychrometrics.cpp`.
#
# `exports.mojo` exports each function under the C name the C++ shim gives it
# (`cpp__<namespace>__<name>`), and `cpp/wrapper.cpp` gives C++ callers the original
# signatures. The statements are EnergyPlus's as the facade has them: `build` turns off
# floating-point contraction (`--fp-mode contract=off`) and `record` compiles the facade
# with `-ffp-contract=off`, so each product and each sum is rounded on its own, as g++
# does for x86-64 at `-O1`.


def _max(a: Float64, b: Float64) -> Float64:
    # `std::max` (and ObjexxFCL's `max`): `a < b ? b : a`, so a NaN `a` stays NaN.
    return b if a < b else a


# Port of `EnergyPlus::Psychrometrics::PsyRhoAirFnPbTdbW` (`src/psychrometrics.cpp:24`).
# Density of air {kg/m3}: ideal gas law, gas constant for air 287 J/(kg K), air/water
# molecular mass ratio 28.9645/18.01534.
def PsyRhoAirFnPbTdbW(pb: Float64, tdb: Float64, dw: Float64) -> Float64:
    var kelvin: Float64 = 273.15
    return pb / (287.0 * (tdb + kelvin) * (1.0 + 1.6077687 * _max(dw, 1.0e-5)))


# Port of `EnergyPlus::Psychrometrics::PsyHFnTdbW` (`src/psychrometrics.cpp:41`).
# Enthalpy {J/kg}: ASHRAE Handbook of Fundamentals, 1972, p. 100, eqn. 32.
def PsyHFnTdbW(TDB: Float64, dW: Float64) -> Float64:
    return 1.00484e3 * TDB + _max(dW, 1.0e-5) * (2.50094e6 + 1.85895e3 * TDB)


# Port of `EnergyPlus::Psychrometrics::PsyTdbFnHW` (`src/psychrometrics.cpp:56`).
# Dry-bulb temperature {C}: `PsyHFnTdbW` inverted.
def PsyTdbFnHW(H: Float64, dW: Float64) -> Float64:
    var W = _max(dW, 1.0e-5)
    return (H - 2.50094e6 * W) / (1.00484e3 + 1.85895e3 * W)
