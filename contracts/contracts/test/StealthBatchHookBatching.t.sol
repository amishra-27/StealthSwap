// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
Test context:
- Uniswap v4 hooks are pool-specific contracts invoked by PoolManager lifecycle callbacks.
- AsyncSwap/custom accounting enables deferred swap settlement, which this test suite models by
  injecting deterministic `windowTotalOut` in a test-only hook harness.
Docs:
- https://docs.uniswap.org/contracts/v4/concepts/hooks
- https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
*/

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {StealthBatchHook} from "../src/StealthBatchHook.sol";
import {StealthBatchMath} from "../src/StealthBatchMath.sol";

contract StealthBatchHookHarness is StealthBatchHook {
    mapping(uint64 => uint256) internal mockedWindowOut;
    mapping(uint64 => bool) internal hasMockedWindowOut;

    constructor(
        IPoolManager _poolManager,
        uint64 _startBlock,
        uint64 _blocksPerWindow,
        uint64 _cancelDelayBlocks,
        uint16 _maxIntentsPerWindow,
        uint128 _minAmountIn,
        bool _zeroForOneDirection
    )
        StealthBatchHook(
            _poolManager,
            _startBlock,
            _blocksPerWindow,
            _cancelDelayBlocks,
            _maxIntentsPerWindow,
            _minAmountIn,
            _zeroForOneDirection
        )
    {}

    /// @dev TEST-ONLY override input for deferred execution output.
    function setMockWindowTotalOut(uint64 windowId, uint256 totalOut) external {
        mockedWindowOut[windowId] = totalOut;
        hasMockedWindowOut[windowId] = true;
    }

    function _computeWindowTotalOut(PoolId poolId, uint64 windowId, uint256 totalIn)
        internal
        view
        override
        returns (uint256 totalOut)
    {
        poolId;
        totalIn;
        if (hasMockedWindowOut[windowId]) return mockedWindowOut[windowId];
        return super._computeWindowTotalOut(poolId, windowId, totalIn);
    }
}

contract StealthBatchHookBatchingTest is Test {
    StealthBatchHookHarness internal hook;
    PoolId internal constant ALLOWED_POOL_ID =
        PoolId.wrap(0x00000000000000000000000000000000000000000000000000000000000000ab);

    address internal constant USER_A = address(0xA11CE);
    address internal constant USER_B = address(0xB0B);
    address internal constant RECIP_A = address(0xAAA1);
    address internal constant RECIP_B = address(0xBBB2);

    function setUp() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs =
            abi.encode(IPoolManager(address(1)), uint64(0), uint64(20), uint64(0), uint16(10), uint128(1), true);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StealthBatchHookHarness).creationCode, constructorArgs);

        hook = new StealthBatchHookHarness{salt: salt}(IPoolManager(address(1)), 0, 20, 0, 10, 1, true);
        require(address(hook) == hookAddress, "StealthBatchHookBatchingTest: hook address mismatch");
        hook.setAllowedPoolIdOnce(ALLOWED_POOL_ID);
    }

    function testQueueStoresIntentInCorrectWindow() public {
        vm.roll(5);
        vm.prank(USER_A);
        (uint64 windowId, uint256 intentId) = hook.queueSwapExactIn(100, 0, RECIP_A);

        assertEq(windowId, 0);
        assertEq(intentId, 0);

        StealthBatchHook.SwapIntent memory intent = hook.getIntent(windowId, intentId);
        assertEq(intent.user, USER_A);
        assertEq(intent.recipient, RECIP_A);
        assertEq(intent.amountIn, 100);
        assertEq(intent.windowId, 0);
        assertTrue(intent.zeroForOne);
        assertFalse(intent.claimed);
    }

    function testClearOnlyAfterWindowEnd() public {
        vm.roll(5);
        vm.prank(USER_A);
        hook.queueSwapExactIn(100, 0, RECIP_A);

        vm.expectRevert(abi.encodeWithSelector(StealthBatchHook.WindowNotEnded.selector, 5, 20));
        hook.clear(0);

        hook.setMockWindowTotalOut(0, 50);
        vm.roll(20);
        hook.clear(0);

        StealthBatchHook.WindowState memory window = hook.getWindow(0);
        assertTrue(window.cleared);
        assertEq(window.totalOut, 50);
    }

    function testClaimComputesProRataOutput() public {
        vm.roll(5);

        vm.prank(USER_A);
        hook.queueSwapExactIn(100, 0, RECIP_A);

        vm.prank(USER_B);
        hook.queueSwapExactIn(300, 0, RECIP_B);

        hook.setMockWindowTotalOut(0, 200);
        vm.roll(20);
        hook.clear(0);

        vm.prank(USER_A);
        uint256 outA = hook.claim(0, 0);
        assertEq(outA, 50);

        vm.prank(USER_B);
        uint256 outB = hook.claim(0, 1);
        assertEq(outB, 150);
    }

    function testClaimEnforcesMinOut() public {
        vm.roll(5);
        vm.prank(USER_A);
        hook.queueSwapExactIn(100, 60, RECIP_A);

        hook.setMockWindowTotalOut(0, 50);
        vm.roll(20);
        hook.clear(0);

        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(StealthBatchMath.MinOutNotMet.selector, 50, uint128(60)));
        hook.claim(0, 0);
    }

    function testDoubleClaimReverts() public {
        vm.roll(5);
        vm.prank(USER_A);
        hook.queueSwapExactIn(100, 0, RECIP_A);

        hook.setMockWindowTotalOut(0, 100);
        vm.roll(20);
        hook.clear(0);

        vm.prank(USER_A);
        hook.claim(0, 0);

        vm.prank(USER_A);
        vm.expectRevert(StealthBatchHook.IntentAlreadyClaimed.selector);
        hook.claim(0, 0);
    }
}
