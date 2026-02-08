// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
Docs references:
- Uniswap v4 Hooks concepts (pool-specific hooks):
  https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 AsyncSwap/custom accounting (deferred execution patterns):
  https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
*/

/// @notice Deterministic N-block window math for batched intent processing.
/// @dev Half-open windows are used for clean gating and verifiable boundaries.
/// window k = [startBlock + k*N, startBlock + (k+1)*N), where end is exclusive.
abstract contract StealthBatchWindow {
    error BlocksPerWindowZero();
    error WindowNotStarted(uint256 blockNumber, uint64 startBlock);

    uint64 public immutable blocksPerWindow;
    uint64 public immutable startBlock;

    constructor(uint64 _startBlock, uint64 _blocksPerWindow) {
        if (_blocksPerWindow == 0) revert BlocksPerWindowZero();
        startBlock = _startBlock;
        blocksPerWindow = _blocksPerWindow;
    }

    function getWindowId(uint256 blockNumber) public view returns (uint64 windowId) {
        if (blockNumber < startBlock) revert WindowNotStarted(blockNumber, startBlock);
        windowId = uint64((blockNumber - startBlock) / blocksPerWindow);
    }

    function getCurrentWindowId() public view returns (uint64 windowId) {
        return getWindowId(block.number);
    }

    function getWindowStart(uint64 windowId) public view returns (uint256 windowStart) {
        windowStart = startBlock + uint256(windowId) * blocksPerWindow;
    }

    /// @notice Returns the exclusive upper bound for a window.
    function getWindowEnd(uint64 windowId) public view returns (uint256 windowEndExclusive) {
        windowEndExclusive = getWindowStart(windowId) + blocksPerWindow;
    }
}
