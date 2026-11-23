// EnergyPlus, Copyright (c) 1996-present, The Board of Trustees of the University of Illinois,
// The Regents of the University of California, through Lawrence Berkeley National Laboratory
// (subject to receipt of any required approvals from the U.S. Dept. of Energy), Oak Ridge
// National Laboratory, managed by UT-Battelle, Alliance for Energy Innovation, LLC, and other
// contributors. All rights reserved.
//
// The full notice and conditions are in ../../LICENSE (EnergyPlus's LICENSE.txt).
//
// The statements below are copied unchanged from EnergyPlus version 27.1.0 (development, commit
// 7ab256b), src/EnergyPlus/Psychrometrics.hh, lines 548-573, 647-665 and 742-761, with their
// comments shortened (`scripts/verify.sh` checks each statement against that file); see
// psychrometrics.hpp for what the facade changes around them.

#include "psychrometrics.hpp"

#include <algorithm>

namespace EnergyPlus {

namespace Psychrometrics {

    using std::max;

    Real64 PsyRhoAirFnPbTdbW(Real64 const pb,  // barometric pressure (Pascals)
                             Real64 const tdb, // dry bulb temperature (Celsius)
                             Real64 const dw   // humidity ratio (kgWater/kgDryAir)
    )
    {
        // FUNCTION INFORMATION:
        //       AUTHOR         G. S. Wright
        //       DATE WRITTEN   June 2, 1994

        // METHODOLOGY EMPLOYED:
        // ideal gas law
        //    universal gas const for air 287 J/(kg K)
        //    air/water molecular mass ratio 28.9645/18.01534

        return (pb / (287.0 * (tdb + Constant::Kelvin) * (1.0 + 1.6077687 * std::max(dw, 1.0e-5))));
    }

    Real64 PsyHFnTdbW(Real64 const TDB, // dry-bulb temperature {C}
                      Real64 const dW   // humidity ratio
    )
    {
        // FUNCTION INFORMATION:
        //       AUTHOR         George Shih
        //       DATE WRITTEN   May 1976

        // REFERENCES:
        // ASHRAE HANDBOOK OF FUNDAMENTALS, 1972, P100, EQN 32

        // calculate enthalpy
        return 1.00484e3 * TDB + max(dW, 1.0e-5) * (2.50094e6 + 1.85895e3 * TDB); // enthalpy {J/kg}
    }

    Real64 PsyTdbFnHW(Real64 const H, // enthalpy {J/kg}
                      Real64 const dW // humidity ratio
    )
    {
        // FUNCTION INFORMATION:
        //       AUTHOR         J. C. VanderZee
        //       DATE WRITTEN   Feb. 1994

        // REFERENCES:
        // ASHRAE HANDBOOK OF FUNDAMENTALS, 1972, P100, EQN 32
        //   by inverting function PsyHFnTdbW

        Real64 const W(max(dW, 1.0e-5));                          // humidity ratio
        return (H - 2.50094e6 * W) / (1.00484e3 + 1.85895e3 * W); // result=> dry-bulb temperature {C}
    }

} // namespace Psychrometrics

} // namespace EnergyPlus
