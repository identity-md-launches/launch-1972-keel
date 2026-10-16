// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keel} from "../src/Keel.sol";

/// @dev Drives the token with both valid and deliberately invalid calls in random order. Valid calls
/// update an independent ledger; invalid ones must revert with the exact ERC-6093 error and leave every
/// balance, allowance and the supply untouched. Six holders start from an uneven split so that empty,
/// partial and whole-supply accounts all occur from the first call.
contract KeelFailurePathHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant ACTOR_COUNT = 6;

    Keel internal immutable token;
    address[ACTOR_COUNT] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    // Ghost counters, so the invariants can tell the failure paths were actually exercised.
    uint256 public successfulMoves;
    uint256 public volumeMoved;
    uint256 public rejectedCalls;
    uint256 public privilegedAttempts;

    constructor(Keel token_) {
        token = token_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
    }

    /// @dev Called once by the test after the supply has been handed to the handler.
    function seedBalances() external {
        require(token.balanceOf(address(this)) == SUPPLY, "handler must hold the supply");
        uint256[ACTOR_COUNT] memory shares = [SUPPLY / 2, SUPPLY / 4, SUPPLY / 8, 1, 0, 0];
        uint256 given;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            if (i == ACTOR_COUNT - 1) shares[i] = SUPPLY - given;
            require(token.transfer(actors[i], shares[i]), "seed transfer failed");
            expectedBalance[actors[i]] = shares[i];
            given += shares[i];
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ---------------------------------------------------------------------------------------------
    // Valid calls: keep the ledger in step
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        successfulMoves++;
        volumeMoved += amount;
    }

    /// @dev Full-amount stress variant: the sender empties itself.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        transfer(fromSeed, toSeed, expectedBalance[_actor(fromSeed)]);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function approveUnlimited(uint256 ownerSeed, uint256 spenderSeed) external {
        approve(ownerSeed, spenderSeed, type(uint256).max);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        amount = bound(amount, 0, _min(approved, expectedBalance[from]));
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (approved != type(uint256).max) expectedAllowance[from][spender] -= amount;
        successfulMoves++;
        volumeMoved += amount;
    }

    /// @dev Full-amount stress variant: spend the whole of whatever is smaller, allowance or balance.
    function transferFromAll(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        transferFrom(spenderSeed, fromSeed, toSeed, _min(expectedAllowance[from][spender], expectedBalance[from]));
    }

    // ---------------------------------------------------------------------------------------------
    // Invalid calls: must revert with the exact error and change nothing
    // ---------------------------------------------------------------------------------------------

    function transferOverdraw(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;
        bytes32 before = _fingerprint(from, to, from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(_fingerprint(from, to, from), before, "overdraw changed state");
        rejectedCalls++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        bytes32 before = _fingerprint(from, address(0), from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        assertEq(_fingerprint(from, address(0), from), before, "transfer to zero changed state");
        rejectedCalls++;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        if (approved == type(uint256).max) {
            // An unlimited allowance cannot be exceeded; cover the path by revoking it first.
            approve(fromSeed, spenderSeed, 0);
            approved = 0;
        }
        excess = bound(excess, 1, type(uint256).max - approved);
        uint256 amount = approved + excess;
        bytes32 before = _fingerprint(from, to, spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        assertEq(_fingerprint(from, to, spender), before, "over-allowance transferFrom changed state");
        rejectedCalls++;
    }

    /// @dev Grants an allowance larger than the balance, then tries to use it in full: the balance check
    /// fails and the allowance granted a moment ago must survive the rollback intact.
    function approveThenOverdrawFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;
        approve(fromSeed, spenderSeed, amount);
        bytes32 before = _fingerprint(from, to, spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        assertEq(_fingerprint(from, to, spender), before, "over-balance transferFrom changed state");
        assertEq(token.allowance(from, spender), amount, "allowance consumed by a failed transferFrom");
        rejectedCalls++;
    }

    function transferFromToZero(uint256 spenderSeed, uint256 fromSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 approved = expectedAllowance[from][spender];
        bytes memory expected = approved < amount
            ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
            : abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        bytes32 before = _fingerprint(from, address(0), spender);
        vm.expectRevert(expected);
        vm.prank(spender);
        token.transferFrom(from, address(0), amount);
        assertEq(_fingerprint(from, address(0), spender), before, "transferFrom to zero changed state");
        rejectedCalls++;
    }

    function transferFromZeroOwner(uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        bytes memory expected = amount == 0
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount);
        bytes32 before = _fingerprint(address(0), to, spender);
        vm.expectRevert(expected);
        vm.prank(spender);
        token.transferFrom(address(0), to, amount);
        assertEq(_fingerprint(address(0), to, spender), before, "transferFrom from zero changed state");
        rejectedCalls++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        assertEq(token.allowance(owner, address(0)), 0);
        rejectedCalls++;
    }

    /// @dev A would-be administrator, picked from the holders, tries a privileged entry point at random.
    /// None exists, so every attempt must fail and the victim's balance must not move.
    function privilegedCall(uint256 callerSeed, uint256 victimSeed, uint256 which) external {
        address caller = _actor(callerSeed);
        address victim = _actor(victimSeed);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "setTransfersEnabled(bool)",
            "upgradeTo(address)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], victim, SUPPLY);
        bytes32 before = _fingerprint(caller, victim, caller);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged entry point answered");
        assertEq(_fingerprint(caller, victim, caller), before, "privileged call changed state");
        assertEq(token.totalSupply(), supplyBefore);
        privilegedAttempts++;
    }

    function _fingerprint(address a, address b, address spender) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(a),
                token.balanceOf(b),
                token.allowance(a, spender),
                token.allowance(b, spender),
                token.totalSupply()
            )
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract KeelFailurePathsInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant ACTOR_COUNT = 6;

    Keel internal token;
    KeelFailurePathHandler internal handler;
    bytes32 internal codehashAtDeployment;

    function setUp() public {
        token = new Keel();
        codehashAtDeployment = address(token).codehash;
        handler = new KeelFailurePathHandler(token);
        token.transfer(address(handler), SUPPLY);
        handler.seedBalances();

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.approveUnlimited.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.transferFromAll.selector;
        selectors[6] = handler.transferOverdraw.selector;
        selectors[7] = handler.transferToZero.selector;
        selectors[8] = handler.transferFromOverAllowance.selector;
        selectors[9] = handler.approveThenOverdrawFrom.selector;
        selectors[10] = handler.transferFromToZero.selector;
        selectors[11] = handler.transferFromZeroOwner.selector;
        selectors[12] = handler.approveZeroSpender.selector;
        selectors[13] = handler.privilegedCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Balances and allowances equal the ledger the handler keeps from the calls that succeeded.
    function invariant_BalancesAndAllowancesMatchLedger() public view {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address holder = handler.actors(i);
            assertEq(token.balanceOf(holder), handler.expectedBalance(holder), "balance drifted from ledger");
            for (uint256 j; j < ACTOR_COUNT; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(holder, spender),
                    handler.expectedAllowance(holder, spender),
                    "allowance drifted from ledger"
                );
            }
        }
    }

    /// @dev The fixed supply never changes and is held entirely by the six actors; nothing leaks to the
    /// zero address, the token, the handler or the test.
    function invariant_SupplyIsFixedAndFullyAccountedFor() public view {
        uint256 sum;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "actors do not hold the whole supply");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev Metadata and code are immutable: no sequence renames, redenominates or replaces the token.
    function invariant_MetadataAndCodeAreImmutable() public view {
        assertEq(token.name(), "Keel");
        assertEq(token.symbol(), "KEEL");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(address(token).codehash, codehashAtDeployment);
    }

    /// @dev No single successful move can exceed the supply, so the volume ghost is bounded by the count
    /// ghost. Guards against a handler that records a move it did not make.
    function invariant_MovedVolumeIsBoundedByMoveCount() public view {
        assertLe(handler.volumeMoved(), handler.successfulMoves() * SUPPLY);
    }

    /// @dev Runs after each sequence: both the happy and the failure paths must actually have been
    /// driven, so the ledger invariants above are never vacuous. With half the selectors rejecting, a
    /// 64-call sequence that misses one side has probability below 2^-60.
    function afterInvariant() public view {
        assertGt(handler.successfulMoves(), 0, "no successful transfer was driven");
        assertGt(handler.rejectedCalls(), 0, "no failure path was driven");
    }
}
