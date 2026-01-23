// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { User, NativeAmountMismatch } from "./User.sol";
import { Invalid } from "./Core.sol";
import { IERC20, TokenAmount, BondContext, IBondRouteProtected, InsufficientFunding, NATIVE_TOKEN } from "@BondRouteProtected/BondRouteProtected.sol";
import { TransferLib } from "./utils/TransferLib.sol";
import { HashLib } from "./HashLib.sol";
import "./Definitions.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error Forbidden( address caller, uint256 calculated_hash, uint256 expected_hash );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event ProtocolAnnounced( address indexed protocol, string name, string description );
event Airdrop( address indexed sender, address indexed protocol, address indexed token, uint256 amount, string message );


/**
 * @title Provider
 * @notice Service layer providing functionality to BondRoute-protected contracts
 */
abstract contract Provider is User {

    /**
     * @notice Announce a protocol for on-chain discovery
     * @param name Protocol name (1-64 chars)
     * @param description Short description (0-280 chars, optional)
     *
     * @dev Call from protocol constructor for automatic discovery.
     *      Intentionally permissionless — cannot verify caller legitimacy or protected selectors
     *      because announcements may occur during construction (before code is deployed).
     *
     * @dev Optionally call `airdrop()` to attach economic signal for indexer filtering/sorting.
     *
     * @dev EMITTED EVENTS:
     *      - `ProtocolAnnounced(protocol, name, description)` on success
     *
     * @dev ERROR CODES:
     *      - `Invalid(string field, uint256 value)` if `name` is empty or exceeds 64 bytes
     *      - `Invalid(string field, uint256 value)` if `description` exceeds 280 bytes
     */
    function announce_protocol( string calldata name, string calldata description )
    external
    {
        if(  bytes(name).length == 0  ||  bytes(name).length > MAX_NAME_LENGTH  )   revert Invalid({ field: "name.length", value: bytes(name).length });
        if(  bytes(description).length > MAX_MESSAGE_LENGTH  )  revert Invalid({ field: "description.length", value: bytes(description).length });

        emit ProtocolAnnounced({ protocol: msg.sender, name: name, description: description });
    }

    /**
     * @notice Attach economic signal for off-chain discoverability filtering and sorting
     *
     * @param protocol Protocol address the signal is for (use `msg.sender` when signaling for yourself)
     * @param token Token to airdrop (`NATIVE_TOKEN` for native)
     * @param amount Amount to airdrop (must equal `msg.value` for native token, 0 allowed for message-only signals)
     * @param message Optional message (truncated to 280 bytes if exceeded)
     *
     * @dev `announce_protocol()` is intentionally permissionless — anyone can claim any name or description.
     *      This function complements it by allowing protocols to attach value as a credibility signal.
     *      Indexers and frontends can filter/sort by sender, protocol, token, and cumulative amounts.
     *
     * @dev Third-party signals supported — multisigs, DAOs, and partners can signal for protocols.
     *
     * @dev Funds transfer directly to collector — BondRoute never holds airdrops.
     *
     * @dev For gas-efficient micro-airdrops: mint directly to collector (use `get_collector()`),
     *      then optionally call with `amount=0` and a message to emit the event.
     *
     * @dev EMITTED EVENTS:
     *      - `Airdrop(sender, protocol, token, amount, message)` if `amount > 0` or message non-empty
     *
     * @dev ERROR CODES:
     *      - `NativeAmountMismatch(sent, expected)` if `msg.value` doesn't match native semantics
     *      - `TransferFailed(from, token, amount, to)` if transfer fails
     */
    function airdrop( address protocol, IERC20 token, uint256 amount, string calldata message )
    external  payable
    {
        if(  amount > 0  )
        {
            if(  address(token) == address(NATIVE_TOKEN)  )
            {
                if(  msg.value != amount  )  revert NativeAmountMismatch({ sent: msg.value, expected: amount });

                TransferLib.transfer_native({ to: _collector, amount: amount });
            }
            else
            {
                if(  msg.value > 0  )  revert NativeAmountMismatch({ sent: msg.value, expected: 0 });

                TransferLib.transfer_erc20({ token: token, from: msg.sender, to: _collector, amount: amount });
            }
        }
        else
        {
            if(  msg.value > 0  )  revert NativeAmountMismatch({ sent: msg.value, expected: 0 });
        }

        // *NOTE*  -  We rather truncate the message instead of reverting if it exceeds the max length allowed.
        string memory truncated_message  =  message;
        if(  bytes(message).length > MAX_MESSAGE_LENGTH  )
        {
            assembly ("memory-safe") {  mstore( truncated_message, MAX_MESSAGE_LENGTH )  }
        }

        if(  bytes(truncated_message).length > 0  ||  amount > 0  )
        {
            emit Airdrop({ sender: msg.sender, protocol: protocol, token: address(token), amount: amount, message: truncated_message });
        }
    }

    /**
     * @notice Transfer user funds during bond execution (ONLY callable by executing protocol)
     * @param to Recipient address
     * @param token Token to transfer (`NATIVE_TOKEN` or `address(0)` for native)
     * @param amount Amount to transfer
     * @param context Current execution context (must match active context)
     * @return updated_index Index of funding entry that was updated
     * @return new_available_amount Remaining amount available for this token
     *
     * @dev SMART STAKE CONSUMPTION (maximizes capital efficiency):
     *      Uses staked funds FIRST when funding token matches stake token.
     *      Example: 1,000 USDC swap with 10% stake (100 USDC staked) →
     *               BondRoute uses 100 USDC stake + pulls 900 USDC from user.
     *
     * @dev APPROVALS REQUIRED:
     *      - Fundings are pulled from user via `transferFrom()` during execution
     *      - User must approve BondRoute for ALL funding tokens before executing
     *
     * @dev IMPORTANT: Must update `context.fundings[updated_index].amount` with returned value before calling again.
     * @dev WARNING: Fee-on-transfer/rebase fundings - recipient may receive less than `amount`.
     *
     * @dev ERROR CODES:
     *      - `Invalid(string field, uint256 value)` if `to` is zero address
     *      - `Forbidden(address caller, uint256 calculated_hash, uint256 expected_hash)` if context hash mismatch
     *      - `InsufficientFunding(address token, uint256 provided, uint256 required)` if amount exceeds declared funding
     *      - `TransferFailed(address from, address token, uint256 amount, address to)` if transfer fails
     *      - `Reentrancy()` if nested within a BondRoute function call (except `execute_bond()` or `execute_bond_as()`)
     */
    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external  lockAndAllow( TRANSFER_FUNDING, EXECUTE_BOND )  returns ( uint256 updated_index, uint256 new_available_amount )
    {
        if(  to == address(0)  )  revert Invalid({ field: "to", value: 0 });

        // ━━━━  STEP 1: Access control  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        uint256 calculated_context_hash  =  HashLib.calc_context_hash({ protocol: IBondRouteProtected(msg.sender), context: context });
        if(  calculated_context_hash != __transient__context_hash  )
        {
            revert Forbidden({ caller: msg.sender, calculated_hash: calculated_context_hash, expected_hash: __transient__context_hash });
        }

        // ━━━━  STEP 2: Find the funding entry for this token  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        uint index  =  _find_funding_index( context.fundings, token );
        if(  index == INDEX_NOT_FOUND  )  revert InsufficientFunding({ token: address(token), provided: 0, required: amount });

        uint declared_available  =  context.fundings[ index ].amount;
        if(  amount == 0  )  return ( index, declared_available );  // Graceful no-op for 0 transfer amount.
        if(  amount > declared_available  )  revert InsufficientFunding({ token: address(token), provided: declared_available, required: amount });

        // ━━━━  STEP 3: Load held funds state (read slots once, only when relevant)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        //  *GAS SAVING*  -  Only read slots that are relevant to this token.
        bool is_native_token        =  ( address(token) == address(NATIVE_TOKEN) );
        bool stake_matches_token    =  ( context.stake.token == token );

        uint held_from_stake        =  ( stake_matches_token )  ?  __transient__held_stake  :  0;
        uint held_from_msg_value    =  ( is_native_token )  ?  __transient__held_msg_value  :  0;

        // ━━━━  STEP 4: Transfer to recipient  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        //  Amount comes from held funds first.
        //  For ERC20: if held funds are insufficient, pull the rest from user.
        //  For native: MUST come entirely from held funds (can't pull native from user).

        ( held_from_stake, held_from_msg_value )  =  _transfer_using_held_and_pull({
            token: token,
            from: context.user,
            to: to,
            amount: amount,
            held_from_stake: held_from_stake,
            held_from_msg_value: held_from_msg_value
        });

        // ━━━━  STEP 5: Write held state and update context  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        //  *GAS SAVING*  -  Only write transient vars that are relevant to this token.
        if(  stake_matches_token  )  __transient__held_stake      =  held_from_stake;
        if(  is_native_token  )      __transient__held_msg_value  =  held_from_msg_value;

        unchecked {  new_available_amount  =  declared_available - amount;  }  // *GAS SAVING*  -  Safe bc `amount <= declared_available` validated above.
        context.fundings[ index ].amount  =  new_available_amount;
        updated_index  =  index;

        __transient__context_hash  =  HashLib.calc_context_hash({ protocol: IBondRouteProtected(msg.sender), context: context });
    }


    // ━━━━  PRIVATE HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


    /**
     * @dev Transfer `amount` to `to` using held funds (`held_from_stake` + `held_from_msg_value`) first, then pull remainder from `from`.
     */
    function _transfer_using_held_and_pull( IERC20 token, address from, address to, uint256 amount, uint256 held_from_stake, uint256 held_from_msg_value )
    private returns ( uint256 new_held_from_stake, uint256 new_held_from_msg_value )
    {
        uint total_held;
        unchecked {  total_held  =  held_from_stake + held_from_msg_value;  }

        uint amount_from_held  =  _min( amount, total_held );
        uint amount_to_pull;
        unchecked {  amount_to_pull  =  amount - amount_from_held;  }  // *GAS SAVING*  -  Safe bc `amount_from_held = _min(amount, ...)`.

        if(  amount_from_held > 0  )
        {
            //  Consume from stake first, then from msg.value.
            uint from_stake  =  _min( amount_from_held, held_from_stake );
            uint from_msg_value;
            unchecked {  from_msg_value  =  amount_from_held - from_stake;  }  // *GAS SAVING*  -  Safe bc `from_stake = _min(amount_from_held, ...)`.

            //  Transfer from held funds to recipient.
            if(  from_stake > 0  )
            {
                TransferLib.transfer({ token: token, from: address(this), to: to, amount: from_stake });
            }

            if(  from_msg_value > 0  )
            {
                TransferLib.transfer_native({ to: to, amount: from_msg_value });
            }

            //  Update held amounts.
            unchecked   // *GAS SAVING*  -  Safe bc all values derived from `_min()` results.
            {
                held_from_stake      -=  from_stake;
                held_from_msg_value  -=  from_msg_value;
            }
        }

        if(  amount_to_pull > 0  )
        {
            //  *NOTE*  -  Native token can never reach here - can't pull native.
            TransferLib.transfer_erc20({ token: token, from: from, to: to, amount: amount_to_pull });
        }

        return ( held_from_stake, held_from_msg_value );
    }

    uint256 private constant INDEX_NOT_FOUND  =  type(uint256).max;

    /**
     * @dev Returns index of `token` in `fundings` array, or `INDEX_NOT_FOUND` if not found.
     */
    function _find_funding_index( TokenAmount[] memory fundings, IERC20 token ) private pure returns ( uint256 index )
    {
        unchecked   // *GAS SAVING*  -  Safe bc `index++` is bounded by array length.
        {
            for(  index = 0  ;  index < fundings.length  ;  index++  )
            {
                if(  fundings[ index ].token == token  )  return index;
            }
        }
        return INDEX_NOT_FOUND;
    }

    function _min( uint256 a, uint256 b ) private pure returns ( uint256 )
    {
        return  ( a < b )  ?  a  :  b;
    }
}
