// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {HonkVerifier, IVerifier} from "../src/HonkVerifier.sol";
import {PrivateMandateRegistry, IERC20Min} from "../src/PrivateMandateRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Replays real UltraHonk proofs produced by `npm run fixtures` (sdk/scripts/fixtures.ts).
/// Mandate (private, never on-chain): 5 USDC/tx, 12 USDC total, 3 allowed payees.
contract PrivateMandateRegistryTest is Test {
    struct Pay {
        address payee;
        uint64 amount;
        bytes32 newHead;
        bytes proof;
    }

    MockUSDC usdc;
    HonkVerifier verifier;
    PrivateMandateRegistry reg;

    address principal = makeAddr("principal");
    address agent;
    address mallory = makeAddr("mallory");
    bytes32 mandate;
    bytes32 initialHead;
    uint64 validUntil;
    Pay[3] pays;

    function setUp() public {
        string memory json = vm.readFile("test/fixtures/payments.json");
        address regAddr = vm.parseJsonAddress(json, ".registry");
        agent = vm.parseJsonAddress(json, ".agent");
        mandate = vm.parseJsonBytes32(json, ".mandate");
        initialHead = vm.parseJsonBytes32(json, ".initialHead");
        validUntil = uint64(vm.parseJsonUint(json, ".validUntil"));
        for (uint256 i; i < 3; ++i) {
            string memory k = string.concat(".payments[", vm.toString(i), "]");
            pays[i] = Pay({
                payee: vm.parseJsonAddress(json, string.concat(k, ".payee")),
                amount: uint64(vm.parseJsonUint(json, string.concat(k, ".amount"))),
                newHead: vm.parseJsonBytes32(json, string.concat(k, ".newHead")),
                proof: vm.parseJsonBytes(json, string.concat(k, ".proof"))
            });
        }

        usdc = new MockUSDC();
        verifier = new HonkVerifier();
        // Proofs are bound to (chainid, registry address, mandate), so the
        // registry must live at the address the fixtures were generated for.
        deployCodeTo("PrivateMandateRegistry.sol:PrivateMandateRegistry", abi.encode(verifier, usdc), regAddr);
        reg = PrivateMandateRegistry(regAddr);

        usdc.mint(principal, 100e6);
        vm.startPrank(principal);
        usdc.approve(address(reg), type(uint256).max);
        reg.deposit(50e6);
        reg.createMandate(mandate, initialHead, agent);
        vm.stopPrank();
    }

    function _pay(uint256 i) internal {
        Pay storage p = pays[i];
        vm.prank(agent);
        reg.pay(mandate, p.payee, p.amount, validUntil, p.newHead, p.proof);
    }

    function _head() internal view returns (bytes32 h) {
        (,,, h) = reg.mandates(mandate);
    }

    // ------------------------------------------------------------ happy --

    function test_ValidPayment() public {
        _pay(0);
        assertEq(usdc.balanceOf(pays[0].payee), 4e6);
        assertEq(reg.escrowOf(principal), 46e6);
        assertEq(_head(), pays[0].newHead);
    }

    function test_ThreePaymentsChainTheState() public {
        _pay(0);
        _pay(1);
        _pay(2);
        assertEq(usdc.balanceOf(pays[0].payee), 4e6);
        assertEq(usdc.balanceOf(pays[1].payee), 4e6);
        assertEq(usdc.balanceOf(pays[2].payee), 3e6);
        assertEq(reg.escrowOf(principal), 39e6);
        assertEq(_head(), pays[2].newHead);
    }

    function test_EmitsPaidWithoutRevealingTerms() public {
        vm.expectEmit(true, true, false, true, address(reg));
        emit PrivateMandateRegistry.Paid(mandate, pays[0].payee, 4e6, pays[0].newHead);
        _pay(0);
    }

    // -------------------------------------------------- the five rules --

    /// Proof is for 4 USDC; claiming 6 USDC (over the hidden 5 USDC/tx cap) fails.
    function test_RevertWhen_OverPerTxCap() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[0].payee, 6e6, validUntil, pays[0].newHead, pays[0].proof);
    }

    /// After 4 + 4 USDC, inflating the 3rd payment to 5 USDC would total 13 > 12.
    /// (An honest 4th payment over the cap cannot even be proven: see sdk tests.)
    function test_RevertWhen_OverCumulativeCap() public {
        _pay(0);
        _pay(1);
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[2].payee, 5e6, validUntil, pays[2].newHead, pays[2].proof);
    }

    /// A front-runner or compromised relayer cannot redirect a proven payment.
    function test_RevertWhen_WrongPayee() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, mallory, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_Expired() public {
        vm.warp(uint256(validUntil) + 1);
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.Expired.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    /// Lying about the deadline (extending validUntil) invalidates the proof.
    function test_RevertWhen_ValidUntilExtended() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil + 1, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_ReplayedProof() public {
        _pay(0);
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
        assertEq(usdc.balanceOf(pays[0].payee), 4e6);
    }

    // ------------------------------------------------- extra hardening --

    function test_RevertWhen_OutOfOrder() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[1].payee, pays[1].amount, validUntil, pays[1].newHead, pays[1].proof);
    }

    /// Recording a smaller spend than paid (forged next head) fails.
    function test_RevertWhen_TamperedNewHead() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, initialHead, pays[0].proof);
    }

    function test_RevertWhen_GarbageProof() public {
        bytes memory junk = pays[0].proof;
        junk[100] = bytes1(uint8(junk[100]) ^ 0x01);
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, junk);
    }

    function test_RevertWhen_TruncatedProof() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, hex"00");
    }

    /// Same mandate registered on another registry: proofs do not cross over.
    function test_RevertWhen_ProofReplayedOnOtherRegistry() public {
        PrivateMandateRegistry other = new PrivateMandateRegistry(IVerifier(address(verifier)), IERC20Min(address(usdc)));
        vm.startPrank(principal);
        usdc.approve(address(other), type(uint256).max);
        other.deposit(10e6);
        other.createMandate(mandate, initialHead, agent);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InvalidProof.selector);
        other.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_NotAgent() public {
        vm.prank(mallory);
        vm.expectRevert(PrivateMandateRegistry.NotAgent.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_Revoked() public {
        vm.prank(principal);
        reg.revoke(mandate);
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.Revoked.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_RevokeByStranger() public {
        vm.prank(mallory);
        vm.expectRevert(PrivateMandateRegistry.NotPrincipal.selector);
        reg.revoke(mandate);
    }

    function test_RevertWhen_EscrowDrained() public {
        vm.prank(principal);
        reg.withdraw(50e6);
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.InsufficientEscrow.selector);
        reg.pay(mandate, pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_UnknownMandate() public {
        vm.prank(agent);
        vm.expectRevert(PrivateMandateRegistry.MandateMissing.selector);
        reg.pay(bytes32(uint256(1)), pays[0].payee, pays[0].amount, validUntil, pays[0].newHead, pays[0].proof);
    }

    function test_RevertWhen_DuplicateMandate() public {
        vm.prank(mallory);
        vm.expectRevert(PrivateMandateRegistry.MandateExists.selector);
        reg.createMandate(mandate, initialHead, mallory);
    }

    function test_RevertWhen_NonCanonicalCommitment() public {
        vm.expectRevert(PrivateMandateRegistry.NonCanonical.selector);
        reg.createMandate(bytes32(type(uint256).max), initialHead, agent);
    }

    function test_WithdrawAndOverWithdraw() public {
        vm.startPrank(principal);
        reg.withdraw(20e6);
        assertEq(usdc.balanceOf(principal), 70e6);
        vm.expectRevert(PrivateMandateRegistry.InsufficientEscrow.selector);
        reg.withdraw(31e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- gas --

    /// Execution gas only (no calldata / intrinsic cost). See BENCHMARKS.md for full tx gas on anvil.
    function test_Gas_VerifyAndPay() public {
        Pay memory p = pays[0]; // copy out of storage so SLOADs are not measured
        bytes32[] memory pub = new bytes32[](7);
        pub[0] = mandate;
        pub[1] = initialHead;
        pub[2] = p.newHead;
        pub[3] = bytes32(uint256(p.amount));
        pub[4] = bytes32(uint256(uint160(p.payee)));
        pub[5] = bytes32(uint256(validUntil));
        pub[6] = reg.contextOf(mandate);
        uint256 g = gasleft();
        bool ok = verifier.verify(p.proof, pub);
        console2.log("verifier.verify execution gas", g - gasleft());
        assertTrue(ok);

        vm.prank(agent);
        g = gasleft();
        reg.pay(mandate, p.payee, p.amount, validUntil, p.newHead, p.proof);
        console2.log("registry.pay execution gas (verify + state + transfer)", g - gasleft());
    }
}
