// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Signing } from "./Signing.sol";
import { Invalid, BondCreated, ExecutionData } from "./Core.sol";
import { TokenAmount, NATIVE_TOKEN } from "@BondRouteProtected/BondRouteProtected.sol";
import { SignatureValidator } from "./utils/SignatureValidator.sol";
import { TransferLib } from "./utils/TransferLib.sol";
import { HashLib } from "./HashLib.sol";
import { ValidationLib } from "./ValidationLib.sol";
import { BondStatus, CREATE_BOND, EXECUTE_BOND, ALLOW_NONE } from "./Definitions.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error NativeAmountMismatch( uint256 sent, uint256 expected );
error CommitmentMismatch( bytes32 commitment_hash, uint256 chain_id, address stake_token, uint256 stake_amount );
error InvalidSignature( address signer, bytes32 digest, bytes signature );


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct EIP712Domain {
    string name;
    string version;
    uint256 chainId;
    address verifyingContract;
}


/**
 * @title User
 * @notice User-facing bond operations and off-chain helper functions
 */
abstract contract User is Signing {

    /**
     * @notice Create a bond with optional stake
     * @param commitment_hash Hash of the execution intent — use `__OFF_CHAIN__calc_commitment_hash()` to compute
     * @param stake Token and amount to stake (`NATIVE_TOKEN` or `address(0)` for native, `amount = 0` for stakeless)
     *
     * @dev *WARNING* - BOND EXPIRATION:
     *      Bonds must be executed within the protocol-defined window or stake is forfeited.
     *      Hard cap of 111 days (`MAX_BOND_LIFETIME`) enforced by BondRoute — after which the bond can be liquidated by collector.
     *
     * @dev USER STAKING MODEL:
     *      - Native stake: `stake.token = NATIVE_TOKEN` and `stake.amount == msg.value`
     *      - ERC20 stake: `msg.value == 0` and BondRoute must have token approval
     *      - Fee-on-transfer tokens: accepted, actual received amount measured
     *      - Rebase tokens: NOT supported (amount fixed at stake time)
     *
     * @dev APPROVAL REQUIREMENTS:
     *      - Stake token: transferred immediately and held by BondRoute
     *      - Funding tokens: remain with user, transferred during `execute_bond()` as directed by protocol
     *      Example: 1,000 USDC swap with 10% stake → approve BondRoute for USDC,
     *               create with 100 USDC stake, execute pulls remaining 900 USDC
     *
     * @dev EMITTED EVENTS:
     *      - `BondCreated(commitment_hash, stake_token, stake_amount)` on success
     *
     * @dev ERROR CODES:
     *      - `CommitmentMismatch(bytes32 commitment_hash, uint256 chain_id, address stake_token, uint256 stake_amount)` if invalid
     *      - `Invalid(string field, uint256 value)` if `stake.amount` is zero for ERC20 stake
     *      - `NativeAmountMismatch(uint256 sent, uint256 expected)` if `msg.value` doesn't match stake semantics
     *      - `BondAlreadyExists(bytes32 commitment_hash, address stake_token, uint256 stake_amount)` if bond already exists
     *      - `UnsupportedStake(uint256 amount_sent, uint256 amount_received)` if transfer delta exceeds `type(int128).max`
     *      - `TransferFailed(address from, address token, uint256 amount, address to)` if ERC20 transfer fails
     *      - `Reentrancy()` if nested within a BondRoute function call
     */
    function create_bond( bytes32 commitment_hash, TokenAmount memory stake )
    external  payable  lockAndAllow( CREATE_BOND, ALLOW_NONE )
    {
        // *SECURITY*  -  Commitment hash encodes chainid, stake, and integrity checksum. Validation prevents
        //                accidental stake loss from wrong chain, mismatched stake, or corrupted hash.
        bool is_valid_commitment_hash  =  HashLib.is_valid_commitment_hash( commitment_hash, stake );
        if(  is_valid_commitment_hash == false  )  revert CommitmentMismatch( commitment_hash, block.chainid, address(stake.token), stake.amount );

        uint256 amount_received;
        if(  address(stake.token) == address(NATIVE_TOKEN)  )
        {
            if(  msg.value != stake.amount  )  revert NativeAmountMismatch({ sent: msg.value, expected: stake.amount });

            amount_received  =  stake.amount;
        }
        else
        {
            if(  msg.value > 0  )       revert NativeAmountMismatch({ sent: msg.value, expected: 0 });
            if(  stake.amount == 0  )   revert Invalid({ field: "stake.amount", value: 0 });

            // *NOTE*  -  Actual amount received might be different than intended due to "fee-on-transfer" or other exotic tokens.
            amount_received  =  TransferLib.transfer_erc20_and_get_amount_delivered(
                {  token: stake.token,  from: msg.sender,  to: address(this),  amount: stake.amount  }
            );
        }

        _create_bond_internal( commitment_hash, stake, amount_received );

        // *NOTE*  -  Emit `stake.amount` and not `amount_received` bc that is what the collector needs to liquidate the bond.
        emit BondCreated( commitment_hash, address(stake.token), stake.amount );
    }

    /**
     * @notice Execute a bond and recover stake
     * @param execution_data Execution data matching the original commitment
     * @return status Final bond status (`EXECUTED`, `INVALID_BOND`, or `PROTOCOL_REVERTED`)
     * @return output Validation reason on invalid bond, revert data on protocol failure, or protocol return data on success
     *
     * @dev *WARNING* - BOND EXPIRATION:
     *      Bonds must be executed within the protocol-defined window or stake is forfeited.
     *      Hard cap of 111 days (`MAX_BOND_LIFETIME`) enforced by BondRoute — after which the bond can be liquidated by collector.
     *
     * @dev BOND FARMING PROTECTION:
     *      - This function intentionally reverts on user-controllable failures (`TransferFailed`, `Reentrancy`, OOG), keeping
     *        stake locked - legitimate users may just fix the issue and retry. Protocols can also revert with `PossiblyBondFarming` 
     *        to trigger the same behavior.
     *      - Why: without this, attackers could create many bonds, execute only profitable ones, and freely recover stakes by
     *        intentionally failing execution (revoking approval, moving fundings away, crafting a transaction to starve on gas).
     *
     * @dev STATUS SEMANTICS:
     *      - `EXECUTED`: protocol call succeeded, stake refunded; `output` is protocol result
     *      - `INVALID_BOND`: structural/validation failure, stake refunded; `output` is reason string
     *      - `PROTOCOL_REVERTED`: protocol reverted without a bond farming indicator, stake refunded; `output` is revert data
     *
     * @dev EMITTED EVENTS:
     *      - `BondValidationFailed(commitment_hash, reason)` on invalid bond
     *      - `BondProtocolReverted(commitment_hash, output)` on protocol revert without bond farming indicator
     *      - `BondExecuted(commitment_hash)` on success
     *
     * @dev ERROR CODES (call reverts):
     *      - `BondNotFound(bytes32 commitment_hash, address stake_token, uint256 stake_amount)` if no bond exists
     *      - `BondAlreadySettled(BondStatus status)` if bond was already executed, failed, or liquidated
     *      - `SameBlockExecution()` if attempting execution in same block as creation
     *      - `BondExpired(uint256 expired_time, uint256 current_time)` if bond exceeded `MAX_BOND_LIFETIME`
     *      - `InsufficientNativeFunding(uint256 held, uint256 expected)` if `msg.value` incorrect for native funding
     *      - `PossiblyBondFarming(string reason, bytes32 info)` if selective failure detected (fix and retry)
     *      - `TransferFailed(address from, address token, uint256 amount, address to)` if transfer fails
     *      - `Reentrancy()` if nested within a BondRoute function call
     */
    function execute_bond( ExecutionData memory execution_data )
    external  payable  lockAndAllow( EXECUTE_BOND, ALLOW_NONE )  returns ( BondStatus status, bytes memory output )
    {
        return _execute_bond_internal( msg.sender, execution_data );
    }

    /**
     * @notice Execute a bond on behalf of another user (signature based)
     * @param execution_data Execution data committed by `user`
     * @param user Owner of the bond
     * @param signature User's authorization for this execution
     * @param is_eip1271 Use EIP-1271 validation instead of ECDSA
     * @return status Final bond status
     * @return output Validation reason on invalid bond, revert data on protocol failure, or protocol return data on success
     *
     * @dev *WARNING* - BOND EXPIRATION:
     *      Bonds must be executed within the protocol-defined window or stake is forfeited.
     *      Hard cap of 111 days (`MAX_BOND_LIFETIME`) enforced by BondRoute — after which the bond can be liquidated by collector.
     *
     * @dev GASLESS EXECUTION:
     *      - `msg.sender` pays gas and may provide native funding via `msg.value`
     *      - Fundings are pulled from `user`, not `msg.sender`
     *      - ALL refunds (stake + unused native) always go to `user`
     *
     * @dev EMITTED EVENTS:
     *      - All events from `execute_bond()` apply
     *
     * @dev ERROR CODES (call reverts):
     *      - `InvalidSignature(address signer, bytes32 digest, bytes signature)` if signature invalid (ECDSA or EIP-1271)
     *      - All error codes from `execute_bond()` apply
     */
    function execute_bond_as( ExecutionData memory execution_data, address user, bytes memory signature, bool is_eip1271 )
    external  payable  lockAndAllow( EXECUTE_BOND, ALLOW_NONE )  returns ( BondStatus status, bytes memory output )
    {
        ( bytes32 digest, , )  =  _get_signing_data_for_execute_bond_as( execution_data );
        bool is_valid_signature  =  SignatureValidator.is_valid_signature({ signer: user, _hash: digest, signature: signature, is_eip1271: is_eip1271 });
        if(  is_valid_signature == false  )  revert InvalidSignature({ signer: user, digest: digest, signature: signature });

        return _execute_bond_internal( user, execution_data );
    }


    // ━━━━  OFF-CHAIN HELPER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Compute commitment hash for off-chain bond preparation
     * @param user Bond owner
     * @param execution_data Data to commit
     * @return commitment_hash Hash for `create_bond()`
     *
     * @dev SENTINELED COMMITMENT HASH:
     *      Returns a structured hash with `0xcaffe0...` prefix and 2-byte checksum suffix.
     *      The checksum validates chainid, stake, and hash integrity at bond creation,
     *      preventing accidental stake loss from wrong chain, mismatched stake, or corrupted hash.
     *
     * @dev ERROR CODES:
     *      - `Invalid(string field, uint256 value)` if `user` is zero address
     *      - `Error(string)` if `execution_data` is invalid (invalid protocol, too many fundings, funding with 0 amount, duplicate tokens)
     */
    function __OFF_CHAIN__calc_commitment_hash( address user, ExecutionData memory execution_data )
    external view returns ( bytes32 commitment_hash )
    {
        if(  user == address(0)  )  revert Invalid({ field: "user", value: 0 });

        ( bool is_valid, string memory invalid_reason )  =  ValidationLib.is_valid_execution( execution_data );
        if(  is_valid == false  )  revert( invalid_reason );

        return HashLib.calc_commitment_hash( user, address(this), execution_data );
    }

    /**
     * @notice Retrieve stored bond information
     * @param commitment_hash Commitment identifier
     * @param stake Stake originally provided
     * @return bond_info Creation time, creation block, received stake amount, status
     *
     * @dev ERROR CODES:
     *      - `BondNotFound(bytes32 commitment_hash, address stake_token, uint256 stake_amount)` if no matching bond exists
     */
    function __OFF_CHAIN__get_bond_info( bytes32 commitment_hash, TokenAmount memory stake )
    external view returns ( BondInfo memory bond_info )
    {
        ( bond_info, , )  =  _get_bond_info( commitment_hash, stake );
    }

    /**
     * @notice Get signing data for gasless bond execution
     * @param execution_data Execution data to sign
     * @return digest Hash to sign
     * @return type_hash EIP-712 type hash (default or protocol-customized)
     * @return type_string Complete EIP-712 type description for wallet display
     * @return domain EIP-712 domain for this deployment
     * @dev Frontends call this to build EIP-712 typed-data payloads. Returns custom types if protocol provides them.
     *
     * @dev ERROR CODES:
     *      - `InvalidTypedString(string provided, string reason)` if protocol provides malformed custom EIP-712 type string
     */
    function __OFF_CHAIN__get_signing_info( ExecutionData memory execution_data )
    external view returns ( bytes32 digest, bytes32 type_hash, string memory type_string, EIP712Domain memory domain )
    {
        ( digest, type_hash, type_string )  =  _get_signing_data_for_execute_bond_as( execution_data );

        ( , string memory name, string memory version, uint256 chainId, address verifyingContract, , )  =  eip712Domain( );

        domain  =  EIP712Domain({
            name:               name,
            version:            version,
            chainId:            chainId,
            verifyingContract:  verifyingContract
        });
    }

}
