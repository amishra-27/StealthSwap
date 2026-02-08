// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../lib/forge-std/src/Script.sol";
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address manager = payable(vm.envAddress("POOL_MANAGER_ADDR"));
    error InvalidStealthBatchFlags(uint160 expected, uint160 actual);

    function setUp() public {}

    function run() public {
        bytes memory constructorArgs = getConstructorArgsFromEnv();
        string memory hookContract = vm.envString("HOOK_CONTRACT");

        // hook contracts must have specific flags encoded in the address
        // ------------------------------ //
        // --- Set your flags in .env --- //
        // ------------------------------ //
        uint160 flags = getFlagsFromEnv();
        validateFlagsForHook(hookContract, flags);
        console2.logBytes32(bytes32(uint256(flags)));

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory creationCode = vm.getCode(hookContract);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        vm.startBroadcast();
        address deployedHook;
        assembly {
            deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        vm.stopBroadcast();

        // verify proper create2 usage
        require(deployedHook == hookAddress, "DeployScript: hook address mismatch");
    }

    /// @dev Constructor args are contract-specific. Keep this in sync with the selected HOOK_CONTRACT.
    function getConstructorArgsFromEnv() internal view returns (bytes memory) {
        string memory hookContract = vm.envString("HOOK_CONTRACT");
        if (_eq(hookContract, "StealthBatchHook.sol:StealthBatchHook")) {
            return abi.encode(
                manager,
                uint64(vm.envUint("START_BLOCK")),
                uint64(vm.envUint("BLOCKS_PER_WINDOW")),
                uint64(vm.envUint("CANCEL_DELAY_BLOCKS")),
                uint16(vm.envUint("MAX_INTENTS_PER_WINDOW")),
                uint128(vm.envUint("MIN_AMOUNT_IN")),
                vm.envBool("ZERO_FOR_ONE_DIRECTION")
            );
        }
        // Default scaffold hook (Counter) constructor args.
        return abi.encode(manager);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev If permissions change (e.g. adding afterInitialize), update flags and re-mine.
    function validateFlagsForHook(string memory hookContract, uint160 flags) internal pure {
        if (_eq(hookContract, "StealthBatchHook.sol:StealthBatchHook")) {
            uint160 expected = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
            if (flags != expected) revert InvalidStealthBatchFlags(expected, flags);
        }
    }

    /// @dev Read booleans flags from the environemnt and encode them into the uint160 bit flags
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
}
