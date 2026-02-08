// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {StealthBatchWindow} from "../src/StealthBatchWindow.sol";

contract WindowHarness is StealthBatchWindow {
    constructor(uint64 _startBlock, uint64 _blocksPerWindow) StealthBatchWindow(_startBlock, _blocksPerWindow) {}
}

contract StealthBatchWindowTest is Test {
    WindowHarness internal window;

    function setUp() public {
        window = new WindowHarness(100, 10);
    }

    function testGetWindowId() public {
        assertEq(window.getWindowId(100), 0);
        assertEq(window.getWindowId(109), 0);
        assertEq(window.getWindowId(110), 1);
        assertEq(window.getWindowId(149), 4);
    }

    function testGetWindowStart() public {
        assertEq(window.getWindowStart(0), 100);
        assertEq(window.getWindowStart(1), 110);
        assertEq(window.getWindowStart(4), 140);
    }

    function testGetWindowEndExclusive() public {
        assertEq(window.getWindowEnd(0), 110);
        assertEq(window.getWindowEnd(1), 120);
        assertEq(window.getWindowEnd(4), 150);
    }

    function testRevertWhenBeforeStartBlock() public {
        vm.expectRevert(abi.encodeWithSelector(StealthBatchWindow.WindowNotStarted.selector, 99, 100));
        window.getWindowId(99);
    }

    function testRevertWhenBlocksPerWindowZero() public {
        vm.expectRevert(StealthBatchWindow.BlocksPerWindowZero.selector);
        new WindowHarness(100, 0);
    }
}
