// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keel} from "../src/Keel.sol";

/// @dev Deploys raw creation code through CREATE2 in a single call, the way the launch factory deploys a
/// project in one transaction, and checks after every constructor that the supply is whole and still here.
/// Local scaffolding only; never a launch artifact.
contract KeelRawDeployer {
    function deployAll(bytes[] memory codes, bytes32[] memory salts, uint256 expectedSupply)
        external
        returns (address[] memory deployed)
    {
        require(codes.length > 0 && codes.length == salts.length, "invalid project list");
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
            Keel token = Keel(deployed[0]);
            require(token.totalSupply() == expectedSupply, "manifest supply mismatch");
            require(token.balanceOf(address(this)) == expectedSupply, "a constructor moved the launch supply");
        }
    }
}

/// @dev A recipient with no receive or fallback function: an ERC-20 transfer must not depend on the
/// recipient accepting anything.
contract InertRecipient {}

/// forge-config: default.fuzz.runs = 1000
contract KeelPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    Keel internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        token = new Keel();
    }

    // ---------------------------------------------------------------------------------------------
    // Supply and deployment
    // ---------------------------------------------------------------------------------------------

    function test_InitialSupplyIsOneBillionWholeTokens() public view {
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev The creation code takes no constructor arguments, so the launch address is a pure function of
    /// the factory, the launch number used as salt, and the creation code hash. The initiator of the
    /// deploying transaction receives nothing.
    function testFuzz_RawCreationCodeDeploysAtPredictedAddressWithSupplyToFactory(uint64 launchNumber) public {
        KeelRawDeployer factory = new KeelRawDeployer();
        bytes memory code = type(Keel).creationCode;
        bytes[] memory codes = new bytes[](1);
        codes[0] = code;
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(launchNumber));
        address predicted = computeCreate2Address(salts[0], keccak256(code), address(factory));

        vm.prank(alice, alice);
        address[] memory deployed = factory.deployAll(codes, salts, SUPPLY);

        assertEq(deployed.length, 1);
        assertEq(deployed[0], predicted);
        Keel launched = Keel(deployed[0]);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.name(), "Keel");
        assertEq(launched.symbol(), "KEEL");
        assertEq(launched.decimals(), 18);
    }

    function test_SameSaltCannotDeployTwiceFromTheSameFactory() public {
        KeelRawDeployer factory = new KeelRawDeployer();
        bytes[] memory codes = new bytes[](1);
        codes[0] = type(Keel).creationCode;
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(7));
        factory.deployAll(codes, salts, SUPPLY);
        // A CREATE2 collision consumes all the gas handed to it, so cap the call to keep the test cheap.
        vm.expectRevert(bytes("constructor failed"));
        factory.deployAll{gas: 2_000_000}(codes, salts, SUPPLY);
    }

    function test_DeployerClaimingWrongSupplyIsRefused() public {
        KeelRawDeployer factory = new KeelRawDeployer();
        bytes[] memory codes = new bytes[](1);
        codes[0] = type(Keel).creationCode;
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = bytes32(uint256(1));
        vm.expectRevert(bytes("manifest supply mismatch"));
        factory.deployAll(codes, salts, SUPPLY + 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        factory.deployAll(codes, salts, SUPPLY - 1);
    }

    /// @dev Whoever deploys receives the whole supply: an externally owned account as much as a factory.
    function testFuzz_AnyDeployerReceivesTheWholeSupply(uint256 seed) public {
        address deployer = address(uint160(bound(seed, 1, type(uint160).max)));
        vm.assume(deployer.code.length == 0 && deployer != VM_ADDRESS && deployer != CONSOLE);
        vm.prank(deployer);
        Keel deployed = new Keel();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(deployer), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    /// @dev Two independent deployments are independent ledgers with the same fixed supply each.
    function test_SeparateDeploymentsDoNotShareState() public {
        vm.prank(alice);
        Keel second = new Keel();
        token.transfer(bob, 5 ether);
        assertEq(second.balanceOf(bob), 0);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(alice);
        second.approve(bob, 1);
        assertEq(token.allowance(alice, bob), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    function testFuzz_TransferRoundTripIsNetZero(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        vm.prank(bob);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The same transfer twice moves twice the amount, and a third one past the balance fails whole.
    function testFuzz_RepeatedTransfersAccumulateUntilTheBalanceRunsOut(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY / 2);
        token.transfer(alice, 2 * amount);
        vm.startPrank(alice);
        assertTrue(token.transfer(bob, amount));
        assertTrue(token.transfer(bob, amount));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, amount));
        token.transfer(bob, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 2 * amount);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Splitting the supply across many holders in random shares conserves it exactly, and every
    /// holder can send everything back.
    function testFuzz_ManyHoldersConserveSupply(uint256 seed, uint8 holderCount) public {
        uint256 count = bound(holderCount, 2, 48);
        address[] memory holders = new address[](count);
        uint256 remaining = SUPPLY;
        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            holders[i] = makeAddr(string.concat("holder-", vm.toString(i)));
            uint256 share = bound(uint256(keccak256(abi.encode(seed, i))), 0, remaining);
            if (i == count - 1) share = remaining; // the last holder takes the rest, so some hold zero and one may hold it all
            assertTrue(token.transfer(holders[i], share));
            remaining -= share;
            distributed += share;
        }
        assertEq(distributed, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        for (uint256 i; i < count; ++i) {
            uint256 held = token.balanceOf(holders[i]);
            vm.prank(holders[i]);
            assertTrue(token.transfer(address(this), held));
            assertEq(token.balanceOf(holders[i]), 0);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferToContractWithoutReceiveSucceeds() public {
        InertRecipient inert = new InertRecipient();
        assertTrue(token.transfer(address(inert), 3 ether));
        assertEq(token.balanceOf(address(inert)), 3 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Plain ERC-20 behaviour: the token accepts transfers to its own address and has no rescue
    /// path, so such tokens are stranded. Documented here, not a defect of a fixed-supply token.
    function test_TokensSentToTheTokenItselfAreAcceptedAndStranded() public {
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", address(this), 1 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 1 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1 ether);
    }

    function test_TransferEmitsExactlyOneLog() public {
        vm.recordLogs();
        token.transfer(alice, 9);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), 9);
    }

    /// @dev Any transfer that reverts reverts whole: no balance, allowance or supply moves, whatever the
    /// amount or the reason.
    function testFuzz_FailedTransfersLeaveNoTrace(uint256 held, uint256 amount, bool toZero) public {
        held = bound(held, 0, SUPPLY);
        token.transfer(alice, held);
        address to = toZero ? address(0) : bob;
        if (!toZero) amount = bound(amount, held + 1, type(uint256).max);
        bytes memory expected = toZero
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount);
        vm.expectRevert(expected);
        vm.prank(alice);
        token.transfer(to, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    /// @dev approve sets, it does not add: the second value replaces the first, repeating it changes
    /// nothing, and zero clears it.
    function testFuzz_ApproveOverwritesAndIsIdempotent(uint256 first, uint256 second) public {
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(address(this), spender), first);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_ApproveEmitsExactlyOneApprovalLog() public {
        vm.recordLogs();
        token.approve(spender, 11);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], APPROVAL_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(spender))));
        assertEq(abi.decode(logs[0].data, (uint256)), 11);
    }

    /// @dev Consuming an allowance emits no Approval event, as the README states; only the Transfer.
    function test_TransferFromEmitsOnlyTheTransferLog() public {
        token.approve(spender, 10 ether);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(token.allowance(address(this), spender), 6 ether);
    }

    function testFuzz_ExactAllowanceIsConsumedToZeroAndNoMore(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), amount);
    }

    /// @dev Only exactly type(uint256).max is unlimited. One below it is an ordinary finite allowance.
    function testFuzz_OneBelowMaxAllowanceIsStillDecremented(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 nearMax = type(uint256).max - 1;
        token.approve(spender, nearMax);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), nearMax - amount);
        assertEq(token.balanceOf(alice), amount);
    }

    /// @dev Partial consumption, then re-approval: the new value replaces what was left, so an owner who
    /// re-approves after a spend grants the full new amount again (the classic ERC-20 approve race).
    function testFuzz_ReapprovalAfterPartialSpendReplacesRemainder(uint256 approved, uint256 spent, uint256 renewed)
        public
    {
        approved = bound(approved, 1, SUPPLY);
        spent = bound(spent, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        token.transferFrom(address(this), alice, spent);
        assertEq(token.allowance(address(this), spender), approved - spent);
        token.approve(spender, renewed);
        assertEq(token.allowance(address(this), spender), renewed);
    }

    /// @dev When both the allowance and the balance are short, the allowance is what the revert reports:
    /// the allowance is checked before the balance.
    function testFuzz_AllowanceIsCheckedBeforeBalance(uint256 amount, uint256 held, uint256 approved) public {
        amount = bound(amount, 1, SUPPLY);
        held = bound(held, 0, amount - 1);
        approved = bound(approved, 0, amount - 1);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), approved);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev The allowance check runs before the receiver check too: a spender without allowance sending
    /// to the zero address sees the allowance error, and one with allowance sees the receiver error.
    function testFuzz_TransferFromToZeroReportsAllowanceFirst(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);

        token.approve(spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), spender), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// @dev A holder is not exempt from the allowance rule when it uses transferFrom on itself.
    function testFuzz_HolderNeedsItsOwnAllowanceForTransferFrom(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.transfer(alice, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, amount));
        vm.prank(alice);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), amount);

        vm.startPrank(alice);
        token.approve(alice, amount);
        assertTrue(token.transferFrom(alice, bob, amount));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
    }

    /// @dev transferFrom from the zero address: with a non-zero amount the missing allowance is reported;
    /// with zero the zero approver is. Neither path moves anything.
    function testFuzz_TransferFromZeroOwnerAlwaysReverts(uint256 amount) public {
        bytes memory expected = amount == 0
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount);
        vm.expectRevert(expected);
        vm.prank(spender);
        token.transferFrom(address(0), alice, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Allowances are per spender: one spender using its allowance does not touch another's.
    function testFuzz_SpendersAllowancesAreIndependent(uint256 a, uint256 b, uint256 spent) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY);
        spent = bound(spent, 0, a);
        address other = makeAddr("other-spender");
        token.approve(spender, a);
        token.approve(other, b);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spent));
        assertEq(token.allowance(address(this), spender), a - spent);
        assertEq(token.allowance(address(this), other), b);
        assertEq(token.balanceOf(alice), spent);
    }

    /// @dev A third party cannot change an allowance it does not own, by any call shape.
    function test_NoCallerCanSetAnotherOwnersAllowance() public {
        token.approve(spender, 5 ether);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSignature("increaseAllowance(address,uint256)", spender, 1 ether);
        calls[1] = abi.encodeWithSignature("decreaseAllowance(address,uint256)", spender, 1 ether);
        calls[2] = abi.encodeWithSignature("approveFrom(address,address,uint256)", address(this), bob, SUPPLY);
        calls[3] = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(this),
            bob,
            SUPPLY,
            type(uint256).max,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(bob);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.allowance(address(this), spender), 5 ether);
        assertEq(token.allowance(address(this), bob), 0);
    }
}
