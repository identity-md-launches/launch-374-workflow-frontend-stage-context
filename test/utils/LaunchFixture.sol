// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RCPT} from "../../src/RCPT.sol";
import {SwapReceiptHook} from "../../src/SwapReceiptHook.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";

/// @notice Opens the launch pool the way the factory does: a real `PoolManager`, the zero-argument
/// token minted to this contract (standing in for the factory), the hook at a mined address with the
/// manager as its only constructor argument, the pool initialised at the configured price and
/// seeded with one-sided RCPT liquidity. Every test file builds on this.
abstract contract LaunchFixture is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    PoolManager internal manager;
    RCPT internal token;
    SwapReceiptHook internal hook;
    Deploy internal deployer;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    PoolId internal poolId;
    uint128 internal seededLiquidity;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // The factory deploys the token with no arguments and receives the whole supply.
        token = new RCPT();

        // The factory mines a salt for the afterSwap bit and deploys with the manager as the only
        // constructor argument. `Deploy` performs the CREATE2 itself, so it is the deployer.
        deployer = new Deploy();
        (hook,) = deployer.deployHook(IPoolManager(address(manager)), address(deployer));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LaunchConfig.POOL_FEE,
            tickSpacing: LaunchConfig.TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        openPoolLikeTheFactory();
    }

    /// @dev Initialise at the configured price and seed the one-sided RCPT position. Nothing in
    /// the hook may revert either step; the fixture would fail here if it did.
    function openPoolLikeTheFactory() internal {
        manager.initialize(key, LaunchConfig.INITIAL_SQRT_PRICE_X96);
        seededLiquidity = liquidityForToken1(LaunchConfig.SEED_TOKEN_AMOUNT);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LaunchConfig.SEED_TICK_LOWER,
                tickUpper: LaunchConfig.SEED_TICK_UPPER,
                liquidityDelta: int256(uint256(seededLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Liquidity a position from SEED_TICK_LOWER to SEED_TICK_UPPER holds for `amount1` of
    /// token1 when the current price sits at or above the upper tick (so it holds only token1).
    function liquidityForToken1(uint256 amount1) internal pure returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(LaunchConfig.SEED_TICK_LOWER);
        uint160 upper = TickMath.getSqrtPriceAtTick(LaunchConfig.SEED_TICK_UPPER);
        return uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, upper - lower));
    }

    // ---------------------------------------------------------------------------------------------
    // Swap helpers. Each routes through PoolSwapTest, the router the site uses on Sepolia.
    // ---------------------------------------------------------------------------------------------

    function hookDataFor(address who) internal pure returns (bytes memory) {
        return abi.encode(who);
    }

    /// @dev Buy with an exact ETH input, from `buyer`, crediting whatever `hookData` names.
    function buyExactIn(address buyer, uint256 ethIn, bytes memory hookData) internal returns (BalanceDelta) {
        return buyExactIn(buyer, ethIn, MIN_PRICE_LIMIT, hookData);
    }

    function buyExactIn(address buyer, uint256 ethIn, uint160 priceLimit, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.deal(buyer, buyer.balance + ethIn);
        vm.prank(buyer);
        delta = swapRouter.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Buy an exact token output; `ethBudget` is sent along and the router refunds the rest.
    function buyExactOut(address buyer, uint256 tokensOut, uint256 ethBudget, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.deal(buyer, buyer.balance + ethBudget);
        vm.prank(buyer);
        delta = swapRouter.swap{value: ethBudget}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Sell an exact token input for ETH.
    function sellExactIn(address seller, uint256 tokensIn, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(seller);
        token.approve(address(swapRouter), tokensIn);
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    /// @dev Sell for an exact ETH output.
    function sellExactOut(address seller, uint256 ethOut, uint256 tokenBudget, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(seller);
        token.approve(address(swapRouter), tokenBudget);
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    function abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }
}
