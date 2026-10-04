// zkmandate: prove a payment fits a private spending mandate.
//
// The verifier learns: the mandate commitment, the current and next state
// commitments, the payment (amount, payee), a deadline and a binding context.
// The verifier does NOT learn: maxPerTx, totalCap, notAfter, the payee
// allowlist (its members or its size), the salt, or the opening of the state.
//
// State chaining: every mandate has a head commitment
//     state = H(TAG_STATE, mandateCommitment, spentSoFar, stateSalt)
// The proof opens the current head privately and outputs the next head with
// spentSoFar + amount. The next salt is derived in-circuit from the mandate
// secret, the old head and the context, so a payment can only ever produce one
// successor state, and the agent can always recompute its own state from chain
// data plus the mandate secret. The registry accepts a proof only against its
// stored head, so a replayed proof references a stale head and is rejected.

use poseidon::poseidon2::Poseidon2;

// Allowlist Merkle depth: up to 2^8 = 256 payees. The real list size is hidden.
pub global DEPTH: u32 = 8;

// Domain separation tags. Every hash in the protocol gets its own tag so a
// preimage for one role can never be reinterpreted as another.
pub global TAG_MANDATE: Field = 1;
pub global TAG_LEAF: Field = 2;
pub global TAG_NODE: Field = 3;
pub global TAG_STATE: Field = 4;
pub global TAG_SALT: Field = 5;
pub global TAG_SALT0: Field = 6;

pub fn mandate_commitment(
    max_per_tx: u64,
    total_cap: u64,
    not_after: u64,
    allowlist_root: Field,
    salt: Field,
) -> Field {
    Poseidon2::hash(
        [
            TAG_MANDATE,
            max_per_tx as Field,
            total_cap as Field,
            not_after as Field,
            allowlist_root,
            salt,
        ],
        6,
    )
}

pub fn leaf(payee: Field) -> Field {
    Poseidon2::hash([TAG_LEAF, payee], 2)
}

pub fn node(left: Field, right: Field) -> Field {
    Poseidon2::hash([TAG_NODE, left, right], 3)
}

pub fn state_commitment(mandate: Field, spent: u64, state_salt: Field) -> Field {
    Poseidon2::hash([TAG_STATE, mandate, spent as Field, state_salt], 4)
}

pub fn initial_state_salt(salt: Field) -> Field {
    Poseidon2::hash([TAG_SALT0, salt], 2)
}

pub fn next_state_salt(salt: Field, old_state: Field, context: Field) -> Field {
    Poseidon2::hash([TAG_SALT, salt, old_state, context], 4)
}

pub fn merkle_root(leaf_value: Field, index: u32, path: [Field; DEPTH]) -> Field {
    let mut cur = leaf_value;
    for i in 0..DEPTH {
        let bit = ((index >> i) & 1) as Field;
        let sib = path[i];
        // bit == 0: cur is the left child; bit == 1: cur is the right child.
        let left = cur + bit * (sib - cur);
        let right = sib + bit * (cur - sib);
        cur = node(left, right);
    }
    cur
}

fn main(
    // ---- public ----
    mandate: pub Field, // H(TAG_MANDATE, maxPerTx, totalCap, notAfter, root, salt)
    old_state: pub Field, // current head stored by the registry
    new_state: pub Field, // head after this payment
    amount: pub u64, // payment amount (token base units)
    payee: pub Field, // payee address as a field element
    valid_until: pub u64, // registry enforces block.timestamp <= valid_until
    context: pub Field, // keccak(chainid, registry, principal, mandate) >> 8: anti cross-domain replay
    // ---- private ----
    max_per_tx: u64,
    total_cap: u64,
    not_after: u64,
    allowlist_root: Field,
    salt: Field,
    spent: u64,
    state_salt: Field,
    payee_index: u32,
    payee_path: [Field; DEPTH],
) {
    // 1. The private terms open the public mandate commitment.
    assert(
        mandate_commitment(max_per_tx, total_cap, not_after, allowlist_root, salt) == mandate,
        "mandate opening",
    );

    // 2. The private spent-so-far opens the current head.
    assert(state_commitment(mandate, spent, state_salt) == old_state, "state opening");

    // 3. Per-transaction cap (and no zero-value state churn).
    assert(amount != 0, "zero amount");
    assert(amount <= max_per_tx, "over per-tx cap");

    // 4. Cumulative cap. Widen to u128 so the sum cannot wrap.
    let new_spent = (spent as u128) + (amount as u128);
    assert(new_spent <= (total_cap as u128), "over cumulative cap");

    // 5. Expiry. The payment can only land while block.timestamp <= valid_until
    //    <= notAfter, so expiry is enforced exactly, not within a skew window.
    assert(valid_until <= not_after, "expired");

    // 6. Payee is in the private allowlist.
    assert(payee_index < (1 << DEPTH), "index out of range");
    assert(
        merkle_root(leaf(payee), payee_index, payee_path) == allowlist_root,
        "payee not allowed",
    );

    // 7. Successor head: spent + amount under a salt derived from the old head.
    let next_salt = next_state_salt(salt, old_state, context);
    assert(state_commitment(mandate, new_spent as u64, next_salt) == new_state, "new state");
}

// ------------------------------------------------------------------ tests ---

struct Fixture {
    max_per_tx: u64,
    total_cap: u64,
    not_after: u64,
    root: Field,
    salt: Field,
    mandate: Field,
    payees: [Field; 3],
    paths: [[Field; DEPTH]; 3],
}

global CONTEXT: Field = 0xc0ffee;

// Allowlist of 3 payees at indexes 0, 1, 2; the remaining leaves are zero.
fn fixture() -> Fixture {
    let payees = [0xA11CE, 0xB0B, 0xCAFE];
    let mut zeros = [0; DEPTH];
    let mut z = 0;
    for i in 0..DEPTH {
        zeros[i] = z;
        z = node(z, z);
    }
    let l0 = leaf(payees[0]);
    let l1 = leaf(payees[1]);
    let l2 = leaf(payees[2]);
    let n01 = node(l0, l1);
    let n23 = node(l2, 0);
    let mut paths = [[0; DEPTH]; 3];
    paths[0][0] = l1;
    paths[0][1] = n23;
    paths[1][0] = l0;
    paths[1][1] = n23;
    paths[2][0] = 0;
    paths[2][1] = n01;
    for p in 0..3 {
        for i in 2..DEPTH {
            paths[p][i] = zeros[i];
        }
    }
    let root = merkle_root(l0, 0, paths[0]);
    let max_per_tx = 5_000_000; // 5 USDC
    let total_cap = 12_000_000; // 12 USDC
    let not_after = 2_000_000_000;
    let salt = 0x5a17;
    Fixture {
        max_per_tx,
        total_cap,
        not_after,
        root,
        salt,
        mandate: mandate_commitment(max_per_tx, total_cap, not_after, root, salt),
        payees,
        paths,
    }
}

// Run one payment from (spent, state_salt). Returns (new_state, new_spent, new_salt).
fn pay(
    f: Fixture,
    spent: u64,
    state_salt: Field,
    amount: u64,
    who: u32,
    valid_until: u64,
) -> (Field, u64, Field) {
    let old_state = state_commitment(f.mandate, spent, state_salt);
    let next_salt = next_state_salt(f.salt, old_state, CONTEXT);
    let new_state = state_commitment(f.mandate, spent + amount, next_salt);
    main(
        f.mandate,
        old_state,
        new_state,
        amount,
        f.payees[who],
        valid_until,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        spent,
        state_salt,
        who,
        f.paths[who],
    );
    (new_state, spent + amount, next_salt)
}

#[test]
fn test_merkle_paths_agree() {
    let f = fixture();
    for i in 0..3 {
        assert(merkle_root(leaf(f.payees[i]), i, f.paths[i]) == f.root);
    }
}

#[test]
fn test_valid_payment() {
    let f = fixture();
    let _ = pay(
        f,
        0,
        initial_state_salt(f.salt),
        4_000_000,
        0,
        1_900_000_000,
    );
}

#[test]
fn test_three_payments_then_cap_is_exact() {
    let f = fixture();
    let (_, s1, salt1) = pay(
        f,
        0,
        initial_state_salt(f.salt),
        4_000_000,
        0,
        1_900_000_000,
    );
    let (_, s2, salt2) = pay(f, s1, salt1, 4_000_000, 1, 1_900_000_000);
    // Exactly hits the 12 USDC cap.
    let (_, s3, _) = pay(f, s2, salt2, 4_000_000, 2, 1_900_000_000);
    assert(s3 == f.total_cap);
}

#[test]
fn test_payment_at_exact_per_tx_cap_and_expiry() {
    let f = fixture();
    let _ = pay(f, 0, initial_state_salt(f.salt), 5_000_000, 1, f.not_after);
}

#[test(should_fail_with = "over per-tx cap")]
fn test_over_per_tx() {
    let f = fixture();
    let _ = pay(
        f,
        0,
        initial_state_salt(f.salt),
        5_000_001,
        0,
        1_900_000_000,
    );
}

#[test(should_fail_with = "over cumulative cap")]
fn test_fourth_payment_over_cumulative() {
    let f = fixture();
    let (_, s1, salt1) = pay(
        f,
        0,
        initial_state_salt(f.salt),
        4_000_000,
        0,
        1_900_000_000,
    );
    let (_, s2, salt2) = pay(f, s1, salt1, 4_000_000, 1, 1_900_000_000);
    let (_, s3, salt3) = pay(f, s2, salt2, 3_000_000, 2, 1_900_000_000);
    let _ = pay(f, s3, salt3, 1_000_001, 0, 1_900_000_000);
}

#[test(should_fail_with = "expired")]
fn test_expired() {
    let f = fixture();
    let _ = pay(
        f,
        0,
        initial_state_salt(f.salt),
        1_000_000,
        0,
        f.not_after + 1,
    );
}

#[test(should_fail_with = "zero amount")]
fn test_zero_amount() {
    let f = fixture();
    let _ = pay(f, 0, initial_state_salt(f.salt), 0, 0, 1_900_000_000);
}

#[test(should_fail_with = "payee not allowed")]
fn test_wrong_payee() {
    let f = fixture();
    let old_state = state_commitment(f.mandate, 0, initial_state_salt(f.salt));
    let next_salt = next_state_salt(f.salt, old_state, CONTEXT);
    let new_state = state_commitment(f.mandate, 1_000_000, next_salt);
    // Mallory reuses Alice's Merkle path but claims her own address.
    main(
        f.mandate,
        old_state,
        new_state,
        1_000_000,
        0xBAD,
        1_900_000_000,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        initial_state_salt(f.salt),
        0,
        f.paths[0],
    );
}

#[test(should_fail_with = "state opening")]
fn test_cannot_lie_about_spent() {
    let f = fixture();
    // Real head says 8 USDC spent; agent claims 0 spent to reset the budget.
    let real_head = state_commitment(f.mandate, 8_000_000, 0x1234);
    let next_salt = next_state_salt(f.salt, real_head, CONTEXT);
    let new_state = state_commitment(f.mandate, 5_000_000, next_salt);
    main(
        f.mandate,
        real_head,
        new_state,
        5_000_000,
        f.payees[0],
        1_900_000_000,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        0x1234,
        0,
        f.paths[0],
    );
}

#[test(should_fail_with = "mandate opening")]
fn test_cannot_inflate_cap() {
    let f = fixture();
    let st = initial_state_salt(f.salt);
    let old_state = state_commitment(f.mandate, 0, st);
    let next_salt = next_state_salt(f.salt, old_state, CONTEXT);
    let new_state = state_commitment(f.mandate, 50_000_000, next_salt);
    main(
        f.mandate,
        old_state,
        new_state,
        50_000_000,
        f.payees[0],
        1_900_000_000,
        CONTEXT,
        100_000_000,
        100_000_000,
        f.not_after,
        f.root,
        f.salt,
        0,
        st,
        0,
        f.paths[0],
    );
}

#[test(should_fail_with = "new state")]
fn test_cannot_under_report_new_spent() {
    let f = fixture();
    let st = initial_state_salt(f.salt);
    let old_state = state_commitment(f.mandate, 0, st);
    let next_salt = next_state_salt(f.salt, old_state, CONTEXT);
    // Pays 4 USDC but tries to record only 1 USDC spent.
    let new_state = state_commitment(f.mandate, 1_000_000, next_salt);
    main(
        f.mandate,
        old_state,
        new_state,
        4_000_000,
        f.payees[0],
        1_900_000_000,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        st,
        0,
        f.paths[0],
    );
}

#[test(should_fail_with = "new state")]
fn test_context_is_bound() {
    let f = fixture();
    let st = initial_state_salt(f.salt);
    let old_state = state_commitment(f.mandate, 0, st);
    let next_salt = next_state_salt(f.salt, old_state, CONTEXT);
    let new_state = state_commitment(f.mandate, 1_000_000, next_salt);
    // Same witness, different deployment context.
    main(
        f.mandate,
        old_state,
        new_state,
        1_000_000,
        f.payees[0],
        1_900_000_000,
        0xdead,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        st,
        0,
        f.paths[0],
    );
}

// The index is range checked: index 256 has the same low 8 bits as index 0, and
// would otherwise be a second "name" for the same leaf.
#[test(should_fail_with = "index out of range")]
fn test_index_alias_rejected() {
    let f = fixture();
    let st = initial_state_salt(f.salt);
    let old_state = state_commitment(f.mandate, 0, st);
    let new_state = state_commitment(f.mandate, 1, next_state_salt(f.salt, old_state, CONTEXT));
    main(
        f.mandate,
        old_state,
        new_state,
        1,
        f.payees[0],
        1_900_000_000,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        st,
        256,
        f.paths[0],
    );
}

// An empty slot (zero leaf) is not a payee: leaf(x) is never 0 for any known x.
#[test(should_fail_with = "payee not allowed")]
fn test_empty_slot_is_not_a_payee() {
    let f = fixture();
    let st = initial_state_salt(f.salt);
    let old_state = state_commitment(f.mandate, 0, st);
    let new_state = state_commitment(f.mandate, 1, next_state_salt(f.salt, old_state, CONTEXT));
    // Index 3 is the empty sibling of payee 2.
    let mut path = f.paths[2];
    path[0] = leaf(f.payees[2]);
    main(
        f.mandate,
        old_state,
        new_state,
        1,
        0,
        1_900_000_000,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        st,
        3,
        path,
    );
}

// Domain separation: the leaf hash of an allowed payee is not itself a payee.
#[test(should_fail_with = "payee not allowed")]
fn test_leaf_value_is_not_a_payee() {
    let f = fixture();
    let st = initial_state_salt(f.salt);
    let old_state = state_commitment(f.mandate, 0, st);
    let new_state = state_commitment(f.mandate, 1, next_state_salt(f.salt, old_state, CONTEXT));
    main(
        f.mandate,
        old_state,
        new_state,
        1,
        leaf(f.payees[0]),
        1_900_000_000,
        CONTEXT,
        f.max_per_tx,
        f.total_cap,
        f.not_after,
        f.root,
        f.salt,
        0,
        st,
        0,
        f.paths[0],
    );
}

// u64 boundary: spent + amount exceeds 2^64 - 1. Widening to u128 means the sum
// cannot wrap to a small number and slip under a maximal cap.
#[test(should_fail_with = "over cumulative cap")]
fn test_sum_cannot_wrap_at_u64_max() {
    let f = fixture();
    let max: u64 = 0xffffffffffffffff;
    let mandate = mandate_commitment(max, max, f.not_after, f.root, f.salt);
    let st: Field = 0x99;
    let spent = max - 1;
    let old_state = state_commitment(mandate, spent, st);
    // Whatever the prover claims as the next head, the cap check fires first.
    main(
        mandate,
        old_state,
        0,
        2,
        f.payees[0],
        1_900_000_000,
        CONTEXT,
        max,
        max,
        f.not_after,
        f.root,
        f.salt,
        spent,
        st,
        0,
        f.paths[0],
    );
}

#[test]
fn test_spend_up_to_u64_max() {
    let f = fixture();
    let max: u64 = 0xffffffffffffffff;
    let mandate = mandate_commitment(max, max, f.not_after, f.root, f.salt);
    let st: Field = 0x99;
    let spent = max - 2;
    let old_state = state_commitment(mandate, spent, st);
    let new_state = state_commitment(mandate, max, next_state_salt(f.salt, old_state, CONTEXT));
    main(
        mandate,
        old_state,
        new_state,
        2,
        f.payees[0],
        1_900_000_000,
        CONTEXT,
        max,
        max,
        f.not_after,
        f.root,
        f.salt,
        spent,
        st,
        0,
        f.paths[0],
    );
}

#[test]
fn test_vectors_for_sdk() {
    // Printed for cross-checking the TypeScript hashing (see sdk tests).
    std::println(leaf(0xA11CE));
    std::println(node(1, 2));
    std::println(
        mandate_commitment(5_000_000, 12_000_000, 2_000_000_000, 7, 0x5a17),
    );
    std::println(state_commitment(9, 3, 0x77));
}
