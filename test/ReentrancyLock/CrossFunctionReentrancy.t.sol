// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { BondRoute } from "@BondRoute/BondRoute.sol";
import { TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";
import { MockERC20 } from "@test/mocks/MockERC20.sol";
import { MockProtocolReentrant } from "@test/mocks/MockProtocolReentrant.sol";
import { ExecutionData } from "@BondRoute/Core.sol";
import "@BondRoute/Definitions.sol";

/**
 * @title CrossFunctionReentrancyTest
 * @notice Comprehensive tests for cross-function reentrancy protection via bitmask locks.
 *
 * @dev LOCK CONFIGURATION:
 *      - create_bond():             lock=CREATE_BOND,      allow=ALLOW_NONE
 *      - execute_bond():            lock=EXECUTE_BOND,     allow=TRANSFER_FUNDING
 *      - transfer_funding():        lock=TRANSFER_FUNDING, allow=ALLOW_NONE
 *      - liquidate_expired_bonds(): lock=LIQUIDATE,        allow=ALLOW_NONE
 *
 * @dev TEST MATRIX (Entry → Target):
 *      ┌─────────────────┬─────────────┬──────────────┬──────────────────┬───────────┐
 *      │ Entry \ Target  │ create_bond │ execute_bond │ transfer_funding │ liquidate │
 *      ├─────────────────┼─────────────┼──────────────┼──────────────────┼───────────┤
 *      │ create_bond     │ BLOCKED     │ BLOCKED      │ BLOCKED          │ BLOCKED   │
 *      │ execute_bond    │ BLOCKED     │ BLOCKED      │ **ALLOWED**      │ BLOCKED   │
 *      │ liquidate       │ BLOCKED     │ BLOCKED      │ BLOCKED          │ BLOCKED   │
 *      └─────────────────┴─────────────┴──────────────┴──────────────────┴───────────┘
 *
 * @dev EXPLOIT MECHANISM:
 *      Functions using balance delta patterns (measure tokens before/after transfer) are
 *      vulnerable to reentrancy via ERC777-style callbacks during transferFrom. The bitmask
 *      lock system prevents cross-function reentrancy by tracking which locks are held.
 */
contract CrossFunctionReentrancyTest is Test {

    BondRoute public bondroute;
    MockERC20 public token;
    MockProtocolReentrant public protocol;

    uint256 public constant USER_PRIVATE_KEY  =  0x1111;
    address public USER;  // Derived from USER_PRIVATE_KEY in setUp
    address public constant COLLECTOR  =  address(0x5555);

    function setUp() public
    {
        USER       =  vm.addr( USER_PRIVATE_KEY );
        bondroute  =  new BondRoute( COLLECTOR );
        token      =  new MockERC20( "ReentrantToken", "REENT" );
        protocol   =  new MockProtocolReentrant();

        token.mint( USER, 10000e18 );
        token.mint( COLLECTOR, 10000e18 );
        vm.deal( USER, 100 ether );
        vm.deal( COLLECTOR, 100 ether );

        vm.prank( USER );
        token.approve( address(bondroute), type(uint256).max );

        vm.prank( COLLECTOR );
        token.approve( address(bondroute), type(uint256).max );

        // Reentrancy callback comes from token contract, so it needs tokens and approval too.
        token.mint( address(token), 10000e18 );
        vm.prank( address(token) );
        token.approve( address(bondroute), type(uint256).max );
    }


    // ━━━━  HELPER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _create_test_execution_data( TokenAmount memory stake, uint256 salt ) internal view returns ( ExecutionData memory )
    {
        return ExecutionData({
            fundings: new TokenAmount[](0),
            stake: stake,
            salt: salt,
            protocol: protocol,
            call: abi.encodeWithSignature( "test()" )
        });
    }

    function _create_expired_bond( TokenAmount memory stake, uint256 salt ) internal returns ( bytes32 commitment_hash )
    {
        ExecutionData memory execution_data  =  _create_test_execution_data( stake, salt );
        commitment_hash  =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondroute.create_bond( commitment_hash, stake );

        vm.warp( block.timestamp + MAX_BOND_LIFETIME + 1 );
    }

    function _create_executable_bond( TokenAmount memory stake, uint256 salt ) internal returns ( bytes32 commitment_hash, ExecutionData memory execution_data )
    {
        execution_data    =  _create_test_execution_data( stake, salt );
        commitment_hash   =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondroute.create_bond( commitment_hash, stake );

        vm.roll( block.number + 1 );
    }


    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // FROM CREATE_BOND → ALL TARGETS (all should be blocked)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_create_bond_to_create_bond_blocked() public
    {
        TokenAmount memory stake  =  TokenAmount({ token: token, amount: 100e18 });
        ExecutionData memory execution_data  =  _create_test_execution_data( stake, 1 );
        bytes32 commitment_hash  =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        // Setup: during create_bond, try to call create_bond again
        bytes memory reentrancy_call  =  abi.encodeCall( bondroute.create_bond, ( commitment_hash, stake ) );
        token.set_reentrancy_call( address(bondroute), reentrancy_call );

        vm.prank( USER );
        bondroute.create_bond( commitment_hash, stake );

        assertFalse( token.did_reentrancy_succeed(), "create_bond -> create_bond should be blocked" );
    }

    function test_create_bond_to_execute_bond_blocked() public
    {
        // First create a bond that can be executed
        TokenAmount memory existing_stake  =  TokenAmount({ token: token, amount: 50e18 });
        ( , ExecutionData memory existing_execution_data )  =  _create_executable_bond( existing_stake, 100 );

        // Now setup reentrancy: during new create_bond, try to execute existing bond
        TokenAmount memory new_stake  =  TokenAmount({ token: token, amount: 100e18 });
        ExecutionData memory new_execution_data  =  _create_test_execution_data( new_stake, 2 );
        bytes32 new_commitment_hash  =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, new_execution_data );

        bytes memory reentrancy_call  =  abi.encodeCall( bondroute.execute_bond, ( existing_execution_data ) );
        token.set_reentrancy_call( address(bondroute), reentrancy_call );

        vm.prank( USER );
        bondroute.create_bond( new_commitment_hash, new_stake );

        assertFalse( token.did_reentrancy_succeed(), "create_bond -> execute_bond should be blocked" );
    }

    function test_create_bond_to_liquidate_blocked() public
    {
        // First create an expired bond to liquidate
        TokenAmount memory expired_stake  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 expired_commitment_hash  =  _create_expired_bond( expired_stake, 999 );

        // Now setup reentrancy: during create_bond, try to liquidate
        TokenAmount memory stake  =  TokenAmount({ token: token, amount: 100e18 });
        ExecutionData memory execution_data  =  _create_test_execution_data( stake, 3 );
        bytes32 commitment_hash  =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  expired_commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  expired_stake;

        bytes memory reentrancy_call  =  abi.encodeCall( bondroute.liquidate_expired_bonds, ( commitment_hashes, stakes, COLLECTOR ) );
        token.set_reentrancy_call( address(bondroute), reentrancy_call );

        vm.prank( USER );
        bondroute.create_bond( commitment_hash, stake );

        assertFalse( token.did_reentrancy_succeed(), "create_bond -> liquidate should be blocked" );
    }


    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // FROM EXECUTE_BOND → ALL TARGETS (only transfer_funding should be allowed)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_execute_bond_to_create_bond_blocked() public
    {
        // Create a bond to execute (protocol will attempt reentrancy)
        TokenAmount memory stake  =  TokenAmount({ token: token, amount: 50e18 });
        ( , ExecutionData memory execution_data )  =  _create_executable_bond( stake, 200 );

        // Setup: protocol tries to call create_bond during execution
        TokenAmount memory reentrant_stake  =  TokenAmount({ token: token, amount: 10e18 });
        bytes32 reentrant_hash  =  keccak256( "reentrant" );
        protocol.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.create_bond, ( reentrant_hash, reentrant_stake ) ) );

        vm.prank( USER );
        bondroute.execute_bond( execution_data );

        assertFalse( protocol.did_reentrancy_succeed(), "execute_bond -> create_bond should be blocked" );
    }

    function test_execute_bond_to_execute_bond_blocked() public
    {
        // Create two bonds
        TokenAmount memory stake1  =  TokenAmount({ token: token, amount: 50e18 });
        ( , ExecutionData memory execution_data1 )  =  _create_executable_bond( stake1, 300 );

        TokenAmount memory stake2  =  TokenAmount({ token: token, amount: 50e18 });
        ( , ExecutionData memory execution_data2 )  =  _create_executable_bond( stake2, 301 );

        // Setup: protocol tries to execute second bond during first execution
        protocol.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.execute_bond, ( execution_data2 ) ) );

        vm.prank( USER );
        bondroute.execute_bond( execution_data1 );

        assertFalse( protocol.did_reentrancy_succeed(), "execute_bond -> execute_bond should be blocked" );
    }

    function test_execute_bond_to_liquidate_blocked() public
    {
        // Create an expired bond to liquidate
        TokenAmount memory expired_stake  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 expired_commitment_hash  =  _create_expired_bond( expired_stake, 400 );

        // Create a bond to execute
        TokenAmount memory stake  =  TokenAmount({ token: token, amount: 50e18 });
        ( , ExecutionData memory execution_data )  =  _create_executable_bond( stake, 401 );

        // Setup: protocol tries to liquidate during execution
        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  expired_commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  expired_stake;

        protocol.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.liquidate_expired_bonds, ( commitment_hashes, stakes, COLLECTOR ) ) );

        vm.prank( USER );
        bondroute.execute_bond( execution_data );

        assertFalse( protocol.did_reentrancy_succeed(), "execute_bond -> liquidate should be blocked" );
    }

    // NOTE: execute_bond -> transfer_funding is ALLOWED (this is the legitimate flow)
    // This is tested implicitly by all execute_bond tests that use fundings


    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // FROM LIQUIDATE → ALL TARGETS (all should be blocked)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_liquidate_to_create_bond_blocked() public
    {
        // Create an expired bond to liquidate
        TokenAmount memory expired_stake  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 expired_commitment_hash  =  _create_expired_bond( expired_stake, 500 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  expired_commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  expired_stake;

        // Setup: during liquidation, try to create a bond
        TokenAmount memory new_stake  =  TokenAmount({ token: token, amount: 10e18 });
        bytes32 new_commitment_hash  =  keccak256( "new_bond" );
        token.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.create_bond, ( new_commitment_hash, new_stake ) ) );

        vm.prank( COLLECTOR );
        bondroute.liquidate_expired_bonds( commitment_hashes, stakes, address(token) );  // Send to token to trigger callback

        assertFalse( token.did_reentrancy_succeed(), "liquidate -> create_bond should be blocked" );
    }

    function test_liquidate_to_execute_bond_blocked() public
    {
        // Create an expired bond to liquidate
        TokenAmount memory expired_stake  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 expired_commitment_hash  =  _create_expired_bond( expired_stake, 600 );

        // Create a bond to execute
        TokenAmount memory exec_stake  =  TokenAmount({ token: token, amount: 50e18 });
        ( , ExecutionData memory execution_data )  =  _create_executable_bond( exec_stake, 601 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  expired_commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  expired_stake;

        // Setup: during liquidation, try to execute a bond
        token.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.execute_bond, ( execution_data ) ) );

        vm.prank( COLLECTOR );
        bondroute.liquidate_expired_bonds( commitment_hashes, stakes, address(token) );

        assertFalse( token.did_reentrancy_succeed(), "liquidate -> execute_bond should be blocked" );
    }

    function test_liquidate_to_liquidate_blocked() public
    {
        // Create two expired bonds
        TokenAmount memory stake1  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 hash1  =  _create_expired_bond( stake1, 700 );

        TokenAmount memory stake2  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 hash2  =  _create_expired_bond( stake2, 701 );

        // Setup first liquidation
        bytes32[] memory hashes1  =  new bytes32[](1);
        hashes1[ 0 ]  =  hash1;
        TokenAmount[] memory stakes1  =  new TokenAmount[](1);
        stakes1[ 0 ]  =  stake1;

        // Setup reentrancy to liquidate second bond
        bytes32[] memory hashes2  =  new bytes32[](1);
        hashes2[ 0 ]  =  hash2;
        TokenAmount[] memory stakes2  =  new TokenAmount[](1);
        stakes2[ 0 ]  =  stake2;

        token.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.liquidate_expired_bonds, ( hashes2, stakes2, COLLECTOR ) ) );

        vm.prank( COLLECTOR );
        bondroute.liquidate_expired_bonds( hashes1, stakes1, address(token) );

        assertFalse( token.did_reentrancy_succeed(), "liquidate -> liquidate should be blocked" );
    }


    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // EXECUTE_BOND_AS TESTS (same lock as execute_bond)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_execute_bond_as_to_create_bond_blocked() public
    {
        // Create a bond to execute
        TokenAmount memory stake  =  TokenAmount({ token: token, amount: 50e18 });
        ExecutionData memory execution_data  =  _create_test_execution_data( stake, 800 );
        bytes32 commitment_hash  =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondroute.create_bond( commitment_hash, stake );
        vm.roll( block.number + 1 );

        // Get signature
        ( bytes32 digest, , , )  =  bondroute.__OFF_CHAIN__get_signing_info( execution_data );
        ( uint8 v, bytes32 r, bytes32 s )  =  vm.sign( USER_PRIVATE_KEY, digest );  // USER's private key
        bytes memory signature  =  abi.encodePacked( r, s, v );

        // Setup: protocol tries to call create_bond during execution
        TokenAmount memory reentrant_stake  =  TokenAmount({ token: token, amount: 10e18 });
        bytes32 reentrant_hash  =  keccak256( "reentrant_as" );
        protocol.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.create_bond, ( reentrant_hash, reentrant_stake ) ) );

        // Give relayer tokens to front the stake
        address relayer  =  address(0x9999);
        token.mint( relayer, 1000e18 );
        vm.prank( relayer );
        token.approve( address(bondroute), type(uint256).max );

        vm.prank( relayer );
        bondroute.execute_bond_as( execution_data, USER, signature, false );

        assertFalse( protocol.did_reentrancy_succeed(), "execute_bond_as -> create_bond should be blocked" );
    }

    function test_execute_bond_as_to_liquidate_blocked() public
    {
        // Create an expired bond to liquidate
        TokenAmount memory expired_stake  =  TokenAmount({ token: token, amount: 50e18 });
        bytes32 expired_commitment_hash  =  _create_expired_bond( expired_stake, 900 );

        // Create a bond to execute via execute_bond_as
        TokenAmount memory stake  =  TokenAmount({ token: token, amount: 50e18 });
        ExecutionData memory execution_data  =  _create_test_execution_data( stake, 901 );
        bytes32 commitment_hash  =  bondroute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondroute.create_bond( commitment_hash, stake );
        vm.roll( block.number + 1 );

        // Get signature
        ( bytes32 digest, , , )  =  bondroute.__OFF_CHAIN__get_signing_info( execution_data );
        ( uint8 v, bytes32 r, bytes32 s )  =  vm.sign( USER_PRIVATE_KEY, digest );
        bytes memory signature  =  abi.encodePacked( r, s, v );

        // Setup reentrancy
        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  expired_commitment_hash;
        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  expired_stake;

        protocol.set_reentrancy_call( address(bondroute), abi.encodeCall( bondroute.liquidate_expired_bonds, ( commitment_hashes, stakes, COLLECTOR ) ) );

        // Give relayer tokens
        address relayer  =  address(0x9999);
        token.mint( relayer, 1000e18 );
        vm.prank( relayer );
        token.approve( address(bondroute), type(uint256).max );

        vm.prank( relayer );
        bondroute.execute_bond_as( execution_data, USER, signature, false );

        assertFalse( protocol.did_reentrancy_succeed(), "execute_bond_as -> liquidate should be blocked" );
    }
}
