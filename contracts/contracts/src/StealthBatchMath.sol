// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
Docs references:
- Uniswap v4 Hooks concepts (pool-specific hooks):
  https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 AsyncSwap/custom accounting (batched/deferred execution context):
  https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
*/

import {FullMath} from "../lib/v4-core/src/libraries/FullMath.sol";

/// @notice Math helpers for pro-rata claims in batched windows.
/// @dev Rounding policy is floor. Any remainder becomes sweepable dust.
library StealthBatchMath {
    error WindowTotalInZero();
    error MinOutNotMet(uint256 userOut, uint128 minOut);
    error ClaimedOutExceedsTotalOut(uint256 claimedOutSum, uint256 windowTotalOut);

    /// @notice Floor-rounded pro-rata output: floor(windowTotalOut * userIn / windowTotalIn).
    function proRataOutFloor(uint256 windowTotalOut, uint256 userIn, uint256 windowTotalIn)
        internal
        pure
        returns (uint256 userOut)
    {
        if (windowTotalIn == 0) revert WindowTotalInZero();
        userOut = FullMath.mulDiv(windowTotalOut, userIn, windowTotalIn);
    }

    /// @notice Enforces minOut at claim time.
    /// @dev Tradeoff: reverting at claim-time is simpler and deterministic; deferred failure state adds storage complexity.
    function enforceMinOutAtClaim(uint256 userOut, uint128 minOut) internal pure {
        if (userOut < minOut) revert MinOutNotMet(userOut, minOut);
    }

    /// @notice Returns remaining dust after floor-rounded claims.
    function getSweepableDust(uint256 windowTotalOut, uint256 claimedOutSum) internal pure returns (uint256 dustOut) {
        if (claimedOutSum > windowTotalOut) revert ClaimedOutExceedsTotalOut(claimedOutSum, windowTotalOut);
        dustOut = windowTotalOut - claimedOutSum;
    }
}
