// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { Storage } from "./Storage.sol";
import { TransferLib } from "./utils/TransferLib.sol";
import { ValidationLib } from "./ValidationLib.sol";
import { HashLib } from "./HashLib.sol";
import { IERC20, IBondRouteProtected, TokenAmount, BondContext, NATIVE_TOKEN } from "@BondRouteProtected/BondRouteProtected.sol";
import "./Definitions.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error Invalid( string field, uint256 value );
error SameBlockExecution( );
error BondAlreadySettled( BondStatus status );
error BondExpired( uint256 expired_time, uint256 current_time );
error InsufficientNativeFunding( uint256 held, uint256 expected_msg_value );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event BondCreated( bytes32 indexed commitment_hash, address stake_token, uint256 stake_amount );
event BondExecuted( bytes32 indexed commitment_hash );
event BondProtocolReverted( bytes32 indexed commitment_hash, bytes call_output );
event BondValidationFailed( bytes32 indexed commitment_hash, string reason );


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Complete bond data used throughout the bond lifecycle
 * @dev Used by frontends and wallets to:
 *      - Calculate commitment_hash (via `__OFF_CHAIN__calc_commitment_hash()`)
 *      - Create bonds (pass hash to `create_bond()`)
 *      - Execute bonds (pass full data to `execute_bond()` or `execute_bond_as()`)
 *      - Generate signatures (via `__OFF_CHAIN__get_signing_info()`)
 */
struct ExecutionData {
    TokenAmount[] fundings;
    TokenAmount stake;
    uint256 salt;
    IBondRouteProtected protocol;
    bytes call;
}


/**
 * @title Core
 * @notice Internal bond execution logic
 */
abstract contract Core is Storage, EIP712 {

    constructor( )
    EIP712( EIP712_DOMAIN_NAME, EIP712_DOMAIN_VERSION ) { }


    // ━━━━  BOND EXECUTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @return status Final bond status (`EXECUTED`, `INVALID_BOND`, or `PROTOCOL_REVERTED`)
     * @return output Validation reason on invalid bond, revert data on protocol failure, or protocol return data on success
     */
    function _execute_bond_internal( address user, ExecutionData memory execution_data ) internal returns ( BondStatus status, bytes memory output )
    {
        bytes32 commitment_hash  =  HashLib.calc_commitment_hash( user, address(this), execution_data );

        // May revert with `BondNotFound()`.
        ( BondInfo memory bond_info, bytes32 bond_key, uint256 packed_value )  =  _get_bond_info( commitment_hash, execution_data.stake );

        if(  bond_info.status != BondStatus.ACTIVE  )  revert BondAlreadySettled( bond_info.status );

        if(  block.number == bond_info.creation_block  )  revert SameBlockExecution( );  // *SECURITY* - Would defeat the commit-reveal purpose.

        // *NOTE*  -  Each protocol may define its own execution window. We are just checking for a hard cap max execution time.
        uint256 execution_deadline;
        unchecked {  execution_deadline = bond_info.creation_time + MAX_BOND_LIFETIME;  }  // *GAS SAVING*  -  Safe bc timestamp + constant won't overflow.
        if(  block.timestamp > execution_deadline  )  revert BondExpired({ expired_time: execution_deadline, current_time: block.timestamp });

        ( bool is_valid, string memory invalid_reason )  =  ValidationLib.is_valid_execution( execution_data );
        if(  is_valid == false  )
        {
            // For an invalid bond assume a frontend bug and gracefully return any stake to the user.
            _set_bond_status( bond_key, packed_value, BondStatus.INVALID_BOND );

            // *SECURITY*  -  `_return_user_funds()` might enter user controlled code! Safe bc:
            //                   - Context hash was never set (execution never started, cant call `transfer_funding()`);
            //                   - All bond interactions within `lockAndAllow()`;
            //                   - Bond status already marked as INVALID_BOND (above);
            _return_user_funds({
                stake_token: execution_data.stake.token,
                stake_amount_received: bond_info.stake_amount_received,
                user: user,
                might_have_been_consumed: false  // *GAS SAVING*  -  Avoids reading `__transient__held_stake` and `__transient__held_msg_value`.
            });

            emit BondValidationFailed( commitment_hash, invalid_reason );

            return ( BondStatus.INVALID_BOND, bytes(invalid_reason) );
        }

        _revert_if_insufficient_native_amount( execution_data.stake, execution_data.fundings );

        //━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        //  Bond validated. Prepare execution context.
        //
        __transient__held_stake      =  bond_info.stake_amount_received;
        __transient__held_msg_value  =  msg.value;

        BondContext memory context  =  BondContext({
            user:                       user,
            stake:                      execution_data.stake,
            fundings:                   execution_data.fundings,
            creation_block:             bond_info.creation_block,
            creation_timestamp:         bond_info.creation_time
        });
        uint256 initial_context_hash  =  HashLib.calc_context_hash( execution_data.protocol, context );

        //━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        //  *SECURITY*  -  Use low-level call to control a tight window in which `transfer_funding()` can be called.
        //
        __transient__context_hash  =  initial_context_hash;

        bool did_call_succeed;
        ( did_call_succeed, output )  =  address(execution_data.protocol).call(
            abi.encodeCall( IBondRouteProtected.BondRoute_entry_point, ( execution_data.call, context ) )
        );

        __transient__context_hash  =  0;
        //━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        if(  did_call_succeed  )
        {
            _set_bond_status( bond_key, packed_value, BondStatus.EXECUTED );

            emit BondExecuted( commitment_hash );

            status  =  BondStatus.EXECUTED;
        }
        else
        {
            // *SECURITY*  -  Keep stake locked if possibly bond farming (trying to recover stakes from unprofitable bonds after bond farming).
            //             -  May be erronously flagged if transaction sent with low gas. A legit user will just retry.
            ValidationLib.revert_if_possibly_bond_farming( output );

            // If we reach here: protocol reverted with some specific error, let's settle this bond and return user's stake (and/or native funding).

            _set_bond_status( bond_key, packed_value, BondStatus.PROTOCOL_REVERTED );

            emit BondProtocolReverted( commitment_hash, output );

            status  =  BondStatus.PROTOCOL_REVERTED;
        }

        // *GAS SAVING*  -  No need to clear `__transient__held_stake` and `__transient__held_msg_value` bc they are always overwritten before being read.

        // *SECURITY*  -  `_return_user_funds()` might enter user controlled code! Safe bc:
        //                   - Already cleared context hash above (cant call `transfer_funding()`);
        //                   - All bond interactions within `lockAndAllow()`;
        //                   - Bond status already marked as settled;
        _return_user_funds({
            stake_token: execution_data.stake.token,
            stake_amount_received: bond_info.stake_amount_received,
            user: user,
            might_have_been_consumed: ( status == BondStatus.EXECUTED )  // Only potentially consumed if execution succeeded, otherwise any consumption reverted.
        });

        return ( status, output );
    }


    // ━━━━  PRIVATE HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _revert_if_insufficient_native_amount( TokenAmount memory stake, TokenAmount[] memory fundings ) private view
    {
        uint native_amount_held  =  msg.value;
        if(  address(stake.token) == address(NATIVE_TOKEN) )
        {
            unchecked {  native_amount_held  =  native_amount_held + stake.amount;  }  // *GAS SAVING*  -  Safe bc native token amounts cannot overflow uint256.
        }

        uint native_funding  =  0;
        unchecked   // *GAS SAVING*  -  Safe bc `i++` is bounded by `fundings.length` (max 4, `MAX_FUNDINGS_PER_BOND`).
        {
            for(  uint i = 0  ;  i < fundings.length  ;  i++  )
            {
                if(  address(fundings[ i ].token) == address(NATIVE_TOKEN)  )
                {
                    native_funding  =  fundings[ i ].amount;
                    break;
                }
            }
        }

        // Revert if actual held native funding (via stake and or `msg.value`) is lower than declared at fundings.
        if(  native_amount_held < native_funding  )
        {
            // *NOTE*  -  Allow native amount staked or sent to be greater than actual funding bc:
            //            1) BondRouteProtected contracts may require a minimum native stake without funding.
            //            2) BondRouteProtected contracts can only consume at max the amount set as funding.
            //            3) Any unconsumed value (stake or msg.value) will be returned to the user at the end of bond execution.
            uint expected_msg_value  =  native_funding;

            if(  address(stake.token) == address(NATIVE_TOKEN)  )
            {
                unchecked  // *GAS SAVING* - Underflow impossible: `msg.value + stake.amount < native_funding`, therefore `stake.amount < native_funding`.
                {
                    expected_msg_value  =  expected_msg_value - stake.amount;
                }
            }

            revert InsufficientNativeFunding( native_amount_held, expected_msg_value );
        }
    }

    function _return_user_funds( IERC20 stake_token, uint256 stake_amount_received, address user, bool might_have_been_consumed ) private
    {
        // If stake is in native token then we try to aggregate it with `msg.value` to transfer the sum in a single call.
        if(  address(stake_token) == address(NATIVE_TOKEN)  )
        {
            uint total_to_return;

            unchecked  // *GAS SAVING*  -  Safe bc native amounts can't overflow.
            {
                if(  might_have_been_consumed  )
                {
                    // Transient vars contain remaining amounts after consumption during bond execution.
                    total_to_return  =  __transient__held_msg_value + __transient__held_stake;
                }
                else
                {
                    // Nothing was consumed - return original amounts.
                    total_to_return  =  msg.value + stake_amount_received;
                }
            }

            TransferLib.transfer_native({ to: user, amount: total_to_return });
        }
        else
        {
            // Return unused native token (msg.value) in our possession to the user.
            if(  msg.value > 0  )
            {
                uint msg_value_to_return;

                if(  might_have_been_consumed  )
                {
                    msg_value_to_return  =  __transient__held_msg_value;
                }
                else
                {
                    msg_value_to_return  =  msg.value;
                }

                TransferLib.transfer_native({ to: user, amount: msg_value_to_return });
            }

            // Return unused stake in our possession to the user.
            if(  stake_amount_received > 0  )
            {
                uint stake_to_return;

                if(  might_have_been_consumed  )
                {
                    stake_to_return  =  __transient__held_stake;
                }
                else
                {
                    stake_to_return  =  stake_amount_received;
                }

                TransferLib.transfer_erc20({ token: stake_token, from: address(this), to: user, amount: stake_to_return });
            }
        }
    }

}
