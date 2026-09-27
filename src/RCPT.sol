// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Receipts (RCPT)
/// @notice The launch token: a fixed supply of 1,000,000,000 RCPT with 18 decimals, minted once to
/// the deployer in the constructor. There is no owner, no admin, no further mint and no burn.
/// @dev Zero constructor arguments so the launch factory can deploy it and then count the whole
/// supply in its own balance. The factory receives the supply because it is `msg.sender` at
/// construction; nothing here refers to a fixed address.
contract RCPT is ERC20 {
    /// @notice Total supply, minted exactly once.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Receipts", "RCPT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
