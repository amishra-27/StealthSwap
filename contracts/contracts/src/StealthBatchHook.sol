// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
Docs references:
- Uniswap v4 Hooks concepts (pool-specific hooks):
  https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle / hook execution:
  https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap + custom accounting:
  https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
- OpenZeppelin Uniswap Hooks base contracts overview (optional BaseHook/BaseCustomAccounting):
  https://github.com/openzeppelin/uniswap-hooks/blob/master/docs/modules/ROOT/pages/base.adoc
*/

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {StealthBaseHook} from "./base/StealthBaseHook.sol";
import {StealthBatchWindow} from "./StealthBatchWindow.sol";
import {StealthBatchMath} from "./StealthBatchMath.sol";

/// @notice SC-1 skeleton for N-block batched intents with pull-based pro-rata claims.
/// @dev This contract is single-pool for MVP, but storage remains PoolId-scoped for future multi-pool extension.
contract StealthBatchHook is StealthBaseHook, StealthBatchWindow, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error InvalidPool();
    error MaxIntentsZero();
    error MinAmountZero();
    error UnknownWindow();
    error WindowNotEnded(uint256 currentBlock, uint256 windowEndExclusive);
    error WindowAlreadyCleared();
    error WindowNotCleared();
    error WindowNotFullySettled(uint256 terminalIntentCount, uint256 intentCount);
    error DustAlreadySwept();
    error SweepRecipientZero();
    error RecipientZero();
    error AmountTooSmall();
    error AlreadyQueuedInWindow();
    error MaxIntentsReached();
    error InvalidIntentId();
    error IntentAlreadyClaimed();
    error UnauthorizedClaim();
    error CancelDelayNotElapsed(uint256 currentBlock, uint256 cancelAvailableBlock);
    error WindowTotalInTooLow(uint256 totalIn, uint256 intentAmountIn);

    struct WindowState {
        uint256 totalIn;
        uint256 totalOut;
        uint256 intentCount;
        uint256 terminalIntentCount;
        uint256 claimedOutSum;
        bool cleared;
        bool dustSwept;
    }

    /// @dev Intent schema requested by SC-1.
    struct SwapIntent {
        address user;
        address recipient;
        uint128 amountIn;
        uint128 minOut;
        uint64 windowId;
        bool zeroForOne;
        // NOTE: "claimed" means terminally settled for this intent (claimed OR canceled).
        bool claimed;
    }

    uint64 public immutable cancelDelayBlocks;
    uint16 public immutable maxIntentsPerWindow;
    uint128 public immutable minAmountIn;
    bool public immutable zeroForOneDirection;
    PoolId public immutable allowedPoolId;

    // Pool-scoped data model (single-pool MVP uses `allowedPoolId` only).
    mapping(PoolId => mapping(uint64 => WindowState)) internal windows;
    mapping(PoolId => mapping(uint64 => SwapIntent[])) internal intentsByPoolAndWindow;
    mapping(PoolId => mapping(uint64 => mapping(address => bool))) public hasQueuedIntent;
    mapping(PoolId => uint256) public beforeSwapCount;
    mapping(PoolId => uint256) public afterSwapCount;

    event IntentQueued(
        PoolId indexed poolId,
        uint64 indexed windowId,
        uint256 indexed intentId,
        address user,
        uint128 amountIn,
        bool zeroForOne
    );
    event WindowCleared(PoolId indexed poolId, uint64 indexed windowId, uint256 totalIn, uint256 totalOut);
    event Claimed(PoolId indexed poolId, uint64 indexed windowId, uint256 indexed intentId, address user, uint256 amountOut);
    event IntentCancelled(
        PoolId indexed poolId, uint64 indexed windowId, uint256 indexed intentId, address user, uint128 amountIn
    );
    event DustSwept(PoolId indexed poolId, uint64 indexed windowId, address indexed to, uint256 amountOut);

    constructor(
        IPoolManager _poolManager,
        PoolId _allowedPoolId,
        uint64 _startBlock,
        uint64 _blocksPerWindow,
        uint64 _cancelDelayBlocks,
        uint16 _maxIntentsPerWindow,
        uint128 _minAmountIn,
        bool _zeroForOneDirection
    ) StealthBaseHook(_poolManager) StealthBatchWindow(_startBlock, _blocksPerWindow) {
        if (_maxIntentsPerWindow == 0) revert MaxIntentsZero();
        if (_minAmountIn == 0) revert MinAmountZero();

        allowedPoolId = _allowedPoolId;
        cancelDelayBlocks = _cancelDelayBlocks;
        maxIntentsPerWindow = _maxIntentsPerWindow;
        minAmountIn = _minAmountIn;
        zeroForOneDirection = _zeroForOneDirection;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            noOp: false,
            accessLock: false
        });
    }

    function getWindowBounds(uint64 windowId) public view returns (uint256 windowStart, uint256 windowEndExclusive) {
        windowStart = getWindowStart(windowId);
        windowEndExclusive = getWindowEnd(windowId);
    }

    function getWindow(uint64 windowId) external view returns (WindowState memory) {
        return windows[allowedPoolId][windowId];
    }

    function getIntent(uint64 windowId, uint256 intentId) external view returns (SwapIntent memory) {
        if (intentId >= intentsByPoolAndWindow[allowedPoolId][windowId].length) revert InvalidIntentId();
        return intentsByPoolAndWindow[allowedPoolId][windowId][intentId];
    }

    function queueSwapExactIn(uint128 amountIn, uint128 minOut, address recipient)
        external
        nonReentrant
        returns (uint64 windowId, uint256 intentId)
    {
        if (recipient == address(0)) revert RecipientZero();
        if (amountIn < minAmountIn) revert AmountTooSmall();

        PoolId poolId = allowedPoolId;
        windowId = getCurrentWindowId();
        if (hasQueuedIntent[poolId][windowId][msg.sender]) revert AlreadyQueuedInWindow();

        WindowState storage window = windows[poolId][windowId];
        if (window.intentCount >= maxIntentsPerWindow) revert MaxIntentsReached();

        intentsByPoolAndWindow[poolId][windowId].push(
            SwapIntent({
                user: msg.sender,
                recipient: recipient,
                amountIn: amountIn,
                minOut: minOut,
                windowId: windowId,
                zeroForOne: zeroForOneDirection,
                claimed: false
            })
        );

        intentId = intentsByPoolAndWindow[poolId][windowId].length - 1;
        window.totalIn += amountIn;
        window.intentCount += 1;
        // Intentionally not reset on claim/cancel: one intent per user per window for MVP.
        hasQueuedIntent[poolId][windowId][msg.sender] = true;

        emit IntentQueued(poolId, windowId, intentId, msg.sender, amountIn, zeroForOneDirection);
    }

    /// @notice Permissionless clear after the half-open window [start, end) has ended.
    /// @dev No loops over intents here; settlement remains pull-based in `claim`.
    /// REVIEW REQUIRED: replace placeholder 1:1 accounting with real AsyncSwap/custom accounting execution path.
    function clear(uint64 windowId) external nonReentrant {
        PoolId poolId = allowedPoolId;
        WindowState storage window = windows[poolId][windowId];
        if (window.intentCount == 0) revert UnknownWindow();
        if (window.cleared) revert WindowAlreadyCleared();

        uint256 windowEndExclusive = getWindowEnd(windowId);
        if (block.number < windowEndExclusive) {
            revert WindowNotEnded(block.number, windowEndExclusive);
        }

        window.totalOut = _computeWindowTotalOut(poolId, windowId, window.totalIn);
        window.cleared = true;

        emit WindowCleared(poolId, windowId, window.totalIn, window.totalOut);
    }

    function claim(uint64 windowId, uint256 intentId) external nonReentrant returns (uint256 amountOut) {
        PoolId poolId = allowedPoolId;
        WindowState storage window = windows[poolId][windowId];
        if (!window.cleared) revert WindowNotCleared();
        if (intentId >= intentsByPoolAndWindow[poolId][windowId].length) revert InvalidIntentId();

        SwapIntent storage intent = intentsByPoolAndWindow[poolId][windowId][intentId];
        if (intent.user != msg.sender) revert UnauthorizedClaim();
        if (intent.claimed) revert IntentAlreadyClaimed();

        amountOut = StealthBatchMath.proRataOutFloor(window.totalOut, uint256(intent.amountIn), window.totalIn);
        StealthBatchMath.enforceMinOutAtClaim(amountOut, intent.minOut);

        intent.claimed = true;
        window.terminalIntentCount += 1;
        window.claimedOutSum += amountOut;

        /// REVIEW REQUIRED:
        /// - Transfer output tokens to `intent.recipient` using pull-based payout.
        /// - Enforce settlement currency correctness (single-pool token-out).
        /// - Add precise rounding policy and dust handling for pro-rata distribution.
        /// - Integrate with AsyncSwap/custom accounting execution output.

        emit Claimed(poolId, windowId, intentId, msg.sender, amountOut);
    }

    function cancelUncleared(uint64 windowId, uint256 intentId) external nonReentrant {
        PoolId poolId = allowedPoolId;
        WindowState storage window = windows[poolId][windowId];
        if (window.intentCount == 0) revert UnknownWindow();
        if (window.cleared) revert WindowAlreadyCleared();
        if (intentId >= intentsByPoolAndWindow[poolId][windowId].length) revert InvalidIntentId();

        uint256 windowEndExclusive = getWindowEnd(windowId);
        uint256 cancelAvailableBlock = windowEndExclusive + cancelDelayBlocks;
        if (block.number < cancelAvailableBlock) {
            revert CancelDelayNotElapsed(block.number, cancelAvailableBlock);
        }

        SwapIntent storage intent = intentsByPoolAndWindow[poolId][windowId][intentId];
        if (intent.user != msg.sender) revert UnauthorizedClaim();
        if (intent.claimed) revert IntentAlreadyClaimed();

        if (window.totalIn < intent.amountIn) revert WindowTotalInTooLow(window.totalIn, intent.amountIn);
        intent.claimed = true;
        window.totalIn -= intent.amountIn;
        window.terminalIntentCount += 1;

        /// REVIEW REQUIRED:
        /// - Return escrowed input to `intent.user` using pull-based refund.
        /// - Ensure escrow accounting cannot be drained/replayed after cancellation.
        /// - `cancelDelayBlocks == 0` means cancel is available immediately once window end is reached.

        emit IntentCancelled(poolId, windowId, intentId, msg.sender, intent.amountIn);
    }

    function sweepDust(uint64 windowId, address to) external nonReentrant returns (uint256 amountOut) {
        if (to == address(0)) revert SweepRecipientZero();

        PoolId poolId = allowedPoolId;
        WindowState storage window = windows[poolId][windowId];
        if (!window.cleared) revert WindowNotCleared();
        if (window.dustSwept) revert DustAlreadySwept();
        if (window.terminalIntentCount != window.intentCount) {
            revert WindowNotFullySettled(window.terminalIntentCount, window.intentCount);
        }

        amountOut = StealthBatchMath.getSweepableDust(window.totalOut, window.claimedOutSum);
        window.dustSwept = true;

        /// REVIEW REQUIRED:
        /// - Transfer dust output tokens to `to`.
        /// - Confirm sweep authorization model (permissionless vs role-gated).
        /// - Confirm final-state accounting invariants across claim/cancel/sweep.

        emit DustSwept(poolId, windowId, to, amountOut);
    }

    /// @dev Callback hook placeholder for lifecycle visibility; poolManager invokes this before swap execution.
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(allowedPoolId)) revert InvalidPool();
        beforeSwapCount[key.toId()]++;
        return this.beforeSwap.selector;
    }

    /// @dev Callback hook placeholder for lifecycle visibility; poolManager invokes this after swap execution.
    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(allowedPoolId)) revert InvalidPool();
        afterSwapCount[key.toId()]++;
        return this.afterSwap.selector;
    }

    /// REVIEW REQUIRED:
    /// - Replace placeholder accounting with deterministic execution against PoolManager + custom accounting path.
    /// - Record the actual output from execution and set window.totalOut from that result.
    /// - Validate slippage and settlement token invariants for single-pool mode.
    function _computeWindowTotalOut(PoolId, uint64, uint256 totalIn) internal view virtual returns (uint256 totalOut) {
        // Minimal end-to-end placeholder to keep clear/claim operational for MVP demos.
        totalOut = totalIn;
    }
}
