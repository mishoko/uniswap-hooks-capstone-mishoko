// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {VPINDynamicFeeHook} from "../src/VPINDynamicFeeHook.sol";
import "forge-std/console.sol";

/// @notice Deployment script for VPIN Dynamic Fee Hook
/// @dev Uses HookMiner to find a CREATE2 salt that produces an address with the correct hook flags
contract DeployVPINHook is Script {
    // Unichain Sepolia PoolManager address
    PoolManager constant POOL_MANAGER =
        PoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);

    // Hook configuration
    uint256 constant BUCKET_SIZE = 10 ether;
    uint24 constant BASE_FEE = 3000;   // 0.3%
    uint24 constant MAX_FEE = 10000;   // 1.0%

    function run() public {
        // Hook flags we need enabled
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

        // Find a salt that gives us a valid hook address
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(VPINDynamicFeeHook).creationCode,
            abi.encode(address(POOL_MANAGER), BUCKET_SIZE, BASE_FEE, MAX_FEE)
        );

        console.log("Deploying VPINDynamicFeeHook to:", hookAddress);
        console.log("Salt:", uint256(salt));

        vm.startBroadcast();
        VPINDynamicFeeHook hook = new VPINDynamicFeeHook{salt: salt}(
            POOL_MANAGER, BUCKET_SIZE, BASE_FEE, MAX_FEE
        );
        require(address(hook) == hookAddress, "hook address mismatch");
        vm.stopBroadcast();

        console.log("VPINDynamicFeeHook deployed at:", address(hook));
    }
}
