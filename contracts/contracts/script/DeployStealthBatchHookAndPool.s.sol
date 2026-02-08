// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
REVIEW REQUIRED:
- This script is for hackathon/demo flows and is NOT production deployment guidance.
- Validate network addresses, constructor args, pool params, and token addresses per target environment.

Docs references:
- Uniswap v4 Hook Deployment (flags encoded in hook address + HookMiner/CREATE2 flow):
  https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment
- Uniswap v4 Deployments (official network contract addresses):
  https://docs.uniswap.org/contracts/v4/deployments
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
import {StealthBatchHook} from "../src/StealthBatchHook.sol";

contract DeployStealthBatchHookAndPoolScript is Script {
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    uint256 constant ETHEREUM_SEPOLIA_CHAIN_ID = 11155111;
    address constant OFFICIAL_SEPOLIA_POOL_MANAGER = address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);

    error InvalidStealthBatchFlags(uint160 expected, uint160 actual);
    error InvalidHookContract(string expected, string actual);
    error IdenticalPoolCurrencies();
    error InvalidTickSpacing();
    error InvalidStartBlock(uint256 startBlock);
    error AllowedPoolIdSetMismatch(bytes32 expected, bytes32 actual);

    struct HookConstructorConfig {
        uint64 startBlock;
        uint64 blocksPerWindow;
        uint64 cancelDelayBlocks;
        uint16 maxIntentsPerWindow;
        uint128 minAmountIn;
        bool zeroForOneDirection;
    }

    function run() external {
        string memory hookContract = vm.envString("HOOK_CONTRACT");
        if (!_eq(hookContract, "StealthBatchHook.sol:StealthBatchHook")) {
            revert InvalidHookContract("StealthBatchHook.sol:StealthBatchHook", hookContract);
        }

        address manager = vm.envAddress("POOL_MANAGER_ADDR");
        _logPreflight(manager);
        HookConstructorConfig memory cfg = _loadHookConstructorConfig();
        uint160 flags = getFlagsFromEnv();
        uint160 expectedFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        if (flags != expectedFlags) revert InvalidStealthBatchFlags(expectedFlags, flags);

        bytes memory creationCode = vm.getCode(hookContract);
        bytes memory constructorArgs = _encodeConstructorArgs(manager, cfg);
        (address minedHookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);
        PoolKey memory key = getPoolKey(IHooks(minedHookAddress));
        PoolId poolId = key.toId();

        uint160 sqrtPriceX96 = uint160(vm.envUint("POOL_SQRT_PRICE_X96"));
        bytes memory hookData = vm.envBytes("POOL_HOOK_DATA");
        (address deployedHook, int24 initializedTick) = _deployAndInitialize(
            manager,
            creationCode,
            constructorArgs,
            salt,
            minedHookAddress,
            key,
            poolId,
            sqrtPriceX96,
            hookData
        );
        console2.log("final_hookAddress", deployedHook);
        console2.log("final_poolId");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("initializedTick");
        console2.logInt(initializedTick);
    }

    function _logPreflight(address manager) internal view {
        console2.log("preflight_chainId");
        console2.logUint(block.chainid);
        console2.log("preflight_poolManager");
        console2.logAddress(manager);

        if (block.chainid == ETHEREUM_SEPOLIA_CHAIN_ID && manager != OFFICIAL_SEPOLIA_POOL_MANAGER) {
            console2.log("WARNING: POOL_MANAGER_ADDR differs from Uniswap v4 deployments doc for Sepolia.");
            console2.log("expected_sepolia_poolManager");
            console2.logAddress(OFFICIAL_SEPOLIA_POOL_MANAGER);
            console2.log("docs: https://docs.uniswap.org/contracts/v4/deployments");
        }
    }

    function _loadHookConstructorConfig() internal view returns (HookConstructorConfig memory cfg) {
        bool useRuntimeStartBlock = vm.envBool("USE_RUNTIME_START_BLOCK");
        uint256 startBlockRaw = useRuntimeStartBlock ? block.number : vm.envUint("START_BLOCK");
        if (startBlockRaw > type(uint64).max) revert InvalidStartBlock(startBlockRaw);

        console2.log("preflight_startBlock_mode");
        console2.log(useRuntimeStartBlock ? "runtime_block_number" : "fixed_env_start_block");
        console2.log("preflight_startBlock");
        console2.logUint(startBlockRaw);

        cfg = HookConstructorConfig({
            startBlock: uint64(startBlockRaw),
            blocksPerWindow: uint64(vm.envUint("BLOCKS_PER_WINDOW")),
            cancelDelayBlocks: uint64(vm.envUint("CANCEL_DELAY_BLOCKS")),
            maxIntentsPerWindow: uint16(vm.envUint("MAX_INTENTS_PER_WINDOW")),
            minAmountIn: uint128(vm.envUint("MIN_AMOUNT_IN")),
            zeroForOneDirection: vm.envBool("ZERO_FOR_ONE_DIRECTION")
        });
    }

    function _encodeConstructorArgs(address manager, HookConstructorConfig memory cfg) internal pure returns (bytes memory) {
        return abi.encode(
            manager,
            cfg.startBlock,
            cfg.blocksPerWindow,
            cfg.cancelDelayBlocks,
            cfg.maxIntentsPerWindow,
            cfg.minAmountIn,
            cfg.zeroForOneDirection
        );
    }

    function _deployAndInitialize(
        address manager,
        bytes memory creationCode,
        bytes memory constructorArgs,
        bytes32 salt,
        address hookAddress,
        PoolKey memory key,
        PoolId poolId,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (address deployedHook, int24 initializedTick) {
        vm.startBroadcast();

        // Deploy hook using CREATE2 salt mined for required flags.
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        assembly {
            deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(deployedHook == hookAddress, "DeployStealthBatchHookAndPool: hook address mismatch");

        // Configure single-pool guard once, then initialize that pool.
        StealthBatchHook(deployedHook).setAllowedPoolIdOnce(poolId);
        bytes32 configuredPoolId = PoolId.unwrap(StealthBatchHook(deployedHook).allowedPoolId());
        if (configuredPoolId != PoolId.unwrap(poolId)) {
            revert AllowedPoolIdSetMismatch(PoolId.unwrap(poolId), configuredPoolId);
        }

        // Initialize pool with this hook attached.
        initializedTick = IPoolManager(manager).initialize(key, sqrtPriceX96, hookData);

        vm.stopBroadcast();
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
