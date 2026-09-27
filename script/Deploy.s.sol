// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {RCPT} from "../src/RCPT.sol";
import {SwapReceiptHook} from "../src/SwapReceiptHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {LaunchConfig} from "./LaunchConfig.sol";

/// @title Deploy
/// @notice Reference deployment of RCPT and SwapReceiptHook. On Sepolia the launch factory performs
/// the deployment, pool initialisation and seeding itself; this script exists so a reviewer can
/// rehearse the exact same shape (zero-argument token, hook with the pool manager as its only
/// argument, CREATE2 salt mined for the afterSwap bit) on a fork or a local chain.
/// @dev Configuration is constants and function arguments only; nothing here reads the environment.
contract Deploy is Script {
    /// @notice The canonical CREATE2 deployer proxy that `forge script --broadcast` routes
    /// salted `new` through.
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Deploys the token and the hook against the Sepolia pool manager, salted through
    /// the CREATE2 proxy. Broadcast this only on a chain where that manager exists.
    function run() external returns (RCPT token, SwapReceiptHook hook, bytes32 salt) {
        vm.startBroadcast();
        token = new RCPT();
        (hook, salt) = deployHook(IPoolManager(LaunchConfig.SEPOLIA_POOL_MANAGER), CREATE2_PROXY);
        vm.stopBroadcast();
        console2.log("RCPT", address(token));
        console2.log("SwapReceiptHook", address(hook));
        console2.logBytes32(salt);
    }

    /// @notice Mines a salt for `create2Deployer` and deploys the hook with it.
    /// @param poolManager The pool manager the hook will serve; its only constructor argument.
    /// @param create2Deployer The address that executes CREATE2. When this contract calls
    /// `new{salt: ...}` outside a broadcast it is `address(this)`; under `--broadcast` it is the
    /// CREATE2 proxy.
    function deployHook(IPoolManager poolManager, address create2Deployer)
        public
        returns (SwapReceiptHook hook, bytes32 salt)
    {
        bytes memory creationCode = abi.encodePacked(type(SwapReceiptHook).creationCode, abi.encode(poolManager));
        address predicted;
        (predicted, salt) = HookMiner.find(create2Deployer, LaunchConfig.HOOK_FLAGS, creationCode);
        hook = new SwapReceiptHook{salt: salt}(poolManager);
        require(address(hook) == predicted, "hook landed on an unexpected address");
    }
}
