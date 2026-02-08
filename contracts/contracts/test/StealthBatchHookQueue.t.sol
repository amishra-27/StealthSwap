// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {StealthBatchHook} from "../src/StealthBatchHook.sol";

contract StealthBatchHookQueueTest is Test {
    StealthBatchHook internal hook;
    PoolId internal constant ALLOWED_POOL_ID =
        PoolId.wrap(0x00000000000000000000000000000000000000000000000000000000000000ab);

    function setUp() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs =
            abi.encode(IPoolManager(address(1)), uint64(0), uint64(100), uint64(0), uint16(10), uint128(1), true);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StealthBatchHook).creationCode, constructorArgs);

        hook = new StealthBatchHook{salt: salt}(IPoolManager(address(1)), 0, 100, 0, 10, 1, true);
        hook.setAllowedPoolIdOnce(ALLOWED_POOL_ID);
        require(address(hook) == hookAddress, "StealthBatchHookQueueTest: hook address mismatch");
    }

    function testCannotQueueTwiceInSameWindow() public {
        hook.queueSwapExactIn(10, 0, address(this));

        vm.expectRevert(StealthBatchHook.AlreadyQueuedInWindow.selector);
        hook.queueSwapExactIn(10, 0, address(this));
    }

    function testHasQueuedIntentRemainsTrueAfterCancel() public {
        (uint64 windowId, uint256 intentId) = hook.queueSwapExactIn(10, 0, address(this));
        vm.roll(100);
        hook.cancelUncleared(windowId, intentId);

        assertTrue(hook.hasQueuedIntent(ALLOWED_POOL_ID, windowId, address(this)));

        StealthBatchHook.WindowState memory window = hook.getWindow(windowId);
        assertEq(window.intentCount, 1);
        assertEq(window.terminalIntentCount, 1);
    }
}
