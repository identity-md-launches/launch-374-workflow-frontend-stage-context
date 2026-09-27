// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SwapReceiptHook
/// @notice A Uniswap v4 `afterSwap` hook that mints a soulbound ERC-721 receipt for every buy of at
/// least 0.001 ETH on a native-ETH pool, credited to the address the swapper names in `hookData`.
///
/// @dev Behaviour, in full:
///
/// - Permissions: exactly `afterSwap`. The address must carry the `AFTER_SWAP` bit (0x0040) and no
///   other permission bit; the constructor calls `Hooks.validateHookPermissions` and reverts
///   otherwise. No other callback is enabled, so pool initialisation, liquidity changes and donations
///   never reach this contract and can never be reverted by it.
/// - Deltas: the hook never returns a delta (`afterSwapReturnDelta` is off), never takes, settles or
///   holds funds and charges no fee. Every pool on it gets a zero delta from `afterSwap`.
/// - Which swaps mint: `params.zeroForOne == true` (ETH in, token out) on a pool whose `currency0`
///   is native ETH, where the ETH the pool actually settled, `|delta.amount0()|`, is at least
///   `MIN_ETH_PAID`. Exact-in and exact-out swaps are measured the same way, so a partial fill or an
///   exact-out buy is judged by what was really paid. Sells (`oneForZero`), dust buys, buys with no
///   valid `hookData` address, and any swap on a pool whose `currency0` is not native ETH mint
///   nothing and have no other effect.
/// - Identity: the credited address is the 32-byte `hookData` word read as an address when
///   `hookData` is exactly 32 bytes, non-zero and fits in 160 bits (the same value
///   `abi.decode(hookData, (address))` would produce); anything else credits nobody. There is no
///   fallback to the `sender` argument: that is a router, which could never claim a receipt.
/// - **`hookData` is not authenticated.** The pool manager passes it through from whoever called
///   `swap`. Anyone can therefore mint a receipt to any address by paying for a qualifying buy; a
///   receipt proves that a buy of the recorded size happened and named that address, not that the
///   address made the buy. Consumers must treat receipts accordingly.
/// - Minting can never revert a buy. `_mint` is used rather than `_safeMint`, so a contract
///   recipient without `onERC721Received` still gets its receipt and can never block the swap; ids
///   start at 1 and rise by one, so no id collides; no callback is made to any address.
/// - Receipts are soulbound. `_update` only admits mints, so `transferFrom` and both
///   `safeTransferFrom` variants revert. `_approve` and `_setApprovalForAll` revert, so `approve` and
///   `setApprovalForAll` revert. There is no burn.
/// - There is no owner, admin, setter, pause, upgrade or sweep. Every threshold is a source constant.
///   The only constructor argument is the pool manager, and every callback requires
///   `msg.sender == poolManager`.
contract SwapReceiptHook is IHooks, ERC721 {
    using Strings for uint256;
    using Strings for address;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice What one receipt records.
    /// @param ethPaid ETH the pool settled for the buy, in wei (`|delta.amount0()|`).
    /// @param tokensReceived Tokens the buyer received, in the token's smallest unit (`|delta.amount1()|`).
    /// @param token The pool's `currency1`, the token that was bought.
    /// @param blockNumber Block in which the buy landed.
    /// @param timestamp Timestamp of that block.
    struct ReceiptData {
        uint128 ethPaid;
        uint128 tokensReceived;
        address token;
        uint48 blockNumber;
        uint48 timestamp;
    }

    /// @notice Smallest buy, measured as the ETH the pool settled, that mints a receipt.
    uint256 public constant MIN_ETH_PAID = 0.001 ether;

    /// @notice The only address allowed to drive a callback.
    IPoolManager public immutable poolManager;

    uint256 private _totalMinted;
    mapping(uint256 id => ReceiptData) private _receipts;
    /// @dev Per-owner id list. Receipts never leave an owner, so `balanceOf(owner)` is exactly the
    /// list length; indexing by it saves a separate length slot on every mint.
    mapping(address owner => mapping(uint256 index => uint256 id)) private _ownedIds;

    /// @notice Emitted once per minted receipt.
    event Receipt(
        uint256 indexed id,
        address indexed owner,
        PoolId indexed poolId,
        uint128 ethPaid,
        uint128 tokensReceived,
        uint256 blockNumber
    );

    /// @dev A callback was driven by something other than the pool manager.
    error NotPoolManager();
    /// @dev A callback this hook does not enable was called anyway.
    error HookNotImplemented();
    /// @dev A transfer, approval or burn was attempted; receipts admit only mints.
    error Soulbound();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The Uniswap v4 pool manager this hook serves.
    constructor(IPoolManager _poolManager) ERC721("Swap Receipts", "SWAPRCPT") {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice Only `afterSwap` is enabled. The deployed address must agree (low bits 0x0040).
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // The one callback
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Mints at most one receipt and returns a zero delta on every path. Nothing in here can
    /// revert for a well-formed call from the pool manager: the only arithmetic is a negation of
    /// an `int128` widened to `int256`, ids are a counter, and `_mint` makes no external call.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Only buys (ETH in) on a native-ETH pool are receipts. A pool whose currency0 is another
        // token gets nothing from this hook beyond a zero delta.
        if (!params.zeroForOne || !key.currency0.isAddressZero()) {
            return (IHooks.afterSwap.selector, 0);
        }

        // ETH paid is what the pool settled, whatever the swap specified. For a buy amount0 is
        // negative from the swapper's side; anything else is not a buy that paid.
        int256 amount0 = int256(delta.amount0());
        if (amount0 >= 0) return (IHooks.afterSwap.selector, 0);
        uint256 ethPaid = uint256(-amount0);
        if (ethPaid < MIN_ETH_PAID) return (IHooks.afterSwap.selector, 0);

        address to = _recipient(hookData);
        if (to == address(0)) return (IHooks.afterSwap.selector, 0);

        int256 amount1 = int256(delta.amount1());
        uint256 tokensReceived = amount1 < 0 ? uint256(-amount1) : uint256(amount1);

        uint256 id = ++_totalMinted;
        _receipts[id] = ReceiptData({
            ethPaid: uint128(ethPaid),
            tokensReceived: uint128(tokensReceived),
            token: Currency.unwrap(key.currency1),
            blockNumber: uint48(block.number),
            timestamp: uint48(block.timestamp)
        });
        _ownedIds[to][balanceOf(to)] = id;
        _mint(to, id);

        emit Receipt(id, to, key.toId(), uint128(ethPaid), uint128(tokensReceived), block.number);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev The address to credit, or zero. Reads the word by hand rather than `abi.decode` so a
    /// word with dirty upper bytes credits nobody instead of reverting the swap.
    function _recipient(bytes calldata hookData) private pure returns (address) {
        if (hookData.length != 32) return address(0);
        uint256 raw = uint256(bytes32(hookData));
        if (raw == 0 || raw > type(uint160).max) return address(0);
        return address(uint160(raw));
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Number of receipts minted so far; also the highest id in existence.
    function totalMinted() external view returns (uint256) {
        return _totalMinted;
    }

    /// @notice The record behind receipt `id`. Reverts for an id that was never minted.
    function receiptOf(uint256 id) external view returns (ReceiptData memory) {
        _requireOwned(id);
        return _receipts[id];
    }

    /// @notice A page of `owner`'s receipt ids, oldest first: ids at positions
    /// `[offset, offset + limit)` of the owner's list, clamped to what exists.
    function receiptsOf(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        mapping(uint256 index => uint256 id) storage all = _ownedIds[owner];
        uint256 total = balanceOf(owner);
        if (offset >= total) return ids;
        uint256 end = total - offset > limit ? offset + limit : total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = all[i];
        }
    }

    /// @notice Base64 data URI of on-chain JSON metadata with an SVG image. Reverts for an id that
    /// was never minted.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        ReceiptData memory r = _receipts[id];

        string memory idStr = id.toString();
        string memory eth = _formatEth(r.ethPaid);
        string memory whole = (uint256(r.tokensReceived) / 1e18).toString();
        string memory token = r.token.toChecksumHexString();
        string memory blockStr = uint256(r.blockNumber).toString();

        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 420 420" width="420" height="420">',
            '<rect width="420" height="420" rx="24" fill="#0b0d12"/>',
            '<rect x="16" y="16" width="388" height="388" rx="16" fill="none" stroke="#3d7eff" stroke-width="2"/>',
            '<text x="32" y="72" fill="#ffffff" font-family="monospace" font-size="30">Swap Receipt #',
            idStr,
            "</text>",
            '<text x="32" y="140" fill="#9db4ff" font-family="monospace" font-size="18">ETH paid</text>',
            '<text x="32" y="168" fill="#ffffff" font-family="monospace" font-size="22">',
            eth,
            " ETH</text>",
            '<text x="32" y="216" fill="#9db4ff" font-family="monospace" font-size="18">Tokens received</text>',
            '<text x="32" y="244" fill="#ffffff" font-family="monospace" font-size="22">',
            whole,
            "</text>",
            '<text x="32" y="292" fill="#9db4ff" font-family="monospace" font-size="18">Token</text>',
            '<text x="32" y="316" fill="#ffffff" font-family="monospace" font-size="13">',
            token,
            "</text>",
            '<text x="32" y="364" fill="#9db4ff" font-family="monospace" font-size="18">Block ',
            blockStr,
            "</text></svg>"
        );

        string memory json = string.concat(
            '{"name":"Swap Receipt #',
            idStr,
            '","description":"Soulbound receipt for a buy of at least 0.001 ETH on a Uniswap v4 pool served by SwapReceiptHook. hookData is unauthenticated: the receipt proves a buy of this size named this address, not that the address made it.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[',
            '{"trait_type":"ETH paid (wei)","value":"',
            uint256(r.ethPaid).toString(),
            '"},{"trait_type":"ETH paid","value":"',
            eth,
            '"},{"trait_type":"Tokens received (raw)","value":"',
            uint256(r.tokensReceived).toString(),
            '"},{"trait_type":"Tokens received","value":"',
            whole,
            '"},{"trait_type":"Token","value":"',
            token,
            '"},{"trait_type":"Block","value":"',
            blockStr,
            '"},{"trait_type":"Timestamp","value":"',
            uint256(r.timestamp).toString(),
            '"}]}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Wei rendered as ETH with exactly six decimals, truncated.
    function _formatEth(uint256 wei_) private pure returns (string memory) {
        uint256 whole = wei_ / 1e18;
        uint256 micro = (wei_ % 1e18) / 1e12;
        bytes memory frac = bytes(micro.toString());
        bytes memory padded = new bytes(6);
        uint256 lead = 6 - frac.length;
        for (uint256 i = 0; i < 6; ++i) {
            padded[i] = i < lead ? bytes1("0") : frac[i - lead];
        }
        return string.concat(whole.toString(), ".", string(padded));
    }

    // ---------------------------------------------------------------------------------------------
    // Soulbound
    // ---------------------------------------------------------------------------------------------

    /// @dev Every ERC-721 state change funnels through here. Only a mint (no current owner) passes;
    /// a transfer or a burn of an existing receipt reverts before any authorisation check.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    /// @dev `approve` routes here; receipts cannot be approved.
    function _approve(address, uint256, address, bool) internal pure override {
        revert Soulbound();
    }

    /// @dev `setApprovalForAll` routes here; receipts cannot have operators.
    function _setApprovalForAll(address, address, bool) internal pure override {
        revert Soulbound();
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not enable. The address carries no bit for them, so the pool manager
    // never calls them; they exist only to satisfy IHooks and refuse anything that reaches them.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
