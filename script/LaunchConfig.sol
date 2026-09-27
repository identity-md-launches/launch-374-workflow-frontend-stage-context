// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../src/HookFlags.sol";

/// @title LaunchConfig
/// @notice Every deployment parameter of the Receipts launch, as constants. The launch factory and
/// the manifest are the source of truth on chain; these values are what the Foundry launch
/// rehearsal mirrors, and they must agree with `launch.json`.
library LaunchConfig {
    /// @notice Sepolia only.
    uint256 internal constant CHAIN_ID = 11_155_111;

    /// @notice Uniswap v4 PoolManager on Sepolia: the hook's only constructor argument.
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice Uniswap's published Sepolia PoolSwapTest router the site swaps through.
    address internal constant SEPOLIA_POOL_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;

    /// @notice Uniswap's Sepolia StateView the site reads pool state through.
    address internal constant SEPOLIA_STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;

    /// @notice Permission bits the hook address must carry: afterSwap only.
    uint160 internal constant HOOK_FLAGS = HookFlags.AFTER_SWAP;

    /// @notice Pool key the factory opens: currency0 native ETH, currency1 RCPT.
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @notice Initial tick the rehearsal opens the pool at, aligned to the tick spacing.
    /// 1.0001^138180 is about 1,001,800 RCPT per ETH, so 0.001 ETH buys about 1,000 RCPT at the
    /// opening price and the full supply is worth about 1,000 ETH. The manifest may state a
    /// different price; the hook does not depend on it.
    int24 internal constant INITIAL_TICK = 138_180;

    /// @notice `TickMath.getSqrtPriceAtTick(INITIAL_TICK)`, the value the factory passes to
    /// `initialize`. Asserted against the library in the test suite.
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 79_299_443_975_792_720_780_679_863_727_831;

    /// @notice The one-sided RCPT position the rehearsal seeds: from the lowest usable tick up to
    /// the initial tick, so the position holds only RCPT and every buy walks the price down into it.
    int24 internal constant SEED_TICK_LOWER = -887_220;
    int24 internal constant SEED_TICK_UPPER = INITIAL_TICK;

    /// @notice RCPT the rehearsal seeds. The rehearsal uses the whole supply; the factory may seed
    /// a different share.
    uint256 internal constant SEED_TOKEN_AMOUNT = 1_000_000_000 ether;
}
