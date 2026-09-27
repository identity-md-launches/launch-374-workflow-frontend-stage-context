// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {SwapReceiptHook} from "../src/SwapReceiptHook.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {LaunchFixture} from "./utils/LaunchFixture.sol";

/// @notice The launch, rehearsed end to end the way the factory performs it on Sepolia: token with
/// no arguments, hook at a mined address with the pool manager as its only argument, pool opened at
/// the configured price with one-sided RCPT liquidity, then the first buy into a pool that holds
/// no ETH.
contract LaunchRehearsalTest is LaunchFixture {
    using StateLibrary for IPoolManager;

    function test_configuredPriceIsTheTickPrice() public pure {
        assertEq(LaunchConfig.INITIAL_SQRT_PRICE_X96, TickMath.getSqrtPriceAtTick(LaunchConfig.INITIAL_TICK));
        assertEq(LaunchConfig.INITIAL_TICK % LaunchConfig.TICK_SPACING, 0, "initial tick must be spacing-aligned");
        assertEq(LaunchConfig.SEED_TICK_LOWER, TickMath.minUsableTick(LaunchConfig.TICK_SPACING));
        assertEq(LaunchConfig.HOOK_FLAGS, uint160(0x0040));
        assertEq(LaunchConfig.HOOK_FLAGS, Hooks.AFTER_SWAP_FLAG);
    }

    function test_deployShapeMatchesTheFactory() public view {
        // Token: whole supply to its deployer, which here is the fixture standing in for the factory.
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        // Hook: address carries exactly the afterSwap bit, manager is its only constructor input.
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.AFTER_SWAP);
        assertEq(address(hook.poolManager()), address(manager));
        // Hook: ERC-721 identity is literal in source.
        assertEq(hook.name(), "Swap Receipts");
        assertEq(hook.symbol(), "SWAPRCPT");
    }

    function test_poolOpenedAtTheConfiguredPriceWithOnlyTokenLiquidity() public view {
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(sqrtPriceX96, LaunchConfig.INITIAL_SQRT_PRICE_X96);
        assertEq(tick, LaunchConfig.INITIAL_TICK);

        // The seed is one-sided: the manager holds RCPT and no ETH.
        assertEq(address(manager).balance, 0, "pool must hold no ETH before the first buy");
        uint256 expectedToken = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(LaunchConfig.SEED_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(LaunchConfig.SEED_TICK_UPPER),
            seededLiquidity,
            true
        );
        assertEq(token.balanceOf(address(manager)), expectedToken);
        assertLe(expectedToken, LaunchConfig.SEED_TOKEN_AMOUNT);
        assertGt(expectedToken, LaunchConfig.SEED_TOKEN_AMOUNT - 1e12, "seed should use almost the whole amount");
        assertEq(
            IPoolManager(address(manager)).getLiquidity(poolId),
            0,
            "active liquidity is zero until a buy walks into the range"
        );
    }

    function test_firstBuyOfOneThousandthEthMintsReceiptOne() public {
        assertEq(hook.totalMinted(), 0);
        assertEq(address(manager).balance, 0);

        vm.expectEmit(true, true, true, false, address(hook));
        emit SwapReceiptHook.Receipt(1, alice, poolId, 0, 0, block.number);
        BalanceDelta delta = buyExactIn(alice, 0.001 ether, hookDataFor(alice));

        assertEq(abs(delta.amount0()), 0.001 ether, "the whole 0.001 ETH must be consumed");
        assertGt(delta.amount1(), 0, "the buyer must receive tokens");

        assertEq(hook.totalMinted(), 1);
        assertEq(hook.ownerOf(1), alice);
        assertEq(hook.balanceOf(alice), 1);

        SwapReceiptHook.ReceiptData memory r = hook.receiptOf(1);
        assertEq(r.ethPaid, 0.001 ether);
        assertEq(r.tokensReceived, abs(delta.amount1()));
        assertEq(r.token, address(token));
        assertEq(r.blockNumber, block.number);
        assertEq(r.timestamp, block.timestamp);
        assertEq(token.balanceOf(alice), r.tokensReceived);

        // About 1,000 RCPT at the opening price, less the 0.3% fee and the price walk.
        assertGt(r.tokensReceived, 990 ether);
        assertLt(r.tokensReceived, 1000 ether);

        uint256[] memory ids = hook.receiptsOf(alice, 0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        assertEq(address(manager).balance, 0.001 ether, "the pool now holds the ETH paid");
    }

    function test_secondBuyMintsReceiptTwoAndSellReturnsEth() public {
        buyExactIn(alice, 0.001 ether, hookDataFor(alice));
        buyExactIn(bob, 0.5 ether, hookDataFor(bob));
        assertEq(hook.totalMinted(), 2);
        assertEq(hook.ownerOf(2), bob);
        assertGt(hook.receiptOf(2).ethPaid, hook.receiptOf(1).ethPaid);

        uint256 ethBefore = bob.balance;
        BalanceDelta delta = sellExactIn(bob, token.balanceOf(bob), hookDataFor(bob));
        assertGt(delta.amount0(), 0);
        assertEq(bob.balance - ethBefore, uint256(int256(delta.amount0())));
        assertEq(hook.totalMinted(), 2, "a sell mints nothing");
    }
}
