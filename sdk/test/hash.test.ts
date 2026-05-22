// SPDX-License-Identifier: MIT
//
// Regression tests for the SDK's commitment-hash implementation.
//
// The expected values below were computed by the on-chain `HashLib.calc_commitment_hash`
// with matching inputs. BondRoute is immutable infrastructure — these vectors are pinned
// forever; no regeneration story needed.

import { describe, test, expect } from "bun:test";
import { encodeAbiParameters, encodeErrorResult, hashTypedData, keccak256, parseAbi, toHex } from "viem";
import {
    BONDROUTE_ADDRESS,
    NATIVE_TOKEN,
    BondRoute,
    BondExpiredError,
    BondrouteContractError,
    BondrouteSdkSchemaMismatch,
    InsufficientBalanceError,
    NeedsApprovalError,
    RpcError,
    type ExecutionData,
} from "../BondRoute";

const calc_commitment_hash  =  BondRoute.calc_commitment_hash;
const hash_fundings         =  BondRoute.hash_fundings;
const serialize_bond        =  ( bond: TestBondRecord ) => JSON.stringify( bond, ( _key, value ) => typeof value === "bigint" ? toHex( value ) : value );

type TestBondRecord = any;

const USER      =  "0x1111111111111111111111111111111111111111" as const;
const PROTOCOL  =  "0x4444444444444444444444444444444444444444" as const;
const TOKEN_A   =  "0x2222222222222222222222222222222222222222" as const;
const TOKEN_B   =  "0x3333333333333333333333333333333333333333" as const;
const TX_HASH   =  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as const;
const TEST_ERROR_ABI = parseAbi([
    "error BondNotFound(bytes32 commitment_hash, address stake_token, uint256 stake_amount)",
    "error BondAlreadySettled(uint8 status)",
]);


describe( "hash_fundings", () => {

    test( "empty array hashes to bytes32(0)", () => {
        expect( hash_fundings( [] ) ).toBe( "0x0000000000000000000000000000000000000000000000000000000000000000" );
    });

    test( "single funding hashes deterministically", () => {
        const h1  =  hash_fundings([ { token: TOKEN_A, amount: 1000n } ]);
        const h2  =  hash_fundings([ { token: TOKEN_A, amount: 1000n } ]);
        expect( h1 ).toBe( h2 );
        expect( h1 ).not.toBe( "0x0000000000000000000000000000000000000000000000000000000000000000" );
    });

    test( "different order produces different hash", () => {
        const h1  =  hash_fundings([
            { token: TOKEN_A, amount: 1000n },
            { token: TOKEN_B, amount: 100n },
        ]);
        const h2  =  hash_fundings([
            { token: TOKEN_B, amount: 100n },
            { token: TOKEN_A, amount: 1000n },
        ]);
        expect( h1 ).not.toBe( h2 );
    });
});


describe( "calc_commitment_hash", () => {

    test( "empty fundings + ERC20 stake matches on-chain", () => {
        const ed: ExecutionData  =  {
            fundings: [],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        };
        const hash  =  calc_commitment_hash({ user: USER, chain_id: 1n, bondroute_address: BONDROUTE_ADDRESS, execution_data: ed });
        expect( hash ).toBe( "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce" );
    });

    test( "single funding + ERC20 stake matches on-chain", () => {
        const ed: ExecutionData  =  {
            fundings: [{ token: TOKEN_A, amount: 1000n }],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        };
        const hash  =  calc_commitment_hash({ user: USER, chain_id: 1n, bondroute_address: BONDROUTE_ADDRESS, execution_data: ed });
        expect( hash ).toBe( "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84" );
    });

    test( "native stake + native funding matches on-chain", () => {
        const ed: ExecutionData  =  {
            fundings: [{ token: NATIVE_TOKEN, amount: 5_000_000_000_000_000_000n }],
            stake:    { token: NATIVE_TOKEN, amount:   500_000_000_000_000_000n },
            salt:     12345n,
            protocol: PROTOCOL,
            call:     "0xa9059cbb000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0000000000000000000000000000000000000000000000000de0b6b3a7640000",
        };
        const hash  =  calc_commitment_hash({ user: USER, chain_id: 1n, bondroute_address: BONDROUTE_ADDRESS, execution_data: ed });
        expect( hash ).toBe( "0xcaffe0000000000000e6fc71435c6c1559b50a92f57da75964183394504f094f" );
    });

    test( "chain_id is mixed into the hash (mainnet vs Base produce different outputs)", () => {
        const ed: ExecutionData  =  {
            fundings: [],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        };
        const hash  =  calc_commitment_hash({ user: USER, chain_id: 8453n, bondroute_address: BONDROUTE_ADDRESS, execution_data: ed });
        expect( hash ).toBe( "0xcaffe0000000000000b97f3737ca54ae9873f74f20b64bbb5e8e1bc3a5a9dfec" );
    });

    test( "always emits the structured 0xcaffe0 prefix + 6 zero bytes", () => {
        const ed: ExecutionData  =  {
            fundings: [],
            stake:    { token: TOKEN_B, amount: 1n },
            salt:     0n,
            protocol: PROTOCOL,
            call:     "0x",
        };
        const hash  =  calc_commitment_hash({ user: USER, chain_id: 1n, bondroute_address: BONDROUTE_ADDRESS, execution_data: ed });
        expect( hash.slice( 0, 8 ) ).toBe( "0xcaffe0" );
        expect( hash.slice( 8, 20 ) ).toBe( "000000000000" );
    });

    test( "instance helper uses the SDK chain and BondRoute address", async () => {
        const sdk = await make_sdk_for_records();
        const ed: ExecutionData  =  {
            fundings: [],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        };

        expect( sdk.calc_commitment_hash({ execution_data: ed }) ).toBe(
            calc_commitment_hash({ user: USER, chain_id: 1n, bondroute_address: BONDROUTE_ADDRESS, execution_data: ed })
        );
    });
});


describe( "BondRoute.decode_protocol_revert", () => {

    test( "decodes a known error from the protocol ABI", () => {
        const data    =  encodeErrorResult({ abi: TEST_ERROR_ABI, errorName: "BondAlreadySettled", args: [ 2 ] });
        const decoded =  BondRoute.decode_protocol_revert( data, TEST_ERROR_ABI );
        expect( decoded?.name ).toBe( "BondAlreadySettled" );
        expect( decoded?.args[0] ).toBe( 2 );
    });

    test( "returns null for bytes that don't match any error in the ABI", () => {
        expect( BondRoute.decode_protocol_revert( "0xdeadbeef", TEST_ERROR_ABI ) ).toBeNull();
    });

    test( "returns null for empty revert data", () => {
        expect( BondRoute.decode_protocol_revert( "0x", TEST_ERROR_ABI ) ).toBeNull();
    });
});


describe( "serialize_bond / deserialize_bond", () => {

    test( "round-trips a minimal Bond", async () => {
        const bond: TestBondRecord  =  {
            schema_version:  1,
            chain_id:        1n,
            bondroute:       BONDROUTE_ADDRESS,
            user:            USER,
            execution_data:  {
                fundings: [{ token: TOKEN_A, amount: 1000n }],
                stake:    { token: TOKEN_B, amount: 100n },
                salt:     42n,
                protocol: PROTOCOL,
                call:     "0xdeadbeef",
            },
            commitment_hash: "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84",
            state:           "prepared",
        };

        const sdk    =  await make_sdk_for_records();
        const json   =  serialize_bond( bond );
        const back   =  sdk.deserialize_bond( json );
        expect( JSON.parse( back.serialize() ) ).toEqual( JSON.parse( json ) );
    });

    test( "round-trips a fully-populated Bond including constraints and tx tracking", async () => {
        const bond: TestBondRecord  =  {
            schema_version:      1,
            chain_id:            1n,
            bondroute:           BONDROUTE_ADDRESS,
            user:               USER,
            execution_data:     {
                fundings: [
                    { token: TOKEN_A, amount: 1000n },
                    { token: NATIVE_TOKEN, amount: 5_000_000_000_000_000_000n },
                ],
                stake:    { token: TOKEN_B, amount: 100n },
                salt:     12345n,
                protocol: PROTOCOL,
                call:     "0xa9059cbb",
            },
            commitment_hash:    "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84",
            state:              "created",
            create_tx_hash:     "0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            create_tx_nonce:    7,
            creation_block:     19_000_000n,
            creation_timestamp: 1_700_000_000n,
            constraints:        {
                min_stake:                       { token: TOKEN_B, amount: 100n },
                min_fundings:                    [{ token: TOKEN_A, amount: 1000n }],
                min_execution_delay_in_blocks:   3n,
                min_execution_delay_in_seconds:  2n,
                max_execution_delay_in_seconds:  7200n,
                valid_creation_timestamp_range:  { min: 0n, max: 0n },
                valid_execution_timestamp_range: { min: 0n, max: 0n },
            },
            execute_tx_hash:    "0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            execute_tx_nonce:   8,
        };

        const sdk   =  await make_sdk_for_records();
        const json  =  serialize_bond( bond );
        const back  =  sdk.deserialize_bond( json );
        expect( JSON.parse( back.serialize() ) ).toEqual( JSON.parse( json ) );
    });

    test( "produces plain JSON (no custom bigint envelopes)", () => {
        const bond: TestBondRecord  =  {
            schema_version:  1,
            chain_id:        1n,
            bondroute:       BONDROUTE_ADDRESS,
            user:            USER,
            execution_data:  {
                fundings: [],
                stake:    { token: TOKEN_B, amount: 100n },
                salt:     42n,
                protocol: PROTOCOL,
                call:     "0xdeadbeef",
            },
            commitment_hash: "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce" as const,
            state:           "prepared",
        };

        const json  =  serialize_bond( bond );
        // Should parse as plain JSON — no exotic wrappers.
        const parsed  =  JSON.parse( json );
        expect( parsed.execution_data.salt ).toBe( "0x2a" );          // 42 in hex
        expect( parsed.execution_data.stake.amount ).toBe( "0x64" );  // 100 in hex
        expect( parsed.user ).toBe( USER );
    });

    test( "rejects unknown schema versions", async () => {
        const json = JSON.stringify({
            schema_version: 999,
            chain_id: "0x1",
            bondroute: BONDROUTE_ADDRESS,
            user: USER,
            execution_data: { fundings: [], stake: { token: TOKEN_B, amount: "0x64" }, salt: "0x2a", protocol: PROTOCOL, call: "0xdeadbeef" },
            commitment_hash: "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce" as const,
            state: "prepared",
        });
        const sdk = await make_sdk_for_records();
        expect( () => sdk.deserialize_bond( json ) ).toThrow( BondrouteSdkSchemaMismatch );
    });
});


describe( "BondRoute.prepare / storage", () => {

    test( "prepare quotes constraints and builds a prepared bond", async () => {
        const constraints = {
            min_stake:                       { token: TOKEN_B, amount: 100n },
            min_fundings:                    [{ token: TOKEN_A, amount: 1000n }],
            min_execution_delay_in_blocks:   3n,
            min_execution_delay_in_seconds:  2n,
            max_execution_delay_in_seconds:  7200n,
            valid_creation_timestamp_range:  { min: 0n, max: 0n },
            valid_execution_timestamp_range: { min: 0n, max: 0n },
        };
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async () => [
                    constraints.min_stake,
                    constraints.min_fundings,
                    constraints.min_execution_delay_in_blocks,
                    constraints.min_execution_delay_in_seconds,
                    constraints.max_execution_delay_in_seconds,
                    constraints.valid_creation_timestamp_range,
                    constraints.valid_execution_timestamp_range,
                ],
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });

        const bond = await sdk.prepare({
            protocol: PROTOCOL,
            call: "0xdeadbeef",
            preferred_stake_token: TOKEN_B,
            preferred_fundings: [{ token: TOKEN_A, amount: 2000n }],
            salt: 42n,
        });

        expect( bond.state ).toBe( "prepared" );
        expect( bond.execution_data.stake ).toEqual( constraints.min_stake );
        expect( bond.execution_data.fundings ).toEqual( constraints.min_fundings );
        expect( bond.constraints ).toEqual( constraints );
        expect( bond.commitment_hash ).toBe( "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84" );
    });

    test( "list_pending filters by chain, BondRoute address, and account", async () => {
        const storage = make_storage();
        const bond: TestBondRecord = {
            schema_version:  1,
            chain_id:        1n,
            bondroute:       BONDROUTE_ADDRESS,
            user:            USER,
            execution_data:  { fundings: [], stake: { token: TOKEN_B, amount: 100n }, salt: 42n, protocol: PROTOCOL, call: "0xdeadbeef" },
            commitment_hash: "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce",
            state:           "prepared",
        };
        await storage.set( `bondroute:pending:1:${ BONDROUTE_ADDRESS.toLowerCase() }:${ USER }:${ bond.commitment_hash }`, serialize_bond( bond ) );
        await storage.set( `bondroute:pending:8453:${ BONDROUTE_ADDRESS.toLowerCase() }:${ USER }:${ bond.commitment_hash }`, serialize_bond({ ...bond, chain_id: 8453n }) );

        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, readContract: async () => { throw bond_not_found_error( bond.commitment_hash ); } } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage,
            on_pending_bond: () => {},
        });

        expect( ( await sdk.list_pending() ).length ).toBe( 1 );
    });

    test( "understands unversioned in-progress records using SDK context", async () => {
        const storage = make_storage();
        const old_record = {
            user: USER,
            execution_data: { fundings: [], stake: { token: TOKEN_B, amount: "0x64" }, salt: "0x2a", protocol: PROTOCOL, call: "0xdeadbeef" },
            commitment_hash: "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce",
            state: "pending_create",
            create_tx_hash: TX_HASH,
            create_tx_nonce: 3,
        } as const;
        await storage.set( `bondroute:pending:${ old_record.commitment_hash }`, JSON.stringify( old_record ) );

        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, getTransactionReceipt: async () => { throw new Error( "not found" ); }, readContract: async () => { throw bond_not_found_error( old_record.commitment_hash ); } } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage,
            on_pending_bond: () => {},
        });
        const [ bond ] = await sdk.list_pending();

        expect( bond?.chain_id ).toBe( 1n );
        expect( bond?.bondroute ).toBe( BONDROUTE_ADDRESS );
        expect( bond?.state ).toBe( "creating" );
        expect( bond?.create_tx_status ).toBe( "pending" );
    });

    test( "init refreshes pending bonds before callback", async () => {
        const storage = make_storage();
        const bond: TestBondRecord = {
            schema_version:  1,
            chain_id:        1n,
            bondroute:       BONDROUTE_ADDRESS,
            user:            USER,
            execution_data:  { fundings: [], stake: { token: TOKEN_B, amount: 100n }, salt: 42n, protocol: PROTOCOL, call: "0xdeadbeef" },
            commitment_hash: "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce",
            state:           "creating",
            create_tx_hash:  TX_HASH,
            constraints:     default_constraints(),
        };
        await storage.set( `bondroute:pending:1:${ BONDROUTE_ADDRESS.toLowerCase() }:${ USER }:${ bond.commitment_hash }`, serialize_bond( bond ) );

        let callback_bond: any;
        await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                getTransactionReceipt: async () => ({ status: "success", blockNumber: 10n }),
                getBlock: async () => ({ number: 12n, timestamp: 105n }),
                readContract: async () => ({ creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 0 }),
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage,
            on_pending_bond: ( bond ) => { callback_bond = bond; },
        });

        expect( callback_bond.state ).toBe( "created" );
        expect( callback_bond.chain_state ).toBe( "found" );
        expect( callback_bond.status ).toBe( "active" );
        expect( callback_bond.create_tx_status ).toBe( "mined" );
        expect( callback_bond.executable_now ).toBe( false );
    });

    test( "refresh distinguishes RPC failure from BondNotFound", async () => {
        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, readContract: async () => { throw new Error( "network down" ); } } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond({ fundings: [], stake: { token: TOKEN_B, amount: 100n }, salt: 42n, protocol: PROTOCOL, call: "0xdeadbeef" });

        await expect( bond.refresh() ).rejects.toBeInstanceOf( RpcError );
    });

    test( "refresh treats decoded BondNotFound as missing chain state", async () => {
        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, readContract: async () => { throw bond_not_found_error( "0xcaffe0000000000000f496f374cbbe0e801f3890cd61ea116c9f2c9ea806a8ce" ); } } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond({ fundings: [], stake: { token: TOKEN_B, amount: 100n }, salt: 42n, protocol: PROTOCOL, call: "0xdeadbeef" });

        await bond.refresh();

        expect( bond.chain_state ).toBe( "missing" );
    });

    test( "refresh surfaces decoded non-BondNotFound contract errors", async () => {
        const data = encodeErrorResult({ abi: TEST_ERROR_ABI, errorName: "BondAlreadySettled", args: [ 1 ] });
        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, readContract: async () => { throw { data }; } } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond({ fundings: [], stake: { token: TOKEN_B, amount: 100n }, salt: 42n, protocol: PROTOCOL, call: "0xdeadbeef" });

        try
        {
            await bond.refresh();
            throw new Error( "expected refresh to reject" );
        }
        catch( err )
        {
            expect( err ).toBeInstanceOf( BondrouteContractError );
            expect( (err as BondrouteContractError).solidity_error.name ).toBe( "BondAlreadySettled" );
            expect( (err as BondrouteContractError).solidity_error.args[0] ).toBe( 1 );
        }
    });

    test( "resume forgets settled bonds once confirmations meet the threshold", async () => {
        const storage = make_storage();
        const bond_data = stored_bond({ state: "created", constraints: default_constraints() });
        await storage.set( storage_key( bond_data ), serialize_bond( bond_data ) );

        let recovered: any;
        await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async () => ({ creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 1 }),
                getBlock: async () => ({ number: 12n, timestamp: 105n }),
                getBlockNumber: async () => 12n,
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage,
            min_confirmations_to_forget: 0,
            on_pending_bond: ( bond ) => { recovered = bond; },
        });

        const result = await recovered.resume();

        expect( result.status ).toBe( "executed" );
        expect( await storage.keys() ).toEqual( [] );
    });

    test( "resume keeps settled bonds in storage until confirmations meet the threshold", async () => {
        const storage = make_storage();
        const bond_data = stored_bond({ state: "created", constraints: default_constraints() });
        await storage.set( storage_key( bond_data ), serialize_bond( bond_data ) );

        let head = 12n;
        let recovered: any;
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async () => ({ creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 1 }),
                getBlock: async () => ({ number: head, timestamp: 105n }),
                getBlockNumber: async () => head,
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage,
            min_confirmations_to_forget: 3,
            on_pending_bond: ( bond ) => { recovered = bond; },
        });

        await recovered.resume();
        expect( recovered.confirmations ).toBe( 0 );
        expect( ( await storage.keys() ).length ).toBe( 1 );

        head = 15n;
        await recovered.resume();
        expect( recovered.confirmations ).toBe( 3 );
        expect( await storage.keys() ).toEqual( [] );

        void sdk;
    });

    test( "resume retries failed execute tx when on-chain bond is still active", async () => {
        const writes: string[] = [];
        const old_execute_hash = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as const;
        const new_execute_hash = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" as const;
        const bond_data = stored_bond({
            state: "executing",
            creation_block: 10n,
            creation_timestamp: 100n,
            constraints: default_constraints(),
            execute_tx_hash: old_execute_hash,
            execute_tx_nonce: 9,
        });
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                getTransactionReceipt: async ({ hash }: any) => {
                    if(  hash === old_execute_hash  )  return { status: "reverted", blockNumber: 12n };
                    return { status: "success", blockNumber: 13n };
                },
                readContract: async ({ functionName }: any) => {
                    if(  functionName === "allowance"  )  return 10_000n;
                    return { creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 0 };
                },
                getBlock: async () => ({ number: 13n, timestamp: 105n }),
                getBlockNumber: async () => 13n,
                getTransactionCount: async () => 10,
                estimateFeesPerGas: async () => ({ maxFeePerGas: 10n, maxPriorityFeePerGas: 1n }),
                waitForTransactionReceipt: async () => ({ status: "success", blockNumber: 13n }),
                simulateContract: async () => ({ result: [ 1, "0x" ] }),
            } as any,
            wallet_client: {
                chain: {},
                writeContract: async ({ functionName }: any) => {
                    writes.push( functionName );
                    return new_execute_hash;
                },
            } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.deserialize_bond( serialize_bond( bond_data ) );

        const result = await bond.resume();

        expect( result.status ).toBe( "executed" );
        expect( writes ).toEqual([ "execute_bond" ]);
        expect( bond.execute_tx_hash ).toBe( new_execute_hash );
    });

    test( "create throws InsufficientBalanceError when user lacks stake/funding balance", async () => {
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async ({ functionName }: any) => {
                    if(  functionName === "balanceOf"  )  return 0n;
                    throw bond_not_found_error( "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84" );
                },
                getBalance: async () => 0n,
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond({
            fundings: [{ token: TOKEN_A, amount: 1000n }],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        });

        await expect( bond.create() ).rejects.toBeInstanceOf( InsufficientBalanceError );
    });

    test( "get_missing_balances aggregates stake and funding into per-token shortfalls", async () => {
        const sdk = await BondRoute.init({
            public_client: {
                getChainId:   async () => 1,
                readContract: async ({ functionName, address }: any) => {
                    if(  functionName === "balanceOf"  )  return address === TOKEN_B ? 50n : 200n;
                    throw bond_not_found_error( "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84" );
                },
                getBalance:   async () => 0n,
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond({
            fundings: [{ token: TOKEN_A, amount: 1000n }],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        });

        const shortfalls = await bond.get_missing_balances();

        expect( shortfalls.length ).toBe( 2 );
        const by_token = Object.fromEntries( shortfalls.map( s => [ s.token, s ] ) );
        expect( by_token[ TOKEN_B ]?.required ).toBe( 100n );
        expect( by_token[ TOKEN_B ]?.current ).toBe( 50n );
        expect( by_token[ TOKEN_A ]?.required ).toBe( 1000n );
        expect( by_token[ TOKEN_A ]?.current ).toBe( 200n );
    });

    test( "resume({ auto_approve: false }) throws NeedsApprovalError instead of auto-approving", async () => {
        const bond_data = stored_bond({
            state: "created",
            creation_block: 10n,
            creation_timestamp: 100n,
            constraints: default_constraints(),
        });
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async ({ functionName }: any) => {
                    if(  functionName === "allowance"  )  return 0n;
                    return { creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 0 };
                },
                getBlock: async () => ({ number: 13n, timestamp: 105n }),
                getBlockNumber: async () => 13n,
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.deserialize_bond( serialize_bond( bond_data ) );

        await expect( bond.resume({ auto_approve: false }) ).rejects.toBeInstanceOf( NeedsApprovalError );
    });

    test( "resume approves missing execute funding allowance before execution", async () => {
        const writes: string[] = [];
        const bond_data = stored_bond({
            state: "created",
            creation_block: 10n,
            creation_timestamp: 100n,
            constraints: default_constraints(),
        });
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async ({ functionName }: any) => {
                    if(  functionName === "allowance"  )  return 0n;
                    return { creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 0 };
                },
                getBlock: async () => ({ number: 13n, timestamp: 105n }),
                getBlockNumber: async () => 13n,
                getTransactionCount: async () => 10,
                estimateFeesPerGas: async () => ({ maxFeePerGas: 10n, maxPriorityFeePerGas: 1n }),
                waitForTransactionReceipt: async () => ({ status: "success", blockNumber: 13n }),
                simulateContract: async () => ({ result: [ 1, "0x" ] }),
            } as any,
            wallet_client: {
                chain: {},
                writeContract: async ({ functionName }: any) => {
                    writes.push( functionName );
                    return functionName === "approve"
                        ? "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
                        : "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
                },
            } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.deserialize_bond( serialize_bond( bond_data ) );

        await bond.resume();

        expect( writes ).toEqual([ "approve", "execute_bond" ]);
    });

    test( "resume throws BondExpiredError for expired active bonds", async () => {
        const sdk = await BondRoute.init({
            public_client: {
                getChainId: async () => 1,
                readContract: async () => ({ creation_time: 100n, creation_block: 10n, stake_amount_received: 100n, status: 0 }),
                getBlock: async () => ({ number: 13n, timestamp: 100n + 111n * 24n * 60n * 60n + 1n }),
                getBlockNumber: async () => 13n,
            } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.deserialize_bond( serialize_bond( stored_bond({
            state: "created",
            creation_block: 10n,
            creation_timestamp: 100n,
            constraints: default_constraints(),
        }) ) );

        await expect( bond.resume() ).rejects.toBeInstanceOf( BondExpiredError );
    });

    test( "builds default EIP-712 typed data that matches BondRoute digest", async () => {
        const execution_data: ExecutionData = {
            fundings: [{ token: TOKEN_A, amount: 1000n }],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        };
        const domain = {
            name: "BondRoute",
            version: "1",
            chainId: 1n,
            verifyingContract: BONDROUTE_ADDRESS,
        };
        const type_string = "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,bytes32 calldata_hash)TokenAmount(address token,uint256 amount)";
        const typed_data = {
            domain,
            primaryType: "ExecuteBondAs" as const,
            types: {
                ExecuteBondAs: [
                    { name: "fundings", type: "TokenAmount[]" },
                    { name: "stake", type: "TokenAmount" },
                    { name: "salt", type: "uint256" },
                    { name: "protocol", type: "address" },
                    { name: "calldata_hash", type: "bytes32" },
                ],
                TokenAmount: [
                    { name: "token", type: "address" },
                    { name: "amount", type: "uint256" },
                ],
            },
            message: {
                fundings: execution_data.fundings,
                stake: execution_data.stake,
                salt: execution_data.salt,
                protocol: execution_data.protocol,
                calldata_hash: keccak256( execution_data.call ),
            },
        };
        const digest = hashTypedData( typed_data );
        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, readContract: async () => [ digest, "0x" + "00".repeat(32), type_string, domain ] } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond( execution_data );
        const built = await bond.build_execution_typed_data();

        expect( hashTypedData( built as any ) ).toBe( digest );
        expect( built.message.calldata_hash ).toBe( keccak256( execution_data.call ) );
    });

    test( "builds custom EIP-712 typed data from mirrored calldata args", async () => {
        const encoded_args = encodeAbiParameters(
            [
                { name: "tokenIn", type: "address" },
                { name: "amountIn", type: "uint256" },
            ],
            [ TOKEN_A, 1000n ],
        );
        const execution_data: ExecutionData = {
            fundings: [{ token: TOKEN_A, amount: 1000n }],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     ( "0x12345678" + encoded_args.slice( 2 ) ) as `0x${ string }`,
        };
        const domain = {
            name: "BondRoute",
            version: "1",
            chainId: 1n,
            verifyingContract: BONDROUTE_ADDRESS,
        };
        const type_string = "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,SwapExactInput call)SwapExactInput(address tokenIn,uint256 amountIn)TokenAmount(address token,uint256 amount)";
        const typed_data = {
            domain,
            primaryType: "ExecuteBondAs" as const,
            types: {
                ExecuteBondAs: [
                    { name: "fundings", type: "TokenAmount[]" },
                    { name: "stake", type: "TokenAmount" },
                    { name: "salt", type: "uint256" },
                    { name: "protocol", type: "address" },
                    { name: "call", type: "SwapExactInput" },
                ],
                SwapExactInput: [
                    { name: "tokenIn", type: "address" },
                    { name: "amountIn", type: "uint256" },
                ],
                TokenAmount: [
                    { name: "token", type: "address" },
                    { name: "amount", type: "uint256" },
                ],
            },
            message: {
                fundings: execution_data.fundings,
                stake: execution_data.stake,
                salt: execution_data.salt,
                protocol: execution_data.protocol,
                call: { tokenIn: TOKEN_A, amountIn: 1000n },
            },
        };
        const digest = hashTypedData( typed_data );
        const sdk = await BondRoute.init({
            public_client: { getChainId: async () => 1, readContract: async () => [ digest, "0x" + "00".repeat(32), type_string, domain ] } as any,
            wallet_client: { chain: {} } as any,
            account: USER,
            storage: make_storage(),
            on_pending_bond: () => {},
        });
        const bond = sdk.bond( execution_data );
        const built = await bond.build_execution_typed_data();

        expect( hashTypedData( built as any ) ).toBe( digest );
        expect( built.message.call ).toEqual({ tokenIn: TOKEN_A, amountIn: 1000n });
    });
});

function make_storage()
{
    const map = new Map<string, string>();
    return {
        get:    async ( k: string ) => map.get( k ) ?? null,
        set:    async ( k: string, v: string ) => { map.set( k, v ); },
        remove: async ( k: string ) => { map.delete( k ); },
        keys:   async () => Array.from( map.keys() ),
    };
}

function default_constraints()
{
    return {
        min_stake:                       { token: TOKEN_B, amount: 100n },
        min_fundings:                    [],
        min_execution_delay_in_blocks:   3n,
        min_execution_delay_in_seconds:  2n,
        max_execution_delay_in_seconds:  7200n,
        valid_creation_timestamp_range:  { min: 0n, max: 0n },
        valid_execution_timestamp_range: { min: 0n, max: 0n },
    };
}

function stored_bond( overrides: Partial<TestBondRecord> = {} ): TestBondRecord
{
    return {
        schema_version:  1,
        chain_id:        1n,
        bondroute:       BONDROUTE_ADDRESS,
        user:            USER,
        execution_data:  {
            fundings: [{ token: TOKEN_A, amount: 1000n }],
            stake:    { token: TOKEN_B, amount: 100n },
            salt:     42n,
            protocol: PROTOCOL,
            call:     "0xdeadbeef",
        },
        commitment_hash: "0xcaffe0000000000000ac0c78d8221dcfdf931398a3a557f30a4a330370e53a84",
        state:           "created",
        ...overrides,
    };
}

function storage_key( bond: TestBondRecord ): string
{
    return `bondroute:pending:${ bond.chain_id.toString() }:${ bond.bondroute.toLowerCase() }:${ bond.user.toLowerCase() }:${ bond.commitment_hash }`;
}

async function make_sdk_for_records()
{
    return await BondRoute.init({
        public_client: { getChainId: async () => 1 } as any,
        wallet_client: { chain: {} } as any,
        account: USER,
        storage: make_storage(),
        on_pending_bond: () => {},
    });
}

function bond_not_found_error( commitment_hash: `0x${ string }` )
{
    return {
        data: encodeErrorResult({
            abi: TEST_ERROR_ABI,
            errorName: "BondNotFound",
            args: [ commitment_hash, TOKEN_B, 100n ],
        }),
    };
}
