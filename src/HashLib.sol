// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TokenAmount, BondContext, IBondRouteProtected } from "./integrations/BondRouteProtected.sol";
import { ExecutionData } from "./Core.sol";
import { TYPE_HASH_TOKEN_AMOUNT } from "./Definitions.sol";

library HashLib {

    /// @notice Compute sentineled commitment hash with structured layout.
    /// @dev Layout: [3 bytes 0xCAFFE0 prefix][6 bytes zeros][21 bytes hash][2 bytes sentinel]
    ///      Sentinel validates: chainid, stake token, stake amount, hash integrity.
    /// @dev *WARNING* Writes 0x100 bytes at free memory pointer without updating or clearing it.
    function calc_commitment_hash( address user, address bondroute, ExecutionData memory execution_data ) internal view returns ( bytes32 result )
    {
        bytes32 fundings_hash   =  hash_fundings( execution_data.fundings );
        bytes32 call_hash       =  keccak256( execution_data.call );  // forge-lint: disable-line(asm-keccak256)
        address stake_token     =  address(execution_data.stake.token);
        uint256 stake_amount    =  execution_data.stake.amount;
        uint256 salt            =  execution_data.salt;
        address protocol        =  address(execution_data.protocol);

        // *SECURITY*  -  Binds: chain, BondRoute address, user, fundings, stake, salt, protocol, call.
        //                All dynamic data is pre-hashed to fixed 32-byte values, preventing field drift.
        //                Sentinel further binds chainid + stake + hash integrity for validation at bond creation.
        assembly ("memory-safe")  // *GAS SAVING*  -  Avoids abi.encode overhead for struct with dynamic fields.
        {
            let ptr  :=  mload( 0x40 )

            // Layout with packed chainid|token for gas-efficient sentinel reuse.
            mstore( ptr,              bondroute )
            mstore( add(ptr, 0x20),   user )
            mstore( add(ptr, 0x40),   fundings_hash )
            mstore( add(ptr, 0x60),   salt )
            mstore( add(ptr, 0x80),   protocol )
            mstore( add(ptr, 0xa0),   call_hash )
            mstore( add(ptr, 0xc0),   or( shl(160, chainid()), stake_token ) )  // ┐ Packed for sentinel reuse.
            mstore( add(ptr, 0xe0),   stake_amount )                            // ┘

            // Raw intent hash (8 words = 0x100 bytes).
            let raw_hash  :=  keccak256( ptr, 0x100 )

            // Build structured commitment: [3 prefix][6 zeros][21 hash][2 zeros for sentinel]
            // shl(232, 0xCAFFE0) places prefix at bits 255-232 (top 3 bytes).
            // shr(88, raw_hash) extracts top 168 bits (21 bytes).
            // shl(16, ...) shifts left to make room for 2-byte sentinel at bits 15-0.
            let without_sentinel  :=  or(
                shl( 232, 0xCAFFE0 ),
                shl( 16, shr( 88, raw_hash ) )
            )

            // Overwrite call_hash slot (ptr + 0xa0) with structured commitment.
            mstore( add(ptr, 0xa0), without_sentinel )

            // Sentinel hash reuses packed chainid|token and stake_amount already in memory.
            // ptr + 0xa0:  without_sentinel       (just written)
            // ptr + 0xc0:  chainid | stake_token  (already there)
            // ptr + 0xe0:  stake_amount           (already there)
            let sentinel  :=  and(
                keccak256( add(ptr, 0xa0), 0x60 ),
                0xFFFF
            )
            // calldatacopy( ptr, calldatasize(), 0x100 )  // Clears memory; reading past calldata returns 0 per EVM spec.

            result  :=  or( without_sentinel, sentinel )
        }
    }

    /// @notice Check if commitment hash is valid.
    /// @dev Recomputes expected sentinel from (commitment_without_sentinel, chainid, stake) and compares.
    function is_valid_commitment_hash( bytes32 commitment_hash, TokenAmount memory stake ) internal view returns ( bool result )
    {
        address token   =  address(stake.token);
        uint256 amount  =  stake.amount;

        assembly ("memory-safe")
        {
            // Clear sentinel (low 2 bytes) and recompute expected.
            let without_sentinel  :=  and( commitment_hash, not(0xFFFF) )

            let free_ptr  :=  mload( 0x40 )
            mstore( 0x00, without_sentinel )
            mstore( 0x20, or( shl(160, chainid()), token ) )  // Packed chainid|token.
            mstore( 0x40, amount )

            let expected_sentinel  :=  and( keccak256( 0x00, 0x60 ), 0xFFFF )
            let expected_hash      :=  or( without_sentinel, expected_sentinel )

            mstore( 0x40, free_ptr )  // Restore free memory pointer.

            result  :=  eq( expected_hash, commitment_hash )
        }
    }

    /// @dev *WARNING* Writes length*0x40 bytes at free memory pointer without updating or clearing it.
    ///      If uninitialized memory must be zero, uncomment the calldatacopy line at end of assembly block.
    function hash_fundings( TokenAmount[] memory fundings ) internal pure returns ( bytes32 result )
    {
        uint length  =  fundings.length;
        if(  length == 0  )  return bytes32(0);

        // *NOTE*  -  Assembly pointer math validated against Solidity reference in "test/HashLib/HashLib.t.sol".

        assembly ("memory-safe")  // *GAS SAVING*  -  Assembly avoids abi.encode overhead.
        {
            let ptr  :=  mload( 0x40 )
            for { let i := 0 } lt( i, length ) { i := add(i, 1) }
            {
                let funding_ptr  :=  mload( add( add(fundings, 0x20), mul(i, 0x20) ) )
                let token   :=  mload( funding_ptr )
                let amount  :=  mload( add(funding_ptr, 0x20) )
                mstore( add(ptr, mul(i, 0x40)),            token )
                mstore( add(ptr, add(mul(i, 0x40), 0x20)), amount )
            }
            result  :=  keccak256( ptr, mul(length, 0x40) )
            // calldatacopy( ptr, calldatasize(), mul(length, 0x40) )  // Clears memory; reading past calldata returns 0 per EVM spec.
        }
    }

    function calc_bond_key( bytes32 commitment_hash, TokenAmount memory stake ) internal pure returns ( bytes32 result )
    {
        // *SECURITY*  -  Must hash in the `commitment_hash` with the stake or we would be vulnerable to griefing
        //                if an attacker would frontrun the bond creation with a bogus stake, causing the legit
        //                user to fail with `error BondAlreadyExists()`.
        address token   =  address(stake.token);
        uint256 amount  =  stake.amount;
        assembly ("memory-safe")  // *GAS SAVING*  -  Assembly avoids abi.encode overhead (~230 gas saved per call).
        {
            let free_ptr  :=  mload( 0x40 )
            mstore( 0x00, commitment_hash )
            mstore( 0x20, token )
            mstore( 0x40, amount )
            result  :=  keccak256( 0x00, 0x60 )
            mstore( 0x40, free_ptr )
        }
    }

    /// @dev *WARNING* Writes 0xa0 bytes at free memory pointer without updating or clearing it.
    ///      If uninitialized memory must be zero, uncomment the calldatacopy line at end of assembly block.
    function calc_context_hash( IBondRouteProtected protocol, BondContext memory context ) internal pure returns ( uint256 result )
    {
        bytes32 fundings_hash  =  hash_fundings( context.fundings );
        address user           =  context.user;
        address stake_token    =  address(context.stake.token);
        uint256 stake_amount   =  context.stake.amount;

        // *SECURITY*  -  Used to validate that `transfer_funding()` calls made during bond execution
        //                come from the authorized `protocol` and are passed the exact correct context
        //                (user, stake, up-to-date available fundings) to ensure only authorized and
        //                limited funding access.
        assembly ("memory-safe")  // *GAS SAVING*  -  Avoids abi.encode overhead for struct with dynamic field.
        {
            let ptr  :=  mload( 0x40 )
            mstore( ptr,              protocol )
            mstore( add(ptr, 0x20),   user )
            mstore( add(ptr, 0x40),   stake_token )
            mstore( add(ptr, 0x60),   stake_amount )
            mstore( add(ptr, 0x80),   fundings_hash )
            result  :=  keccak256( ptr, 0xa0 )
            // calldatacopy( ptr, calldatasize(), 0xa0 )  // Clears memory; reading past calldata returns 0 per EVM spec.
        }
    }


    // ━━━━  EIP-712 HASHES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function hash_stake_for_eip712( TokenAmount memory stake ) internal pure returns ( bytes32 result )
    {
        bytes32 type_hash  =  TYPE_HASH_TOKEN_AMOUNT;
        address token      =  address(stake.token);
        uint256 amount     =  stake.amount;
        assembly ("memory-safe")  // *GAS SAVING*  -  Assembly avoids abi.encode overhead (~200 gas saved).
        {
            let free_ptr  :=  mload( 0x40 )
            mstore( 0x00, type_hash )
            mstore( 0x20, token )
            mstore( 0x40, amount )
            result  :=  keccak256( 0x00, 0x60 )
            mstore( 0x40, free_ptr )
        }
    }

    function hash_fundings_for_eip712( TokenAmount[] memory fundings ) internal pure returns ( bytes32 result )
    {
        bytes32[] memory hashes  =  new bytes32[]( fundings.length );
        bytes32 type_hash  =  TYPE_HASH_TOKEN_AMOUNT;

        unchecked   // *GAS SAVING*  -  Safe bc `i++` is bounded by array length.
        {
            for(  uint i = 0  ;  i < fundings.length  ;  i++  )
            {
                address token   =  address(fundings[ i ].token);
                uint256 amount  =  fundings[ i ].amount;
                bytes32 hash;
                assembly ("memory-safe")  // *GAS SAVING*  -  Assembly avoids abi.encode overhead (~200 gas saved per funding).
                {
                    let free_ptr  :=  mload( 0x40 )
                    mstore( 0x00, type_hash )
                    mstore( 0x20, token )
                    mstore( 0x40, amount )
                    hash  :=  keccak256( 0x00, 0x60 )
                    mstore( 0x40, free_ptr )
                }
                hashes[ i ]  =  hash;
            }
        }

        assembly ("memory-safe")  // *GAS SAVING*  -  Hash array elements directly without Solidity overhead.
        {
            let array_length  :=  mload( hashes )
            result  :=  keccak256(
                add( hashes, 32 ),        // Sets the pointer to the hashes values (past the array length).
                mul( array_length, 32 )   // Sets the size in bytes. Each entry is 32 bytes.
            )
        }
    }

    /// @dev *WARNING* Writes 0xc0 bytes at free memory pointer without updating or clearing it.
    ///      If uninitialized memory must be zero, uncomment the calldatacopy line at end of assembly block.
    function calc_struct_hash_for_execute_bond_as( ExecutionData memory execution_data, bytes32 type_hash, bytes32 calldata_hash )
    internal pure returns ( bytes32 result )
    {
        bytes32 fundings_hash  =  hash_fundings_for_eip712( execution_data.fundings );
        bytes32 stake_hash     =  hash_stake_for_eip712( execution_data.stake );
        uint256 salt           =  execution_data.salt;
        address protocol       =  address(execution_data.protocol);

        assembly ("memory-safe")  // *GAS SAVING*  -  Assembly avoids abi.encode overhead (~400 gas saved).
        {
            let ptr  :=  mload( 0x40 )
            mstore( ptr,              type_hash )
            mstore( add(ptr, 0x20),   fundings_hash )
            mstore( add(ptr, 0x40),   stake_hash )
            mstore( add(ptr, 0x60),   salt )
            mstore( add(ptr, 0x80),   protocol )
            mstore( add(ptr, 0xa0),   calldata_hash )
            result  :=  keccak256( ptr, 0xc0 )
            // calldatacopy( ptr, calldatasize(), 0xc0 )  // Clears memory; reading past calldata returns 0 per EVM spec.
        }
    }
}
