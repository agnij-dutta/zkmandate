// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {HonkVerifier, IVerifier} from "../src/HonkVerifier.sol";
import {PrivateMandateRegistry, IERC20Min} from "../src/PrivateMandateRegistry.sol";
import {FeeToken, NoReturnToken, FalseToken, HookToken, Reenterer} from "./mocks/WeirdTokens.sol";

/// Escrow accounting against tokens that do not behave like USDC.
contract TokenHandlingTest is Test {
    IVerifier verifier;
    address alice = makeAddr("alice");

    function setUp() public {
        verifier = IVerifier(address(new HonkVerifier()));
    }

    function _registry(address token) internal returns (PrivateMandateRegistry) {
        return new PrivateMandateRegistry(verifier, IERC20Min(token));
    }

    /// Credits what actually arrived, so the pooled escrow stays solvent.
    function test_FeeOnTransferCreditsReceivedAmount() public {
        FeeToken t = new FeeToken();
        PrivateMandateRegistry reg = _registry(address(t));
        t.mint(alice, 100e6);
        vm.prank(alice);
        reg.deposit(100e6);
        assertEq(reg.escrowOf(alice), 99e6);
        assertEq(t.balanceOf(address(reg)), 99e6);
        vm.prank(alice);
        reg.withdraw(99e6);
        assertEq(t.balanceOf(address(reg)), 0);
    }

    function test_NoReturnValueTokenWorks() public {
        NoReturnToken t = new NoReturnToken();
        PrivateMandateRegistry reg = _registry(address(t));
        t.mint(alice, 5e6);
        vm.startPrank(alice);
        reg.deposit(5e6);
        reg.withdraw(5e6);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), 5e6);
    }

    function test_RevertWhen_TokenReturnsFalse() public {
        PrivateMandateRegistry reg = _registry(address(new FalseToken()));
        vm.prank(alice);
        vm.expectRevert(PrivateMandateRegistry.TransferFailed.selector);
        reg.deposit(1);
    }

    /// Without the guard, re-entering deposit from a token hook would credit the
    /// inner deposit twice (once itself, once in the outer balance delta).
    function test_ReentrantDepositIsBlocked() public {
        HookToken t = new HookToken();
        PrivateMandateRegistry reg = _registry(address(t));
        Reenterer r = new Reenterer();
        t.mint(address(r), 200e6);
        t.setHook(address(r), abi.encodeCall(Reenterer.call, (address(reg), abi.encodeCall(reg.deposit, (100e6)))));
        r.call(address(reg), abi.encodeCall(reg.deposit, (100e6)));
        assertTrue(t.reentered());
        assertFalse(t.reentrySucceeded());
        assertEq(reg.escrowOf(address(r)), 100e6);
        assertEq(t.balanceOf(address(reg)), 100e6);
    }

    function test_ReentrantWithdrawIsBlocked() public {
        HookToken t = new HookToken();
        PrivateMandateRegistry reg = _registry(address(t));
        Reenterer r = new Reenterer();
        t.mint(address(r), 100e6);
        r.call(address(reg), abi.encodeCall(reg.deposit, (100e6)));
        t.setHook(address(r), abi.encodeCall(Reenterer.call, (address(reg), abi.encodeCall(reg.withdraw, (10e6)))));
        r.call(address(reg), abi.encodeCall(reg.withdraw, (10e6)));
        assertTrue(t.reentered());
        assertFalse(t.reentrySucceeded());
        assertEq(reg.escrowOf(address(r)), 90e6);
    }
}
