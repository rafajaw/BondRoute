// SPDX-License-Identifier: MIT
//
// ██████╗  ██████╗ ███╗   ██╗██████╗ ██████╗  ██████╗ ██╗   ██╗████████╗███████╗
// ██╔══██╗██╔═══██╗████╗  ██║██╔══██╗██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝██╔════╝
// ██████╔╝██║   ██║██╔██╗ ██║██║  ██║██████╔╝██║   ██║██║   ██║   ██║   █████╗
// ██╔══██╗██║   ██║██║╚██╗██║██║  ██║██╔══██╗██║   ██║██║   ██║   ██║   ██╔══╝
// ██████╔╝╚██████╔╝██║ ╚████║██████╔╝██║  ██║╚██████╔╝╚██████╔╝   ██║   ███████╗
// ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━  trustless fair play  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// BondRoute SDK — single-file TypeScript client for staked commitment bonds.
//
// QUICK INTEGRATION:
//   1. Copy this file into your project (or install once published as @bondroute/sdk)
//   2. Install peer dep: `npm install viem`
//   3. Initialize once: `const bondRoute = await BondRoute.init({ on_pending_bond: ..., ... })`
//   4. Prepare + dispatch: `const bond = await bondRoute.prepare({ protocol, call, preferred_fundings })`
//
// No external dependencies beyond viem. Storage defaults to localStorage in browsers.

import {
    concat,
    keccak256,
    maxUint256,
    pad,
    parseAbi,
    toHex,
    type Abi,
    type Account,
    type Address,
    type Chain,
    type Hex,
    type Log,
    type PublicClient,
    type WalletClient,
    decodeAbiParameters,
    decodeErrorResult,
    decodeEventLog,
    hashTypedData,
} from "viem";


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// CONSTANTS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Canonical BondRoute deployment address (same across chains). */
export const BONDROUTE_ADDRESS  =  "0xb01d00000000440215e86e0A436f9b59FeB2F14a" as const;

/** Sentinel address representing the native chain token (ETH, etc.). */
export const NATIVE_TOKEN  =  "0x0000000000000000000000000000000000000000" as const;

/** BondRouteProtected enforces a hard 1-second floor on real elapsed time. */
const SECONDS_FLOOR  =  1n;

/** BondRouteProtected adds one timestamp tick to compensate for 1-second granularity on fast-block chains. */
const TIMESTAMP_TICK  =  1n;

/** BondRoute core enforces a 1-block minimum execution delay. */
const BLOCKS_FLOOR  =  1n;

/** Default gas multiplier applied to network estimates when first submitting a tx. */
const DEFAULT_GAS_MULTIPLIER  =  1.5;

/** Default gas multiplier when bumping a stuck tx (must be >10% above original for most mempools). */
const DEFAULT_BUMP_MULTIPLIER  =  2.0;

const SCHEMA_VERSION  =  1;
const MAX_BOND_LIFETIME_SECONDS  =  111n * 24n * 60n * 60n;

/** Default reorg buffer before auto-forgetting a terminally-settled bond. 60 should be enough for virtually all EVM-compatible chains. */
const DEFAULT_MIN_CONFIRMATIONS_TO_FORGET  =  60;


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TYPES
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export type TokenAmount = {
    token: Address;
    amount: bigint;
};

export type Range = {
    min: bigint;
    max: bigint;
};

export type BondConstraints = {
    min_stake: TokenAmount;
    min_fundings: TokenAmount[];
    min_execution_delay_in_blocks: bigint;
    min_execution_delay_in_seconds: bigint;
    max_execution_delay_in_seconds: bigint;
    valid_creation_timestamp_range: Range;
    valid_execution_timestamp_range: Range;
};

export type ExecutionData = {
    fundings: TokenAmount[];
    stake: TokenAmount;
    salt: bigint;
    protocol: Address;
    call: Hex;
};

/**
 * Plain-data shape of a bond record. The `Bond` class wraps this with SDK-aware methods.
 *
 * `state` tracks lifecycle. `status` is the settlement discriminator — switch on it after
 * `bond.dispatch()` resolves. Settlement payload fields (`execution_logs`, `revert_output`,
 * `invalid_reason`) are always present and only meaningful when the matching `status` is set:
 *
 *   status === "executed"          → `execution_logs` contains the receipt's full log list.
 *   status === "protocol_reverted" → `revert_output` contains the bytes from BondProtocolReverted.
 *   status === "invalid_bond"      → `invalid_reason` contains the string from BondValidationFailed.
 *
 * `*_tx_hash` / `*_tx_nonce` are stored so a stuck tx can be replaced with a higher-gas resend
 * at the same nonce via `bond.bump_create()` / `bond.bump_execute()`.
 */
type BondRecord = {
    schema_version: 1;
    chain_id: bigint;
    bondroute: Address;
    user: Address;
    execution_data: ExecutionData;
    commitment_hash: Hex;
    state: BondState;
    status: BondStatus;

    create_tx_hash?: Hex;
    create_tx_nonce?: number;

    creation_block?: bigint;
    creation_timestamp?: bigint;
    constraints?: BondConstraints;

    execute_tx_hash?: Hex;
    execute_tx_nonce?: number;

    execution_logs: Log[];
    revert_output: Hex;
    invalid_reason: string;

    updated_at_block?: bigint;
};

export type BondState =
    | "prepared"
    | "creating"
    | "created"
    | "waiting"
    | "executing"
    | "settled"
    | "unknown";

export type BondStatus = "active" | "executed" | "invalid_bond" | "protocol_reverted" | "liquidated";
export type BondChainState = "unknown" | "missing" | "found";
export type TxStatus = "missing" | "pending" | "mined" | "failed";

export type BondrouteSdkErrorKind =
    | "contract_error"
    | "needs_approval"
    | "insufficient_balance"
    | "create_tx_pending"
    | "execute_tx_pending"
    | "not_executable_yet"
    | "bond_expired"
    | "bond_already_settled"
    | "protocol_reverted"
    | "possibly_bond_farming"
    | "invalid_bond"
    | "rpc_error"
    | "storage_error"
    | "user_rejected"
    | "schema_mismatch";

export class BondrouteSdkError extends Error {
    kind: BondrouteSdkErrorKind;
    details?: unknown;

    constructor( kind: BondrouteSdkErrorKind, message: string, details?: unknown )
    {
        super( message );
        this.name     =  "BondrouteSdkError";
        this.kind     =  kind;
        this.details  =  details;
    }
}

export type SolidityError = {
    name: string;
    args: readonly unknown[];
    data: Hex;
};

export class BondrouteContractError extends BondrouteSdkError {
    solidity_error: SolidityError;
    constructor( solidity_error: SolidityError, cause?: unknown )
    {
        super( "contract_error", `BondRoute contract reverted with ${ solidity_error.name }.`, { solidity_error, cause } );
        this.name            =  "BondrouteContractError";
        this.solidity_error  =  solidity_error;
    }
}

export class NeedsApprovalError extends BondrouteSdkError {
    approvals: Approval[];
    constructor( approvals: Approval[] )
    {
        super( "needs_approval", "Bond requires ERC20 approvals before continuing.", { approvals } );
        this.name       =  "NeedsApprovalError";
        this.approvals  =  approvals;
    }
}

export class BondAlreadySettledError extends BondrouteSdkError {
    settled_status: BondStatus;
    constructor( settled_status: BondStatus )
    {
        super( "bond_already_settled", `Bond is already settled: ${ settled_status }`, { settled_status } );
        this.name            =  "BondAlreadySettledError";
        this.settled_status  =  settled_status;
    }
}

export class InsufficientBalanceError extends BondrouteSdkError {
    shortfalls: BalanceShortfall[];
    constructor( shortfalls: BalanceShortfall[] )
    {
        super( "insufficient_balance", `Bond requires more funds than ${ shortfalls.length === 1 ? "the user holds" : `the user holds in ${ shortfalls.length } tokens` }.`, { shortfalls } );
        this.name        =  "InsufficientBalanceError";
        this.shortfalls  =  shortfalls;
    }
}
export class CreateTxPendingError extends BondrouteSdkError { constructor( details?: unknown ) { super( "create_tx_pending", "Create transaction is still pending.", details ); this.name = "CreateTxPendingError"; } }
export class ExecuteTxPendingError extends BondrouteSdkError { constructor( details?: unknown ) { super( "execute_tx_pending", "Execute transaction is still pending.", details ); this.name = "ExecuteTxPendingError"; } }
export class NotExecutableYetError extends BondrouteSdkError { constructor( details?: unknown ) { super( "not_executable_yet", "Bond is not executable yet.", details ); this.name = "NotExecutableYetError"; } }
export class BondExpiredError extends BondrouteSdkError { constructor( details?: unknown ) { super( "bond_expired", "Bond has expired.", details ); this.name = "BondExpiredError"; } }
export class ProtocolRevertedError extends BondrouteSdkError { constructor( output: Hex ) { super( "protocol_reverted", "Protocol reverted during bond execution.", { output } ); this.name = "ProtocolRevertedError"; } }
export class PossiblyBondFarmingError extends BondrouteSdkError { constructor( reason: string, additional_info: Hex ) { super( "possibly_bond_farming", reason, { additional_info } ); this.name = "PossiblyBondFarmingError"; } }
export class InvalidBondError extends BondrouteSdkError { constructor( reason: string ) { super( "invalid_bond", reason ); this.name = "InvalidBondError"; } }
export class RpcError extends BondrouteSdkError { constructor( message = "RPC error.", details?: unknown ) { super( "rpc_error", message, details ); this.name = "RpcError"; } }
export class StorageError extends BondrouteSdkError { constructor( message = "Storage error.", details?: unknown ) { super( "storage_error", message, details ); this.name = "StorageError"; } }
export class UserRejectedError extends BondrouteSdkError { constructor( message = "User rejected the request.", details?: unknown ) { super( "user_rejected", message, details ); this.name = "UserRejectedError"; } }

export class BondrouteSdkSchemaMismatch extends BondrouteSdkError {
    constructor( schema_version: unknown )
    {
        super( "schema_mismatch", `Unsupported BondRoute SDK bond schema version: ${ String( schema_version ) }`, { schema_version } );
        this.name  =  "BondrouteSdkSchemaMismatch";
    }
}

export type GasOpts = {
    /** Multiplier applied to the network's estimated maxFeePerGas / maxPriorityFeePerGas. */
    gas_multiplier?: number;
};

export type ResumeOpts = {
    /** When `false`, missing token allowances throw `NeedsApprovalError` instead of being auto-approved. Defaults to `true`. */
    auto_approve?: boolean;
};

export type Approval = {
    token: Address;
    spender: Address;
    required: bigint;
    current_allowance: bigint;
    phase: "create" | "execute" | "both";
};

export type BalanceShortfall = {
    token: Address;
    required: bigint;
    current: bigint;
    is_native: boolean;
};

export type BondSnapshot = {
    state: BondState;
    chain_state?: BondChainState;
    status?: BondStatus;
    create_tx_status?: TxStatus;
    execute_tx_status?: TxStatus;
    expired?: boolean;
    executable_now?: boolean;
    blocks_until_executable?: bigint;
    seconds_until_executable?: bigint;
    seconds_until_expiry?: bigint;
    updated_at_block?: bigint;
    confirmations?: number;
};

export type ExecuteBondTypedData = {
    domain: {
        name: string;
        version: string;
        chainId: bigint;
        verifyingContract: Address;
    };
    primaryType: "ExecuteBondAs";
    types: Record<string, { name: string, type: string }[]>;
    message: Record<string, unknown>;
};


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// STORAGE
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * Storage adapter contract. The SDK persists bond state across crashes via this interface.
 * Browser default uses localStorage. Pass a custom adapter for Node.js, IndexedDB, etc.
 */
export type Storage = {
    get(key: string): string | null | Promise<string | null>;
    set(key: string, value: string): void | Promise<void>;
    remove(key: string): void | Promise<void>;
    keys(): string[] | Promise<string[]>;
};

const STORAGE_PREFIX  =  "bondroute:pending:";

function default_storage(): Storage
{
    if(  typeof globalThis === "undefined"  ||  typeof (globalThis as any).localStorage === "undefined"  )
    {
        throw new StorageError(
            "BondRoute SDK requires a storage adapter outside browser contexts. " +
            "Pass `storage: { get, set, remove, keys }` to BondRoute.init() or set `storage: 'memory'` to opt out of recovery (NOT recommended)."
        );
    }
    // Adapt the browser localStorage API (getItem/setItem/removeItem/key/length) to the Storage interface (get/set/remove/keys).
    const ls  =  (globalThis as any).localStorage;
    return {
        get:    ( k ) => ls.getItem( k ),
        set:    ( k, v ) => { ls.setItem( k, v ); },
        remove: ( k ) => { ls.removeItem( k ); },
        keys:   () => { const out: string[] = []; for( let i = 0; i < ls.length; i++ ) { const key = ls.key( i ); if( key !== null ) out.push( key ); } return out; },
    };
}

function memory_storage(): Storage
{
    const map  =  new Map<string, string>();
    return {
        get:    ( k ) => map.get(k) ?? null,
        set:    ( k, v ) => { map.set(k, v); },
        remove: ( k ) => { map.delete(k); },
        keys:   () => Array.from( map.keys() ),
    };
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SERIALIZATION
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function bond_record_to_plain( bond: BondRecord ): unknown
{
    return {
        schema_version:     SCHEMA_VERSION,
        chain_id:           bigint_to_plain( bond.chain_id ),
        bondroute:          bond.bondroute,
        user:               bond.user,
        execution_data:     execution_data_to_plain( bond.execution_data ),
        commitment_hash:    bond.commitment_hash,
        state:              bond.state,
        status:             bond.status,
        execution_logs:     logs_to_plain( bond.execution_logs ),
        revert_output:      bond.revert_output,
        invalid_reason:     bond.invalid_reason,
        create_tx_hash:     bond.create_tx_hash,
        create_tx_nonce:    bond.create_tx_nonce,
        creation_block:     bigint_to_plain( bond.creation_block ),
        creation_timestamp: bigint_to_plain( bond.creation_timestamp ),
        constraints:        bond.constraints  ?  constraints_to_plain( bond.constraints )  :  undefined,
        execute_tx_hash:    bond.execute_tx_hash,
        execute_tx_nonce:   bond.execute_tx_nonce,
        updated_at_block:   bigint_to_plain( bond.updated_at_block ),
    };
}

function plain_to_bond_record( o: any, context?: { chain_id?: bigint, bondroute?: Address } ): BondRecord
{
    if(  o.schema_version !== undefined && o.schema_version !== SCHEMA_VERSION  )
    {
        throw new BondrouteSdkSchemaMismatch( o.schema_version );
    }
    const migrated_state  =  migrate_state( o.state, o.create_tx_hash );
    return {
        schema_version:     SCHEMA_VERSION,
        chain_id:           o.chain_id !== undefined  ?  BigInt( o.chain_id )  :  ( context?.chain_id ?? 0n ),
        bondroute:          ( o.bondroute ?? context?.bondroute ?? BONDROUTE_ADDRESS ) as Address,
        user:               o.user,
        execution_data:     plain_to_execution_data( o.execution_data ),
        commitment_hash:    o.commitment_hash,
        state:              migrated_state.state,
        status:             ( o.status ?? migrated_state.status ?? "active" ) as BondStatus,
        execution_logs:     plain_to_logs( o.execution_logs ),
        revert_output:      ( o.revert_output ?? "0x" ) as Hex,
        invalid_reason:     o.invalid_reason ?? "",
        create_tx_hash:     o.create_tx_hash,
        create_tx_nonce:    o.create_tx_nonce,
        creation_block:     plain_to_bigint( o.creation_block ),
        creation_timestamp: plain_to_bigint( o.creation_timestamp ),
        constraints:        o.constraints  ?  plain_to_constraints( o.constraints )  :  undefined,
        execute_tx_hash:    o.execute_tx_hash,
        execute_tx_nonce:   o.execute_tx_nonce,
        updated_at_block:   plain_to_bigint( o.updated_at_block ),
    };
}

function logs_to_plain( logs: Log[] ): unknown[]
{
    return logs.map(( log ) => ({
        ...log,
        blockNumber:      log.blockNumber      === null || log.blockNumber      === undefined  ?  log.blockNumber      :  toHex( log.blockNumber as bigint ),
        transactionIndex: log.transactionIndex,
        logIndex:         log.logIndex,
    }));
}

function plain_to_logs( o: any ): Log[]
{
    if(  ! Array.isArray( o )  )  return [];
    return o.map(( log: any ) => ({
        ...log,
        blockNumber: log.blockNumber === null || log.blockNumber === undefined  ?  log.blockNumber  :  BigInt( log.blockNumber ),
    })) as Log[];
}

function migrate_state( state: string, create_tx_hash?: Hex ): { state: BondState, status?: BondStatus }
{
    if(  state === "pending_create"  )  return { state: create_tx_hash ? "creating" : "prepared" };
    if(  state === "executed"  )        return { state: "settled", status: "executed" };
    if(  state === "failed"  )          return { state: "settled", status: "protocol_reverted" };
    return { state: state as BondState };
}

function execution_data_to_plain( ed: ExecutionData ): unknown
{
    return {
        fundings: ed.fundings.map(( f ) => ({ token: f.token, amount: toHex( f.amount ) })),
        stake:    { token: ed.stake.token, amount: toHex( ed.stake.amount ) },
        salt:     toHex( ed.salt ),
        protocol: ed.protocol,
        call:     ed.call,
    };
}

function plain_to_execution_data( o: any ): ExecutionData
{
    return {
        fundings: ( o.fundings as any[] ).map(( f ) => ({ token: f.token as Address, amount: BigInt( f.amount ) })),
        stake:    { token: o.stake.token as Address, amount: BigInt( o.stake.amount ) },
        salt:     BigInt( o.salt ),
        protocol: o.protocol as Address,
        call:     o.call as Hex,
    };
}

function constraints_to_plain( c: BondConstraints ): unknown
{
    return {
        min_stake:                       { token: c.min_stake.token, amount: toHex( c.min_stake.amount ) },
        min_fundings:                    c.min_fundings.map(( f ) => ({ token: f.token, amount: toHex( f.amount ) })),
        min_execution_delay_in_blocks:   toHex( c.min_execution_delay_in_blocks ),
        min_execution_delay_in_seconds:  toHex( c.min_execution_delay_in_seconds ),
        max_execution_delay_in_seconds:  toHex( c.max_execution_delay_in_seconds ),
        valid_creation_timestamp_range:  { min: toHex( c.valid_creation_timestamp_range.min ), max: toHex( c.valid_creation_timestamp_range.max ) },
        valid_execution_timestamp_range: { min: toHex( c.valid_execution_timestamp_range.min ), max: toHex( c.valid_execution_timestamp_range.max ) },
    };
}

function plain_to_constraints( o: any ): BondConstraints
{
    return {
        min_stake:                       { token: o.min_stake.token as Address, amount: BigInt( o.min_stake.amount ) },
        min_fundings:                    ( o.min_fundings as any[] ).map(( f ) => ({ token: f.token as Address, amount: BigInt( f.amount ) })),
        min_execution_delay_in_blocks:   BigInt( o.min_execution_delay_in_blocks ),
        min_execution_delay_in_seconds:  BigInt( o.min_execution_delay_in_seconds ),
        max_execution_delay_in_seconds:  BigInt( o.max_execution_delay_in_seconds ),
        valid_creation_timestamp_range:  { min: BigInt( o.valid_creation_timestamp_range.min ), max: BigInt( o.valid_creation_timestamp_range.max ) },
        valid_execution_timestamp_range: { min: BigInt( o.valid_execution_timestamp_range.min ), max: BigInt( o.valid_execution_timestamp_range.max ) },
    };
}

function bigint_to_plain( v: bigint | undefined ): string | undefined  {  return v === undefined ? undefined : toHex( v );  }
function plain_to_bigint( v: string | undefined ): bigint | undefined  {  return v === undefined ? undefined : BigInt( v );  }


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// COMMITMENT HASH (mirrors HashLib.calc_commitment_hash bit-for-bit; BondRoute core is immutable so this never changes)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function hex_to_bigint( h: Hex | Address ): bigint  {  return BigInt( h );  }
function bigint_to_hex( n: bigint ): Hex            {  return toHex( n );  }


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ABI (minimal — only what the SDK actually calls)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const BONDROUTE_ABI  =  parseAbi([
    "error BondNotFound(bytes32 commitment_hash, address stake_token, uint256 stake_amount)",
    "error BondAlreadyExists(bytes32 commitment_hash, address stake_token, uint256 stake_amount)",
    "error UnsupportedStake(uint256 amount_sent, uint256 amount_received)",
    "error BondNotExpired(uint256 expiration_time, uint256 current_time)",
    "error Invalid(string field, uint256 value)",
    "error SameBlockExecution()",
    "error BondAlreadySettled(uint8 status)",
    "error BondExpired(uint256 expired_time, uint256 current_time)",
    "error InsufficientNativeFunding(uint256 held, uint256 expected_msg_value)",
    "error NativeAmountMismatch(uint256 sent, uint256 expected)",
    "error CommitmentMismatch(bytes32 commitment_hash, uint256 chain_id, address stake_token, uint256 stake_amount)",
    "error InvalidSignature(address signer, bytes32 digest, bytes signature)",
    "error InvalidTypedString(string provided, string reason)",
    "error TransferFailed(address from, address token, uint256 amount, address to)",
    "error Reentrancy()",
    "error PossiblyBondFarming(string reason, bytes32 additional_info)",
    "event BondCreated(bytes32 indexed commitment_hash, address stake_token, uint256 stake_amount)",
    "event BondExecuted(bytes32 indexed commitment_hash)",
    "event BondProtocolReverted(bytes32 indexed commitment_hash, bytes call_output)",
    "event BondValidationFailed(bytes32 indexed commitment_hash, string reason)",
    "function create_bond(bytes32 commitment_hash, (address token, uint256 amount) stake) external payable",
    "function execute_bond(((address token, uint256 amount)[] fundings, (address token, uint256 amount) stake, uint256 salt, address protocol, bytes call) execution_data) external payable returns (uint8 status, bytes output)",
    "function execute_bond_as(((address token, uint256 amount)[] fundings, (address token, uint256 amount) stake, uint256 salt, address protocol, bytes call) execution_data, address user, bytes signature, bool is_eip1271) external payable returns (uint8 status, bytes output)",
    "function __OFF_CHAIN__get_bond_info(bytes32 commitment_hash, (address token, uint256 amount) stake) external view returns ((uint256 creation_time, uint256 creation_block, uint256 stake_amount_received, uint8 status) bond_info)",
    "function __OFF_CHAIN__get_signing_info(((address token, uint256 amount)[] fundings, (address token, uint256 amount) stake, uint256 salt, address protocol, bytes call) execution_data) external view returns (bytes32 digest, bytes32 type_hash, string type_string, (string name, string version, uint256 chainId, address verifyingContract) domain)",
]);

// Solidity BondStatus enum -> string
const BOND_STATUS  =  [ "active", "executed", "invalid_bond", "protocol_reverted", "liquidated" ] as const;

const PROTECTED_ABI  =  parseAbi([
    "function BondRoute_quote_call(bytes call, address preferred_stake_token, (address token, uint256 amount)[] preferred_fundings) external view returns (((address token, uint256 amount) min_stake, (address token, uint256 amount)[] min_fundings, uint256 min_execution_delay_in_blocks, uint256 min_execution_delay_in_seconds, uint256 max_execution_delay_in_seconds, (uint256 min, uint256 max) valid_creation_timestamp_range, (uint256 min, uint256 max) valid_execution_timestamp_range) constraints)",
]);

const ERC20_ABI  =  parseAbi([
    "function allowance(address owner, address spender) external view returns (uint256)",
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function balanceOf(address account) external view returns (uint256)",
]);


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SDK
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export type BondRouteOpts = {
    public_client: PublicClient;
    wallet_client: WalletClient;
    account: Account | Address;
    /**
     * Required handler invoked once per unfinished bond discovered in storage at init.
     * The SDK refreshes each bond from chain state before invoking this callback.
     *
     * Required by design: every consumer must consciously decide what to do with
     * recovered bonds. Pass `(bond) => bond.resume()` to auto-resume, or keep a
     * reference and resume/clear later.
     */
    on_pending_bond: ( bond: Bond ) => void | Promise<void>;
    /**
     * Storage adapter for bond persistence. Defaults to `localStorage` in browsers.
     * Pass `"memory"` to opt out of recovery (NOT recommended outside tests).
     */
    storage?: Storage | "memory";
    /**
     * Override the BondRoute contract address (advanced — for forks and testnets).
     */
    bondroute_address?: Address;
    gas?: {
        default_multiplier?: number;
        default_bump_multiplier?: number;
    };
    /** Reorg buffer before auto-forgetting a settled bond. Defaults to 60. */
    min_confirmations_to_forget?: number;
};


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// BOND CLASS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * A bond — your in-flight commitment. Construct via `bondRoute.bond(execution_data, constraints?)`
 * or `bondRoute.deserialize_bond(json)`, then drive it via instance methods.
 *
 * @example
 *   const bond = bondRoute.bond( execution_data );
 *   const result = await bond.dispatch();              // create -> wait -> execute
 *
 * @example  manual control
 *   await bond.create();                                // submit create tx
 *   await bond.wait_until_executable();                 // block until floors satisfied
 *   const result = await bond.execute();                // submit execute tx
 *
 * @example  bumping a stuck tx
 *   await bond.bump_create();   // or bond.bump_execute()
 *
 * @example  persistence
 *   const json = bond.serialize();                      // portable JSON
 *   const back = bondRoute.deserialize_bond( json );    // re-attach to SDK
 *   await back.dispatch();                              // resume from saved state
 */
export class Bond {

    user: Address;
    schema_version: 1;
    chain_id: bigint;
    bondroute: Address;
    execution_data: ExecutionData;
    commitment_hash: Hex;
    state: BondState;

    /**
     * Settlement discriminator. Read after `await bond.dispatch()` and switch over it.
     *
     *   case "active":            // not yet settled (pre-dispatch or in-flight).
     *   case "executed":          // bond.execution_logs contains the protocol's emitted events.
     *   case "protocol_reverted": // bond.revert_output contains the revert bytes.
     *   case "invalid_bond":      // bond.invalid_reason contains the failure string.
     *   case "liquidated":        // collector claimed expired stake; observed post-expiry only.
     */
    status: BondStatus;

    /** Receipt logs from the successful `execute_bond` tx. Populated iff `status === "executed"`; `[]` otherwise. */
    execution_logs: Log[];

    /** Bytes from `BondProtocolReverted`. Populated iff `status === "protocol_reverted"`; `"0x"` otherwise. */
    revert_output: Hex;

    /** String from `BondValidationFailed`. Populated iff `status === "invalid_bond"`; `""` otherwise. */
    invalid_reason: string;

    create_tx_hash?: Hex;
    create_tx_nonce?: number;
    creation_block?: bigint;
    creation_timestamp?: bigint;
    constraints?: BondConstraints;
    execute_tx_hash?: Hex;
    execute_tx_nonce?: number;
    updated_at_block?: bigint;
    confirmations?: number;
    chain_state: BondChainState;
    create_tx_status?: TxStatus;
    execute_tx_status?: TxStatus;
    expired?: boolean;
    executable_now?: boolean;

    /** SDK reference — true-private (#) so it never leaks into JSON.stringify or instance iteration. */
    readonly #sdk: BondRoute;

    /** @internal Prefer `bondRoute.prepare(...)`, `bondRoute.bond(...)`, or `bondRoute.deserialize_bond(...)`. */
    constructor( sdk: BondRoute, data: any )
    {
        this.#sdk                 =  sdk;
        this.schema_version       =  SCHEMA_VERSION;
        this.chain_id             =  data.chain_id;
        this.bondroute            =  data.bondroute;
        this.user                 =  data.user;
        this.execution_data       =  data.execution_data;
        this.commitment_hash      =  data.commitment_hash;
        this.state                =  data.state;
        this.status               =  data.status ?? "active";
        this.execution_logs       =  data.execution_logs ?? [];
        this.revert_output        =  data.revert_output  ?? "0x";
        this.invalid_reason       =  data.invalid_reason ?? "";
        this.create_tx_hash       =  data.create_tx_hash;
        this.create_tx_nonce      =  data.create_tx_nonce;
        this.creation_block       =  data.creation_block;
        this.creation_timestamp   =  data.creation_timestamp;
        this.constraints          =  data.constraints;
        this.execute_tx_hash      =  data.execute_tx_hash;
        this.execute_tx_nonce     =  data.execute_tx_nonce;
        this.updated_at_block     =  data.updated_at_block;
        this.chain_state          =  "unknown";
        this.create_tx_status     =  data.create_tx_hash  ?  "pending"  :  "missing";
        this.execute_tx_status    =  data.execute_tx_hash ?  "pending"  :  "missing";
    }

    /**
     * Resume-aware full flow: create (or bump) → wait → execute (or bump).
     *
     * Looks at `this.state` and any persisted tx hashes to pick up exactly where the bond left off.
     * Safe to call on a freshly-constructed bond, a recovered bond, or a partially-dispatched bond.
     *
     * Settlement is exposed via mutation, not a return value: read `bond.status` after the await,
     * then `bond.execution_logs` / `bond.revert_output` / `bond.invalid_reason` for the matching payload.
     */
    async dispatch( opts?: ResumeOpts ): Promise<this>
    {
        return await this.resume( opts );
    }

    async resume( opts?: ResumeOpts ): Promise<this>
    {
        const throw_on_missing  =  opts?.auto_approve === false;

        await this.refresh();
        if(  this.state === "settled"  )
        {
            await this.#sdk._maybe_forget( this );
            return this;
        }
        if(  this.expired  )  throw new BondExpiredError({ bond: this.commitment_hash });

        if(  this.state === "prepared" || this.state === "creating" || this.state === "unknown"  )
        {
            await this.#sdk._approve_if_needed( this, "create", { throw_on_missing } );
            if(  this.create_tx_hash !== undefined  )  await this.bump_create();
            else                                       await this.create();
        }
        if(  this.state === "executing" && this.execute_tx_hash !== undefined  )  return await this.bump_execute();
        if(  this.state !== "created"  )  throw new InvalidBondError( `Bond cannot resume from state: ${ this.state }` );

        await this.wait_until_executable();

        await this.#sdk._approve_if_needed( this, "execute", { throw_on_missing } );
        if(  this.execute_tx_hash !== undefined  )  return await this.bump_execute();
        return await this.execute();
    }

    async forget(): Promise<void>                             {  await this.#sdk._forget( this );  }

    /** Submit `create_bond`, persist, and wait for mining. Gas-multiplier 1.5× by default. */
    async create( opts?: GasOpts ): Promise<this>             {  await this.#sdk._create_tx(       this, opts );  return this;  }

    /** Replace a stuck create tx at the same nonce with higher gas (2.0× by default). */
    async bump_create( opts?: GasOpts ): Promise<this>        {  await this.#sdk._bump_create_tx(  this, opts );  return this;  }

    /** Block until both block and seconds floors are satisfied. */
    async wait_until_executable(): Promise<this>              {  await this.#sdk._wait_until_executable( this );  return this;  }

    /** Submit `execute_bond`, persist, wait for mining, clear from storage. Gas-multiplier 1.5× by default. */
    async execute( opts?: GasOpts ): Promise<this>             {  await this.#sdk._execute_tx(       this, opts );  return this;  }

    /** Replace a stuck execute tx at the same nonce with higher gas (2.0× by default). */
    async bump_execute( opts?: GasOpts ): Promise<this>        {  await this.#sdk._bump_execute_tx(  this, opts );  return this;  }

    async get_missing_approvals(): Promise<Approval[]>           {  return await this.#sdk._get_missing_approvals( this );  }

    async approve_if_needed(): Promise<void>                  {  await this.#sdk._approve_if_needed( this );  }

    async get_missing_balances(): Promise<BalanceShortfall[]>    {  return await this.#sdk._get_missing_balances( this );  }

    async check_balances(): Promise<void>                     {  await this.#sdk._check_balances( this );  }

    get_native_value_for_create(): bigint                         {  return this.#sdk._get_native_value_for_create( this );  }

    get_native_value_for_execute(): bigint                        {  return this.#sdk._get_native_value_for_execute( this );  }

    async refresh(): Promise<this>                            {  await this.#sdk._refresh( this );  return this;  }

    async get_status(): Promise<BondSnapshot>           {  return await this.#sdk._get_status( this );  }

    async sign_execution(): Promise<Hex>                      {  return await this.#sdk._sign_execution( this );  }

    async get_signing_info()                                      {  return await this.#sdk._get_signing_info( this );  }

    async build_execution_typed_data(): Promise<ExecuteBondTypedData> {  return await this.#sdk._build_execution_typed_data( this );  }

    async execute_as( signature: Hex, opts?: GasOpts & { relayer_account?: Account | Address, is_eip1271?: boolean } ): Promise<this>
    {
        await this.#sdk._execute_as_tx( this, signature, opts );
        return this;
    }

    /** Serialize to portable JSON (hex-encoded bigints). The #sdk reference is automatically omitted. */
    serialize(): string                                       {  return this.#sdk.serialize_bond( this );  }
}

/**
 * BondRoute SDK entry point.
 *
 * Construct with `BondRoute.init({ ... })`. The async factory scans storage for any
 * unfinished bonds and routes them through your `on_pending_bond` handler before returning.
 *
 * @example
 *   const bondRoute = await BondRoute.init({
 *       public_client, wallet_client, account,
     *       on_pending_bond: (bond) => bond.resume(),    // auto-resume all
 *   });
 *   const bond   = bondRoute.bond( execution_data );
 *   const result = await bond.dispatch();
 */
export class BondRoute {

    readonly account: Address;
    readonly public_client: PublicClient;
    readonly wallet_client: WalletClient;
    readonly storage: Storage;
    readonly bondroute_address: Address;
    readonly chain_id: bigint;
    readonly default_gas_multiplier: number;
    readonly default_bump_multiplier: number;
    readonly min_confirmations_to_forget: number;

    private constructor( opts: BondRouteOpts, chain_id: bigint )
    {
        this.public_client      =  opts.public_client;
        this.wallet_client      =  opts.wallet_client;
        this.account            =  typeof opts.account === "string"  ?  opts.account  :  opts.account.address;
        this.bondroute_address  =  opts.bondroute_address ?? BONDROUTE_ADDRESS;
        this.storage            =  opts.storage === "memory"
            ?  memory_storage()
            :  ( opts.storage ?? default_storage() );
        this.chain_id           =  chain_id;
        this.default_gas_multiplier      =  opts.gas?.default_multiplier      ?? DEFAULT_GAS_MULTIPLIER;
        this.default_bump_multiplier     =  opts.gas?.default_bump_multiplier ?? DEFAULT_BUMP_MULTIPLIER;
        this.min_confirmations_to_forget =  opts.min_confirmations_to_forget  ?? DEFAULT_MIN_CONFIRMATIONS_TO_FORGET;
    }

    /**
     * Async factory. Caches chain_id, then scans storage for pending bonds and routes them
     * through `on_pending_bond` before returning.
     *
     * Throws if `on_pending_bond` is missing — recovery is too important to make optional.
     */
    static async init( opts: BondRouteOpts ): Promise<BondRoute>
    {
        if(  typeof opts.on_pending_bond !== "function"  )
        {
            throw new BondrouteSdkError( "invalid_bond",
                "BondRoute.init requires an `on_pending_bond` handler. " +
                "Pass `(bond) => bond.resume()` to auto-resume, or a function that stores/prompts. " +
                "Recovery cannot be silently opted-out of."
            );
        }

        const chain_id  =  BigInt( await opts.public_client.getChainId() );
        const sdk       =  new BondRoute( opts, chain_id );
        const pending   =  await sdk.list_pending();

        for(  const bond of pending  )
        {
            await bond.refresh();
            await opts.on_pending_bond( bond );
        }

        return sdk;
    }


    // ━━━━  STATIC UTILITIES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Compute the sentineled commitment hash for a bond.
     * Layout: `[3 bytes 0xCAFFE0 prefix][6 bytes zeros][21 bytes raw_hash top][2 bytes sentinel]`.
     */
    static calc_commitment_hash( params: {
        user: Address;
        chain_id: bigint;
        bondroute_address?: Address;
        execution_data: ExecutionData;
    } ): Hex
    {
        const bondroute  =  ( params.bondroute_address ?? BONDROUTE_ADDRESS ) as Address;
        const user       =  params.user;
        const ed         =  params.execution_data;

        const fundings_hash  =  BondRoute.hash_fundings( ed.fundings );
        const call_hash      =  keccak256( ed.call );

        // Word 6 (offset 0xc0): (chain_id << 160) | stake_token
        const stake_token_packed  =  ( params.chain_id << 160n ) | hex_to_bigint( ed.stake.token );

        // 8 words = 256 bytes
        const raw_input  =  concat([
            pad( bondroute, { size: 32 } ),                                               // word 0: bondroute (left-padded address)
            pad( user, { size: 32 } ),                                                    // word 1: user
            fundings_hash,                                                                // word 2: fundings_hash
            pad( bigint_to_hex( ed.salt ), { size: 32 } ),                                // word 3: salt
            pad( ed.protocol, { size: 32 } ),                                             // word 4: protocol
            call_hash,                                                                    // word 5: call_hash
            pad( bigint_to_hex( stake_token_packed ), { size: 32 } ),                     // word 6: chainid|stake_token
            pad( bigint_to_hex( ed.stake.amount ), { size: 32 } ),                        // word 7: stake_amount
        ]);

        const raw_hash  =  keccak256( raw_input );

        // Build the structured commitment WITHOUT the sentinel:
        //   bits [255:232] = 0xCAFFE0
        //   bits [231:184] = 0 (6 bytes of zeros)
        //   bits [183:16]  = raw_hash >> 88 (top 21 bytes of raw_hash)
        //   bits [15:0]    = 0 (sentinel slot)
        const raw_hash_big          =  hex_to_bigint( raw_hash );
        const without_sentinel_big  =  ( 0xCAFFE0n << 232n ) | ( ( raw_hash_big >> 88n ) << 16n );
        const without_sentinel_hex  =  pad( bigint_to_hex( without_sentinel_big ), { size: 32 } );

        // Sentinel = bottom 16 bits of keccak256( without_sentinel || (chainid|stake_token) || stake_amount )
        const sentinel_input  =  concat([
            without_sentinel_hex,
            pad( bigint_to_hex( stake_token_packed ), { size: 32 } ),
            pad( bigint_to_hex( ed.stake.amount ), { size: 32 } ),
        ]);
        const sentinel_hash_big  =  hex_to_bigint( keccak256( sentinel_input ) );
        const sentinel_big       =  sentinel_hash_big & 0xFFFFn;

        const final_big  =  without_sentinel_big | sentinel_big;
        return pad( bigint_to_hex( final_big ), { size: 32 } );
    }

    /** Hash a fundings array using the contract's packed layout: `keccak256([ token, amount ]*)`. Empty array → bytes32(0). */
    static hash_fundings( fundings: TokenAmount[] ): Hex
    {
        if(  fundings.length === 0  )  return  "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;
        const packed  =  concat(
            fundings.flatMap(( f ) => [
                pad( f.token, { size: 32 } ),
                pad( bigint_to_hex( f.amount ), { size: 32 } ),
            ])
        );
        return keccak256( packed );
    }

    /** Decode a protocol's revert output against its ABI. Returns null if the bytes don't match any error in the ABI. */
    static decode_protocol_revert( output: Hex, abi: Abi ): { name: string, args: readonly unknown[] } | null
    {
        if(  output.length < 10  )  return null;
        try
        {
            const decoded  =  decodeErrorResult({ abi, data: output }) as { errorName: string, args?: readonly unknown[] };
            return { name: decoded.errorName, args: decoded.args ?? [] };
        }
        catch
        {
            return null;
        }
    }


    // ━━━━  FACTORIES & READS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Compute the sentineled commitment hash using this SDK instance's chain id and BondRoute address.
     * Pass `user` only when preparing a bond for an account different from `bondRoute.account`.
     */
    calc_commitment_hash( params: { execution_data: ExecutionData, user?: Address } ): Hex
    {
        return BondRoute.calc_commitment_hash({
            user:               params.user ?? this.account,
            chain_id:           this.chain_id,
            bondroute_address:  this.bondroute_address,
            execution_data:     params.execution_data,
        });
    }

    /** Serialize a Bond to portable JSON. Bigints become hex strings; no custom envelopes. */
    serialize_bond( bond: Bond ): string
    {
        return JSON.stringify( bond_record_to_plain( bond ) );
    }

    /**
     * Construct a fresh Bond synchronously. Computes the commitment hash; does NOT submit any tx.
     * Drive the bond via its instance methods (`bond.dispatch()`, `bond.create()`, etc.).
     */
    bond( execution_data: ExecutionData, constraints?: BondConstraints ): Bond
    {
        const commitment_hash  =  this.calc_commitment_hash({ execution_data });
        return new Bond( this, {
            schema_version: SCHEMA_VERSION,
            chain_id:      this.chain_id,
            bondroute:     this.bondroute_address,
            user:           this.account,
            execution_data,
            commitment_hash,
            state:          "prepared",
            constraints,
        });
    }

    async prepare( params: {
        account?: Address;
        protocol: Address;
        call: Hex;
        preferred_fundings: TokenAmount[];
        preferred_stake_token?: Address;
        salt?: bigint;
    }): Promise<Bond>
    {
        const user                   =  params.account ?? this.account;
        const preferred_stake_token  =  params.preferred_stake_token ?? NATIVE_TOKEN;
        const constraints            =  await this.quote_call( params.protocol, params.call, preferred_stake_token, params.preferred_fundings );
        const execution_data: ExecutionData  =  {
            fundings: constraints.min_fundings,
            stake:    constraints.min_stake,
            salt:     params.salt ?? random_uint32_bigint(),
            protocol: params.protocol,
            call:     params.call,
        };
        const commitment_hash  =  this.calc_commitment_hash({ user, execution_data });
        return new Bond( this, {
            schema_version: SCHEMA_VERSION,
            chain_id:      this.chain_id,
            bondroute:     this.bondroute_address,
            user,
            execution_data,
            commitment_hash,
            state:         "prepared",
            constraints,
        });
    }

    /** Shortcut for `bondRoute.bond(...).dispatch()`. */
    async dispatch( execution_data: ExecutionData, constraints?: BondConstraints ): Promise<Bond>
    {
        return await this.bond( execution_data, constraints ).dispatch();
    }

    /** Parse a previously-serialized bond back into an SDK-attached Bond instance. */
    deserialize_bond( json: string ): Bond
    {
        return new Bond( this, plain_to_bond_record( JSON.parse( json ), { chain_id: this.chain_id, bondroute: this.bondroute_address } ) );
    }

    /** Return all in-progress bonds in storage for the current account, as Bond instances. */
    async list_pending(): Promise<Bond[]>
    {
        const keys  =  await this.storage.keys();
        const result: Bond[]  =  [];
        for(  const k of keys  )
        {
            if(  ! k.startsWith( STORAGE_PREFIX )  )  continue;
            const raw  =  await this.storage.get( k );
            if(  ! raw  )  continue;
            try
            {
                const data  =  plain_to_bond_record( JSON.parse( raw ), { chain_id: this.chain_id, bondroute: this.bondroute_address } );
                if(  data.state === "settled"  )  continue;
                if(  data.chain_id !== this.chain_id  )  continue;
                if(  data.bondroute.toLowerCase() !== this.bondroute_address.toLowerCase()  )  continue;
                if(  data.user.toLowerCase() === this.account.toLowerCase()  )  result.push( new Bond( this, data ) );
            }
            catch
            {
                /* skip corrupted entries silently — let the user inspect storage manually */
            }
        }
        return result;
    }

    /** Query a protocol's execution constraints for a given call. */
    async quote_call(
        protocol:          Address,
        call:              Hex,
        preferred_stake:   Address,
        preferred_fundings: TokenAmount[],
    ): Promise<BondConstraints>
    {
        const result  =  await this.public_client.readContract({
            address:      protocol,
            abi:          PROTECTED_ABI,
            functionName: "BondRoute_quote_call",
            args:         [ call, preferred_stake, preferred_fundings ],
        });
        // The contract returns a single `BondConstraints` struct, so viem decodes it as one named-tuple object.
        const c  =  result as any;
        return {
            min_stake:                       c.min_stake,
            min_fundings:                    Array.from( c.min_fundings as TokenAmount[] ),
            min_execution_delay_in_blocks:   c.min_execution_delay_in_blocks,
            min_execution_delay_in_seconds:  c.min_execution_delay_in_seconds,
            max_execution_delay_in_seconds:  c.max_execution_delay_in_seconds,
            valid_creation_timestamp_range:  c.valid_creation_timestamp_range,
            valid_execution_timestamp_range: c.valid_execution_timestamp_range,
        };
    }

    watch_bond( bond: Bond, on_update: ( snapshot: BondSnapshot ) => void | Promise<void>, opts?: { interval_ms?: number } ): () => void
    {
        let stopped  =  false;
        const tick = async () => {
            while(  ! stopped  )
            {
                await on_update( await bond.get_status() );
                if(  bond.state === "settled"  )  return;
                await new Promise(( r ) => setTimeout( r, opts?.interval_ms ?? 3000 ));
            }
        };
        tick().catch(() => { /* polling resumes on next external watch */ });
        return () => { stopped = true; };
    }

    watch_pending( on_update: ( bonds: Bond[] ) => void | Promise<void>, opts?: { interval_ms?: number } ): () => void
    {
        let stopped  =  false;
        const tick = async () => {
            while(  ! stopped  )
            {
                await on_update( await this.list_pending() );
                await new Promise(( r ) => setTimeout( r, opts?.interval_ms ?? 5000 ));
            }
        };
        tick().catch(() => { /* polling resumes on next external watch */ });
        return () => { stopped = true; };
    }


    // ━━━━  INTERNAL: TX-SUBMITTING (called by Bond instance methods)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /** @internal — drives bond.create() */
    async _create_tx( bond: Bond, opts?: GasOpts ): Promise<void>
    {
        if(  bond.state !== "prepared" && bond.state !== "creating" && bond.state !== "unknown"  )  throw new InvalidBondError( `Bond is not prepared/creating: ${ bond.state }` );
        await this._check_balances( bond );
        bond.state = "creating";
        await this._save( bond );

        const nonce  =  await this.public_client.getTransactionCount({ address: this.account });
        const fees   =  await this._estimate_fees( opts?.gas_multiplier ?? this.default_gas_multiplier );

        const tx_hash  =  await this._submit_create( bond, nonce, fees );
        bond.create_tx_hash   =  tx_hash;
        bond.create_tx_nonce  =  nonce;
        await this._save( bond );

        await this._finalize_create( bond, tx_hash );
    }

    /** @internal — drives bond.bump_create() */
    async _bump_create_tx( bond: Bond, opts?: GasOpts ): Promise<void>
    {
        if(  bond.state !== "creating" && bond.state !== "unknown"  )  throw new InvalidBondError( `Bond is not creating: ${ bond.state }` );
        if(  bond.create_tx_hash === undefined  ||  bond.create_tx_nonce === undefined  )
        {
            throw new CreateTxPendingError( "No prior create tx to bump — call bond.create() first." );
        }

        const existing  =  await this._try_get_receipt( bond.create_tx_hash );
        if(  existing  )
        {
            await this._finalize_create( bond, bond.create_tx_hash );
            return;
        }

        const fees      =  await this._estimate_fees( opts?.gas_multiplier ?? this.default_bump_multiplier );
        const tx_hash   =  await this._submit_create( bond, bond.create_tx_nonce, fees );
        bond.create_tx_hash  =  tx_hash;
        await this._save( bond );

        await this._finalize_create( bond, tx_hash );
    }

    /** @internal — drives bond.wait_until_executable() */
    async _wait_until_executable( bond: Bond ): Promise<void>
    {
        if(  bond.state !== "created" && bond.state !== "waiting"  )
        {
            throw new NotExecutableYetError({ state: bond.state });
        }
        if(  bond.creation_block === undefined  ||  bond.creation_timestamp === undefined  ||  ! bond.constraints  )
        {
            throw new NotExecutableYetError({ reason: "missing creation_block / creation_timestamp / constraints" });
        }

        const required_blocks   =  max_bigint( bond.constraints.min_execution_delay_in_blocks,  BLOCKS_FLOOR  );
        const configured_secs   =  max_bigint( bond.constraints.min_execution_delay_in_seconds, SECONDS_FLOOR );
        const required_seconds  =  configured_secs + TIMESTAMP_TICK;

        bond.state = "waiting";
        await this._save( bond );
        await wait_for_block(     this.public_client, bond.creation_block     + required_blocks  );
        await wait_for_timestamp( this.public_client, bond.creation_timestamp + required_seconds );
        bond.state = "created";
        await this._save( bond );
    }

    /** @internal — drives bond.execute() */
    async _execute_tx( bond: Bond, opts?: GasOpts ): Promise<void>
    {
        if(  bond.state !== "created"  )  throw new NotExecutableYetError({ state: bond.state });

        bond.state = "executing";
        const nonce  =  await this.public_client.getTransactionCount({ address: this.account });
        const fees   =  await this._estimate_fees( opts?.gas_multiplier ?? this.default_gas_multiplier );

        const tx_hash  =  await this._submit_execute( bond, nonce, fees );
        bond.execute_tx_hash   =  tx_hash;
        bond.execute_tx_nonce  =  nonce;
        await this._save( bond );

        await this._finalize_execute( bond, tx_hash );
    }

    /** @internal — drives bond.bump_execute() */
    async _bump_execute_tx( bond: Bond, opts?: GasOpts ): Promise<void>
    {
        if(  bond.state !== "executing" && bond.state !== "created"  )  throw new NotExecutableYetError({ state: bond.state });
        if(  bond.execute_tx_hash === undefined  ||  bond.execute_tx_nonce === undefined  )
        {
            throw new ExecuteTxPendingError( "No prior execute tx to bump — call bond.execute() first." );
        }

        const existing  =  await this._try_get_receipt( bond.execute_tx_hash );
        if(  existing  )
        {
            await this._finalize_execute( bond, bond.execute_tx_hash );
            return;
        }

        const fees    =  await this._estimate_fees( opts?.gas_multiplier ?? this.default_bump_multiplier );
        const tx_hash =  await this._submit_execute( bond, bond.execute_tx_nonce, fees );
        bond.execute_tx_hash  =  tx_hash;
        await this._save( bond );

        await this._finalize_execute( bond, tx_hash );
    }


    // ━━━━  INTERNAL: HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private storage_key( bond: Bond ): string
    {
        return `${ STORAGE_PREFIX }${ bond.chain_id.toString() }:${ bond.bondroute.toLowerCase() }:${ bond.user.toLowerCase() }:${ bond.commitment_hash }`;
    }

    private async _save( bond: Bond ): Promise<void>
    {
        await this.storage.set( this.storage_key( bond ), this.serialize_bond( bond ) );
    }

    async _forget( bond: Bond ): Promise<void>
    {
        await this.storage.remove( this.storage_key( bond ) );
    }

    async _maybe_forget( bond: Bond ): Promise<void>
    {
        if(  bond.confirmations !== undefined && bond.confirmations >= this.min_confirmations_to_forget  )
        {
            await this._forget( bond );
        }
    }

    private async _estimate_fees( multiplier: number ): Promise<{ maxFeePerGas: bigint, maxPriorityFeePerGas: bigint }>
    {
        const base  =  await this.public_client.estimateFeesPerGas();
        return {
            maxFeePerGas:         bigint_mult( base.maxFeePerGas         ?? 0n, multiplier ),
            maxPriorityFeePerGas: bigint_mult( base.maxPriorityFeePerGas ?? 0n, multiplier ),
        };
    }

    private async _try_get_receipt( hash: Hex ): Promise<{ blockNumber: bigint, status?: string } | null>
    {
        try   {  return await this.public_client.getTransactionReceipt({ hash });  }
        catch {  return null;  }
    }

    private _get_native_value_for_fundings( fundings: TokenAmount[] ): bigint
    {
        for(  const f of fundings  )
        {
            if(  f.token.toLowerCase() === NATIVE_TOKEN.toLowerCase()  )  return f.amount;
        }
        return 0n;
    }

    _get_native_value_for_create( bond: Bond ): bigint
    {
        return bond.execution_data.stake.token.toLowerCase() === NATIVE_TOKEN.toLowerCase()
            ?  bond.execution_data.stake.amount
            :  0n;
    }

    _get_native_value_for_execute( bond: Bond ): bigint
    {
        const native_funding  =  this._get_native_value_for_fundings( bond.execution_data.fundings );
        if(  native_funding === 0n  )  return 0n;
        if(  bond.execution_data.stake.token.toLowerCase() !== NATIVE_TOKEN.toLowerCase()  )  return native_funding;
        return native_funding > bond.execution_data.stake.amount  ?  native_funding - bond.execution_data.stake.amount  :  0n;
    }

    async _get_missing_approvals( bond: Bond, phase_filter?: Approval[ "phase" ] ): Promise<Approval[]>
    {
        // *SECURITY*  -  Aggregate per-token required amounts across phases BEFORE comparing to allowance.
        //                Comparing per-phase would early-return on same-token stake/funding when allowance covers
        //                one phase but not the lifecycle total, leaving the next phase silently under-approved.
        type Need  =  { token: Address, required: bigint, phases: Set<"create" | "execute"> };
        const totals  =  new Map<string, Need>();

        const accumulate = ( token: Address, required: bigint, phase: "create" | "execute" ) => {
            if(  phase_filter !== undefined && phase !== phase_filter  )  return;
            if(  required === 0n || token.toLowerCase() === NATIVE_TOKEN.toLowerCase()  )  return;
            const key       =  token.toLowerCase();
            const existing  =  totals.get( key );
            if(  existing  )
            {
                existing.required  +=  required;
                existing.phases.add( phase );
            }
            else
            {
                totals.set( key, { token, required, phases: new Set([ phase ]) } );
            }
        };

        accumulate( bond.execution_data.stake.token, bond.execution_data.stake.amount, "create" );
        for(  const f of bond.execution_data.fundings  )
        {
            let required  =  f.amount;
            if(  f.token.toLowerCase() === bond.execution_data.stake.token.toLowerCase()  )
            {
                required  =  required > bond.execution_data.stake.amount  ?  required - bond.execution_data.stake.amount  :  0n;
            }
            accumulate( f.token, required, "execute" );
        }

        const result: Approval[]  =  [];
        for(  const need of totals.values()  )
        {
            const current_allowance  =  await this.public_client.readContract({
                address:      need.token,
                abi:          ERC20_ABI,
                functionName: "allowance",
                args:         [ bond.user, this.bondroute_address ],
            }) as bigint;
            if(  current_allowance >= need.required  )  continue;
            const phase: Approval[ "phase" ]  =  need.phases.size === 2
                ?  "both"
                :  ( need.phases.has( "create" )  ?  "create"  :  "execute" );
            result.push({ token: need.token, spender: this.bondroute_address, required: need.required, current_allowance, phase });
        }
        return result;
    }

    async _get_missing_balances( bond: Bond ): Promise<BalanceShortfall[]>
    {
        const totals  =  new Map<string, { token: Address, amount: bigint, is_native: boolean }>();
        const add = ( token: Address, amount: bigint ) => {
            if(  amount === 0n  )  return;
            const key       =  token.toLowerCase();
            const is_native =  key === NATIVE_TOKEN.toLowerCase();
            const existing  =  totals.get( key );
            if(  existing  )  existing.amount += amount;
            else              totals.set( key, { token, amount, is_native } );
        };

        add( bond.execution_data.stake.token, bond.execution_data.stake.amount );
        for(  const f of bond.execution_data.fundings  )
        {
            let amount  =  f.amount;
            if(  f.token.toLowerCase() === bond.execution_data.stake.token.toLowerCase()  )
            {
                amount  =  amount > bond.execution_data.stake.amount  ?  amount - bond.execution_data.stake.amount  :  0n;
            }
            add( f.token, amount );
        }

        const shortfalls: BalanceShortfall[]  =  [];
        for(  const need of totals.values()  )
        {
            const current  =  need.is_native
                ?  await this.public_client.getBalance({ address: bond.user })
                :  ( await this.public_client.readContract({
                    address:      need.token,
                    abi:          ERC20_ABI,
                    functionName: "balanceOf",
                    args:         [ bond.user ],
                }) ) as bigint;
            if(  current < need.amount  )  shortfalls.push({ token: need.token, required: need.amount, current, is_native: need.is_native });
        }
        return shortfalls;
    }

    async _check_balances( bond: Bond ): Promise<void>
    {
        const shortfalls  =  await this._get_missing_balances( bond );
        if(  shortfalls.length > 0  )  throw new InsufficientBalanceError( shortfalls );
    }

    async _approve_if_needed( bond: Bond, phase_filter?: Approval[ "phase" ], opts?: { throw_on_missing?: boolean } ): Promise<void>
    {
        const approvals  =  await this._get_missing_approvals( bond, phase_filter );
        if(  approvals.length === 0  )  return;
        if(  opts?.throw_on_missing  )  throw new NeedsApprovalError( approvals );

        // *NOTE*  -  Auto-approval always writes `maxUint256` because BondRoute is a singleton gateway shared
        //            across protocols; one infinite approval covers every future bond. Devs who want a tighter
        //            cap should read `bond.get_missing_approvals()` and submit ERC20 `approve()` calls themselves.
        for(  const approval of approvals  )
        {
            const tx_hash  =  await this.wallet_client.writeContract({
                address:      approval.token,
                abi:          ERC20_ABI,
                functionName: "approve",
                args:         [ approval.spender, maxUint256 ],
                account:      this.account,
                chain:        this.wallet_client.chain as Chain,
            });
            await this.public_client.waitForTransactionReceipt({ hash: tx_hash });
        }
    }

    async _get_signing_info( bond: Bond ): Promise<{ digest: Hex, type_hash: Hex, type_string: string, domain: { name: string, version: string, chainId: bigint, verifyingContract: Address } }>
    {
        const [ digest, type_hash, type_string, domain ]  =  await this.public_client.readContract({
            address:      this.bondroute_address,
            abi:          BONDROUTE_ABI,
            functionName: "__OFF_CHAIN__get_signing_info",
            args:         [ bond.execution_data ],
        }) as any;
        return { digest, type_hash, type_string, domain };
    }

    async _sign_execution( bond: Bond ): Promise<Hex>
    {
        const typed_data = await this._build_execution_typed_data( bond );
        const sign_typed_data = (this.wallet_client as any).signTypedData;
        if(  sign_typed_data  )
        {
            return await sign_typed_data.call( this.wallet_client, { account: this.account, ...typed_data } );
        }
        const typed_account = this.wallet_client.account as any;
        if(  typed_account?.signTypedData  )
        {
            return await typed_account.signTypedData( typed_data );
        }

        const info     =  await this._get_signing_info( bond );
        const account  =  this.wallet_client.account as any;
        if(  account?.sign  )
        {
            return await account.sign({ hash: info.digest });
        }
        const request = (this.wallet_client as any).request;
        if(  request  )
        {
            return await request({ method: "eth_sign", params: [ bond.user, info.digest ] });
        }
        throw new BondrouteSdkError( "rpc_error", "Wallet client cannot raw-sign the BondRoute execution digest. Provide a local account with account.sign({ hash })." );
    }

    async _build_execution_typed_data( bond: Bond ): Promise<ExecuteBondTypedData>
    {
        const info        =  await this._get_signing_info( bond );
        const types       =  parse_eip712_type_string( info.type_string );
        const primaryType =  "ExecuteBondAs" as const;
        const fields      =  types[ primaryType ];
        if(  ! fields  )  throw new InvalidBondError( "Signing type string is missing ExecuteBondAs." );

        const message: Record<string, unknown> = {};
        const custom_fields = fields.filter(( f ) => ! [ "fundings", "stake", "salt", "protocol" ].includes( f.name ));
        for(  const field of fields  )
        {
            if(  field.name === "fundings"  )  message.fundings = bond.execution_data.fundings;
            else if(  field.name === "stake"  )  message.stake = bond.execution_data.stake;
            else if(  field.name === "salt"  )  message.salt = bond.execution_data.salt;
            else if(  field.name === "protocol"  )  message.protocol = bond.execution_data.protocol;
            else if(  field.name === "calldata_hash" && field.type === "bytes32"  )  message.calldata_hash = keccak256( bond.execution_data.call );
        }

        const undecoded_fields = custom_fields.filter(( f ) => message[ f.name ] === undefined );
        if(  undecoded_fields.length === 1 && types[ strip_array_suffix( undecoded_fields[0]!.type ) ]  )
        {
            const field       =  undecoded_fields[0]!;
            const struct_type =  strip_array_suffix( field.type );
            const struct      =  types[ struct_type ]!;
            const decoded     =  decodeAbiParameters( struct.map(( p ) => ({ name: p.name, type: p.type })) as any, calldata_args( bond.execution_data.call ) );
            message[ field.name ] = Object.fromEntries( struct.map(( p, i ) => [ p.name, decoded[ i ] ]) );
        }
        else if(  undecoded_fields.length > 0  )
        {
            const decoded = decodeAbiParameters( undecoded_fields.map(( p ) => ({ name: p.name, type: p.type })) as any, calldata_args( bond.execution_data.call ) );
            for(  let i = 0  ;  i < undecoded_fields.length  ;  i++  )
            {
                message[ undecoded_fields[ i ]!.name ] = decoded[ i ];
            }
        }

        const typed_data: ExecuteBondTypedData = {
            domain: {
                name:              info.domain.name,
                version:           info.domain.version,
                chainId:           BigInt( info.domain.chainId ),
                verifyingContract: info.domain.verifyingContract,
            },
            primaryType,
            types,
            message,
        };
        const digest = hashTypedData( typed_data as any );
        if(  digest.toLowerCase() !== info.digest.toLowerCase()  )
        {
            throw new InvalidBondError( "Built EIP-712 typed data does not match BondRoute signing digest." );
        }
        return typed_data;
    }

    async _execute_as_tx( bond: Bond, signature: Hex, opts?: GasOpts & { relayer_account?: Account | Address, is_eip1271?: boolean } ): Promise<void>
    {
        if(  bond.state !== "created" && bond.state !== "executing"  )  throw new NotExecutableYetError({ state: bond.state });
        bond.state = "executing";
        const relayer_account  =  opts?.relayer_account
            ?  ( typeof opts.relayer_account === "string" ? opts.relayer_account : opts.relayer_account.address )
            :  this.account;
        const nonce  =  await this.public_client.getTransactionCount({ address: relayer_account as Address });
        const fees   =  await this._estimate_fees( opts?.gas_multiplier ?? this.default_gas_multiplier );
        const value  =  this._get_native_value_for_execute( bond );
        const tx_hash  =  await this.wallet_client.writeContract({
            address:              this.bondroute_address,
            abi:                  BONDROUTE_ABI,
            functionName:         "execute_bond_as",
            args:                 [ bond.execution_data, bond.user, signature, opts?.is_eip1271 ?? false ],
            value,
            account:              relayer_account as Address,
            chain:                this.wallet_client.chain as Chain,
            nonce,
            maxFeePerGas:         fees.maxFeePerGas,
            maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
        });
        bond.execute_tx_hash   =  tx_hash;
        bond.execute_tx_nonce  =  nonce;
        await this._save( bond );
        await this._finalize_execute( bond, tx_hash );
    }

    async _refresh( bond: Bond ): Promise<void>
    {
        const previous_status       =  bond.status;
        const previous_chain_state  =  bond.chain_state;

        await this._reconcile( bond );

        const head           =  await this._get_head_block();
        const state_changed  =  bond.updated_at_block === undefined
            || previous_status      !== bond.status
            || previous_chain_state !== bond.chain_state;
        if(  state_changed  )  bond.updated_at_block = head;
        bond.confirmations  =  bond.updated_at_block !== undefined && head >= bond.updated_at_block
            ?  Number( head - bond.updated_at_block )
            :  0;

        await this._save( bond );
    }

    private async _get_head_block(): Promise<bigint>
    {
        try
        {
            if(  this.public_client.getBlockNumber  )  return await this.public_client.getBlockNumber();
            const block  =  await this.public_client.getBlock();
            return block.number ?? 0n;
        }
        catch
        {
            return 0n;
        }
    }

    async _get_status( bond: Bond ): Promise<BondSnapshot>
    {
        await this._reconcile( bond );
        const snapshot: BondSnapshot  =  {
            state:             bond.state,
            chain_state:       bond.chain_state,
            status:            bond.status,
            create_tx_status:  bond.create_tx_status,
            execute_tx_status: bond.execute_tx_status,
            expired:           bond.expired,
            executable_now:    bond.executable_now,
            updated_at_block:  bond.updated_at_block,
            confirmations:     bond.confirmations,
        };
        if(  bond.creation_block !== undefined && bond.creation_timestamp !== undefined && bond.constraints  )
        {
            const block             =  await this.public_client.getBlock();
            const current_block     =  block.number ?? await this.public_client.getBlockNumber();
            const required_blocks   =  max_bigint( bond.constraints.min_execution_delay_in_blocks,  BLOCKS_FLOOR );
            const required_seconds  =  max_bigint( bond.constraints.min_execution_delay_in_seconds, SECONDS_FLOOR ) + TIMESTAMP_TICK;
            const target_block      =  bond.creation_block + required_blocks;
            const target_timestamp  =  bond.creation_timestamp + required_seconds;
            snapshot.blocks_until_executable   =  current_block >= target_block      ?  0n  :  target_block - current_block;
            snapshot.seconds_until_executable  =  block.timestamp >= target_timestamp ?  0n  :  target_timestamp - block.timestamp;
            const expires_at = bond.creation_timestamp + MAX_BOND_LIFETIME_SECONDS;
            snapshot.seconds_until_expiry = block.timestamp >= expires_at ? 0n : expires_at - block.timestamp;
        }
        return snapshot;
    }

    private async _reconcile( bond: Bond ): Promise<void>
    {
        let create_tx_status: TxStatus    =  "missing";
        let execute_tx_status: TxStatus   =  "missing";

        if(  bond.create_tx_hash  )
        {
            const receipt  =  await this._try_get_receipt( bond.create_tx_hash );
            create_tx_status  =  receipt  ?  ( (receipt as any).status === "success" ? "mined" : "failed" )  :  "pending";
            if(  receipt && (receipt as any).status === "success"  )
            {
                const block = await this.public_client.getBlock({ blockNumber: receipt.blockNumber });
                bond.creation_block = receipt.blockNumber;
                bond.creation_timestamp = block.timestamp;
            }
        }
        if(  bond.execute_tx_hash  )
        {
            const receipt  =  await this._try_get_receipt( bond.execute_tx_hash );
            execute_tx_status  =  receipt  ?  ( (receipt as any).status === "success" ? "mined" : "failed" )  :  "pending";
        }
        bond.create_tx_status   =  create_tx_status;
        bond.execute_tx_status  =  execute_tx_status;

        bond.chain_state = "unknown";
        try
        {
            const info  =  await this.public_client.readContract({
                address:      this.bondroute_address,
                abi:          BONDROUTE_ABI,
                functionName: "__OFF_CHAIN__get_bond_info",
                args:         [ bond.commitment_hash, bond.execution_data.stake ],
            }) as any;
            bond.creation_timestamp  =  BigInt( info.creation_time );
            bond.creation_block      =  BigInt( info.creation_block );
            bond.chain_state         =  "found";
            bond.status              =  BOND_STATUS[ Number( info.status ) ] ?? "active";
            if(  bond.status === "active"  )
            {
                bond.state = execute_tx_status === "pending" ? "executing" : "created";
                if(  execute_tx_status === "failed"  )
                {
                    bond.execute_tx_hash   =  undefined;
                    bond.execute_tx_nonce  =  undefined;
                }
            }
            else
            {
                bond.state  =  "settled";
            }
        }
        catch( err )
        {
            const solidity_error = decode_solidity_error( err );
            if(  solidity_error?.name !== "BondNotFound"  )
            {
                if(  solidity_error  )  throw new BondrouteContractError( solidity_error, err );
                throw new RpcError( "Failed to read BondRoute bond info.", err );
            }
            bond.chain_state = "missing";
            if(  create_tx_status === "pending"  )  bond.state = "creating";
            else if(  bond.state === "unknown"  )   bond.state = "prepared";
        }

        const snapshot = await this._local_executability( bond );
        bond.expired         =  snapshot.expired;
        bond.executable_now  =  snapshot.executable_now;
    }

    private async _local_executability( bond: Bond ): Promise<{ expired: boolean, executable_now: boolean }>
    {
        if(  bond.creation_block === undefined || bond.creation_timestamp === undefined || ! bond.constraints  )
        {
            return { expired: false, executable_now: false };
        }
        const block             =  await this.public_client.getBlock();
        const current_block     =  block.number ?? await this.public_client.getBlockNumber();
        const required_blocks   =  max_bigint( bond.constraints.min_execution_delay_in_blocks,  BLOCKS_FLOOR );
        const required_seconds  =  max_bigint( bond.constraints.min_execution_delay_in_seconds, SECONDS_FLOOR ) + TIMESTAMP_TICK;
        const executable_now    =  current_block >= bond.creation_block + required_blocks
            && block.timestamp >= bond.creation_timestamp + required_seconds;
        const expired           =  block.timestamp > bond.creation_timestamp + MAX_BOND_LIFETIME_SECONDS;
        return { expired, executable_now };
    }

    private async _submit_create( bond: Bond, nonce: number, fees: { maxFeePerGas: bigint, maxPriorityFeePerGas: bigint } ): Promise<Hex>
    {
        const value  =  this._get_native_value_for_create( bond );

        return await this.wallet_client.writeContract({
            address:              this.bondroute_address,
            abi:                  BONDROUTE_ABI,
            functionName:         "create_bond",
            args:                 [ bond.commitment_hash, bond.execution_data.stake ],
            value,
            account:              this.account,
            chain:                this.wallet_client.chain as Chain,
            nonce,
            maxFeePerGas:         fees.maxFeePerGas,
            maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
        });
    }

    private async _submit_execute( bond: Bond, nonce: number, fees: { maxFeePerGas: bigint, maxPriorityFeePerGas: bigint } ): Promise<Hex>
    {
        const value  =  this._get_native_value_for_execute( bond );

        return await this.wallet_client.writeContract({
            address:              this.bondroute_address,
            abi:                  BONDROUTE_ABI,
            functionName:         "execute_bond",
            args:                 [ bond.execution_data ],
            value,
            account:              this.account,
            chain:                this.wallet_client.chain as Chain,
            nonce,
            maxFeePerGas:         fees.maxFeePerGas,
            maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
        });
    }

    private async _finalize_create( bond: Bond, tx_hash: Hex ): Promise<void>
    {
        const receipt  =  await this.public_client.waitForTransactionReceipt({ hash: tx_hash });
        if(  receipt.status !== "success"  )  throw new InvalidBondError( `create_bond tx reverted (hash: ${ tx_hash })` );

        const block  =  await this.public_client.getBlock({ blockNumber: receipt.blockNumber });

        bond.state               =  "created";
        bond.creation_block      =  receipt.blockNumber;
        bond.creation_timestamp  =  block.timestamp;
        if(  ! bond.constraints  )
        {
            bond.constraints  =  await this.quote_call(
                bond.execution_data.protocol,
                bond.execution_data.call,
                bond.execution_data.stake.token,
                bond.execution_data.fundings,
            );
        }
        await this._save( bond );
    }

    private async _finalize_execute( bond: Bond, tx_hash: Hex ): Promise<void>
    {
        const receipt  =  await this.public_client.waitForTransactionReceipt({ hash: tx_hash });
        if(  receipt.status !== "success"  )  throw new InvalidBondError( `execute_bond tx reverted (hash: ${ tx_hash })` );

        const all_logs: Log[]  =  ( receipt.logs ?? [] ) as Log[];
        const settlement       =  this._decode_settlement_from_logs( bond, all_logs );

        bond.state              =  "settled";
        bond.status             =  settlement.status;
        bond.execution_logs     =  settlement.execution_logs;
        bond.revert_output      =  settlement.revert_output;
        bond.invalid_reason     =  settlement.invalid_reason;
        bond.updated_at_block   =  receipt.blockNumber;

        await this._save( bond );
        await this._maybe_forget( bond );
    }

    /**
     * Walks the receipt logs for a `BondExecuted`, `BondProtocolReverted`, or `BondValidationFailed`
     * matching this bond's commitment hash. Exactly one is emitted per successful `execute_bond` tx.
     * On the `executed` path, the full receipt log list is exposed for protocol-side event decoding.
     */
    private _decode_settlement_from_logs( bond: Bond, logs: Log[] ): { status: BondStatus, execution_logs: Log[], revert_output: Hex, invalid_reason: string }
    {
        const bondroute_addr   =  this.bondroute_address.toLowerCase();
        const commitment_hash  =  bond.commitment_hash.toLowerCase();

        for(  const log of logs  )
        {
            if(  log.address.toLowerCase() !== bondroute_addr  )  continue;
            if(  ( log.topics[1] ?? "" ).toLowerCase() !== commitment_hash  )  continue;

            let decoded: { eventName: string, args: any };
            try
            {
                decoded  =  decodeEventLog({ abi: BONDROUTE_ABI, data: log.data, topics: log.topics }) as any;
            }
            catch
            {
                continue;
            }

            if(  decoded.eventName === "BondExecuted"  )
            {
                return { status: "executed",          execution_logs: logs, revert_output: "0x",                                invalid_reason: "" };
            }
            if(  decoded.eventName === "BondProtocolReverted"  )
            {
                return { status: "protocol_reverted", execution_logs: [],   revert_output: decoded.args.call_output as Hex,     invalid_reason: "" };
            }
            if(  decoded.eventName === "BondValidationFailed"  )
            {
                return { status: "invalid_bond",      execution_logs: [],   revert_output: "0x",                                invalid_reason: decoded.args.reason as string };
            }
        }

        throw new InvalidBondError( `execute_bond receipt has no settlement event for commitment ${ bond.commitment_hash } (scanned ${ logs.length } logs).` );
    }
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// INTERNAL HELPERS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function max_bigint( a: bigint, b: bigint ): bigint  {  return a > b ? a : b;  }

function random_uint32_bigint(): bigint
{
    const crypto_obj = (globalThis as any).crypto;
    if(  crypto_obj?.getRandomValues  )
    {
        const values = new Uint32Array(1);
        crypto_obj.getRandomValues( values );
        return BigInt( values[0] ?? 0 );
    }
    return BigInt( Math.floor( Math.random() * 0x1_0000_0000 ) );
}

function parse_eip712_type_string( type_string: string ): Record<string, { name: string, type: string }[]>
{
    const types: Record<string, { name: string, type: string }[]> = {};
    const re = /([A-Za-z_][A-Za-z0-9_]*)\(([^()]*)\)/g;
    let match: RegExpExecArray | null;
    while(  ( match = re.exec( type_string ) ) !== null  )
    {
        const type_name = match[1]!;
        const body      = match[2]!.trim();
        types[ type_name ] = body.length === 0
            ?  []
            :  body.split( "," ).map(( part ) => {
                const pieces = part.trim().split( /\s+/ );
                if(  pieces.length !== 2  )  throw new InvalidBondError( `Invalid EIP-712 field: ${ part }` );
                return { type: pieces[0]!, name: pieces[1]! };
            });
    }
    if(  Object.keys( types ).length === 0  )  throw new InvalidBondError( "Invalid EIP-712 type string." );
    return types;
}

function strip_array_suffix( type: string ): string
{
    return type.replace( /(\[[^\]]*\])+$/g, "" );
}

function calldata_args( call: Hex ): Hex
{
    if(  call.length < 10  )  return "0x";
    return ( "0x" + call.slice( 10 ) ) as Hex;
}

function decode_solidity_error( err: unknown ): SolidityError | undefined
{
    const data = find_revert_data( err );
    if(  ! data  )  return undefined;
    try
    {
        const decoded = decodeErrorResult({ abi: BONDROUTE_ABI, data }) as { errorName: string, args?: readonly unknown[] };
        return { name: decoded.errorName, args: decoded.args ?? [], data };
    }
    catch
    {
        return undefined;
    }
}

function find_revert_data( value: unknown, seen = new Set<unknown>() ): Hex | undefined
{
    if(  value === null || value === undefined  )  return undefined;
    if(  typeof value !== "object"  )  return undefined;
    if(  seen.has( value )  )  return undefined;
    seen.add( value );

    const obj = value as Record<string, unknown>;
    for(  const key of [ "data", "errorData" ]  )
    {
        const candidate = obj[ key ];
        if(  is_hex( candidate )  )  return candidate;
        if(  typeof candidate === "object"  )
        {
            const nested = find_revert_data( candidate, seen );
            if(  nested  )  return nested;
        }
    }

    for(  const key of [ "cause", "error" ]  )
    {
        const nested = find_revert_data( obj[ key ], seen );
        if(  nested  )  return nested;
    }

    return undefined;
}

function is_hex( value: unknown ): value is Hex
{
    return typeof value === "string" && /^0x[0-9a-fA-F]*$/.test( value );
}

/** Multiply a bigint by a float multiplier (rounding to floor); preserves bigint type. */
function bigint_mult( n: bigint, m: number ): bigint
{
    if(  n === 0n  )  return 0n;
    const scale  =  10_000n;
    return ( n * BigInt( Math.floor( m * Number( scale ) ) ) ) / scale;
}

async function wait_for_block( client: PublicClient, target_block: bigint ): Promise<void>
{
    while(  true  )
    {
        const current  =  await client.getBlockNumber();
        if(  current >= target_block  )  return;
        await new Promise(( r ) => setTimeout( r, 1500 ));
    }
}

async function wait_for_timestamp( client: PublicClient, target_timestamp: bigint ): Promise<void>
{
    while(  true  )
    {
        const block  =  await client.getBlock();
        if(  block.timestamp >= target_timestamp  )  return;
        const wait_ms  =  Number( target_timestamp - block.timestamp ) * 1000 + 500;
        await new Promise(( r ) => setTimeout( r, Math.min( wait_ms, 5000 ) ));
    }
}
