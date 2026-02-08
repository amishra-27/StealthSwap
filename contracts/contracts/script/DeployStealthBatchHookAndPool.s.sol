// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
REVIEW REQUIRED:
- This script is for hackathon/demo flows and is NOT production deployment guidance.
- Validate network addresses, constructor args, pool params, and token addresses per target environment.

Docs references:
- Uniswap v4 Hook Deployment (flags encoded in hook address + HookMiner/CREATE2 flow):
  https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment
- Uniswap v4 Hooks Concepts (pool-specific hooks):
  https://docs.uniswap.org/contracts/v4/concepts/hooks
- Uniswap v4 PoolManager lifecycle overview:
  https://docs.uniswap.org/contracts/v4/overview
- Uniswap v4 AsyncSwap/custom accounting context:
  https://docs.uniswap.org/contracts/v4/quickstart/hooks/async-swap
*/

import "../lib/forge-std/src/Script.sol";
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../lib/v4-core/src/types/PoolId.sol";

contract DeployStealthBatchHookAndPoolScript is Script {
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    error InvalidStealthBatchFlags(uint160 expected, uint160 actual);
    error InvalidHookContract(string expected, string actual);
    error AllowedPoolIdMismatch(bytes32 expected, bytes32 actual);
    error IdenticalPoolCurrencies();
    error InvalidTickSpacing();

    function run() external {
        string memory hookContract = vm.envString("HOOK_CONTRACT");
        if (!_eq(hookContract, "StealthBatchHook.sol:StealthBatchHook")) {
            revert InvalidHookContract("StealthBatchHook.sol:StealthBatchHook", hookContract);
        }

        address manager = vm.envAddress("POOL_MANAGER_ADDR");
        bytes memory constructorArgs = abi.encode(
            manager,
            PoolId.wrap(vm.envBytes32("ALLOWED_POOL_ID")),
            uint64(vm.envUint("START_BLOCK")),
            uint64(vm.envUint("BLOCKS_PER_WINDOW")),
            uint64(vm.envUint("CANCEL_DELAY_BLOCKS")),
            uint16(vm.envUint("MAX_INTENTS_PER_WINDOW")),
            uint128(vm.envUint("MIN_AMOUNT_IN")),
            vm.envBool("ZERO_FOR_ONE_DIRECTION")
        );

        uint160 flags = getFlagsFromEnv();
        uint160 expectedFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        if (flags != expectedFlags) revert InvalidStealthBatchFlags(expectedFlags, flags);

        bytes memory creationCode = vm.getCode(hookContract);
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        PoolKey memory key = getPoolKey(IHooks(hookAddress));
        bytes32 configuredAllowedPoolId = vm.envBytes32("ALLOWED_POOL_ID");
        bytes32 computedPoolId = PoolId.unwrap(key.toId());
        if (configuredAllowedPoolId != computedPoolId) {
            revert AllowedPoolIdMismatch(configuredAllowedPoolId, computedPoolId);
        }

        uint160 sqrtPriceX96 = uint160(vm.envUint("POOL_SQRT_PRICE_X96"));
        bytes memory hookData = vm.envBytes("POOL_HOOK_DATA");

        vm.startBroadcast();

        // Deploy hook using CREATE2 salt mined for required flags.
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        address deployedHook;
        assembly {
            deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(deployedHook == hookAddress, "DeployStealthBatchHookAndPool: hook address mismatch");

        // Initialize pool with this hook attached.
        int24 initializedTick = IPoolManager(manager).initialize(key, sqrtPriceX96, hookData);

        vm.stopBroadcast();

        console2.log("StealthBatchHook:", deployedHook);
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.logInt(initializedTick);
    }

    function getPoolKey(IHooks hookAddress) internal view returns (PoolKey memory key) {
        address tokenA = vm.envAddress("POOL_TOKEN_A");
        address tokenB = vm.envAddress("POOL_TOKEN_B");
        if (tokenA == tokenB) revert IdenticalPoolCurrencies();

        uint256 tickSpacingRaw = vm.envUint("POOL_TICK_SPACING");
        if (tickSpacingRaw == 0 || tickSpacingRaw > uint256(uint24(type(int24).max))) revert InvalidTickSpacing();

        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        (Currency currency0, Currency currency1) =
            tokenA < tokenB ? (currencyA, currencyB) : (currencyB, currencyA);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(uint24(tickSpacingRaw)),
            hooks: hookAddress
        });
    }

    function getFlagsFromEnv() internal view returns (uint160) {
        uint256 flags;
        if (vm.envBool("BEFORE_SWAP")) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (vm.envBool("AFTER_SWAP")) flags |= Hooks.AFTER_SWAP_FLAG;
        if (vm.envBool("BEFORE_ADD_LIQUIDITY")) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (vm.envBool("AFTER_ADD_LIQUIDITY")) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (vm.envBool("BEFORE_REMOVE_LIQUIDITY")) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (vm.envBool("AFTER_REMOVE_LIQUIDITY")) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (vm.envBool("BEFORE_INITIALIZE")) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (vm.envBool("AFTER_INITIALIZE")) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (vm.envBool("BEFORE_DONATE")) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (vm.envBool("AFTER_DONATE")) flags |= Hooks.AFTER_DONATE_FLAG;
        if (vm.envBool("NO_OP")) flags |= Hooks.NO_OP_FLAG;
        if (vm.envBool("ACCESS_LOCK")) flags |= Hooks.ACCESS_LOCK_FLAG;
        return uint160(flags);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
