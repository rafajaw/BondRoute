// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import { Collector, CollectorTransferInitiated, CollectorTransferCompleted, ExpiredBondLiquidated, BondNotExpired } from "@BondRoute/Collector.sol";
import { BondStatus } from "@BondRoute/Storage.sol";
import { Invalid, BondAlreadySettled } from "@BondRoute/Core.sol";
import { Unauthorized } from "@BondRouteProtected/BondRouteProtected.sol";
import { IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";
import { MockERC20 } from "@test/mocks/MockERC20.sol";
import { MockFeeOnTransferToken } from "@test/mocks/MockFeeOnTransferToken.sol";
import "@BondRoute/Definitions.sol";

/**
 * @title CollectorHarness
 * @notice Test harness exposing Collector's internal functions for testing
 */
contract CollectorHarness is Collector {

    constructor( address collector ) Collector( collector ) {}

    function exposed_create_bond_internal( bytes32 commitment_hash, TokenAmount memory stake, uint256 amount_received ) external
    {
        _create_bond_internal( commitment_hash, stake, amount_received );
    }

    function exposed_set_bond_status( bytes32 bond_key, uint256 previous_packed_value, BondStatus new_status ) external
    {
        _set_bond_status( bond_key, previous_packed_value, new_status );
    }

    function exposed_get_bond_info( bytes32 commitment_hash, TokenAmount memory stake ) external view returns ( BondInfo memory bond_info, bytes32 bond_key, uint256 packed_value )
    {
        return _get_bond_info( commitment_hash, stake );
    }

    function exposed_get_collector() external view returns ( address )
    {
        return _collector;
    }

    function exposed_get_pending_collector() external view returns ( address )
    {
        return _pending_collector;
    }
}

/**
 * @title CollectorTest
 * @notice Tests for Collector contract (expired bond liquidation)
 * @dev Implements ICollectorTests from TestManifest.sol
 */
contract CollectorTest is Test {

    CollectorHarness public collector_harness;
    MockERC20 public usdc;
    MockERC20 public dai;
    MockFeeOnTransferToken public fee_token;

    address public constant COLLECTOR      =  address(0x5555);
    address public constant NEW_COLLECTOR  =  address(0x6666);
    address public constant RECIPIENT      =  address(0x7777);
    address public constant USER           =  address(0x1111);

    function setUp() public
    {
        collector_harness =  new CollectorHarness( COLLECTOR );
        usdc              =  new MockERC20( "USDC", "USDC" );
        dai               =  new MockERC20( "DAI", "DAI" );
        fee_token         =  new MockFeeOnTransferToken( "FeeToken", "FEE" );
        fee_token.set_fee_percentage( 1 );

        usdc.mint( USER, 10000e6 );
        usdc.mint( address(collector_harness), 10000e6 );
        dai.mint( USER, 10000e18 );
        dai.mint( address(collector_harness), 10000e18 );
        fee_token.mint( USER, 10000e18 );
        fee_token.mint( address(collector_harness), 10000e18 );

        vm.deal( USER, 100 ether );
        vm.deal( address(collector_harness), 100 ether );
        vm.deal( COLLECTOR, 10 ether );
        vm.deal( RECIPIENT, 1 ether );
    }


    // ━━━━  HELPER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _create_expired_bond( TokenAmount memory stake, uint256 amount_received ) internal returns ( bytes32 commitment_hash )
    {
        commitment_hash  =  keccak256( abi.encodePacked( "test_commitment", block.timestamp ) );
        collector_harness.exposed_create_bond_internal( commitment_hash, stake, amount_received );

        vm.warp( block.timestamp + MAX_BOND_LIFETIME + 1 );
    }

    function _create_not_yet_expired_bond( TokenAmount memory stake, uint256 amount_received ) internal returns ( bytes32 commitment_hash )
    {
        commitment_hash  =  keccak256( abi.encodePacked( "test_commitment", block.timestamp ) );
        collector_harness.exposed_create_bond_internal( commitment_hash, stake, amount_received );
    }


    // ━━━━  COLLECTOR ROLE MANAGEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_constructor_sets_initial_collector() public view
    {
        address initial_collector  =  collector_harness.exposed_get_collector();
        assertEq( initial_collector, COLLECTOR, "Constructor should set initial collector" );
    }

    function test_constructor_reverts_on_zero_collector() public
    {
        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "collector", 0 ) );
        new CollectorHarness( address(0) );
    }

    function test_appoint_new_collector_success() public
    {
        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );

        address pending  =  collector_harness.exposed_get_pending_collector();
        assertEq( pending, NEW_COLLECTOR, "Should set pending collector" );
    }

    function test_appoint_new_collector_emits_event() public
    {
        vm.expectEmit( true, false, false, false );
        emit CollectorTransferInitiated( NEW_COLLECTOR );

        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );
    }

    function test_appoint_new_collector_reverts_if_not_collector() public
    {
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, USER, COLLECTOR ) );

        vm.prank( USER );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );
    }

    function test_appoint_new_collector_reverts_on_zero_address() public
    {
        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "new_collector", 0 ) );

        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( address(0) );
    }

    function test_claim_collector_role_success() public
    {
        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );

        vm.prank( NEW_COLLECTOR );
        collector_harness.claim_collector_role();

        address current_collector  =  collector_harness.exposed_get_collector();
        assertEq( current_collector, NEW_COLLECTOR, "Should update current collector" );
    }

    function test_claim_collector_role_emits_event() public
    {
        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );

        vm.expectEmit( true, false, false, false );
        emit CollectorTransferCompleted( NEW_COLLECTOR );

        vm.prank( NEW_COLLECTOR );
        collector_harness.claim_collector_role();
    }

    function test_claim_collector_role_reverts_if_not_pending() public
    {
        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, USER, NEW_COLLECTOR ) );

        vm.prank( USER );
        collector_harness.claim_collector_role();
    }

    function test_claim_collector_role_clears_pending() public
    {
        vm.prank( COLLECTOR );
        collector_harness.appoint_new_collector( NEW_COLLECTOR );

        vm.prank( NEW_COLLECTOR );
        collector_harness.claim_collector_role();

        address pending  =  collector_harness.exposed_get_pending_collector();
        assertEq( pending, address(0), "Should clear pending collector" );
    }


    // ━━━━  LIQUIDATE EXPIRED BONDS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_liquidate_expired_bonds_single_bond() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        uint256 recipient_balance_before  =  usdc.balanceOf( RECIPIENT );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        uint256 recipient_balance_after  =  usdc.balanceOf( RECIPIENT );
        assertEq( recipient_balance_after, recipient_balance_before + 100e6, "Recipient should receive stake" );
    }

    function test_liquidate_expired_bonds_with_native_stake() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: IERC20(address(0)), amount: 1 ether });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 1 ether );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        uint256 recipient_balance_before  =  RECIPIENT.balance;

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        uint256 recipient_balance_after  =  RECIPIENT.balance;
        assertEq( recipient_balance_after, recipient_balance_before + 1 ether, "Recipient should receive native stake" );

        ( CollectorHarness.BondInfo memory bond_info, , )  =  collector_harness.exposed_get_bond_info( commitment_hash, stake );
        assertEq( uint8(bond_info.status), uint8(BondStatus.LIQUIDATED), "Bond should be marked as liquidated" );
    }

    function test_liquidate_expired_bonds_multiple_bonds() public
    {
        TokenAmount memory stake1  =  TokenAmount({ token: usdc, amount: 100e6 });
        TokenAmount memory stake2  =  TokenAmount({ token: dai, amount: 200e18 });

        bytes32 commitment_hash1  =  _create_expired_bond( stake1, 100e6 );

        vm.warp( block.timestamp + 10 );

        bytes32 commitment_hash2  =  _create_expired_bond( stake2, 200e18 );

        bytes32[] memory commitment_hashes  =  new bytes32[](2);
        commitment_hashes[ 0 ]  =  commitment_hash1;
        commitment_hashes[ 1 ]  =  commitment_hash2;

        TokenAmount[] memory stakes  =  new TokenAmount[](2);
        stakes[ 0 ]  =  stake1;
        stakes[ 1 ]  =  stake2;

        uint256 usdc_balance_before  =  usdc.balanceOf( RECIPIENT );
        uint256 dai_balance_before   =  dai.balanceOf( RECIPIENT );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        uint256 usdc_balance_after  =  usdc.balanceOf( RECIPIENT );
        uint256 dai_balance_after   =  dai.balanceOf( RECIPIENT );

        assertEq( usdc_balance_after, usdc_balance_before + 100e6, "Recipient should receive USDC stake" );
        assertEq( dai_balance_after, dai_balance_before + 200e18, "Recipient should receive DAI stake" );
    }

    function test_liquidate_expired_bonds_emits_events() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.expectEmit( true, true, false, true );
        emit ExpiredBondLiquidated( commitment_hash, address(usdc), 100e6, RECIPIENT );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );
    }

    function test_liquidate_expired_bonds_transfers_stakes() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        uint256 contract_balance_before   =  usdc.balanceOf( address(collector_harness) );
        uint256 recipient_balance_before  =  usdc.balanceOf( RECIPIENT );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        uint256 contract_balance_after   =  usdc.balanceOf( address(collector_harness) );
        uint256 recipient_balance_after  =  usdc.balanceOf( RECIPIENT );

        assertEq( contract_balance_after, contract_balance_before - 100e6, "Contract should lose stake" );
        assertEq( recipient_balance_after, recipient_balance_before + 100e6, "Recipient should gain stake" );
    }

    function test_liquidate_expired_bonds_marks_as_liquidated() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        ( CollectorHarness.BondInfo memory bond_info, , )  =  collector_harness.exposed_get_bond_info( commitment_hash, stake );
        assertEq( uint8(bond_info.status), uint8(BondStatus.LIQUIDATED), "Bond should be marked as liquidated" );
    }

    function test_liquidate_expired_bonds_reverts_if_not_collector() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, USER, COLLECTOR ) );

        vm.prank( USER );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );
    }

    function test_liquidate_expired_bonds_reverts_on_zero_recipient() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "recipient", 0 ) );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, address(0) );
    }

    function test_liquidate_expired_bonds_reverts_on_array_mismatch() public
    {
        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  keccak256( "test" );

        TokenAmount[] memory stakes  =  new TokenAmount[](2);
        stakes[ 0 ]  =  TokenAmount({ token: usdc, amount: 100e6 });
        stakes[ 1 ]  =  TokenAmount({ token: dai, amount: 200e18 });

        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "array_length_mismatch", 0 ) );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );
    }

    function test_liquidate_expired_bonds_reverts_if_not_expired() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_not_yet_expired_bond( stake, 100e6 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        uint256 expected_expiration  =  block.timestamp + MAX_BOND_LIFETIME;

        vm.expectRevert( abi.encodeWithSelector( BondNotExpired.selector, expected_expiration, block.timestamp ) );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );
    }

    function test_liquidate_expired_bonds_reverts_if_already_executed() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        ( , bytes32 bond_key, uint256 packed_value )  =  collector_harness.exposed_get_bond_info( commitment_hash, stake );
        collector_harness.exposed_set_bond_status( bond_key, packed_value, BondStatus.EXECUTED );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.expectRevert( abi.encodeWithSelector( BondAlreadySettled.selector, BondStatus.EXECUTED ) );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );
    }

    function test_liquidate_expired_bonds_reverts_if_already_liquidated() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        ( , bytes32 bond_key, uint256 packed_value )  =  collector_harness.exposed_get_bond_info( commitment_hash, stake );
        collector_harness.exposed_set_bond_status( bond_key, packed_value, BondStatus.LIQUIDATED );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.expectRevert( abi.encodeWithSelector( BondAlreadySettled.selector, BondStatus.LIQUIDATED ) );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );
    }

    function test_liquidate_expired_bonds_reverts_on_reentrancy() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_expired_bond( stake, 100e6 );

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        bytes32[] memory hashes  =  new bytes32[](1);
        hashes[ 0 ]  =  commitment_hash;

        bytes memory reentrancy_call  =  abi.encodeCall(
            collector_harness.liquidate_expired_bonds,
            ( hashes, stakes, RECIPIENT )
        );
        usdc.set_reentrancy_call( address(collector_harness), reentrancy_call );

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( hashes, stakes, RECIPIENT );

        assertFalse( usdc.did_reentrancy_succeed(), "Reentrancy attack should fail - missing reentrancy guard!" );
    }

    function test_liquidate_expired_bonds_exactly_at_expiration() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_not_yet_expired_bond( stake, 100e6 );

        vm.warp( block.timestamp + MAX_BOND_LIFETIME );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        ( CollectorHarness.BondInfo memory bond_info, , )  =  collector_harness.exposed_get_bond_info( commitment_hash, stake );
        assertEq( uint8(bond_info.status), uint8(BondStatus.LIQUIDATED), "Should liquidate at exact expiration" );
    }

    function test_liquidate_expired_bonds_one_second_after_expiration() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        bytes32 commitment_hash  =  _create_not_yet_expired_bond( stake, 100e6 );

        vm.warp( block.timestamp + MAX_BOND_LIFETIME + 1 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        vm.prank( COLLECTOR );
        collector_harness.liquidate_expired_bonds( commitment_hashes, stakes, RECIPIENT );

        ( CollectorHarness.BondInfo memory bond_info, , )  =  collector_harness.exposed_get_bond_info( commitment_hash, stake );
        assertEq( uint8(bond_info.status), uint8(BondStatus.LIQUIDATED), "Should liquidate one second after expiration" );
    }
}
