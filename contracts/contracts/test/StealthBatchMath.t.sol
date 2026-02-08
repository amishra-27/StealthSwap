// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {StealthBatchMath} from "../src/StealthBatchMath.sol";

contract MathHarness {
    function proRataOutFloor(uint256 windowTotalOut, uint256 userIn, uint256 windowTotalIn)
        external
        pure
        returns (uint256)
    {
        return StealthBatchMath.proRataOutFloor(windowTotalOut, userIn, windowTotalIn);
    }

    function enforceMinOutAtClaim(uint256 userOut, uint128 minOut) external pure {
        StealthBatchMath.enforceMinOutAtClaim(userOut, minOut);
    }

    function getSweepableDust(uint256 windowTotalOut, uint256 claimedOutSum) external pure returns (uint256) {
        return StealthBatchMath.getSweepableDust(windowTotalOut, claimedOutSum);
    }
}

contract StealthBatchMathTest is Test {
    MathHarness internal harness;

    function setUp() public {
        harness = new MathHarness();
    }

    function testProRataSingleUser() public {
        assertEq(harness.proRataOutFloor(1_000, 1_000, 1_000), 1_000);
    }

    function testProRataManyUsersFloorRounding() public {
        uint256 out0 = harness.proRataOutFloor(100, 1, 3);
        uint256 out1 = harness.proRataOutFloor(100, 1, 3);
        uint256 out2 = harness.proRataOutFloor(100, 1, 3);
        uint256 sum = out0 + out1 + out2;

        assertEq(out0, 33);
        assertEq(sum, 99);
        assertEq(harness.getSweepableDust(100, sum), 1);
    }

    function testProRataWhenWindowTotalOutZero() public {
        assertEq(harness.proRataOutFloor(0, 5, 100), 0);
    }

    function testProRataRevertsWhenWindowTotalInZero() public {
        vm.expectRevert(StealthBatchMath.WindowTotalInZero.selector);
        harness.proRataOutFloor(100, 1, 0);
    }

    function testEnforceMinOutPasses() public {
        harness.enforceMinOutAtClaim(10, 10);
    }

    function testEnforceMinOutReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StealthBatchMath.MinOutNotMet.selector, 9, uint128(10)));
        harness.enforceMinOutAtClaim(9, 10);
    }

    function testSweepableDustRevertsIfClaimedOutExceedsTotalOut() public {
        vm.expectRevert(abi.encodeWithSelector(StealthBatchMath.ClaimedOutExceedsTotalOut.selector, 101, 100));
        harness.getSweepableDust(100, 101);
    }
}
