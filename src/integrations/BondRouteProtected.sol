// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ██████╗  ██████╗ ███╗   ██╗██████╗ ██████╗  ██████╗ ██╗   ██╗████████╗███████╗
        ██╔══██╗██╔═══██╗████╗  ██║██╔══██╗██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝██╔════╝
        ██████╔╝██║   ██║██╔██╗ ██║██║  ██║██████╔╝██║   ██║██║   ██║   ██║   █████╗
        ██╔══██╗██║   ██║██║╚██╗██║██║  ██║██╔══██╗██║   ██║██║   ██║   ██║   ██╔══╝
        ██████╔╝╚██████╔╝██║ ╚████║██████╔╝██║  ██║╚██████╔╝╚██████╔╝   ██║   ███████╗
        ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝                                                                                              
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━  trustless fair play  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 

        ██████╗ ██████╗  ██████╗ ████████╗███████╗ ██████╗████████╗███████╗██████╗
        ██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗
        ██████╔╝██████╔╝██║   ██║   ██║   █████╗  ██║        ██║   █████╗  ██║  ██║
        ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██╔══╝  ██║        ██║   ██╔══╝  ██║  ██║
        ██║     ██║  ██║╚██████╔╝   ██║   ███████╗╚██████╗   ██║   ███████╗██████╔╝
        ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝   ╚═╝   ╚══════╝╚═════╝

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    BondRouteProtected — Drop-in base contract for BondRoute integration

    QUICK INTEGRATION:
    1. Copy this file to your project
    2. Inherit: `contract YourProtocol is BondRouteProtected`
    3. Initialize `BondRouteProtected("YourProtocol", "Description")` in constructor
    4. Implement two functions:
       - `BondRoute_quote_call()` — return constraints based on calldata
       - `BondRoute_get_protected_selectors()` — return protected function selectors
    5. `BondContext memory ctx = BondRoute_initialize()` at start of protected functions
    6. Use `ctx.user` instead of `msg.sender` in protected functions
    7. Use `ctx.pull(token, amount)` to pull user funds
    8. Deploy and pin metadata

    FOUNDRY LIB:
    If BondRoute is installed as a lib, import this file from the lib instead of copying it locally.
    Solidity treats identical structs from different files as different types.

    No external dependencies. No package manager.

    WHAT IT DOES:
    - Makes user commitments binding (commit-reveal with stakes)
    - Users must attempt execution or forfeit stake — no free optionality

    WHY IT MATTERS:
    - MEV protection: reserved execution prevents frontrunning, binding economics deters speculation
    - Credible coordination: votes, bids, claims can't be strategically abandoned
    - Standardized query interface across all protocols

    EXAMPLE:

    ```solidity
    string constant PROTOCOL_NAME         =  "YourToken";
    string constant PROTOCOL_DESCRIPTION  =  "Early depositor bonus mints";
    IERC20 constant DEPOSIT_TOKEN         =  NATIVE_TOKEN;  // Could be native like ETH or any ERC20 token address.

    contract YourToken is ERC20, BondRouteProtected {
        using FundingsLib for BondContext;

        uint256 private _total_deposits;

        constructor( )
        ERC20( PROTOCOL_NAME, "TOKEN" )
        BondRouteProtected( PROTOCOL_NAME, PROTOCOL_DESCRIPTION ) { }

        function deposit( ) external
        {
            BondContext memory context  =  BondRoute_initialize( );
            uint256 amount  =  context.fundings[0].amount;
            context.pull( DEPOSIT_TOKEN, amount );

            // Early depositors get 2x tokens. Decreases to 1x after 100 ETH total.
            uint256 multiplier   =  _total_deposits < 100 ether  ?  2  :  1;
            uint256 mint_amount  =  amount * multiplier;

            _total_deposits  +=  amount;
            _mint( context.user, mint_amount );
        }

        function BondRoute_quote_call( bytes calldata call, IERC20, TokenAmount[] memory preferred_fundings )
        public view override returns ( BondConstraints memory constraints )
        {
            if(  bytes4(call) != this.deposit.selector  )  revert UnsupportedCall( );

            uint256 amount                              =  preferred_fundings[0].amount;
            constraints.min_stake                       =  TokenAmount({ token: DEPOSIT_TOKEN, amount: amount / 100 });  // 1% stake.
            constraints.min_fundings                    =  new TokenAmount[](1);
            constraints.min_fundings[0]                 =  TokenAmount({ token: DEPOSIT_TOKEN, amount: amount });
            constraints.min_execution_delay_in_blocks   =  3;        // Durable chain ordering: public reveal delay and reorg-depth floor.
            constraints.min_execution_delay_in_seconds  =  2;        // Real elapsed-time floor for fast-block environments.
            constraints.max_execution_delay_in_seconds  =  2 hours;  // Sensible security/UX balance.
        }

        function BondRoute_get_protected_selectors() external pure override returns ( bytes4[] memory selectors )
        {
            selectors     =  new bytes4[](1);
            selectors[0]  =  this.deposit.selector;
        }
    }
    ```

*/


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  DATA STRUCTURES
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TokenAmount {
    IERC20 token;
    uint256 amount;
}

struct Range {
    uint256 min;
    uint256 max;
}

struct BondContext {
    address user;
    TokenAmount stake;
    TokenAmount[] fundings;
    uint256 creation_block;
    uint256 creation_timestamp;
}

struct BondConstraints {
    TokenAmount min_stake;
    TokenAmount[] min_fundings;
    uint256 min_execution_delay_in_blocks;
    uint256 min_execution_delay_in_seconds;
    uint256 max_execution_delay_in_seconds;
    Range valid_creation_timestamp_range;
    Range valid_execution_timestamp_range;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  INTERFACES
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @title IBondRouteProtected
 * @notice Interface for contracts integrating with BondRoute
 *
 * @dev ━━━━  SECURITY MODEL — EXECUTION AS COMMITMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * BondRoute enforces a single economic invariant:
 *
 *      Creating a bond commits the creator to attempting execution within a bounded execution window,
 *      or to forfeiting stake.
 *
 * Bonds have no cancellation path. Stake is recoverable only through execution attempts.
 *
 * This invariant applies uniformly across protocol actions such as:
 *   swaps, liquidations, claims, mints, auctions, votes.
 *
 *
 * ━━━━  HOW PROTECTION WORKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * BondRoute provides two distinct protections:
 *
 *   1. RESERVED EXECUTION (prevents frontrunning)
 *      - Intent hidden in commitment hash
 *      - Protected functions reject unbonded calls and enforce a protocol-specified block delay before execution
 *      → Attackers can't see what to bond for and can't react in time
 *
 *   2. BINDING ECONOMICS (prevents preemptive bond farming)
 *      - Each bond requires explicit, protocol-defined stake
 *      - Stake recoverable only through execution attempts; expired bonds forfeit stake
 *      → Without stakes, attackers pre-create bonds covering likely parameters and let unused ones expire for free
 *      → Stakes make this unprofitable: losses on abandoned bonds exceed gains from the few that hit
 *
 *
 * ━━━━  WHAT ATTACKERS SEE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * At bond creation, attackers observe ONLY:
 *   - Commitment hash (opaque 32 bytes)
 *   - Stake token and amount
 *
 * Hidden until execution:
 *   - User address (bonds can be created via relayers or other accounts)
 *   - Protocol address
 *   - Function being called
 *   - Call parameters
 *   - Funding tokens and amounts
 *
 * All bonds flow through the singleton BondRoute contract — attackers cannot distinguish which protocol a bond targets.
 * Stake ratios vary by protocol, so stake amount reveals little about transaction value.
 *
 *
 * ━━━━  STAKE SIZING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * Stake makes bond farming unprofitable — not impossible, but economically irrational.
 *
 * Size stake relative to potential extraction. If MEV opportunity is X% of transaction value, stake should exceed X%
 * so that losses on trapped bonds outweigh gains from successful extractions.
 *
 * See MECHANISM_DEEP_DIVE.md for detailed game theory analysis.
 *
 *
 * ━━━━  HOW STAKE RECOVERY WORKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * **Stake is automatically returned upon any execution attempt.**
 *
 * Two exceptions:
 *   - `PossiblyBondFarming` revert → stake remains locked, user can fix issue and retry
 *   - Bond expires without execution → stake permanently forfeited
 *
 * WHY `PossiblyBondFarming` EXISTS:
 *
 * Without it, attackers could freely recover stakes from abandoned bonds by intentionally failing execution —
 * revoking approvals, transferring funds away, executing outside the allowed window, or starving the transaction of gas.
 *
 * Common triggers for `PossiblyBondFarming`:
 *   - Execution outside timing constraints (too early, too late, wrong window)
 *   - Transfer failures (missing approval, insufficient balance)
 *   - Out-of-gas or empty revert data
 *
 * Implementations SHOULD revert with `PossiblyBondFarming` for timing violations and may add protocol-specific triggers.
 * Legitimate users who trigger it accidentally can fix the issue and retry within the execution window.
 *
 * *WARNING*  Naked `revert()` and out-of-gas produce empty revert data — treated as `PossiblyBondFarming`.
 *            Always revert with explicit custom errors or revert strings.
 *
 *
 * ━━━━  STANDARDIZED QUERY INTERFACE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * `BondRoute_quote_call` provides programmatic discovery: "What do I need to execute this call?"
 *
 *   - Timing: when can I execute? (block delays, time limits, absolute windows)
 *   - Stake: what commitment is required? (token, amount)
 *   - Fundings: what must I provide? (tokens, minimums)
 *
 * Same interface across all BondRoute-protected protocols — enables frontends, SDKs,
 * and aggregators to query any protocol uniformly.
 *
 *
 * ━━━━  UPGRADES & VERSIONING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * BondRoute itself is immutable.
 * Protected contracts may upgrade freely.
 *
 * If, at execution time, `BondRoute_get_protected_selectors()` doesn't return a valid array containing the called selector,
 * the bond settles gracefully with stake refunded.
 *
 * To deprecate, pause, or migrate a function: ensure it is not returned by `BondRoute_get_protected_selectors()`.
 *
 * Bonds targeting removed selectors settle gracefully with stake refunded.
 *
 *
 * ━━━━  REENTRANCY PROTECTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * Protected functions are inherently reentrancy-safe.
 *
 * BondRoute holds a global lock during bond execution. Protected functions cannot be reentered
 * within the same transaction. Integrators do not need to add their own reentrancy guards.
 *
 */
interface IBondRouteProtected {

    /**
     * @notice Entry point called by BondRoute during bond execution
     * @param call The original function call (4-byte selector + ABI-encoded arguments)
     * @param context Bond context (user, stake, fundings, timing)
     * @return output Protocol return data from the protected function
     * @dev SECURITY: Cannot be reentered within the same transaction. No reentrancy guard needed.
     */
    function BondRoute_entry_point( bytes calldata call, BondContext memory context )
    external returns ( bytes memory );

    /**
     * @notice Define requirements for a given call
     *
     * @dev ━━━━  CORE RESPONSIBILITY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *
     * This function defines the rules for executing a bond targeting your protocol.
     *
     * It answers three questions:
     *   1. What stake is required to attach cost to abandonment?
     *   2. What funds must the user provide?
     *   3. When is execution intended to occur?
     *
     * This function is commonly used:
     *   - OFF-CHAIN, as a quotation / discovery function for UX
     *   - ON-CHAIN, by protocol validation logic during execution
     *
     *
     * ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *
     * @param call Encoded function call (selector + parameters).
     * @dev        Decode using `bytes4(call)` for selector and `abi.decode(call[4:], (...))` for parameters.
     *
     * @param preferred_stake_token User's preferred ERC20 token for stake (`NATIVE_TOKEN` for native).
     * @dev                         Protocols may ignore this and require a specific token.
     *
     * @param preferred_fundings User's preferred ERC20 fundings, ordered by preference (`NATIVE_TOKEN` for native).
     * @dev                      Protocols may honor or ignore.
     *
     *
     * ━━━━  RETURN VALUE: BondConstraints  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *
     * FIELD: min_stake
     *   - Required stake to attach cost to abandonment (`NATIVE_TOKEN` for native)
     *   - `amount = 0` indicates no stake requirement
     *   - Stake size is entirely protocol-defined
     *
     * FIELD: min_fundings
     *   - Required fundings the user must provide (`NATIVE_TOKEN` for native)
     *   - Max 4 entries, no duplicates
     *   - Empty array = no funding requirement
     *   - All returned entries are required simultaneously
     *
     * FIELD: min_execution_delay_in_blocks
     *   - Minimum blocks elapsed between bond creation and execution.
     *   - Expresses durable chain ordering: the bond must exist for a protocol-defined number of blocks before reveal/execution.
     *   - Provides chain-native public reveal delay and reorg-depth resistance.
     *   - BondRoute enforces 1 block minimum; set higher for stricter public reveal delay or deeper reorg resistance.
     *
     * FIELD: min_execution_delay_in_seconds
     *   - Minimum seconds elapsed between bond creation and execution.
     *   - Expresses real elapsed time, independently from block count.
     *   - Complements the block delay when blocks may be produced too quickly to provide enough public reveal delay.
     *   - For adversarial public execution, configure both dimensions instead of treating either one as a proxy for the other.
     *
     * FIELD: max_execution_delay_in_seconds
     *   - Maximum seconds from creation to execute.
     *   - Constrains sitting on a bond and waiting for favorable conditions before executing.
     *   - If set with `min_execution_delay_in_seconds`, it must leave a valid execution range.
     *   - BondRoute enforces 111 days maximum; set lower to tighten
     *
     * FIELD: valid_creation_timestamp_range
     *   - Absolute creation window
     *   - Range: (min, max) as Unix timestamps (seconds, per EVM `block.timestamp`)
     *   - `(0, 0)` indicates no absolute creation constraint
     *
     * FIELD: valid_execution_timestamp_range
     *   - Absolute execution window
     *   - Range: (min, max) as Unix timestamps (seconds, per EVM `block.timestamp`)
     *   - `(0, 0)` indicates no absolute execution constraint
     *
     *
     * ━━━━  SECURITY NOTES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *
     * - Returning stakeless constraints enables underpriced optionality.
     *   This may be acceptable for some use-cases, but carries no economic deterrence.
     *
     * - Malformed constraints (e.g. duplicate funding tokens, fundings with zero amounts) MUST be avoided as they will
     *   cause the bond to be deemed invalid during execution (with subsequent stake refunding).
     *
     * - Unsupported calls SHOULD revert with `UnsupportedCall()`. This gives frontends and wallets a uniform
     *   integration-level error while preserving immutable BondRoute core behavior.
     */
    function BondRoute_quote_call( bytes calldata call, IERC20 preferred_stake_token, TokenAmount[] memory preferred_fundings ) 
    external view returns (BondConstraints memory);

    /**
     * @notice Declare which functions are BondRoute-protected
     * @return selectors Array of function selectors that can be called via bonds
     *
     * @dev Bonds targeting selectors not returned by this function are settled gracefully with stake refunded.
     *
     * This enables:
     *   - Upgradability
     *   - Emergency pauses
     *   - Selector-level access control
     *
     * @dev GAS REQUIREMENT:
     *      Implementations MUST consume below 50,000 gas on all target EVM-compatible chains.
     */
    function BondRoute_get_protected_selectors( )
    external view returns ( bytes4[] memory selectors );

    /**
     * @notice Optional: provide custom EIP-712 types for better wallet UX
     * @param call Encoded function call (4-byte selector + ABI-encoded arguments)
     * @return typed_string Complete EIP-712 type definition
     * @return struct_hash EIP-712 hash of your call type (the inner type, not outer ExecuteBondAs)
     * @return TokenAmount_offset Byte offset where `TokenAmount(address token,uint256 amount)` starts in `typed_string`
     *
     * @dev WHY: Wallets display human-readable typed data instead of opaque `calldata_hash`.
     * @dev Return `("", bytes32(0), 0)` to use default `calldata_hash` fallback.
     *
     * @dev REQUIREMENTS:
     *      - `typed_string` MUST start with: `ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,`
     *      - `typed_string` MUST contain: `TokenAmount(address token,uint256 amount)`
     *      - `TokenAmount_offset` MUST point to the `T` in that definition
     *
     * @dev Unsupported calls SHOULD revert with `UnsupportedCall()`.
     *
     * @dev Example: `ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,Swap call)Swap(address tokenOut,uint256 minAmountOut)TokenAmount(address token,uint256 amount)`
     */
    function BondRoute_get_signing_info( bytes calldata call )
    external view returns ( string memory typed_string, bytes32 struct_hash, uint256 TokenAmount_offset );
}

/// @dev Minimal interface for integrator use. Frontends use the full BondRoute ABI.
interface IBondRoute {
    function announce_protocol( string calldata name, string calldata description ) external payable;
    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context ) external returns ( uint256 updated_index, uint256 new_available_amount );
}

/// @dev Standard ERC20 interface, embedded for self-contained file. Replace with OZ import if preferred.
interface IERC20 {
    event Transfer( address indexed from, address indexed to, uint256 value );
    event Approval( address indexed owner, address indexed spender, uint256 value );
    function totalSupply( ) external view returns ( uint256 );
    function balanceOf( address account ) external view returns ( uint256 );
    function transfer( address to, uint256 value ) external returns ( bool );
    function allowance( address owner, address spender ) external view returns ( uint256 );
    function approve( address spender, uint256 value ) external returns ( bool );
    function transferFrom( address from, address to, uint256 value ) external returns ( bool );
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  BASE CONTRACT: BondRouteProtected
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error Unauthorized( address caller, address expected );
error BondCreatedTooEarly( uint256 created_at, uint256 min_creation_time );
error BondCreatedTooLate( uint256 created_at, uint256 max_creation_time );
error InsufficientStake( uint256 provided, uint256 required );
error InvalidStakeToken( address provided, address required );
error InsufficientFunding( address token, uint256 provided, uint256 required );
error PossiblyBondFarming( string reason, bytes32 additional_info );
error UnsupportedCall( );

// PossiblyBondFarming reasons - `additional_info` field contains context-specific data:
string constant EXECUTION_TOO_SOON_BLOCKS       =   "Execution too soon (blocks)";     // additional_info: min delay in blocks (uint256)
string constant EXECUTION_TOO_SOON_SECONDS      =   "Execution too soon (seconds)";    // additional_info: required block.timestamp delta in seconds (uint256)
string constant EXECUTION_TOO_LATE              =   "Execution too late";              // additional_info: max delay in seconds (uint256)
string constant BEFORE_EXECUTION_WINDOW         =   "Before execution window";         // additional_info: min execution time (uint256)
string constant AFTER_EXECUTION_WINDOW          =   "After execution window";          // additional_info: max execution time (uint256)


// ━━━━  CONSTANTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

address constant BONDROUTE_ADDRESS              =   address(0xb01d00000000440215e86e0A436f9b59FeB2F14a);
IBondRoute constant BondRoute                   =   IBondRoute(BONDROUTE_ADDRESS);
IERC20 constant NATIVE_TOKEN                    =   IERC20(address(0));

uint256 constant WORD_SIZE                      =   32;
uint256 constant CONTEXT_BASE_SIZE              =   8 * WORD_SIZE;  // - offset, user, creation_time, creation_block, stake.token,
                                                                    //   stake.amount, fundings offset, fundings length
uint256 constant TOKEN_AMOUNT_SIZE              =   2 * WORD_SIZE;  // - token, amount


/**
 * @title BondRouteProtected
 * @notice Abstract base contract for protocols integrating with BondRoute
 *
 * @dev ━━━━  WHAT THIS BASE CONTRACT PROVIDES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 *
 * Default implementation of `IBondRouteProtected` with two key behaviors:
 *
 * 1. REAL-TIME CONSTRAINT VALIDATION
 *    At execution time, calls `BondRoute_quote_call` with actual stake/fundings as preferred values,
 *    then validates the returned constraints against the execution context.
 *
 *    *WARNING*: Dynamic constraints may return different values between bond creation time and bond execution time.
 *    If constraints INCREASE, bonds may subtly fail with `InsufficientStake`, settling the bond and returning stake — creating 
 *    occasional escapes from the trap.
 *    Prefer static constraints or consider sizing the stake and max execution timing for negative expected value overall.
 *
 * 2. CONTEXT PASSING VIA CALLDATA
 *    Encodes `BondContext` into calldata and `delegatecall`s into the protected function.
 *    Protected functions call `BondRoute_initialize()` to recover the context.
 *    `delegatecall` is used so that `msg.sender` remains BondRoute throughout.
 *
 *    For gas savings, integrators can override `BondRoute_entry_point` to dispatch
 *    directly to internal functions instead of using delegatecall.
 *
 */
abstract contract BondRouteProtected is IBondRouteProtected {

    using FundingsLib for BondContext;

    /**
     * @notice Announce your protocol on-chain for discoverability
     *
     * @param name Protocol name (max 64 UTF-8 bytes). Empty to skip announcement.
     * @param description Short description (max 280 UTF-8 bytes)
     *
     * @dev Informational only. No effect on execution or security.
     *
     * @dev Announcements are permissionless — anyone can claim any name or description.
     *      Optionally, call `BondRoute.airdrop()` to attach economic signal for indexer filtering/sorting.
     */
    constructor( string memory name, string memory description )
    payable  // *NOTE*  -  Required so derived constructors can receive `msg.value`.
    {
        if(  bytes(name).length > 0  )  BondRoute.announce_protocol( name, description );
    }


    // ━━━━  REQUIRED OVERRIDES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Declare which functions are callable via BondRoute bonds
     *
     * @return selectors Array of function selectors that are protected
     *
     * @dev ONLY selectors returned here may be executed via bonds
     * @dev Bonds targeting other selectors fail gracefully and refund stake
     * @dev This enables selector-level access control, upgrades, and pauses
     * @dev MUST consume below 50,000 gas
     *
     * @dev Example:
     *      function BondRoute_get_protected_selectors( ) external pure override returns ( bytes4[] memory selectors )
     *      {
     *          selectors       =  new bytes4[]( 1 );
     *          selectors[ 0 ]  =  this.swap.selector;
     *      }
     */
    function BondRoute_get_protected_selectors( )
    external view virtual returns ( bytes4[] memory selectors );


    /**
     * @notice Define execution constraints for a given call
     *
     * @param call Encoded function selector + arguments of the intended call
     * @param preferred_stake_token User-preferred stake token
     * @param preferred_fundings User-preferred funding set
     *
     * @return constraints Protocol-defined execution requirements
     *
     * @dev This function defines the necessary stake, fundings, and timings to successfully execute a given call
     *
     * It may include:
     *   - required stake (token + amount)
     *   - required fundings
     *   - minimum blocks to execute (durable chain ordering: public reveal delay + reorg-depth resistance)
     *   - minimum seconds to execute (real elapsed-time public reveal delay)
     *   - maximum seconds to execute (optionality / stale execution cap)
     *   - absolute creation timestamp range
     *   - absolute execution timestamp range
     *
     * @dev It is mainly used for off-chain discovery and UX.
     * @dev This abstract contract also uses it for on-chain validation during execution.
     *
     * @dev MUST be implemented by integrators.
     *      See IBondRouteProtected for full semantic documentation.
     *
     * @dev Example (sealed-bid auction with bid/reveal phases, 6% stake, USDC):
     *      function BondRoute_quote_call( bytes calldata call, IERC20, TokenAmount[] memory preferred_fundings )
     *      public view virtual returns ( BondConstraints memory constraints )
     *      {
     *          if(  bytes4(call) != this.bid.selector  )  revert UnsupportedCall( );
     *
     *          uint256 bid_amount                            =  preferred_fundings[0].amount;
     *          constraints.min_stake                         =  TokenAmount({ token: USDC, amount: bid_amount * 6 / 100 });  // 6% stake.
     *          constraints.min_fundings                      =  new TokenAmount[](1);
     *          constraints.min_fundings[0]                   =  TokenAmount({ token: USDC, amount: bid_amount });
     *          constraints.min_execution_delay_in_blocks     =  3;  // Durable chain ordering: public reveal delay and reorg-depth floor.
     *          constraints.min_execution_delay_in_seconds    =  2;  // Real elapsed-time floor for fast-block environments.
     *          constraints.valid_creation_timestamp_range    =  Range({ min: BID_START, max: BID_END });
     *          constraints.valid_execution_timestamp_range   =  Range({ min: REVEAL_START, max: REVEAL_END });
     *      }
     */
    function BondRoute_quote_call( bytes calldata call, IERC20 preferred_stake_token, TokenAmount[] memory preferred_fundings )
    public view virtual returns ( BondConstraints memory );


    // ━━━━  OPTIONAL EXTENSIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Optional: provide EIP-712 signing metadata for improved wallet UX
     *
     * @param call Encoded function call being signed
     *
     * @return typed_string EIP-712 type string (empty = fallback to hash)
     * @return struct_hash EIP-712 hash of your call type (the inner type, not outer ExecuteBondAs)
     * @return TokenAmount_offset Byte offset where `TokenAmount(address token,uint256 amount)` starts in `typed_string`
     *
     * @dev This affects signing UX only. Does NOT affect execution, validation, or security.
     * @dev Override to display human-readable parameters in wallets.
     *
     * @dev Example for a swap(address tokenOut, uint256 minAmountOut) function:
     *
     *      string constant SWAP_TYPE_STRING = "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,Swap call)Swap(address tokenOut,uint256 minAmountOut)TokenAmount(address token,uint256 amount)";
     *      uint256 constant TOKEN_AMOUNT_OFFSET = 138;  // Byte position of "TokenAmount(address token..."
     *
     *      function BondRoute_get_signing_info( bytes calldata call )
     *      external pure override returns ( string memory, bytes32, uint256 )
     *      {
     *          if(  bytes4(call) != this.swap.selector  )  revert UnsupportedCall( );
     *
     *          ( address tokenOut, uint256 minAmountOut )  =  abi.decode( call[4:], (address, uint256) );
     *          bytes32 struct_hash  =  keccak256( abi.encode(
     *              keccak256("Swap(address tokenOut,uint256 minAmountOut)"),
     *              tokenOut,
     *              minAmountOut
     *          ));
     *          return ( SWAP_TYPE_STRING, struct_hash, TOKEN_AMOUNT_OFFSET );
     *      }
     */
    function BondRoute_get_signing_info( bytes calldata call )
    external view virtual returns ( string memory typed_string, bytes32 struct_hash, uint256 TokenAmount_offset )
    {
        call;  // Silence unused parameter warning.
        return ( "", bytes32(0), 0 );
    }


    // ━━━━  DEFAULT IMPLEMENTATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Entry point invoked by BondRoute during bond execution
     *
     * @param call Encoded selector + arguments of the user-intended function call
     * @param context Execution context supplied by BondRoute
     *
     * @return output Return data of the protected function
     *
     * @dev Default flow:
     *   1. Verify caller is BondRoute
     *   2. Validate execution constraints
     *   3. Append execution context to calldata
     *   4. Delegatecall into the protected function
     *
     * @dev Advanced integrators may override to dispatch directly to internal functions for gas savings.
     *
     * @dev If overridden, implementations MUST preserve:
     *   - caller authorization
     *   - constraint validation semantics
     */
    function BondRoute_entry_point( bytes calldata call, BondContext memory context )
    external virtual override returns ( bytes memory output )
    {
        // *NOTE*  -  Validates early for security and future-proofing. Also checked in `BondRoute_initialize()`.
        if(  msg.sender != address(BondRoute)  )  revert Unauthorized({ caller: msg.sender, expected: address(BondRoute) });

        BondRoute_validate( call, context );

        // Encode calldata structure: [ original_call | abi.encode(context) | uint8(fundings.length) ]
        // The 1-byte `fundings.length` trailer allows calculating context_size when decoding.
        bytes memory call_with_appended_context  =  bytes.concat(  call,  abi.encode( context ),  abi.encodePacked( uint8(context.fundings.length) )  );

        // *NOTE*  -  `delegatecall` preserves `msg.sender = BondRoute` for semantic correctness during protected call.
        bool success;
        ( success, output )  =  address(this).delegatecall( call_with_appended_context );

        // *NOTE*  -  Return raw bytes in both cases (no ABI wrapping). Core.sol handles both symmetrically.
        assembly ("memory-safe")
        {
            if success { return( add( output, 0x20 ), mload( output ) ) }
            revert( add( output, 0x20 ), mload( output ) )
        }
    }

    /**
     * @notice Recover execution context appended by `BondRoute_entry_point`
     *
     * @return context Decoded `BondContext` struct
     *
     * @dev MUST be called at the beginning of every protected function.
     *
     * @dev SECURITY:
     *      - Validates caller is BondRoute (preserved from entry_point via delegatecall).
     *      - Ensures execution is within BondRoute's reentrancy-protected context.
     */
    function BondRoute_initialize( ) internal view virtual returns ( BondContext memory context )
    {
        if(  msg.sender != address(BondRoute)  )  revert Unauthorized({ caller: msg.sender, expected: address(BondRoute) });

        // The context is appended to `msg.data` by `BondRoute_entry_point`:  [ original_call | abi.encode(context) | uint8(fundings.length) ]
        uint8 fundings_count  =  uint8( msg.data[ msg.data.length - 1 ] );  // Validated at BondRoute to be max 4.

        uint context_size;
        unchecked {  context_size  =  CONTEXT_BASE_SIZE + ( fundings_count * TOKEN_AMOUNT_SIZE );  }  // *GAS SAVING*  -  Safe constant values and max 4.

        // Extract context bytes from `msg.data` (excluding the trailing `fundings_count` byte).
        uint context_end_position    =  msg.data.length - 1;
        uint context_start_position  =  context_end_position - context_size;
        bytes calldata context_bytes    =  msg.data[ context_start_position : context_end_position ];

        context  =  abi.decode( context_bytes, (BondContext) );
    }

    /**
     * @notice Validate execution against protocol-defined constraints
     *
     * @param call Original function call
     * @param context Execution context supplied by BondRoute
     *
     * @dev Default behavior:
     *      - fetch constraints at `BondRoute_quote_call()` using actual call, stake, and fundings.
     *      - validate timing, stake, and funding requirements.
     *
     * @dev Integrators may override to implement protocol-specific validation.
     *
     * @dev Reverts MUST be used deliberately:
     *      - Legitimate failures → revert with custom error or string → Settles bond and refunds stake.
     *      - Suspected bond farming → revert with `PossiblyBondFarming()` → Bond execution reverts,
     *        stake remains locked, user may retry.
     */
    function BondRoute_validate( bytes calldata call, BondContext memory context ) internal view virtual
    {
        BondConstraints memory constraints  =  BondRoute_quote_call({
            call:                       call,
            preferred_stake_token:      context.stake.token,
            preferred_fundings:         context.fundings
        });

        _validate_timing( context, constraints );
        _validate_stake( context, constraints );
        _validate_fundings( context, constraints );
    }


    // ━━━━  PRIVATE VALIDATION HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @dev Validate creation time, execution delay, and execution window.
     *      Creation timestamp violations settle gracefully and refund the stake.
     *      Execution timing violations revert with `PossiblyBondFarming`; stake remains locked, user may retry.
     */
    function _validate_timing( BondContext memory context, BondConstraints memory constraints ) private view
    {
        // Validate bond creation absolute timestamp range.
        if(  constraints.valid_creation_timestamp_range.min > 0  &&  context.creation_timestamp < constraints.valid_creation_timestamp_range.min  )
        {
            revert BondCreatedTooEarly({ created_at: context.creation_timestamp, min_creation_time: constraints.valid_creation_timestamp_range.min });
        }
        if(  constraints.valid_creation_timestamp_range.max > 0  &&  context.creation_timestamp > constraints.valid_creation_timestamp_range.max  )
        {
            revert BondCreatedTooLate({ created_at: context.creation_timestamp, max_creation_time: constraints.valid_creation_timestamp_range.max });
        }

        // Validate minimum blocks elapsed since creation (durable chain ordering: public reveal delay + reorg-depth resistance).
        if(  constraints.min_execution_delay_in_blocks > 0  )
        {
            uint blocks_elapsed;
            unchecked {  blocks_elapsed  =  block.number - context.creation_block;  }
            if(  blocks_elapsed < constraints.min_execution_delay_in_blocks  )
            {
                revert PossiblyBondFarming({ reason: EXECUTION_TOO_SOON_BLOCKS, additional_info: bytes32(constraints.min_execution_delay_in_blocks) });
            }
        }

        // Validate minimum timestamp seconds elapsed since creation (real elapsed-time public reveal delay).
        {
            uint required_seconds_elapsed;
            uint seconds_elapsed;
            unchecked
            {
                // *SECURITY*  -  Floor of 1 second is always enforced (no opt-out), mirroring the 1-block floor BondRoute core enforces on the block dimension.
                //                Closes the footgun where a protocol on a fast-block chain forgets to configure this and gets no real-time public reveal delay.
                uint configured_seconds   =  (  constraints.min_execution_delay_in_seconds == 0  )  ?  1  :  constraints.min_execution_delay_in_seconds;

                // *SECURITY*  -  Add one timestamp tick because EVM timestamps have one-second granularity. On fast-block chains,
                //                two blocks with timestamps one second apart may have been produced only milliseconds apart across a second boundary.
                required_seconds_elapsed  =  configured_seconds + 1;

                seconds_elapsed           =  block.timestamp - context.creation_timestamp;
            }
            if(  seconds_elapsed < required_seconds_elapsed  )
            {
                revert PossiblyBondFarming({ reason: EXECUTION_TOO_SOON_SECONDS, additional_info: bytes32(required_seconds_elapsed) });
            }
        }

        // Validate maximum seconds elapsed since creation (constrains opportunistic execution).
        if(  constraints.max_execution_delay_in_seconds > 0  )
        {
            uint seconds_elapsed;
            unchecked {  seconds_elapsed  =  block.timestamp - context.creation_timestamp;  }
            if(  seconds_elapsed > constraints.max_execution_delay_in_seconds  )
            {
                revert PossiblyBondFarming({ reason: EXECUTION_TOO_LATE, additional_info: bytes32(constraints.max_execution_delay_in_seconds) });
            }
        }

        // Validate bond execution absolute timestamp range.
        if(  constraints.valid_execution_timestamp_range.min > 0  &&  block.timestamp < constraints.valid_execution_timestamp_range.min  )
        {
            revert PossiblyBondFarming({ reason: BEFORE_EXECUTION_WINDOW, additional_info: bytes32(constraints.valid_execution_timestamp_range.min) });
        }
        if(  constraints.valid_execution_timestamp_range.max > 0  &&  block.timestamp > constraints.valid_execution_timestamp_range.max  )
        {
            revert PossiblyBondFarming({ reason: AFTER_EXECUTION_WINDOW, additional_info: bytes32(constraints.valid_execution_timestamp_range.max) });
        }
    }

    /**
     * @dev Validate stake token and minimum amount.
     */
    function _validate_stake( BondContext memory context, BondConstraints memory constraints ) private pure
    {
        if(  constraints.min_stake.amount > 0  )
        {
            if(  address(context.stake.token) != address(constraints.min_stake.token)  )
            {
                revert InvalidStakeToken({ provided: address(context.stake.token), required: address(constraints.min_stake.token) });
            }
            if(  context.stake.amount < constraints.min_stake.amount  )
            {
                revert InsufficientStake({ provided: context.stake.amount, required: constraints.min_stake.amount });
            }
        }
    }

    /**
     * @dev Validate required funding tokens and minimum amounts.
     */
    function _validate_fundings( BondContext memory context, BondConstraints memory constraints ) private pure
    {
        if(  constraints.min_fundings.length == 0  )  return;

        // *NOTE*  -  Nested loop has slight gas overhead but allows natural ordering and user preference signaling.
        unchecked
        {
            for(  uint i = 0  ;  i < constraints.min_fundings.length  ;  i++  )
            {
                IERC20 required_token    =  constraints.min_fundings[ i ].token;
                uint256 required_amount  =  constraints.min_fundings[ i ].amount;

                bool found  =  false;

                for(  uint j = 0  ;  j < context.fundings.length  ;  j++  )
                {
                    if(  address(context.fundings[ j ].token) == address(required_token)  )
                    {
                        if(  context.fundings[ j ].amount < required_amount  )
                        {
                            revert InsufficientFunding({ token: address(required_token), provided: context.fundings[ j ].amount, required: required_amount });
                        }
                        found  =  true;
                        break;
                    }
                }

                if(  found == false  )
                {
                    revert InsufficientFunding({ token: address(required_token), provided: 0, required: required_amount });
                }
            }
        }
    }

}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  HELPER LIBRARY: Convenient funding transfers
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @title FundingsLib
 * @notice Helper library for transferring user funds via BondRoute
 *
 * @dev Usage: `using FundingsLib for BondContext;` then call `ctx.pull(token, amount)` or `ctx.send(token, amount, recipient)`
 *
 * @dev Fundings remain in user's wallet until pulled — they never touch BondRoute. Protocols direct where funds flow via `transfer_funding()`.
 *      When funding token matches stake token, staked funds (held by BondRoute) are used first
 *      (capital efficient: 1000 USDC swap with 100 USDC stake needs only 900 USDC in wallet).
 */
library FundingsLib {

    /**
     * @notice Send funds from user to recipient
     * @dev Wraps `BondRoute.transfer_funding` and handles the required context bookkeeping.
     *      Without this helper, you must manually update `context.fundings` after each transfer
     *      or subsequent calls will fail context validation.
     */
    function send( BondContext memory context, IERC20 token, uint256 amount, address to ) internal
    {
        if(  amount == 0  )  return;

        ( uint256 updated_index, uint256 remaining )  =  BondRoute.transfer_funding( to, token, amount, context );
        context.fundings[ updated_index ].amount  =  remaining;
    }

    /**
     * @notice Pull funds from user to this contract
     * @dev Convenience wrapper — equivalent to `send(context, token, amount, address(this))`.
     */
    function pull( BondContext memory context, IERC20 token, uint256 amount ) internal
    {
        send( context, token, amount, address(this) );
    }
}
