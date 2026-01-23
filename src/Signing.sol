// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Core, ExecutionData } from "./Core.sol";
import { ValidationLib } from "./ValidationLib.sol";
import { HashLib } from "./HashLib.sol";
import { IBondRouteProtected } from "@BondRouteProtected/BondRouteProtected.sol";
import "./Definitions.sol";


/**
 * @title Signing
 * @notice EIP-712 signature preparation for `execute_bond_as()`
 * @dev Handles custom type strings from integrators and builds typed data for signing
 */
abstract contract Signing is Core {

    function _get_signing_data_for_execute_bond_as( ExecutionData memory execution_data )
    internal view returns ( bytes32 digest, bytes32 type_hash, string memory type_string )
    {
        bytes32 calldata_hash;
        ( string memory custom_typed_string, bytes32 struct_hash )  =  _try_get_custom_signing_info( execution_data.protocol, execution_data.call );
        if(  bytes(custom_typed_string).length > 0  )
        {
            // Integrator provided custom type.
            type_string     =   custom_typed_string;
            type_hash       =   keccak256( bytes(type_string) );
            calldata_hash   =   struct_hash;
        }
        else
        {
            // No custom type - use generic calldata_hash fallback.
            type_string     =   TYPE_STRING_EXECUTE_BOND_AS;
            type_hash       =   TYPE_HASH_EXECUTE_BOND_AS;
            calldata_hash   =   keccak256( execution_data.call );
        }

        bytes32 final_struct_hash  =  HashLib.calc_struct_hash_for_execute_bond_as( execution_data, type_hash, calldata_hash );
        digest  =  _hashTypedDataV4( final_struct_hash );
    }

    function _try_get_custom_signing_info( IBondRouteProtected protocol, bytes memory call )
    internal view returns ( string memory typed_string, bytes32 struct_hash )
    {
        // *NOTE*  -  Use try-catch to gracefully handle protocols that don't implement `BondRoute_get_signing_info()`.
        //
        // *NOTE*  -  ABI decode of return data happens OUTSIDE try scope — malformed data causes uncaught panic.
        //            Acceptable: if `__OFF_CHAIN__get_signing_info()` worked at signing time but fails at execution,
        //            that's a protocol bug. User can fall back to `execute_bond` (direct, no signature required).
        try protocol.BondRoute_get_signing_info( call ) returns ( string memory _typed_string, bytes32 _struct_hash, uint256 _TokenAmount_offset )
        {
            if(  bytes(_typed_string).length > 0  )
            {
                // *SECURITY*  -  Validate that typed_string starts with required ExecuteBondAs prefix.
                ValidationLib.validate_typed_string_prefix( _typed_string );

                // *SECURITY*  -  Validate TokenAmount definition to prevent protocol from redefining it.
                ValidationLib.validate_TokenAmount_definition( _typed_string, _TokenAmount_offset );
            }
            return ( _typed_string, _struct_hash );
        }
        catch
        {
            return ( "", bytes32(0) );
        }
    }

}
