

BondRoute Deployment
====================

Contract address (same on every chain):

    0xb01d00000000440215e86e0A436f9b59FeB2F14a


Deploy to a new chain
---------------------

Anyone can deploy BondRoute to any EVM chain that supports Cancun (EIP-1153
transient storage). No build toolchain required — just send the calldata.

    1. Send the contents of calldata.txt to the CREATE2 factory:

       0x4e59b44847b379578588920cA78FbF26c0B4956C

    2. The contract will deploy to the same address, guaranteed by CREATE2.

Example using cast:

    cast send 0x4e59b44847b379578588920cA78FbF26c0B4956C \
        --rpc-url <RPC_URL> \
        --private-key <KEY> \
        --gas-limit 4000000 \
        "$(cat calldata.txt)"

The calldata contains the salt, compiled initcode, and constructor arguments.
No additional parameters are needed.


CREATE2 parameters
------------------

    Factory:        0x4e59b44847b379578588920cA78FbF26c0B4956C
    Salt:           0x20d2af29271f39c9000000000000000000000000000000000000000000000000
    Init Code Hash: 0x9edd1f48d88865847863d2fe3c3ebe978856e2ab1fe5a5ad91233d002e549889


Constructor arguments
---------------------

BondRoute takes a single constructor argument:

    Collector: 0x8FEcd09e19889E52FEae817684C6e478767139a2

The collector is a minimal role. It cannot pause, upgrade,
modify parameters, or interfere with the system in any way. Its only
capability is claiming staked funds from bonds that have already expired.

Bonds expire 111 days after creation. After expiry, the bond is dead — it
can no longer be executed or settled — and the forfeited stake would be
permanently bricked without the collector reclaiming it.

The collector role is transferable via a two-step process (appoint + claim),
keeping the core primitive clean while allowing the collector to later be
set to another contract.
