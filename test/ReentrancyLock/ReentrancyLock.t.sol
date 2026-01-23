// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { ReentrancyLock, Reentrancy } from "@BondRoute/utils/ReentrancyLock.sol";

/**
 * @title ReentrancyLockHarness
 * @notice Exposes ReentrancyLock modifiers for testing bitmask allowlist pattern.
 */
contract ReentrancyLockHarness is ReentrancyLock {

    uint256 public constant LOCK_A      =  1 << 0;
    uint256 public constant LOCK_B      =  1 << 1;
    uint256 public constant LOCK_C      =  1 << 2;
    uint256 public constant ALLOW_NONE  =  0;

    uint256 public call_count;
    uint256 public nesting_depth;

    // ─── Basic lockAndAllow Tests ───────────────────────────────────────────────

    function protected_function() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        call_count  =  call_count + 1;
    }

    function try_reenter_same_lock() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        this.protected_function();  // Should revert - self reentrancy.
    }

    function try_reenter_different_lock_not_allowed() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        this.protected_function_b_no_allow();  // Should revert - LOCK_A not in LOCK_B's allowlist.
    }

    function protected_function_b_no_allow() external lockAndAllow( LOCK_B, ALLOW_NONE )
    {
        call_count  =  call_count + 1;
    }

    // ─── Allowlist Tests ────────────────────────────────────────────────────────

    function protected_function_b_allows_a() external lockAndAllow( LOCK_B, LOCK_A )
    {
        call_count  =  call_count + 1;
    }

    function try_reenter_with_allowlist() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        this.protected_function_b_allows_a();  // Should succeed - LOCK_A is in LOCK_B's allowlist.
    }

    // ─── lockAndAllowView Tests ─────────────────────────────────────────────────

    function view_during_lock() external view lockAndAllowView( LOCK_A, ALLOW_NONE ) returns ( uint256 )
    {
        return call_count;
    }

    function call_view_during_protected() external lockAndAllow( LOCK_A, ALLOW_NONE ) returns ( uint256 )
    {
        return this.view_during_lock();  // Should revert - lock is held.
    }

    function call_view_outside_lock() external view returns ( uint256 )
    {
        return this.view_during_lock();  // Should succeed - no lock held.
    }

    function view_allows_a() external view lockAndAllowView( LOCK_B, LOCK_A ) returns ( uint256 )
    {
        return call_count;
    }

    function call_view_with_allowlist() external lockAndAllow( LOCK_A, ALLOW_NONE ) returns ( uint256 )
    {
        return this.view_allows_a();  // Should succeed - LOCK_A is in view's allowlist.
    }

    // ─── Lock Cleared After Execution ───────────────────────────────────────────

    function verify_lock_cleared() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        // Lock is held here, but after this function returns it should be cleared.
    }

    // ─── Multi-bit Allowlist Tests ──────────────────────────────────────────────

    function lock_c_allow_a_or_b() external lockAndAllow( LOCK_C, LOCK_A | LOCK_B )
    {
        call_count  =  call_count + 1;
    }

    function lock_a_then_call_lock_c_allow_a_or_b() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        this.lock_c_allow_a_or_b();
    }

    function lock_b_then_call_lock_c_allow_a_or_b() external lockAndAllow( LOCK_B, ALLOW_NONE )
    {
        this.lock_c_allow_a_or_b();
    }

    // ─── Three-level Nesting Tests ──────────────────────────────────────────────

    function lock_a_call_b_call_c() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        nesting_depth  =  1;
        this.lock_b_allow_a_call_c();
        nesting_depth  =  1;
    }

    function lock_b_allow_a_call_c() external lockAndAllow( LOCK_B, LOCK_A )
    {
        nesting_depth  =  2;
        this.lock_c_allow_a_or_b();
        nesting_depth  =  2;
    }

    // ─── State Restoration Tests ────────────────────────────────────────────────

    function lock_a_call_inner_twice() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        call_count  =  1;
        this.lock_b_allow_a();
        call_count  =  call_count + 1;
        this.lock_b_allow_a();
        call_count  =  call_count + 1;
    }

    function lock_b_allow_a() external lockAndAllow( LOCK_B, LOCK_A )
    {
        call_count  =  call_count + 10;
    }

    // ─── Revert Preservation Tests ──────────────────────────────────────────────

    function lock_a_call_reverting_then_valid() external lockAndAllow( LOCK_A, ALLOW_NONE )
    {
        call_count  =  1;

        try this.lock_b_allow_a_then_revert() { }
        catch { }

        call_count  =  call_count + 1;
        this.lock_b_allow_a();
    }

    function lock_b_allow_a_then_revert() external lockAndAllow( LOCK_B, LOCK_A )
    {
        revert( "intentional revert" );
    }

    // ─── Self-bit in Allowlist Tests ────────────────────────────────────────────

    function lock_a_allow_a() external lockAndAllow( LOCK_A, LOCK_A )
    {
        call_count  =  call_count + 1;
    }

    function lock_a_allow_a_try_reenter() external lockAndAllow( LOCK_A, LOCK_A )
    {
        this.lock_a_allow_a();
    }

    // ─── Double Lock Tests ──────────────────────────────────────────────────────

    function lock_a_and_b() external lockAndAllow( LOCK_A | LOCK_B, ALLOW_NONE )
    {
        call_count  =  call_count + 1;
    }

    function lock_a_and_b_try_reenter() external lockAndAllow( LOCK_A | LOCK_B, ALLOW_NONE )
    {
        this.lock_a_and_b();
    }

    function lock_a_and_b_call_allows_only_a() external lockAndAllow( LOCK_A | LOCK_B, ALLOW_NONE )
    {
        this.lock_c_allow_a();
    }

    function lock_c_allow_a() external lockAndAllow( LOCK_C, LOCK_A )
    {
        call_count  =  call_count + 1;
    }

    function lock_a_and_b_call_allows_both() external lockAndAllow( LOCK_A | LOCK_B, ALLOW_NONE )
    {
        this.lock_c_allow_a_or_b();
    }
}

/**
 * @title ReentrancyLockTest
 * @notice Tests for ReentrancyLock bitmask allowlist pattern.
 */
contract ReentrancyLockTest is Test {

    ReentrancyLockHarness public harness;

    function setUp() public
    {
        harness  =  new ReentrancyLockHarness();
    }


    // ━━━━  lockAndAllow() Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_lockAndAllow_allows_single_call() public
    {
        harness.protected_function();

        assertEq( harness.call_count(), 1, "Single call should succeed" );
    }

    function test_lockAndAllow_reverts_on_same_lock_reentry() public
    {
        vm.expectRevert( Reentrancy.selector );
        harness.try_reenter_same_lock();
    }

    function test_lockAndAllow_reverts_on_different_lock_not_in_allowlist() public
    {
        vm.expectRevert( Reentrancy.selector );
        harness.try_reenter_different_lock_not_allowed();
    }

    function test_lockAndAllow_allows_reentry_when_in_allowlist() public
    {
        harness.try_reenter_with_allowlist();

        assertEq( harness.call_count(), 1, "Reentry should succeed when caller is in allowlist" );
    }

    function test_lockAndAllow_clears_lock_after_execution() public
    {
        harness.verify_lock_cleared();
        harness.protected_function();  // Should succeed - lock was cleared.

        assertEq( harness.call_count(), 1, "Lock should be cleared after function returns" );
    }

    function test_lockAndAllow_allows_sequential_calls() public
    {
        harness.protected_function();
        harness.protected_function();
        harness.protected_function();

        assertEq( harness.call_count(), 3, "Sequential calls should all succeed" );
    }


    // ━━━━  lockAndAllowView() Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_lockAndAllowView_allows_call_when_unlocked() public view
    {
        uint256 result  =  harness.call_view_outside_lock();

        assertEq( result, 0, "View should succeed when lock not held" );
    }

    function test_lockAndAllowView_reverts_when_same_lock_held() public
    {
        vm.expectRevert( Reentrancy.selector );
        harness.call_view_during_protected();
    }

    function test_lockAndAllowView_allows_when_caller_in_allowlist() public
    {
        uint256 result  =  harness.call_view_with_allowlist();

        assertEq( result, 0, "View should succeed when caller is in allowlist" );
    }


    // ━━━━  Multi-bit Allowlist Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_multibit_allowlist_allows_first_allowed_lock() public
    {
        harness.lock_a_then_call_lock_c_allow_a_or_b();

        assertEq( harness.call_count(), 1, "LOCK_C should allow entry when LOCK_A is held" );
    }

    function test_multibit_allowlist_allows_second_allowed_lock() public
    {
        harness.lock_b_then_call_lock_c_allow_a_or_b();

        assertEq( harness.call_count(), 1, "LOCK_C should allow entry when LOCK_B is held" );
    }


    // ━━━━  Three-level Nesting Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_three_level_nesting_succeeds() public
    {
        harness.lock_a_call_b_call_c();

        assertEq( harness.nesting_depth(), 1, "Nesting depth should be restored to 1 after A->B->C chain" );
        assertEq( harness.call_count(), 1, "Call count should be 1 from innermost function" );
    }


    // ━━━━  State Restoration Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_state_restored_after_nested_call() public
    {
        harness.lock_a_call_inner_twice();

        assertEq( harness.call_count(), 23, "State should allow multiple nested calls: 1 + 10 + 1 + 10 + 1 = 23" );
    }


    // ━━━━  Revert Preservation Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_revert_in_nested_call_preserves_outer_lock() public
    {
        harness.lock_a_call_reverting_then_valid();

        assertEq( harness.call_count(), 12, "After inner revert, outer should continue: 1 + 1 + 10 = 12" );
    }


    // ━━━━  Self-bit in Allowlist Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_self_in_allowlist_allows_single_call() public
    {
        harness.lock_a_allow_a();

        assertEq( harness.call_count(), 1, "Single call should succeed even with self in allowlist" );
    }

    function test_self_in_allowlist_still_blocks_self_reentry() public
    {
        vm.expectRevert( Reentrancy.selector );
        harness.lock_a_allow_a_try_reenter();
    }


    // ━━━━  Double Lock Tests  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_double_lock_allows_single_call() public
    {
        harness.lock_a_and_b();

        assertEq( harness.call_count(), 1, "Double lock single call should succeed" );
    }

    function test_double_lock_blocks_self_reentry() public
    {
        vm.expectRevert( Reentrancy.selector );
        harness.lock_a_and_b_try_reenter();
    }

    function test_double_lock_blocks_when_inner_allows_only_one_bit() public
    {
        vm.expectRevert( Reentrancy.selector );
        harness.lock_a_and_b_call_allows_only_a();
    }

    function test_double_lock_succeeds_when_inner_allows_both_bits() public
    {
        harness.lock_a_and_b_call_allows_both();

        assertEq( harness.call_count(), 1, "Double lock should succeed when inner allows both bits" );
    }
}
