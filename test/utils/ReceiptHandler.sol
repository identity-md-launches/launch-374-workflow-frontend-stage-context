// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RCPT} from "../../src/RCPT.sol";
import {SwapReceiptHook} from "../../src/SwapReceiptHook.sol";

contract ReceiptNonReceiver {}

contract ReceiptRejectingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("receipt mint must never call the recipient");
    }
}

/// @dev Ghost records come from settled balance changes, never from the hook's receipt views.
/// All actions go through the real manager and router. Unexpected reverts fail the campaign.
contract ReceiptHandler is Test {
    struct ExpectedReceipt {
        address owner;
        uint256 ethPaid;
        uint256 tokensReceived;
        uint256 blockNumber;
        uint256 timestamp;
    }

    PoolSwapTest public immutable router;
    RCPT public immutable token;
    SwapReceiptHook public immutable hook;
    PoolKey internal key;
    address[4] public recipients;
    ExpectedReceipt[] internal expected;
    int256 public netEthPaid;
    int256 public netTokensReceived;
    uint256 public successfulSwaps;
    mapping(address => uint256[]) internal owned;

    constructor(PoolSwapTest router_, RCPT token_, SwapReceiptHook hook_, PoolKey memory key_) {
        router = router_;
        token = token_;
        hook = hook_;
        key = key_;
        recipients = [
            address(0xA11CE), address(0xB0B), address(new ReceiptNonReceiver()), address(new ReceiptRejectingReceiver())
        ];
        token.approve(address(router), type(uint256).max);
    }

    receive() external payable {}

    function count() external view returns (uint256) {
        return expected.length;
    }

    function receipt(uint256 index) external view returns (ExpectedReceipt memory) {
        return expected[index];
    }

    function ids(address owner) external view returns (uint256[] memory) {
        return owned[owner];
    }

    function buyExactIn(uint256 size, uint256 recipientSeed, uint8 dataMode) external {
        // Frequently visit both sides of the threshold as well as larger buys.
        uint256 amount = size % 4 == 0 ? 0.001 ether : size % 4 == 1 ? 0.001 ether - 1 : bound(size, 1, 2 ether);
        _swap(true, -int256(amount), amount, recipientSeed, dataMode);
    }

    function buyExactOut(uint256 size, uint256 recipientSeed, uint8 dataMode) external {
        uint256 output = bound(size, 1, 10_000 ether);
        _swap(true, int256(output), 1 ether, recipientSeed, dataMode);
    }

    function sellExactIn(uint256 size, uint256 recipientSeed, uint8 dataMode) external {
        // Bootstrap inventory through a real uncredited buy if needed; do not discard an action.
        if (token.balanceOf(address(this)) < 2) _swap(true, -int256(1 ether), 1 ether, 0, 2);
        uint256 amount = bound(size, 1, token.balanceOf(address(this)) / 2);
        _swap(false, -int256(amount), 0, recipientSeed, dataMode);
    }

    function attemptSoulbound(uint256 idSeed, uint8 path, bool outsider) external {
        uint256 id = idSeed % expected.length + 1;
        address owner = expected[id - 1].owner;
        address to = address(0xCAFE);
        bytes memory callData;
        path %= 7;
        if (path == 0) {
            callData = abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, to, id);
        } else if (path == 1) {
            callData = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", owner, to, id);
        } else if (path == 2) {
            callData =
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", owner, to, id, hex"1234");
        } else if (path == 3) {
            callData = abi.encodeCall(hook.approve, (to, id));
        } else if (path == 4) {
            callData = abi.encodeCall(hook.approve, (address(0), id));
        } else {
            callData = abi.encodeCall(hook.setApprovalForAll, (to, path == 5));
        }
        vm.prank(outsider ? to : owner);
        (bool ok, bytes memory reason) = address(hook).call(callData);
        assertFalse(ok, "soulbound operation succeeded");
        assertEq(reason, abi.encodeWithSelector(SwapReceiptHook.Soulbound.selector));
        assertEq(hook.ownerOf(id), owner);
        assertEq(hook.getApproved(id), address(0));
        assertFalse(hook.isApprovedForAll(owner, to));
    }

    function _data(uint256 seed, uint8 mode) internal view returns (bytes memory data, address credited) {
        address recipient = recipients[seed % recipients.length];
        mode %= 6;
        if (mode <= 1) return (abi.encode(recipient), recipient);
        if (mode == 2) return (bytes(""), address(0));
        if (mode == 3) return (abi.encode(address(0)), address(0));
        if (mode == 4) return (abi.encodePacked(recipient), address(0));
        return (abi.encode(uint256(uint160(recipient)) | (uint256(1) << 160)), address(0));
    }

    function _swap(bool buy, int256 specified, uint256 budget, uint256 recipientSeed, uint8 dataMode) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        (bytes memory data, address credited) = _data(recipientSeed, dataMode);
        vm.deal(address(this), address(this).balance + budget);
        uint256 ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        BalanceDelta delta = router.swap{value: budget}(
            key,
            SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
        int256 ethPaid = int256(ethBefore) - int256(address(this).balance);
        int256 tokensReceived = int256(token.balanceOf(address(this))) - int256(tokensBefore);
        assertEq(ethPaid, -int256(delta.amount0()), "ETH settlement differs from pool delta");
        assertEq(tokensReceived, int256(delta.amount1()), "token settlement differs from pool delta");
        netEthPaid += ethPaid;
        netTokensReceived += tokensReceived;
        ++successfulSwaps;
        if (buy && ethPaid >= 0.001 ether && credited != address(0)) {
            assertGe(tokensReceived, 0);
            expected.push(
                ExpectedReceipt(credited, uint256(ethPaid), uint256(tokensReceived), block.number, block.timestamp)
            );
            owned[credited].push(expected.length);
        }
        assertEq(hook.totalMinted(), expected.length, "receipt eligibility differs from settlement");
    }
}
