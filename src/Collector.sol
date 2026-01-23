// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Provider } from "./Provider.sol";
import { Invalid, BondAlreadySettled } from "./Core.sol";
import { TokenAmount, Unauthorized, NATIVE_TOKEN } from "@BondRouteProtected/BondRouteProtected.sol";
import { TransferLib } from "./utils/TransferLib.sol";
import "./Definitions.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error BondNotExpired( uint256 expiration_time, uint256 current_time );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event CollectorTransferInitiated( address indexed pending_collector );
event CollectorTransferCompleted( address indexed collector );
event ExpiredBondLiquidated( bytes32 indexed commitment_hash, address indexed token, uint256 amount, address recipient );


/**
 * @title Collector
 * @notice Collector functionality for expired bonds
 */
abstract contract Collector is Provider {

    /**
     * @notice Initialize Collector with collector address
     * @param collector Address that will liquidate expired bonds
     *
     * @dev ERROR CODES:
     *      - `Invalid(string field, uint256 value)` if `collector` is zero address
     */
    constructor( address collector )
    {
        if(  collector == address(0)  )  revert Invalid({ field: "collector", value: 0 });

        _collector  =  collector;
    }


    // ━━━━  COLLECTOR ROLE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Get the current collector address
     */
    function get_collector( )
    external view returns ( address )
    {
        return _collector;
    }

    /**
     * @notice Appoint a new collector (two-step process)
     * @param new_collector Address of the new collector
     *
     * @dev EMITTED EVENTS:
     *      - `CollectorTransferInitiated(pending_collector)` upon successful initiation
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not current collector
     *      - `Invalid(string field, uint256 value)` if `new_collector` is zero address
     */
    function appoint_new_collector( address new_collector )
    external
    {
        if(  msg.sender != _collector  )      revert Unauthorized({ caller: msg.sender, expected: _collector });
        if(  new_collector == address(0)  )   revert Invalid({ field: "new_collector", value: 0 });

        _pending_collector  =  new_collector;

        emit CollectorTransferInitiated({ pending_collector: new_collector });
    }

    /**
     * @notice Claim the collector role (second step of two-step process)
     *
     * @dev EMITTED EVENTS:
     *      - `CollectorTransferCompleted(collector)` upon successful role claim
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not the pending collector
     */
    function claim_collector_role( )
    external
    {
        if(  msg.sender != _pending_collector  )  revert Unauthorized({ caller: msg.sender, expected: _pending_collector });

        _collector  =  msg.sender;
        _pending_collector  =  address(0);

        emit CollectorTransferCompleted( _collector );
    }


    // ━━━━  LIQUIDATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Liquidate expired bonds and transfer stakes to recipient
     * @param commitment_hashes Array of commitment hashes from bond creation
     * @param stakes Array of stakes used during bond creation (must match commitment_hashes length)
     * @param recipient Address to receive the liquidated stakes
     *
     * @dev EMITTED EVENTS:
     *      - `ExpiredBondLiquidated(commitment_hash, token, amount, recipient)` for each successfully liquidated bond
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not the collector
     *      - `Invalid(string field, uint256 value)` if `recipient` is zero address
     *      - `Invalid(string field, uint256 value)` if array lengths don't match
     *      - `BondNotFound(bytes32 commitment_hash, address stake_token, uint256 stake_amount)` if any bond doesn't exist
     *      - `BondAlreadySettled(BondStatus status)` if any bond was already settled
     *      - `BondNotExpired(uint256 expiration_time, uint256 current_time)` if any bond has not exceeded `MAX_BOND_LIFETIME`
     *      - `TransferFailed(address from, address token, uint256 amount, address to)` if any transfer fails
     *      - `Reentrancy()` if nested within a BondRoute function call
     */
    function liquidate_expired_bonds( bytes32[] calldata commitment_hashes, TokenAmount[] calldata stakes, address recipient )
    external  lockAndAllow( LIQUIDATE, ALLOW_NONE )
    {
        if(  msg.sender != _collector  )                        revert Unauthorized({ caller: msg.sender, expected: _collector });
        if(  recipient == address(0)  )                         revert Invalid({ field: "recipient", value: 0 });
        if(  commitment_hashes.length != stakes.length  )       revert Invalid({ field: "array_length_mismatch", value: 0 });

        unchecked   // *GAS SAVING*  -  Safe bc `i++` is bounded by array length.
        {
            for(  uint i = 0  ;  i < commitment_hashes.length  ;  i++  )
            {
                _liquidate_expired_bond( commitment_hashes[ i ], stakes[ i ], recipient );
            }
        }
    }

    function _liquidate_expired_bond( bytes32 commitment_hash, TokenAmount memory stake, address recipient ) private
    {
        ( BondInfo memory bond_info, bytes32 bond_key, uint256 packed_value )  =  _get_bond_info( commitment_hash, stake );  // Reverts if bond is not found.

        if(  bond_info.status != BondStatus.ACTIVE  )  revert BondAlreadySettled( bond_info.status );

        uint256 expiration_time;
        unchecked {  expiration_time = bond_info.creation_time + MAX_BOND_LIFETIME;  }  // *GAS SAVING*  -  Safe bc timestamp + constant won't overflow.
        if(  block.timestamp < expiration_time  )  revert BondNotExpired({ expiration_time: expiration_time, current_time: block.timestamp });

        _set_bond_status( bond_key, packed_value, BondStatus.LIQUIDATED );

        if(  address(stake.token) == address(NATIVE_TOKEN)  )
        {
            TransferLib.transfer_native({ to: recipient, amount: bond_info.stake_amount_received });
        }
        else
        {
            TransferLib.transfer_erc20({ token: stake.token, from: address(this), to: recipient, amount: bond_info.stake_amount_received });
        }

        emit ExpiredBondLiquidated( commitment_hash, address(stake.token), bond_info.stake_amount_received, recipient );
    }
}
