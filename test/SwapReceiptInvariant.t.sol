// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SwapReceiptHook} from "../src/SwapReceiptHook.sol";
import {LaunchFixture} from "./utils/LaunchFixture.sol";
import {ReceiptHandler} from "./utils/ReceiptHandler.sol";

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwapReceiptInvariantTest is LaunchFixture {
    using TransientStateLibrary for IPoolManager;

    ReceiptHandler internal handler;
    uint256 internal initialPoolTokens;
    uint256 internal factoryRemainder;

    function setUp() public override {
        super.setUp();
        initialPoolTokens = token.balanceOf(address(manager));
        factoryRemainder = token.balanceOf(address(this));
        handler = new ReceiptHandler(swapRouter, token, hook, key);
        // Guarantee nonempty ownership checks and cover each recipient before random sequences.
        for (uint256 i; i < 4; ++i) {
            handler.buyExactIn(0, i, 0);
        }
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ReceiptHandler.buyExactIn.selector;
        selectors[1] = ReceiptHandler.buyExactOut.selector;
        selectors[2] = ReceiptHandler.sellExactIn.selector;
        selectors[3] = ReceiptHandler.attemptSoulbound.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_receiptsMatchEverySettledBuyAndStayImmutable() public view {
        uint256 count = handler.count();
        assertGe(count, 4, "campaign must check real mints");
        assertEq(hook.totalMinted(), count);
        for (uint256 i; i < count; ++i) {
            ReceiptHandler.ExpectedReceipt memory expected = handler.receipt(i);
            SwapReceiptHook.ReceiptData memory actual = hook.receiptOf(i + 1);
            assertEq(hook.ownerOf(i + 1), expected.owner);
            assertEq(hook.getApproved(i + 1), address(0));
            assertEq(actual.ethPaid, expected.ethPaid);
            assertEq(actual.tokensReceived, expected.tokensReceived);
            assertEq(actual.token, address(token));
            assertEq(actual.blockNumber, expected.blockNumber);
            assertEq(actual.timestamp, expected.timestamp);
        }
        uint256 balances;
        for (uint256 i; i < 4; ++i) {
            address owner = handler.recipients(i);
            uint256[] memory expectedIds = handler.ids(owner);
            assertEq(hook.receiptsOf(owner, 0, type(uint256).max), expectedIds);
            assertEq(hook.balanceOf(owner), expectedIds.length);
            balances += hook.balanceOf(owner);
        }
        assertEq(balances, count, "no duplicated or unindexed ids");
        assertEq(hook.balanceOf(address(swapRouter)), 0, "router must never receive a fallback receipt");
    }

    function invariant_swapsSettleAndHookNeverRetainsFunds() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(pm.currencyDelta(address(swapRouter), key.currency1), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(swapRouter).balance, 0);
        assertEq(token.balanceOf(address(swapRouter)), 0);
        assertEq(int256(address(manager).balance), handler.netEthPaid());
        assertEq(int256(initialPoolTokens) - int256(token.balanceOf(address(manager))), handler.netTokensReceived());
        assertEq(
            token.balanceOf(address(handler)) + token.balanceOf(address(manager)) + factoryRemainder,
            token.totalSupply()
        );
    }
}
