# BondRoute Mechanism Deep Dive

This document explains how BondRoute actually works — the game theory, the trap mechanism, and why speculation is unprofitable.

Read this if you want to understand the mechanism beyond the README overview.

---

## Core Mental Model

BondRoute's defense rests on two pillars:

1. **Reserved execution** — Protected functions reject unbonded calls, and bonds can only be executed after a protocol-specified block delay. When attackers see your `execute_bond` in the mempool, they can't just call the contract directly — they'd need their own bond, and executing it requires waiting blocks. By the time they could act, your transaction already went through.

2. **Binding economics** — Reserved execution alone doesn't stop preemptive speculation. In traditional commit-reveal schemes, attackers can pre-create commitments covering likely parameters — swap amounts cluster around round numbers, auction bids follow common increments, popular names are obvious targets. A multicall contract can create hundreds of commitments in a single transaction for pennies on Ethereum, and orders of magnitude less on L2s. Without stakes, the 99.9% that don't match expire for free. BondRoute lets protocols require stakes that make this kind of attack unprofitable.

Reserved execution prevents frontrunning. Binding economics prevents preemptive bond farming. Most protocols need both.

---

## Case Study: Commit-Reveal Without Stakes

ENS (Ethereum Name Service) is the most widely deployed commit-reveal system on Ethereum. Examining its mechanism reveals exactly what happens when commit-reveal lacks binding economics.

### How ENS commit-reveal works

ENS uses a two-step registration process ([ETHRegistrarController.sol](https://github.com/ensdomains/ens-contracts/blob/master/contracts/ethregistrar/ETHRegistrarController.sol)):

1. **Commit** — `commit(hash)` stores `keccak256(abi.encode(Registration))` where `Registration` includes the name, owner, secret (salt), duration, and other fields
2. **Wait** — minimum 60 seconds (`minCommitmentAge`)
3. **Register** — `register(Registration)` reveals all fields in plaintext, validates the commitment, and registers the name
4. **Expiry** — commitments expire after 24 hours (`maxCommitmentAge`)

The commitment hash includes the `owner` address. This means an attacker and a victim can independently hold valid commitments for the same name — different owners produce different hashes. Both coexist in the `commitments` mapping without interfering.

### The attack: preemptive name sniping

**Step 1: Build a candidate list.** Curate high-value unregistered names: "pay", "bank", "swap", "lend", common 3-letter words, trending terms.

**Step 2: Maintain standing commitments.** Commit to the entire list. At 0.04 gwei (achievable during low-activity periods on Ethereum mainnet), each commitment costs about $0.004 in gas. Via multicall, 2,000 names cost about $8. Refresh every 24 hours.

**Step 3: Monitor and snipe.** When a victim calls `register(Registration{label: "bank", owner: VICTIM, ...})`, the name appears in plaintext in the calldata. The attacker already has a valid commitment for "bank" (with `owner: ATTACKER`). Submit `register()` with higher gas. Attacker's transaction executes first, victim's reverts with `NameNotAvailable`.

**Step 4: Profit.** The attacker owns the name. Unused commitments expire silently — zero penalty.

**Cost:** about $8/day for 2,000 names, about $2,920/year. **One sniped high-value name pays for years of operation** — "agent.eth" sold for 42 ETH (about $148,000) in 2024. Three-digit ENS names have traded at floor prices of 15-28 ETH.

### Expiring names: an even larger attack surface

For *new* names, the attacker must guess which names someone might want. For *expiring* names, the target list is public:

- `nameExpires(id)` is on-chain — anyone can query exact expiry dates for every name
- A 90-day grace period follows expiry, after which the name becomes available
- High-value expiring names are trivially enumerable — just query the contract

ENS uses an exponential premium decay (Dutch auction) after the grace period ends — the price starts high and halves each day. This is meant to prevent racing. But the premium is a function of time, identical for everyone at any given block. The attacker pre-commits to the target names and waits for a victim to reveal their registration at whatever premium level they're willing to pay. The attacker frontruns at the same price point. The premium doesn't differentiate between attacker and victim.

### The 3-character bruteforce

ENS requires a minimum of 3 characters. Three-character names cost $640/year to register.

There are 46,656 possible 3-character combinations (`[a-z0-9]^3`). Most are registered or worthless. Filter to unregistered, high-value targets — maybe 500-2,000 names worth maintaining commitments for.

At $8/day for 2,000 commitments, the attacker covers the entire interesting 3-character space. One sniped 3-letter word like "pay.eth" or "buy.eth" eclipses the annual cost by orders of magnitude.

### What this demonstrates

ENS's commit-reveal successfully prevents *reactive* frontrunning — you can't see a commit and guess what's inside. But it's wide open to *preemptive* speculation because:

1. **Zero penalty for unused commitments** — they expire silently
2. **Low cost** — $0.004 per commitment at off-peak gas
3. **Predictable targets** — high-value names are obvious, expiring names are public
4. **No trap** — the attacker never faces a "execute at bad terms or forfeit" dilemma

### The deeper problem: borrowed security

ENS has no on-chain mechanism to control the cost of commitments. Its security against preemptive speculation is implicitly borrowed from SSTORE gas pricing — an external factor the contract doesn't control, didn't choose, and can't adapt to.

This is fragile by design. A contract's security properties should be enforced by the contract itself, not by hoping that infrastructure costs remain high enough to deter abuse. This is already playing out: Ethereum's gas limit doubled from 30M to 60M in 2025, and ENS registration gas costs dropped 99% as a result — with further increases on the roadmap. The contract has no lever to pull.

BondRoute internalizes the cost. Stakes are an explicit, protocol-defined, on-chain enforced constraint — not a side effect of infrastructure pricing. Gas could go to zero and the trap mechanism still works, because the cost of abandonment is the stake, not the gas to create the commitment.

Most deployed commit-reveal schemes also leak structurally relevant information: the contract being interacted with, the sender, and sometimes partial calldata. In ENS, every commitment targets the registrar directly — attackers know you're registering a name before you reveal which one.

BondRoute addresses this. All bonds flow through a singleton contract. At commit time, attackers observe only the commitment hash, the stake token, and the stake amount. The protocol, function, parameters, fundings, and even the bond owner are hidden inside the hash. Any address can create bonds on behalf of others, so even the transaction sender reveals nothing. Combined with binding economics, this closes both the information leakage and the zero-penalty gaps that make traditional commit-reveal exploitable.

---

## The Trap Mechanism

This is the key insight that makes BondRoute work.

### What Most People Think

> "If you don't execute, you lose stake."

### What Actually Happens

> "If your bond's parameters 'succeed' but the outcome is unfavorable, you're trapped — execute a bad trade OR forfeit stake."

Bonds that FAIL validation (e.g. slippage exceeded, bid too low) typically return stake gracefully — this is protocol-defined behavior.

Bonds that "SUCCEED" at bad terms are the trap.

Note: Some failures trigger `PossiblyBondFarming` (stake remains locked, retry allowed while within valid execution window) — e.g., missing approvals, transfer failures, insufficient gas. This prevents attackers from intentionally failing execution in order to recover stake.

---

## Example 1: Swaps

### Setup

- User wants to swap 1,000 USDC → ETH
- Creates bond with: `amountIn: 1000 USDC`, `amountOutMin: 0.50 ETH` (implies ~$2000/ETH)
- Stake: 1% = 10 USDC

### Honest User Flow

1. Create bond at current market price with reasonable slippage (2-5%)
2. Wait 1 block
3. Execute — get ETH, stake returned
4. If market moved beyond slippage → graceful failure, stake returned

### Attacker Tries to Speculate

Bot creates 10 bonds covering different price scenarios:

| Bond | amountOutMin | Strategy |
|------|--------------|----------|
| 1 | 0.50 ETH | Tight (~$2000) |
| 2 | 0.48 ETH | |
| 3 | 0.46 ETH | |
| ... | ... | |
| 10 | 0.30 ETH | Very loose (~$3333) |

**Price moves UP ($2000 → $2100):**

For 1,000 USDC, bot now gets ~0.476 ETH.

| Bond | amountOutMin | Result |
|------|--------------|--------|
| 1 | 0.50 ETH | FAILS — 0.476 < 0.50, slippage exceeded, **stake returned** |
| 2 | 0.48 ETH | FAILS — 0.476 < 0.48, slippage exceeded, **stake returned** |
| 3 | 0.46 ETH | SUCCEEDS — 0.476 ≥ 0.46 ✓ |
| 4-10 | lower | SUCCEEDS — all pass ✓ |

### The Trap

Bonds 3-10 all "succeed" — they pass the slippage check. But the bot wanted price to go DOWN (more ETH). Price went UP (less ETH).

Now the bot must choose for each of bonds 3-10:

| Choice | Outcome |
|--------|---------|
| **Execute** | Get stake back, BUT execute swap at unfavorable price |
| **Don't execute** | Forfeit stake |

**Either way, the bot loses.** The bonds that "succeed" are the trap, not the ones that fail.

### Why Slippage Becomes a Double-Edged Sword

**For honest users:** Slippage protects from bad fills. Set reasonable tolerance, execute, done.

**For speculators:**

| Slippage | What happens |
|----------|--------------|
| Tight | Fails on small moves, stake returned (free exit, but no upside) |
| Loose | "Succeeds" even on bad moves, trapped into executing or forfeiting |

Attackers can't have free optionality. Tight slippage = free exit but no profit opportunity. Loose slippage = trapped.

---

## Example 2: Blind Auctions

### Setup

- Auction for an item
- Attacker creates bonds for bids: $100, $200, $300... $900
- Each bond requires stake (10% of bid)
- Winning price turns out to be $500

### What Happens to Each Bid

| Bid | vs Winning ($500) | Result |
|-----|-------------------|--------|
| $100-$400 | Below | Execute → Lose auction → **stake returned** |
| $500 | Equal | Execute → WIN at fair price → **stake returned** |
| $600-$900 | Above | **TRAPPED** |

### The Trap (Overbids $600-$900)

These "overbids" are above the winning price. If executed, you WIN the auction but PAY your bid amount — overpaying for something that sold at $500.

| Choice | Outcome |
|--------|---------|
| **Execute overbid** | Win but overpay (bad outcome), stake returned |
| **Don't execute** | Forfeit stake |

**Either way, the bot loses on overbids.**

The bids below winning price gracefully "lose" and recover stake. The overbids are the trap.

---

## The Universal Pattern

In ANY protocol using BondRoute:

| Category | What happens |
|----------|--------------|
| **Below threshold** | Slippage exceeded, bid too low, etc. → Graceful failure, stake returned |
| **Above threshold** | Within slippage, bid wins, etc. → Must execute or forfeit |

The trap is always in category 2: bonds that "succeed" at unfavorable terms.

**For honest users:** Set reasonable params, execute intended action, done.

**For speculators:** Can't cover all scenarios without getting trapped on the "successful" but unfavorable bonds.

---

## Why This Works

### The Economics of Speculation

To speculate profitably, an attacker needs:

1. **Multiple positions** covering different outcomes
2. **Ability to abandon** unprofitable positions cheaply
3. **Ability to execute** only the profitable ones

BondRoute breaks requirement #2. You can't abandon bonds that "succeed" for free.

### The Math

If an attacker creates N bonds covering a range of outcomes:

- Some bonds will fail validation → stake returned (no cost, no gain)
- Some bonds will "succeed" at unfavorable terms → **trapped**
- Some bonds may succeed at favorable terms → profit

For speculation to pay, the profits from winning bonds must exceed the losses from all the trapped bonds. As stake requirements increase relative to potential profit, speculation becomes unprofitable.

### When Stakes Matter Most

The need for stakes depends on how feasible preemptive speculation is:

| Factor | Low Risk | High Risk |
|--------|----------|-----------|
| **Parameter predictability** | Unpredictable (random unique IDs, nonces) | Predictable (swap amounts, bid increments, popular names) |
| **Commitment cost** | Expensive (Ethereum mainnet during congestion) | Cheap (L2s, multicall batching, off-peak gas) — and trending cheaper as the ecosystem optimizes for scale |
| **Potential reward** | Low value transactions | High value transactions |

**Unpredictable parameters:** If parameters are hard to guess, attackers can't build a useful candidate list. Reserved execution alone may suffice.

**Predictable parameters + cheap commitments:** If parameters can be anticipated through heuristics, on-chain analysis, or common sense — and commitment creation is cheap — attackers can pre-create commitments covering the likely range, let 99.9% expire for free, and exploit the 0.1% that match real activity. The ENS case study above demonstrates this concretely: $8/day to maintain 2,000 standing commitments with zero penalty for unused ones. Stakes make this math negative: every expired bond forfeits stake, and the cumulative loss across abandoned bonds exceeds the profit from the few that hit.

Only the protocol knows its economics. BondRoute provides the primitive — protocols define the constraints.

### Protocol Design Considerations

Constraints should ideally be **static** — returning the same values at bond creation and bond execution. This ensures the trap works reliably.

Dynamic constraints (values that change over time) may be acceptable for some use cases, but caution is advised. If constraints INCREASE between bond creation and bond execution, some bonds may escape via validation failure instead of being trapped. Size stake and timing windows accordingly — occasional escapes don't break the economics when trapped losses dominate.

---

## Key Terminology

| Term | Meaning |
|------|---------|
| **Bond farming** | Creating multiple bonds to speculate on different outcomes, executing only profitable ones. Unprofitable because trapped bonds force losses. |
| **Reserved execution** | Protected functions reject unbonded calls and enforce a protocol-specified block delay before execution. |
| **Binding economics** | Fixed params + protocol-defined stakes = no free optionality. |
| **The trap** | Bonds that "succeed" at unfavorable terms force you to execute a bad outcome or forfeit stake. |
