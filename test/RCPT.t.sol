// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RCPT} from "../src/RCPT.sol";

contract RCPTTest is Test {
    RCPT token;

    function setUp() public {
        token = new RCPT();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Receipts");
        assertEq(token.symbol(), "RCPT");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether);
    }

    function test_deployerIsWhoeverCallsTheConstructor() public {
        vm.prank(address(0xFAC7));
        RCPT other = new RCPT();
        assertEq(other.balanceOf(address(0xFAC7)), other.totalSupply());
        assertEq(other.balanceOf(address(this)), 0);
    }

    function test_noMintOrAdminEntryPoint() public {
        uint256 supply = token.totalSupply();
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), supply);
    }

    function test_transferMovesExactly() public {
        assertTrue(token.transfer(address(0xCAFE), 123 ether));
        assertEq(token.balanceOf(address(0xCAFE)), 123 ether);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether - 123 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_transferFromRespectsAllowance() public {
        token.approve(address(0xB0B), 5 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert();
        token.transferFrom(address(this), address(0xB0B), 6 ether);
        vm.prank(address(0xB0B));
        assertTrue(token.transferFrom(address(this), address(0xB0B), 5 ether));
        assertEq(token.balanceOf(address(0xB0B)), 5 ether);
    }
}
