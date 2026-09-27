// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../src/HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that lands a hook on an address carrying exactly the wanted
/// permission bits, the same way the launch factory does before deploying.
library HookMiner {
    /// @dev Enough for a 14-bit pattern with margin: the expected number of tries is 2^14.
    uint256 internal constant MAX_TRIES = 500_000;

    error NoSaltFound();

    /// @param deployer The address that will execute CREATE2.
    /// @param flags The permission bits the address must carry (masked to the fourteen bits).
    /// @param creationCode The hook's creation code, constructor arguments already appended.
    /// @return hook The address the salt produces.
    /// @return salt The salt to deploy with.
    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < MAX_TRIES; ++i) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hook, flags)) return (hook, salt);
        }
        revert NoSaltFound();
    }

    /// @notice The address CREATE2 produces for `deployer`, `salt` and `initCodeHash`.
    /// @dev Hashes from a fixed scratch buffer so a long mining loop does not grow memory.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address at) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initCodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer) // the address occupies bytes 12..31 of this word
            mstore8(add(ptr, 0x0b), 0xff) // byte 11: the 0xff prefix right before the address
            // 0xff (1 byte) | deployer (20) | salt (32) | hash (32) = 85 bytes from ptr + 0x0b
            at := and(keccak256(add(ptr, 0x0b), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
