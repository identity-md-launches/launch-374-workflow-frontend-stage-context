// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {SwapReceiptHook} from "../src/SwapReceiptHook.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {LaunchFixture} from "./utils/LaunchFixture.sol";
import {Base64Decoder} from "./utils/Base64Decoder.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A contract with no `onERC721Received`: a receipt must still land on it.
contract PlainContract {}

/// @dev Stands where the pool manager stands and reports what a plain CALL into the hook costs.
contract GasProbe {
    function callHook(address hook, bytes memory data) external returns (uint256 used, bool ok) {
        uint256 before = gasleft();
        (ok,) = hook.call(data);
        used = before - gasleft();
    }
}

contract SwapReceiptHookTest is LaunchFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant MIN = 0.001 ether;

    // ---------------------------------------------------------------------------------------------
    // Permissions and construction
    // ---------------------------------------------------------------------------------------------

    function test_permissionsAreExactlyAfterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), 0x0040);
        assertEq(hook.MIN_ETH_PAID(), MIN);
    }

    function test_constructorRejectsAnAddressWithoutTheAfterSwapBit() public {
        bytes memory creationCode =
            abi.encodePacked(type(SwapReceiptHook).creationCode, abi.encode(IPoolManager(address(manager))));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), 0, creationCode);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapReceiptHook{salt: salt}(IPoolManager(address(manager)));
    }

    function test_constructorRejectsAnAddressWithExtraBits() public {
        bytes memory creationCode =
            abi.encodePacked(type(SwapReceiptHook).creationCode, abi.encode(IPoolManager(address(manager))));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.AFTER_SWAP | HookFlags.BEFORE_SWAP, creationCode);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapReceiptHook{salt: salt}(IPoolManager(address(manager)));
    }

    function test_constructorAcceptsTheMinedAddress() public {
        bytes memory creationCode =
            abi.encodePacked(type(SwapReceiptHook).creationCode, abi.encode(IPoolManager(address(manager))));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HookFlags.AFTER_SWAP, creationCode);
        SwapReceiptHook fresh = new SwapReceiptHook{salt: salt}(IPoolManager(address(manager)));
        assertEq(address(fresh), predicted);
        assertEq(fresh.totalMinted(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Caller checks
    // ---------------------------------------------------------------------------------------------

    function test_afterSwapRefusesCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, MIN_PRICE_LIMIT);
        BalanceDelta delta = toBalanceDelta(-1 ether, 1 ether);
        vm.expectRevert(SwapReceiptHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, delta, hookDataFor(alice));
        assertEq(hook.totalMinted(), 0);

        vm.prank(address(swapRouter));
        vm.expectRevert(SwapReceiptHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, delta, hookDataFor(alice));
    }

    function test_afterSwapAcceptsThePoolManager() public {
        vm.prank(address(manager));
        (bytes4 sel, int128 d) = hook.afterSwap(
            address(this),
            key,
            SwapParams(true, -1 ether, MIN_PRICE_LIMIT),
            toBalanceDelta(-1 ether, 5),
            hookDataFor(alice)
        );
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(d, 0);
        assertEq(hook.ownerOf(1), alice);
    }

    function test_disabledCallbacksRevertForEveryone() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(true, -1 ether, MIN_PRICE_LIMIT);
        BalanceDelta zero = toBalanceDelta(0, 0);

        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, TickMath.MIN_SQRT_PRICE));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, TickMath.MIN_SQRT_PRICE, 0));
        calls[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, ""));
        calls[3] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, ""));
        calls[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[6] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, sp, ""));
        calls[7] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[8] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = address(hook).call(calls[i]);
            assertFalse(ok, "disabled callback accepted a call");
            assertEq(bytes4(ret), SwapReceiptHook.HookNotImplemented.selector);

            vm.prank(address(manager));
            (ok, ret) = address(hook).call(calls[i]);
            assertFalse(ok, "disabled callback accepted the manager");
            assertEq(bytes4(ret), SwapReceiptHook.HookNotImplemented.selector);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Threshold: the ETH the pool settled
    // ---------------------------------------------------------------------------------------------

    function test_buyOfExactlyTheMinimumMints() public {
        buyExactIn(alice, MIN, hookDataFor(alice));
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.receiptOf(1).ethPaid, MIN);
    }

    function test_buyOfMinimumMinusOneWeiDoesNotMint() public {
        BalanceDelta delta = buyExactIn(alice, MIN - 1, hookDataFor(alice));
        assertEq(abs(delta.amount0()), MIN - 1, "the whole input was consumed");
        assertGt(delta.amount1(), 0, "the buy itself went through");
        assertEq(hook.totalMinted(), 0);
        assertEq(hook.balanceOf(alice), 0);
    }

    function test_dustBuysDoNotMint() public {
        buyExactIn(alice, 1, hookDataFor(alice));
        buyExactIn(alice, 1000, hookDataFor(alice));
        buyExactIn(alice, 1e12, hookDataFor(alice));
        assertEq(hook.totalMinted(), 0);
    }

    function test_exactInBuyRecordsSettledAmounts() public {
        vm.deal(alice, 0);
        BalanceDelta delta = buyExactIn(alice, 0.25 ether, hookDataFor(alice));
        SwapReceiptHook.ReceiptData memory r = hook.receiptOf(1);
        assertEq(r.ethPaid, abs(delta.amount0()));
        assertEq(r.ethPaid, 0.25 ether);
        assertEq(r.tokensReceived, abs(delta.amount1()));
        assertEq(token.balanceOf(alice), r.tokensReceived);
        assertEq(alice.balance, 0, "the whole input was spent");
        assertEq(r.token, address(token));
    }

    function test_exactOutBuyUsesTheSettledEth() public {
        vm.deal(alice, 0);
        uint256 budget = 1 ether;
        BalanceDelta delta = buyExactOut(alice, 5_000 ether, budget, hookDataFor(alice));

        uint256 spent = budget - alice.balance;
        assertEq(abs(delta.amount0()), spent, "router refunded the unspent budget");
        assertEq(uint256(int256(delta.amount1())), 5_000 ether, "exact output honoured");
        assertGt(spent, MIN);
        assertLt(spent, budget);

        assertEq(hook.totalMinted(), 1);
        SwapReceiptHook.ReceiptData memory r = hook.receiptOf(1);
        assertEq(r.ethPaid, spent, "ethPaid is what was settled, not the budget sent");
        assertEq(r.tokensReceived, 5_000 ether);
    }

    function test_exactOutBuyBelowTheMinimumDoesNotMint() public {
        // About 1,000 RCPT costs about 0.001 ETH at the opening price; 100 RCPT is far below.
        vm.deal(alice, 0);
        BalanceDelta delta = buyExactOut(alice, 100 ether, 1 ether, hookDataFor(alice));
        assertLt(abs(delta.amount0()), MIN);
        assertEq(hook.totalMinted(), 0);
    }

    function test_exactOutBuyOfExactlyTheMinimumMints() public {
        // Find the smallest exact-out that costs at least MIN by settling an exact-in first on a
        // scratch buyer, then asking for that many tokens.
        BalanceDelta probe = buyExactIn(bob, MIN, hookDataFor(bob));
        uint256 tokensForMin = uint256(int256(probe.amount1()));
        assertEq(hook.totalMinted(), 1);

        // Reopen the same pool state through a fresh fixture so the price is the opening price.
        setUp();
        vm.deal(alice, 0);
        BalanceDelta delta = buyExactOut(alice, tokensForMin, 1 ether, hookDataFor(alice));
        assertGe(abs(delta.amount0()), MIN);
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.receiptOf(1).ethPaid, abs(delta.amount0()));
    }

    function test_partialFillIsMeasuredByWhatWasSettled() public {
        // Ask to spend 1 ETH but stop after ten ticks (about 0.5 ETH of the seeded liquidity):
        // the pool consumes only part of the input.
        uint160 limit = TickMath.getSqrtPriceAtTick(LaunchConfig.INITIAL_TICK - 10);
        vm.deal(alice, 0);
        BalanceDelta delta = buyExactIn(alice, 1 ether, limit, hookDataFor(alice));
        uint256 spent = abs(delta.amount0());
        assertLt(spent, 1 ether, "the fill must be partial");
        assertEq(1 ether - alice.balance, spent, "the router refunded the rest");
        assertGe(spent, MIN);

        assertEq(hook.totalMinted(), 1);
        assertEq(hook.receiptOf(1).ethPaid, spent);
        assertEq(hook.receiptOf(1).tokensReceived, abs(delta.amount1()));
    }

    function test_partialFillBelowTheMinimumDoesNotMint() public {
        // Stop after a price move of one part in ten million from 1 ETH requested: the settled
        // ETH is about 0.0001 ETH, well under the minimum.
        uint160 opening = TickMath.getSqrtPriceAtTick(LaunchConfig.INITIAL_TICK);
        uint160 limit = opening - opening / 10_000_000;
        BalanceDelta delta = buyExactIn(alice, 1 ether, limit, hookDataFor(alice));
        assertLt(abs(delta.amount0()), MIN);
        assertEq(hook.totalMinted(), 0);
    }

    function testFuzz_exactInMintsIffAtLeastTheMinimum(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 20 ether);
        BalanceDelta delta = buyExactIn(alice, ethIn, hookDataFor(alice));
        assertEq(abs(delta.amount0()), ethIn, "the seeded liquidity absorbs the whole input");
        if (ethIn >= MIN) {
            assertEq(hook.totalMinted(), 1);
            assertEq(hook.ownerOf(1), alice);
            assertEq(hook.receiptOf(1).ethPaid, ethIn);
            assertEq(hook.receiptOf(1).tokensReceived, abs(delta.amount1()));
        } else {
            assertEq(hook.totalMinted(), 0);
        }
    }

    function testFuzz_exactOutMintsIffSettledEthReachesTheMinimum(uint256 tokensOut) public {
        tokensOut = bound(tokensOut, 1 ether, 10_000_000 ether);
        vm.deal(alice, 0);
        BalanceDelta delta = buyExactOut(alice, tokensOut, 100 ether, hookDataFor(alice));
        uint256 spent = 100 ether - alice.balance;
        assertEq(abs(delta.amount0()), spent);
        if (spent >= MIN) {
            assertEq(hook.totalMinted(), 1);
            assertEq(hook.receiptOf(1).ethPaid, spent);
            assertEq(hook.receiptOf(1).tokensReceived, tokensOut);
        } else {
            assertEq(hook.totalMinted(), 0);
        }
    }

    function testFuzz_directCallbackMintsIffThresholdMet(int128 amount0, int128 amount1) public {
        vm.assume(amount0 != type(int128).min);
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams(true, -1, MIN_PRICE_LIMIT),
            toBalanceDelta(amount0, amount1),
            hookDataFor(alice)
        );
        bool shouldMint = amount0 < 0 && uint256(-int256(amount0)) >= MIN;
        assertEq(hook.totalMinted(), shouldMint ? 1 : 0);
        if (shouldMint) {
            assertEq(hook.receiptOf(1).ethPaid, uint256(-int256(amount0)));
            assertEq(hook.receiptOf(1).tokensReceived, abs(amount1));
        }
    }

    function test_directCallbackWithExtremeDeltaDoesNotRevert() public {
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams(true, -1, MIN_PRICE_LIMIT),
            toBalanceDelta(type(int128).min, type(int128).min),
            hookDataFor(alice)
        );
        assertEq(hook.receiptOf(1).ethPaid, uint128(2 ** 127));
        assertEq(hook.receiptOf(1).tokensReceived, uint128(2 ** 127));
    }

    // ---------------------------------------------------------------------------------------------
    // Direction, pool and identity rules
    // ---------------------------------------------------------------------------------------------

    function test_sellsNeverMint() public {
        buyExactIn(alice, 1 ether, hookDataFor(alice));
        assertEq(hook.totalMinted(), 1);

        sellExactIn(alice, token.balanceOf(alice) / 2, hookDataFor(alice));
        sellExactOut(alice, 0.01 ether, token.balanceOf(alice), hookDataFor(alice));
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.balanceOf(alice), 1);
    }

    function test_buyWithoutHookDataMintsNothing() public {
        BalanceDelta delta = buyExactIn(alice, 1 ether, "");
        assertEq(abs(delta.amount0()), 1 ether);
        assertEq(hook.totalMinted(), 0);
    }

    function test_buyWithZeroAddressHookDataMintsNothing() public {
        buyExactIn(alice, 1 ether, abi.encode(address(0)));
        assertEq(hook.totalMinted(), 0);
    }

    function test_buyWithWrongLengthHookDataMintsNothing() public {
        buyExactIn(alice, 1 ether, abi.encodePacked(alice));
        buyExactIn(alice, 1 ether, abi.encode(alice, alice));
        buyExactIn(alice, 1 ether, abi.encodePacked(bytes32(uint256(uint160(alice))), bytes1(0x00)));
        buyExactIn(alice, 1 ether, hex"01");
        assertEq(hook.totalMinted(), 0);
    }

    function test_buyWithDirtyUpperBytesMintsNothingAndDoesNotRevert() public {
        bytes memory dirty = abi.encode(uint256(uint160(alice)) | (uint256(1) << 160));
        BalanceDelta delta = buyExactIn(alice, 1 ether, dirty);
        assertEq(abs(delta.amount0()), 1 ether, "the buy still went through");
        assertEq(hook.totalMinted(), 0);
    }

    function test_hookDataIsUnauthenticated() public {
        // Alice pays, Bob is credited. This is by design and documented.
        buyExactIn(alice, 1 ether, hookDataFor(bob));
        assertEq(hook.ownerOf(1), bob);
        assertEq(hook.balanceOf(alice), 0);
        assertEq(token.balanceOf(alice), hook.receiptOf(1).tokensReceived);
    }

    function test_contractRecipientWithoutReceiverHookGetsItsReceipt() public {
        PlainContract plain = new PlainContract();
        BalanceDelta delta = buyExactIn(alice, 1 ether, hookDataFor(address(plain)));
        assertEq(abs(delta.amount0()), 1 ether);
        assertEq(hook.ownerOf(1), address(plain));
        assertEq(hook.balanceOf(address(plain)), 1);
    }

    function test_nonEthPoolGetsZeroDeltasAndNoOtherEffect() public {
        MockERC20 a = new MockERC20("A", "A", 1e30);
        MockERC20 b = new MockERC20("B", "B", 1e30);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory other = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)), "");

        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        uint256 t0Before = t0.balanceOf(address(this));
        uint256 t1Before = t1.balanceOf(address(this));
        BalanceDelta delta =
            swapRouter.swap(other, SwapParams(true, -10 ether, MIN_PRICE_LIMIT), settings(), hookDataFor(alice));
        // The swap settled exactly what the pool computed: the hook took nothing.
        assertEq(t0Before - t0.balanceOf(address(this)), 10 ether);
        assertEq(t1.balanceOf(address(this)) - t1Before, uint256(int256(delta.amount1())));
        assertEq(hook.totalMinted(), 0);
        assertEq(hook.balanceOf(alice), 0);

        // And the other direction, and a sell, likewise.
        swapRouter.swap(other, SwapParams(false, -10 ether, MAX_PRICE_LIMIT), settings(), hookDataFor(alice));
        assertEq(hook.totalMinted(), 0);
    }

    function test_receiptsFromAnotherEthPoolRecordTheirOwnToken() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 1e30);
        PoolKey memory other = PoolKey({
            currency0: key.currency0,
            currency1: Currency.wrap(address(otherToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId otherId = other.toId();
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));
        otherToken.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        liquidityRouter.modifyLiquidity{value: 50 ether}(other, ModifyLiquidityParams(-600, 600, 1e21, bytes32(0)), "");

        vm.expectEmit(true, true, true, false, address(hook));
        emit SwapReceiptHook.Receipt(1, alice, otherId, 0, 0, block.number);
        swapRouter.swap{value: 1 ether}(
            other, SwapParams(true, -1 ether, MIN_PRICE_LIMIT), settings(), hookDataFor(alice)
        );
        assertEq(hook.receiptOf(1).token, address(otherToken));

        buyExactIn(bob, 1 ether, hookDataFor(bob));
        assertEq(hook.receiptOf(2).token, address(token));
        assertEq(hook.totalMinted(), 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Ids, events, views
    // ---------------------------------------------------------------------------------------------

    function test_idsStartAtOneAndRiseByOne() public {
        for (uint256 i = 1; i <= 5; i++) {
            address who = i % 2 == 0 ? alice : bob;
            vm.expectEmit(true, true, true, false, address(hook));
            emit SwapReceiptHook.Receipt(i, who, poolId, 0, 0, block.number);
            buyExactIn(who, MIN * i, hookDataFor(who));
            assertEq(hook.totalMinted(), i);
            assertEq(hook.ownerOf(i), who);
        }
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        hook.ownerOf(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 6));
        hook.ownerOf(6);
    }

    function test_receiptEventCarriesTheStoredNumbers() public {
        vm.roll(12_345);
        vm.warp(1_700_000_000);
        vm.recordLogs();
        BalanceDelta delta = buyExactIn(alice, 0.01 ether, hookDataFor(alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("Receipt(uint256,address,bytes32,uint128,uint128,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != sig) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), 1);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
            assertEq(logs[i].topics[3], PoolId.unwrap(poolId));
            (uint128 ethPaid, uint128 tokensReceived, uint256 blockNumber) =
                abi.decode(logs[i].data, (uint128, uint128, uint256));
            assertEq(ethPaid, 0.01 ether);
            assertEq(tokensReceived, abs(delta.amount1()));
            assertEq(blockNumber, 12_345);
        }
        assertTrue(found, "Receipt event not emitted");

        SwapReceiptHook.ReceiptData memory r = hook.receiptOf(1);
        assertEq(r.blockNumber, 12_345);
        assertEq(r.timestamp, 1_700_000_000);
    }

    function test_receiptOfRevertsForUnknownIds() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        hook.receiptOf(1);
        buyExactIn(alice, MIN, hookDataFor(alice));
        hook.receiptOf(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        hook.receiptOf(2);
    }

    function test_receiptsOfPaginates() public {
        // alice: 1, 3, 5, 7; bob: 2, 4, 6
        for (uint256 i = 1; i <= 7; i++) {
            address who = i % 2 == 1 ? alice : bob;
            buyExactIn(who, MIN, hookDataFor(who));
        }
        assertEq(hook.balanceOf(alice), 4);
        assertEq(hook.balanceOf(bob), 3);

        uint256[] memory page = hook.receiptsOf(alice, 0, 100);
        assertEq(page.length, 4);
        assertEq(page[0], 1);
        assertEq(page[1], 3);
        assertEq(page[2], 5);
        assertEq(page[3], 7);

        page = hook.receiptsOf(alice, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 3);
        assertEq(page[1], 5);

        page = hook.receiptsOf(alice, 3, 2);
        assertEq(page.length, 1);
        assertEq(page[0], 7);

        assertEq(hook.receiptsOf(alice, 4, 2).length, 0);
        assertEq(hook.receiptsOf(alice, 100, 2).length, 0);
        assertEq(hook.receiptsOf(alice, 0, 0).length, 0);
        assertEq(hook.receiptsOf(address(0xDEAD), 0, 10).length, 0);

        page = hook.receiptsOf(bob, 0, 10);
        assertEq(page.length, 3);
        assertEq(page[0], 2);
        assertEq(page[2], 6);
    }

    // ---------------------------------------------------------------------------------------------
    // tokenURI
    // ---------------------------------------------------------------------------------------------

    function test_tokenURIDecodesToJsonWithTheStoredNumbers() public {
        vm.roll(777_777);
        vm.warp(1_800_000_000);
        BalanceDelta delta = buyExactIn(alice, 0.123456789 ether, hookDataFor(alice));
        uint256 tokens = abs(delta.amount1());

        string memory uri = hook.tokenURI(1);
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
        string memory json = string(Base64Decoder.decodeDataUri(uri));

        assertEq(vm.parseJsonString(json, ".name"), "Swap Receipt #1");
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "ETH paid (wei)");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "123456789000000000");
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "0.123456");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), vm.toString(tokens));
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), vm.toString(tokens / 1e18));
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), vm.toString(address(token)));
        assertEq(vm.parseJsonString(json, ".attributes[5].value"), "777777");
        assertEq(vm.parseJsonString(json, ".attributes[6].value"), "1800000000");

        string memory image = vm.parseJsonString(json, ".image");
        assertTrue(_startsWith(image, "data:image/svg+xml;base64,"));
        string memory svg = string(Base64Decoder.decodeDataUri(image));
        assertTrue(_startsWith(svg, "<svg"));
        assertTrue(_contains(svg, "Swap Receipt #1"));
        assertTrue(_contains(svg, "0.123456 ETH"));
        assertTrue(_contains(svg, vm.toString(tokens / 1e18)));
        assertTrue(_contains(svg, vm.toString(address(token))));
        assertTrue(_contains(svg, "Block 777777"));
    }

    function test_tokenURIFormatsSmallAndLargeAmounts() public {
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams(true, -1, MIN_PRICE_LIMIT),
            toBalanceDelta(-int128(int256(MIN)), 5),
            hookDataFor(alice)
        );
        string memory json = string(Base64Decoder.decodeDataUri(hook.tokenURI(1)));
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "0.001000");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "0");

        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams(true, -1, MIN_PRICE_LIMIT),
            toBalanceDelta(-1_234_567 ether, type(int128).max),
            hookDataFor(alice)
        );
        json = string(Base64Decoder.decodeDataUri(hook.tokenURI(2)));
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "1234567.000000");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), vm.toString(uint256(uint128(type(int128).max))));
    }

    function test_tokenURIRevertsForUnknownIds() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        hook.tokenURI(1);
        buyExactIn(alice, MIN, hookDataFor(alice));
        hook.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        hook.tokenURI(2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        hook.tokenURI(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Soulbound
    // ---------------------------------------------------------------------------------------------

    function _mintTo(address who) internal returns (uint256 id) {
        buyExactIn(who, MIN, hookDataFor(who));
        id = hook.totalMinted();
        assertEq(hook.ownerOf(id), who);
    }

    function test_transferFromReverts() public {
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.transferFrom(alice, bob, id);
        // From a stranger too, and with Soulbound rather than an authorisation error.
        vm.prank(bob);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.transferFrom(alice, bob, id);
        assertEq(hook.ownerOf(id), alice);
    }

    function test_safeTransferFromReverts() public {
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.safeTransferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.safeTransferFrom(alice, bob, id, "data");
        assertEq(hook.ownerOf(id), alice);
    }

    function test_transferToSelfReverts() public {
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.transferFrom(alice, alice, id);
    }

    function test_approveReverts() public {
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.approve(bob, id);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.approve(address(0), id);
        assertEq(hook.getApproved(id), address(0));
    }

    function test_setApprovalForAllReverts() public {
        _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.setApprovalForAll(bob, true);
        vm.prank(alice);
        vm.expectRevert(SwapReceiptHook.Soulbound.selector);
        hook.setApprovalForAll(bob, false);
        assertFalse(hook.isApprovedForAll(alice, bob));
    }

    function test_noBurnPath() public {
        uint256 id = _mintTo(alice);
        string[3] memory signatures = ["burn(uint256)", "burn(address,uint256)", "destroy(uint256)"];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(alice);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], id, id));
            assertFalse(ok, signatures[i]);
        }
        assertEq(hook.ownerOf(id), alice);
        assertEq(hook.balanceOf(alice), 1);
        assertEq(hook.totalMinted(), 1);
    }

    function test_noAdminSurface() public {
        string[6] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "setMinimum(uint256)",
            "sweep(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(address(hook).balance, 0);
    }

    function test_hookHoldsNoFundsAndChargesNoFee() public {
        BalanceDelta delta = buyExactIn(alice, 1 ether, hookDataFor(alice));
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(manager).balance, 1 ether, "all ETH went to the pool");
        assertEq(token.balanceOf(alice), abs(delta.amount1()), "the buyer got the full pool output");
    }

    // ---------------------------------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------------------------------

    /// @dev Measured from a contract at the pool manager's position, the way `PoolManager` itself
    /// calls the hook (a plain CALL with the full calldata), so the figure includes call overhead.
    /// Calls issued straight from the test contract carry extra tracer accounting in forge and are
    /// not representative.
    function test_mintingAfterSwapStaysUnder200kGas() public {
        GasProbe probe = new GasProbe();
        bytes memory creationCode =
            abi.encodePacked(type(SwapReceiptHook).creationCode, abi.encode(IPoolManager(address(probe))));
        (, bytes32 salt) = HookMiner.find(address(this), HookFlags.AFTER_SWAP, creationCode);
        SwapReceiptHook probed = new SwapReceiptHook{salt: salt}(IPoolManager(address(probe)));

        SwapParams memory params = SwapParams(true, -1 ether, MIN_PRICE_LIMIT);
        BalanceDelta delta = toBalanceDelta(-1 ether, 1_000_000 ether);
        bytes memory toAlice = abi.encodeCall(IHooks.afterSwap, (address(this), key, params, delta, hookDataFor(alice)));
        bytes memory toBob = abi.encodeCall(IHooks.afterSwap, (address(this), key, params, delta, hookDataFor(bob)));

        // Worst case: the very first mint, where the id counter, both receipt slots, the owner's
        // index slot and both ERC-721 slots are all fresh.
        (uint256 used, bool ok) = probe.callHook(address(probed), toAlice);
        assertTrue(ok);
        assertEq(probed.ownerOf(1), alice);
        assertLt(used, 200_000, "first mint over budget");
        emit log_named_uint("afterSwap gas, first mint ever (new owner)", used);

        (uint256 usedRepeat, bool okRepeat) = probe.callHook(address(probed), toAlice);
        assertTrue(okRepeat);
        assertLt(usedRepeat, used);
        emit log_named_uint("afterSwap gas, repeat mint to the same owner", usedRepeat);

        (uint256 usedNewOwner, bool okNew) = probe.callHook(address(probed), toBob);
        assertTrue(okNew);
        assertLt(usedNewOwner, 200_000);
        assertEq(probed.ownerOf(3), bob);
        emit log_named_uint("afterSwap gas, later mint to a new owner", usedNewOwner);

        // The through-the-manager figure agrees: same order of magnitude on the real pool.
        assertLt(usedNewOwner, used);
    }

    function test_wholeBuyThroughTheRouterFitsComfortably() public {
        uint256 before = gasleft();
        buyExactIn(alice, MIN, hookDataFor(alice));
        uint256 used = before - gasleft();
        assertLt(used, 600_000);
        emit log_named_uint("router swap with a first mint, total gas", used);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory p = bytes(prefix);
        if (a.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (a[i] != p[i]) return false;
        }
        return true;
    }

    function _contains(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory n = bytes(needle);
        if (n.length == 0 || a.length < n.length) return false;
        for (uint256 i = 0; i + n.length <= a.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (a[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
