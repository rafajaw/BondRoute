# @bondroute/sdk

TypeScript client SDK for [BondRoute](../README.md) — staked commitment bonds for EVM protocols.

Single self-contained file. Browser + Node. viem-based.

## Install

```bash
npm install viem
# Copy sdk/BondRoute.ts into your project, or install the package once published:
# npm install @bondroute/sdk
```

## Quick start

```typescript
import { createPublicClient, createWalletClient, encodeFunctionData, http } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { BondRoute } from "@bondroute/sdk";

const account        =  privateKeyToAccount( "0x..." );
const public_client  =  createPublicClient({ chain: mainnet, transport: http( ) });
const wallet_client  =  createWalletClient({ chain: mainnet, transport: http( ), account });

// Required: handler for any unfinished bonds found in storage on init.
// The SDK refreshes each bond from chain state before invoking this callback.
const bondRoute  =  await BondRoute.init({
    public_client,
    wallet_client,
    account,
    on_pending_bond: ( bond ) => bond.resume( ),    // or prompt the user, log, etc.
});

// Supply the protocol intent. The SDK quotes the protocol, builds ExecutionData,
// computes the commitment hash, and caches constraints on the returned Bond.
const bond  =  await bondRoute.prepare({
    protocol: "0xYourProtocolAddress",
    call:     encodeFunctionData({ abi, functionName: "swap", args: [ ... ] }),
    preferred_stake_token: USDC,
    preferred_fundings: [{ token: USDC, amount: 1000_000_000n }],
});

const { status, output }  =  await bond.dispatch( );
```

`bondRoute.bond( execution_data )` and `bondRoute.dispatch( execution_data )` remain available as advanced escape hatches when you already have quoted constraints.

## `on_pending_bond` is required

`BondRoute.init` throws if you don't pass `on_pending_bond`. By design.

Bonds that get stuck mid-flow (create landed but execute didn't, browser crashed, etc.) need a conscious recovery strategy from the consumer — silently resuming is dangerous (might re-execute an already-stale bond), silently dropping is dangerous (forfeits stake). So the SDK forces you to decide:

```typescript
// Strategy 1: auto-resume everything (good for headless agents)
on_pending_bond: ( bond ) => bond.resume( )

// Strategy 2: collect bonds for later UI action
on_pending_bond: ( bond ) => pending_bond_store.add( bond )

// Strategy 3: prompt the user (good for wallets / dApps)
on_pending_bond: async ( bond ) => {
    if(  await my_ui.confirm( `Resume bond ${ bond.commitment_hash }?` )  )  await bond.resume( );
}
```

## What `dispatch( )` does internally

1. Computes the commitment hash (or uses the hash computed by `prepare( )`)
2. Refreshes chain state, so a recovered bond resumes from the current on-chain truth
3. Checks balances for stake + fundings before creating the bond
4. Submits missing ERC20 approvals for the create phase
5. **Persists the bond to storage** (default: `localStorage`) *before* submitting the create tx — so a crash between create and execute is recoverable on next init
6. Submits `create_bond` **with gas-multiplier 1.5×** so it lands quickly
7. Waits for the create tx to mine; records `creation_block`, `creation_timestamp`, and queries constraints
8. Waits for both timing floors:
   - blocks: `max( min_execution_delay_in_blocks, 1 )` (BondRoute's 1-block core floor)
   - seconds: `max( min_execution_delay_in_seconds, 1 ) + 1` (BondRouteProtected's 1-second floor + 1 timestamp tick)
9. Submits missing ERC20 approvals for the execute phase
10. Submits `execute_bond` **with gas-multiplier 1.5×**
11. Forgets the bond from storage after settlement has enough confirmations

Configure defaults with `BondRoute.init({ gas: { default_multiplier, default_bump_multiplier } })`. Pass `opts.gas_multiplier` to override an individual call (`create`, `execute`, `execute_as`, `bump_create`, `bump_execute`).

By default, approvals are automatic. Pass `bond.dispatch({ auto_approve: false })` or `bond.resume({ auto_approve: false })` to throw `NeedsApprovalError` instead, then surface the approval list in your own UI.

## Approvals, balances, and native values

The SDK exposes preflight helpers so downstream protocol SDKs do not need to duplicate BondRoute token semantics:

```typescript
const approvals  =  await bond.get_missing_approvals( );
await bond.approve_if_needed( );

const shortfalls =  await bond.get_missing_balances( );
await bond.check_balances( );    // throws InsufficientBalanceError if any token is short

const create_value  =  bond.get_native_value_for_create( );
const execute_value =  bond.get_native_value_for_execute( );
```

> [!WARNING]
> Balance preflight runs at `bond.create( )` (and from inside `bond.resume( )`), checking **all** required balances upfront — stake AND fundings — before the create tx is submitted. This prevents the worst-case scenario: stake locked by a create tx, then user lacks funding balance at execute time, then bond expires and stake is forfeited.
>
> **Caveat:** balances can change after create (user spends elsewhere). Preflight is a best-effort safety net against the common case ("I don't have these tokens"); it cannot guarantee execution success.

## Bumping a stuck tx

If either the create or execute tx remains pending, call `bond.resume( )` again to bump from saved state, or bump directly:

```typescript
await bond.bump_create( );    // default 2.0× multiplier
await bond.bump_execute( );   // default 2.0× multiplier

// Or specify a higher multiplier explicitly
await bond.bump_execute({ gas_multiplier: 3.0 });
```

The bump methods first check whether the original tx has already mined. If so, they finalize local state without resubmitting. Otherwise, they resend at the same nonce with bumped fees, which replaces the pending tx in the mempool.

## Recovery model

The SDK protects against mid-flow failures (network drops, crashes, browser closes):

- **Before** every `create_bond` tx, the bond is persisted to storage.
- After submit, the tx hash + nonce are persisted so a stuck tx can be bumped.
- On every `BondRoute.init`, the SDK scans storage, refreshes each unfinished bond against chain state, and routes it through your `on_pending_bond` handler.
- Call `bond.resume( )` to intelligently pick up where the bond left off. It refreshes, runs phase-specific approvals, then drives create/wait/execute. Settled bonds are forgotten from storage once `bond.confirmations >= min_confirmations_to_forget` (default 60).

If storage itself is lost (user wiped browser data, switched devices), use a small salt (32-bit) and the brute-force fallback documented in the main README.

## Storage adapters

Default: `localStorage` in browsers.

Custom adapter:
```typescript
const my_storage = {
    get:    ( k ) => /* read from your store */,
    set:    ( k, v ) => /* write to your store */,
    remove: ( k ) => /* delete from your store */,
    keys:   () => /* list all keys */,
};
const bondRoute = await BondRoute.init({ ..., storage: my_storage });
```

Opt-out (NOT recommended outside tests):
```typescript
const bondRoute = await BondRoute.init({ ..., storage: "memory" });
```

## Serializing bonds for transport

If you want to inspect, save, or hand a bond off between processes/devices:

```typescript
import { type Bond } from "@bondroute/sdk";

const json: string  =  bond.serialize( );
const wired: Bond   =  bondRoute.deserialize_bond( json );  // attached, ready to resume
```

The output is plain JSON. Bigints are hex-encoded as `0x...` strings (no custom envelopes), so it's safe to parse with vanilla `JSON.parse` and inspect by hand.

## Escape hatch: manual control

If you need to interleave logic between create / wait / execute (e.g., relayer flows, monitoring):

```typescript
const bond  =  bondRoute.bond( execution_data );    // construct (no tx)
await bond.create( );                                 // submit create, wait for mining, persist
await bond.wait_until_executable( );                  // blocks until floors satisfied
const result  =  await bond.execute( );               // submit execute, settle, auto-forget after confirmation threshold
```

## Relayer execution

`execute_bond_as` support is included for relayer flows. The user signs the execution data, then the relayer submits the execute transaction from the same serialized bond data:

```typescript
const signature        =  await bond.sign_execution( );
const serialized_bond  =  bond.serialize( );

// relayerBondRoute is initialized with the relayer wallet/account.
const relayer_bond  =  relayerBondRoute.deserialize_bond( serialized_bond );
await relayer_bond.create( );
await relayer_bond.wait_until_executable( );
const result  =  await relayer_bond.execute_as( signature );
```

The relayer creates the bond and pays execution gas. If the stake is native, `create( )` sends the required `msg.value`; if the stake is ERC20, the relayer must approve BondRoute for the stake token. User fundings are still pulled from the signed user during `execute_as( )`, so user ERC20 funding approvals must exist before execution.

`bond.sign_execution( )` prefers typed-data signing using BondRoute's `__OFF_CHAIN__get_signing_info( ... )`. For custom protocol types that mirror calldata args, the SDK parses the type string and decodes calldata into the typed-data message. `bond.get_signing_info( )` and `bond.build_execution_typed_data( )` are available for advanced wallet UX.

## API surface

### `BondRoute`
| Member | Purpose |
|---|---|
| `BondRoute.init( opts )` | Async factory. Scans storage, routes pending bonds through `on_pending_bond`. |
| `bondRoute.prepare({ protocol, call, preferred_fundings, ... })` | Quote-first happy path. Builds `ExecutionData`, constraints, and a prepared `Bond`. |
| `bondRoute.bond( execution_data, constraints? )` | Construct a `Bond` synchronously (no tx). |
| `bondRoute.dispatch( execution_data, constraints? )` | Shortcut: `bondRoute.bond( ... ).dispatch( )`. |
| `bondRoute.calc_commitment_hash({ execution_data, user? })` | Hash using this SDK instance's chain id and BondRoute address. |
| `bondRoute.serialize_bond( bond )` | JSON form of a `Bond`. Usually prefer `bond.serialize( )`. |
| `bondRoute.deserialize_bond( json )` | Parse a serialized bond into an SDK-attached `Bond` instance. |
| `bondRoute.list_pending( )` | All in-progress bonds in storage for the current account, as `Bond` instances. |
| `bondRoute.quote_call( protocol, call, preferred_stake, preferred_fundings )` | Query a protocol's `BondConstraints`. |
| `bondRoute.watch_bond( bond, on_update )` | Poll a `BondSnapshot` until stopped or settled. |
| `bondRoute.watch_pending( on_update )` | Poll pending storage records for the current chain/BondRoute/account. |

### `Bond` (instance methods)
| Method | Purpose |
|---|---|
| `bond.dispatch( )` | Resume-aware full flow (create or bump → wait → execute or bump). |
| `bond.resume( opts? )` | Refresh, check balances, approve, drive to completion. Forgets settled bonds once `bond.confirmations >= min_confirmations_to_forget`. Pass `{ auto_approve: false }` to throw `NeedsApprovalError` instead of auto-submitting approvals. |
| `bond.forget( )` | Ungated removal of the bond from pending storage. Bypasses `min_confirmations_to_forget`. |
| `bond.create( opts? )` | Submit create tx, wait for mining, persist. |
| `bond.bump_create( opts? )` | Replace a stuck create tx with higher gas. |
| `bond.wait_until_executable( )` | Block until block + seconds floors satisfied. |
| `bond.execute( opts? )` | Submit execute, settle, and auto-forget after the confirmation threshold. |
| `bond.bump_execute( opts? )` | Replace a stuck execute tx with higher gas. |
| `bond.get_missing_approvals( )` | Return missing ERC20 approvals for create/execute. |
| `bond.approve_if_needed( )` | Submit required ERC20 approvals manually. Normal `dispatch( )`/`resume( )` already does this. |
| `bond.get_missing_balances( )` | Return per-token balance shortfalls across stake+fundings (native via `getBalance`). |
| `bond.check_balances( )` | Throw `InsufficientBalanceError({ shortfalls })` if any token is short. Runs automatically inside `bond.create( )`. |
| `bond.get_native_value_for_create( )` | Preview `msg.value` for `create_bond`. |
| `bond.get_native_value_for_execute( )` | Preview `msg.value` for `execute_bond` / `execute_bond_as`. |
| `bond.refresh( )` | Refresh live bond fields from chain state. |
| `bond.get_status( )` | Return a `BondSnapshot` with inspectable state, on-chain status, timing, and expiry information. |
| `bond.sign_execution( )` | Sign typed data for `execute_bond_as` when possible; digest fallback for raw-signing wallets. |
| `bond.build_execution_typed_data( )` | Build typed-data input from BondRoute signing metadata. |
| `bond.execute_as( signature, opts? )` | Relayer-compatible execution. |
| `bond.serialize( )` | Portable JSON (hex-encoded bigints). |

### `BondRoute` (statics)
| Function | Purpose |
|---|---|
| `BondRoute.calc_commitment_hash({ user, chain_id, execution_data, bondroute_address? })` | Pure hash with explicit context. `bondroute_address` is only for tests/forks/custom deployments. |
| `BondRoute.hash_fundings( fundings )` | Pure: keccak256 of the packed fundings array. |
| `BondRoute.decode_protocol_revert( output, protocol_abi )` | Decode protocol revert bytes (from `DispatchResult.output` when `status === "protocol_reverted"`) against the protocol's ABI. Returns `{ name, args } \| null`. |

## Errors

BondRoute throws typed `BondrouteSdkError` subclasses for SDK-level concerns: `NeedsApprovalError`, `InsufficientBalanceError`, `BondExpiredError`, `BondrouteContractError`, `BondrouteSdkSchemaMismatch`, `RpcError`, etc. Match these with `instanceof` rather than parsing messages.

Wallet write/sign errors usually come through from viem. Catch viem's `UserRejectedRequestError`, `ContractFunctionRevertedError`, `BaseError`, etc. where you need wallet-specific handling.

## Testing

```bash
bun install
bun test
```

The test suite covers commitment hashing, protocol revert decoding, serialization, quote-first preparation, storage filtering, recovery refresh, typed errors, approval/balance preflight, resume behavior, and EIP-712 typed-data construction.

## What's NOT included

- Timer-based auto-retry while a tx wait is still pending. Call `bond.resume( )` later, or use `bump_*` directly.
- ABI metadata fetching for protocol discovery

## License

MIT. See [LICENSE](../LICENSE) in the parent repo.
