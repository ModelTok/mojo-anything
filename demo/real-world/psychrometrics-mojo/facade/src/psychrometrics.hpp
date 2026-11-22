// EnergyPlus, Copyright (c) 1996-present, The Board of Trustees of the University of Illinois,
// The Regents of the University of California, through Lawrence Berkeley National Laboratory
// (subject to receipt of any required approvals from the U.S. Dept. of Energy), Oak Ridge
// National Laboratory, managed by UT-Battelle, Alliance for Energy Innovation, LLC, and other
// contributors. All rights reserved.
//
// The full notice and conditions are in ../../LICENSE (EnergyPlus's LICENSE.txt).
//
// A free-function facade over three routines of EnergyPlus version 27.1.0 (development, commit
// 7ab256b5adc91032ea9e9856682ce119583db617), src/EnergyPlus/Psychrometrics.hh: there they are
// `constexpr` or `inline`, so no object file defines them for a shim to call. The bodies in
// psychrometrics.cpp are copied unchanged; `Real64` and `Constant::Kelvin` are EnergyPlus's
// definitions (Data/BaseData.hh, DataGlobalConstants.hh), and `max` is `std::max`, which for
// two doubles is ObjexxFCL's `max` (`a < b ? b : a`).

#pragma once

namespace EnergyPlus {

using Real64 = double;

namespace Constant {
    Real64 constexpr Kelvin = 273.15; // Conversion factor for C to K and K to C
} // namespace Constant

namespace Psychrometrics {

    // Density of air {kg/m3} from barometric pressure {Pa}, dry-bulb temperature {C} and humidity
    // ratio {kgWater/kgDryAir}.
    Real64 PsyRhoAirFnPbTdbW(Real64 const pb, Real64 const tdb, Real64 const dw);

    // Enthalpy {J/kg} from dry-bulb temperature {C} and humidity ratio.
    Real64 PsyHFnTdbW(Real64 const TDB, Real64 const dW);

    // Dry-bulb temperature {C} from enthalpy {J/kg} and humidity ratio.
    Real64 PsyTdbFnHW(Real64 const H, Real64 const dW);

} // namespace Psychrometrics

} // namespace EnergyPlus
