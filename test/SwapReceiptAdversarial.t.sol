// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwapReceiptHook} from "../src/SwapReceiptHook.sol";
import {LaunchFixture} from "./utils/LaunchFixture.sol";
import {Base64Decoder} from "./utils/Base64Decoder.sol";
import {ReceiptNonReceiver, ReceiptRejectingReceiver} from "./utils/ReceiptHandler.sol";

contract SwapReceiptAdversarialTest is LaunchFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant MIN = 0.001 ether;

    function test_exactOutFirstBuyAtEachThresholdBoundary() public {
        assertEq(_exactOutAtOpeningPrice(MIN - 1), MIN - 1);
        assertEq(_exactOutAtOpeningPrice(MIN), MIN);
    }

    function testFuzz_exactOutThresholdUsesPaymentNotOutputOrBudget(uint256 paid) public {
        _exactOutAtOpeningPrice(bound(paid, MIN - 1_000, MIN + 1_000));
    }

    function _exactOutAtOpeningPrice(uint256 paid) internal returns (uint256 settled) {
        uint256 snapshot = vm.snapshotState();
        assertEq(address(manager).balance, 0, "first buy starts with token-only liquidity");
        BalanceDelta quote = buyExactIn(alice, paid, "");
        assertTrue(vm.revertToState(snapshot));
        uint256 tokensOut = abs(quote.amount1());
        uint256 ethBefore = alice.balance;
        BalanceDelta delta = buyExactOut(alice, tokensOut, 1 ether, hookDataFor(bob));
        settled = ethBefore + 1 ether - alice.balance;
        // Exact-in fee rounding can consume one more wei for the same output. Eligibility must
        // use this exact-out settlement, not the payment used to obtain the output quote.
        assertGt(settled, 0);
        assertLt(settled, 1 ether);
        assertEq(abs(delta.amount0()), settled);
        assertEq(abs(delta.amount1()), tokensOut);
        assertEq(address(manager).balance, settled);
        assertEq(token.balanceOf(alice), tokensOut);
        assertEq(hook.totalMinted(), settled >= MIN ? 1 : 0);
        assertEq(hook.balanceOf(address(swapRouter)), 0);
        if (settled >= MIN) {
            assertEq(hook.ownerOf(1), bob);
            assertEq(hook.receiptOf(1).ethPaid, settled);
            assertEq(hook.receiptOf(1).tokensReceived, tokensOut);
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function testFuzz_partialExactOutUsesSettledEth(uint256 divisorSeed) public {
        (uint160 opening,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint256 divisor = bound(divisorSeed, 10_000, 100_000_000);
        uint160 limit = opening - uint160(uint256(opening) / divisor);
        uint256 budget = 1 ether;
        uint256 requested = 10_000_000 ether;
        vm.deal(alice, budget);
        vm.prank(alice);
        BalanceDelta delta = swapRouter.swap{value: budget}(
            key, SwapParams(true, int256(requested), limit), PoolSwapTest.TestSettings(false, false), hookDataFor(bob)
        );
        uint256 paid = budget - alice.balance;
        uint256 received = token.balanceOf(alice);
        assertGt(paid, 0);
        assertLt(paid, budget);
        assertGt(received, 0);
        assertLt(received, requested, "must exercise a partial exact-out fill");
        assertEq(abs(delta.amount0()), paid);
        assertEq(abs(delta.amount1()), received);
        assertEq(hook.totalMinted(), paid >= MIN ? 1 : 0);
        if (paid >= MIN) {
            assertEq(hook.receiptOf(1).ethPaid, paid);
            assertEq(hook.receiptOf(1).tokensReceived, received);
        }
        (uint160 finalPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(finalPrice, limit);
    }

    function testFuzz_arbitraryHookDataCannotBlockAQualifyingBuy(bytes memory data) public {
        BalanceDelta delta = buyExactIn(alice, MIN, data);
        assertEq(abs(delta.amount0()), MIN);
        assertGt(delta.amount1(), 0);
        address recipient;
        if (data.length == 32) {
            uint256 word = abi.decode(data, (uint256));
            if (word != 0 && word <= type(uint160).max) recipient = address(uint160(word));
        }
        assertEq(hook.totalMinted(), recipient == address(0) ? 0 : 1);
        if (recipient != address(0)) assertEq(hook.ownerOf(1), recipient);
        assertEq(hook.balanceOf(address(swapRouter)), recipient == address(swapRouter) ? 1 : 0);
    }

    function testFuzz_dirtyAddressWordCannotBlockOrCreditBuy(uint96 upper, address recipient) public {
        upper = uint96(bound(upper, 1, type(uint96).max));
        bytes memory data = abi.encode((uint256(upper) << 160) | uint160(recipient));
        BalanceDelta delta = buyExactIn(alice, MIN, data);
        assertEq(abs(delta.amount0()), MIN);
        assertEq(hook.totalMinted(), 0);
    }

    function testFuzz_sellsInBothModesNeverMint(uint256 sellSize) public {
        buyExactIn(alice, 1 ether, hookDataFor(alice));
        uint256 tokensIn = bound(sellSize, 1 ether, token.balanceOf(alice) / 2);
        uint256 snapshot = vm.snapshotState();
        uint256 ethBefore = alice.balance;
        uint256 tokensBefore = token.balanceOf(alice);
        BalanceDelta exactIn = sellExactIn(alice, tokensIn, hookDataFor(bob));
        uint256 ethOut = abs(exactIn.amount0());
        assertGt(ethOut, 0);
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(tokensBefore - token.balanceOf(alice), tokensIn);
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.balanceOf(bob), 0);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        BalanceDelta exactOut = sellExactOut(alice, ethOut, tokensBefore, hookDataFor(bob));
        assertEq(abs(exactOut.amount0()), ethOut);
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(tokensBefore - token.balanceOf(alice), abs(exactOut.amount1()));
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.balanceOf(bob), 0);
        assertEq(hook.ownerOf(1), alice);
        assertEq(hook.receiptOf(1).ethPaid, 1 ether);
    }

    function testFuzz_paginationHandlesUnboundedOffsetsAndLimits(uint256 offset, uint256 limit) public {
        for (uint256 i; i < 5; ++i) {
            buyExactIn(alice, MIN, hookDataFor(i % 2 == 0 ? alice : bob));
        }
        uint256[] memory page = hook.receiptsOf(alice, offset, limit);
        uint256 length = offset >= 3 ? 0 : (limit < 3 - offset ? limit : 3 - offset);
        assertEq(page.length, length);
        for (uint256 i; i < page.length; ++i) {
            assertEq(page[i], 1 + 2 * (offset + i));
        }
        assertEq(hook.receiptsOf(alice, 1, type(uint256).max).length, 2);
        assertEq(hook.receiptsOf(alice, type(uint256).max, type(uint256).max).length, 0);
    }

    function test_nonReceiverAndRevertingReceiverNeverBlockExactOutBuys() public {
        address[2] memory recipients = [address(new ReceiptNonReceiver()), address(new ReceiptRejectingReceiver())];
        for (uint256 i; i < recipients.length; ++i) {
            vm.expectCall(
                recipients[i],
                abi.encodeWithSelector(bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))),
                uint64(0)
            );
            BalanceDelta delta = buyExactOut(alice, 5_000 ether, 1 ether, hookDataFor(recipients[i]));
            assertGe(abs(delta.amount0()), MIN);
            assertEq(hook.ownerOf(i + 1), recipients[i]);
            assertEq(hook.balanceOf(recipients[i]), 1);
            assertEq(hook.receiptsOf(recipients[i], 0, 1)[0], i + 1);
        }
    }

    function test_unfundedExactOutRollsBackReceiptAndPoolThenCanRetry() public {
        (uint160 opening,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint256 poolTokensBefore = token.balanceOf(address(manager));
        // This output costs more than MIN; afterSwap executes before the router attempts payment.
        // Use a low-level router call so the failure must come from the complete settlement path.
        bytes memory callData = abi.encodeCall(
            swapRouter.swap,
            (
                key,
                SwapParams(true, int256(5_000 ether), MIN_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                hookDataFor(alice)
            )
        );
        vm.prank(alice);
        (bool ok,) = address(swapRouter).call(callData);
        assertFalse(ok, "an unfunded exact-out must fail");
        assertEq(hook.totalMinted(), 0, "reverted swaps must not leave receipts");
        assertEq(hook.balanceOf(alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(manager)), poolTokensBefore);
        assertEq(address(manager).balance, 0);
        (uint160 afterFailure,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(afterFailure, opening);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        hook.receiptOf(1);
        buyExactOut(alice, 5_000 ether, 1 ether, hookDataFor(alice));
        assertEq(hook.totalMinted(), 1, "retry must still start at id one");
        assertEq(hook.ownerOf(1), alice);
    }

    function testFuzz_allSoulboundEntrypointsKeepOwnerAndApprovals(
        address destination,
        bytes memory data,
        bool outsider
    ) public {
        buyExactIn(alice, MIN, hookDataFor(alice));
        bytes[] memory attempts = new bytes[](7);
        attempts[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, destination, 1);
        attempts[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, destination, 1);
        attempts[2] =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, destination, 1, data);
        attempts[3] = abi.encodeCall(hook.approve, (destination, 1));
        attempts[4] = abi.encodeCall(hook.approve, (address(0), 1));
        attempts[5] = abi.encodeCall(hook.setApprovalForAll, (destination, true));
        attempts[6] = abi.encodeCall(hook.setApprovalForAll, (destination, false));
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(outsider ? bob : alice);
            (bool ok,) = address(hook).call(attempts[i]);
            assertFalse(ok, "a soulbound entrypoint succeeded");
            assertEq(hook.ownerOf(1), alice);
            assertEq(hook.balanceOf(alice), 1);
            assertEq(hook.getApproved(1), address(0));
            assertFalse(hook.isApprovedForAll(alice, destination));
        }
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.receiptsOf(alice, 0, type(uint256).max)[0], 1);
    }

    function testFuzz_metadataRoundTripsSettledNumbers(uint256 input, uint48 height, uint48 time) public {
        uint256 paid = bound(input, MIN, 20 ether);
        vm.roll(height);
        vm.warp(time);
        BalanceDelta delta = buyExactIn(alice, paid, hookDataFor(bob));
        SwapReceiptHook.ReceiptData memory r = hook.receiptOf(1);
        string memory json = string(Base64Decoder.decodeDataUri(hook.tokenURI(1)));
        assertEq(vm.parseJsonString(json, ".name"), "Swap Receipt #1");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[0].value")), paid);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[0].value")), r.ethPaid);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[2].value")), abs(delta.amount1()));
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[2].value")), r.tokensReceived);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[3].value")), r.tokensReceived / 1e18);
        assertEq(vm.parseAddress(vm.parseJsonString(json, ".attributes[4].value")), address(token));
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[5].value")), height);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".attributes[6].value")), time);
        assertEq(r.blockNumber, height);
        assertEq(r.timestamp, time);
        // Independently check six-decimal truncation, including leading zeros and whole ETH.
        uint256 micros = paid / 1e12;
        string memory fractional = vm.toString(1_000_000 + micros % 1_000_000);
        bytes memory sixDigits = new bytes(6);
        for (uint256 i; i < 6; ++i) {
            sixDigits[i] = bytes(fractional)[i + 1];
        }
        assertEq(
            vm.parseJsonString(json, ".attributes[1].value"),
            string.concat(vm.toString(micros / 1_000_000), ".", string(sixDigits))
        );
    }

    function test_coldMintCallbackFromRealSwapFits200kGas() public {
        // Capture the exact calldata issued by the real manager, then replay it against the
        // pre-swap hook state with cold storage. Only the replay impersonates the manager; the
        // manager and mined hook are not replaced, subclassed or etched for this measurement.
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        buyExactIn(alice, MIN, hookDataFor(bob));
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        bytes memory callback;
        for (uint256 i; i < accesses.length; ++i) {
            if (
                accesses[i].kind == VmSafe.AccountAccessKind.Call && accesses[i].accessor == address(manager)
                    && accesses[i].account == address(hook) && bytes4(accesses[i].data) == IHooks.afterSwap.selector
            ) {
                assertEq(callback.length, 0, "expected exactly one afterSwap");
                callback = accesses[i].data;
            }
        }
        assertGt(callback.length, 4, "real manager must invoke afterSwap");
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.cool(address(hook));
        vm.prank(address(manager));
        (bool ok, bytes memory result) = address(hook).call{gas: 199_999}(callback);
        Vm.Gas memory gas = vm.lastCallGas();
        assertTrue(ok, "cold first mint exceeds callback gas budget");
        (bytes4 selector, int128 hookDelta) = abi.decode(result, (bytes4, int128));
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        assertLt(gas.gasTotalUsed, 200_000);
        assertEq(hook.totalMinted(), 1);
        assertEq(hook.ownerOf(1), bob);
        emit log_named_uint("cold afterSwap replay of real manager calldata", gas.gasTotalUsed);
    }
}
