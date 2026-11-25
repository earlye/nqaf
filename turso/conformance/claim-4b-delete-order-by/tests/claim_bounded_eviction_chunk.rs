//! Claim 4: a TTL eviction chunk can be expressed as a bounded, deterministically
//! ordered `DELETE`.
//!
//! Blocking. `docs/adr/0005-log-driven-ttl-eviction.md` makes routine TTL eviction
//! a log-anchored event: every member executes the same chunk at the same log
//! index, so the *set of rows a chunk removes* is replicated state and must be
//! identical everywhere. Two properties are load-bearing, and only together:
//!
//! - **Bounded**, because the chunk runs inside `apply()` on the single serial
//!   applier (`event-sorcerer-sdk/src/storage/state_machine.rs`). An unbounded
//!   `DELETE` after a TTL reduction stalls the log for its whole duration.
//! - **Deterministically ordered**, because an unordered `DELETE ... LIMIT n`
//!   removes whatever rows the scan reaches first, which is a property of the
//!   plan rather than of the data.
//!
//! **Settled as of turso `4b59a37f`: `DELETE ... ORDER BY ... LIMIT` does not
//! work — but it is one guard away from working, not absent.** The issue was
//! drafted expecting the stock-SQLite situation, where the clause is real but
//! gated behind `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`. Turso has no such flag, and
//! the returned `ParseError("ORDER BY clause is not supported in DELETE")` invites
//! the conclusion that its grammar lacks the clause. It does not:
//! `sqlite/parser/src/parser.rs:4639-4659` parses `order_by` and `limit` into
//! `Stmt::Delete` and even enforces SQLite's coupling rule ("ORDER BY without
//! LIMIT on DELETE"). The refusal is an unconditional guard in the *translator*,
//! `core/translate/mod.rs:287-289`, and it reads as a `ParseError` only because
//! `bail_parse_error!` is the macro it uses.
//!
//! **Deferred, deliberately: no NQAF ask is being filed** (2026-09-16). The ask
//! would be unusually easy to make — ADR 0003 `:53-55` calls a failing conformance
//! test "the strongest form of the NQAF ask ... the patch prompt ships with its
//! own reproducer", the grammar already exists, `translate_delete` already
//! receives `limit`, and one guard stands between — but nothing here needs it, and
//! upstream is expected to reach this on its own. `claim_4b` stays as the standing
//! tripwire, and doubles as the ready-made reproducer if that expectation changes.
//!
//! Meanwhile the subselect spelling (`DELETE ... WHERE id IN (SELECT ... ORDER BY
//! ... LIMIT n)`) is **the design, not a fallback**, and needs nothing from
//! upstream.
//!
//! # Why the index is a parameter and not a fixture detail
//!
//! Each clause in `ORDER BY delete_after, id` is only observable on a table shape
//! whose plan would otherwise disagree with it, and no single shape observes both.
//! Measured at `4b59a37f` on this fixture — **rows removed**, as `removed_ids`
//! reports them (id-ascending, since it derives from `surviving_ids`), where
//! `none` omits the `ORDER BY` entirely and `da` omits only the tiebreak:
//!
//! ```text
//! index shape                 none          da            da, id
//! NO_INDEX                    [5, 10, 15]   [10,20,30]    [10,20,30]
//! ASCENDING_INDEX  (da, id)   [10,20,30]    [10,20,30]    [10,20,30]
//! DESC_ID_INDEX    (da, id⤓)  [40,50,60]    [40,50,60]    [10,20,30]
//! ```
//!
//! Read down the columns against the correct answer, `[10,20,30]`. Dropping the
//! clause altogether is caught by two shapes, `NO_INDEX` and `DESC_ID_INDEX`.
//! Dropping only the tiebreak is caught by `DESC_ID_INDEX` alone — because a rowid
//! scan and an ascending range scan both visit a tie cohort in ascending id order,
//! so on those two shapes `delete_after` alone and `delete_after, id` agree by
//! construction. That asymmetry is the whole point: `ASCENDING_INDEX`, the shape
//! production actually has, catches neither omission. Two earlier versions of this
//! file were vacuous for exactly that reason, one clause at a time.
//!
//! Each shape named above is one a test in this file actually creates, so every
//! cell is reproducible from here. The raw `SELECT` returns the `DESC_ID_INDEX`
//! rows as `60, 50, 40`; the table reports the removed *set*, which is the
//! property, in the one order this file ever observes it.
//!
//! That is not merely a test defect — it is the claim restating itself. The chunk
//! must be ordered *by the query*, because the alternative is ordering by the
//! plan, and the plan is exactly what may differ between members: whether an index
//! exists yet on a member replaying from a snapshot, which of several candidate
//! indexes a planner picks, how a future turso version costs the same choice.
//! `(delete_after, id DESC)` is not a contrived shape — it is that argument's own
//! example.
//!
//! So 4c runs three times, and the trio is the property: the chunk's result does
//! not depend on which index the member happens to have.
//!
//! ADR 0003 `:56-60` requires a falsifier, and there is one per clause, because
//! each column of that table needs its own. `control_unordered_chunk_takes_the_
//! scan_order` pins that dropping the whole clause still takes a different set on
//! `NO_INDEX`; `control_tiebreak_omission_takes_the_index_order` pins that
//! dropping only `, id` still takes a different set on `DESC_ID_INDEX`. Without
//! the second, the tie-cohort claim's power would rest on turso continuing to walk
//! `id DESC` descending — true today, and asserted nowhere.

use std::sync::Arc;
use turso_conformance::{open_mvcc, Scratch};

type Conn = Arc<turso_core::Connection>;

/// The leader-stamped cutoff. The predicate is `delete_after < CUTOFF`, so a row
/// *below* this is expired and a row at or above it survives.
const CUTOFF: i64 = 500;
/// One chunk's bound — `max_events` in `events.ttl_chunk { cutoff, max_events }`.
const CHUNK: i64 = 3;

/// The direct spelling. The design uses `subselect_chunk` instead, since turso's
/// translator refuses this one today — but it is kept, and kept working against
/// the real fixture, because it serves two purposes: 4b's tripwire, and the
/// ready-made reproducer, should the deferred upstream ask ever be filed (see
/// this module's header).
fn direct_chunk(cutoff: i64, limit: i64) -> String {
    format!(
        "DELETE FROM events \
          WHERE delete_after < {cutoff} \
          ORDER BY delete_after, id \
          LIMIT {limit}"
    )
}

/// The spelling the design uses. `ORDER BY` and `LIMIT` sit in a subselect, where
/// both turso and stock SQLite accept them unconditionally.
fn subselect_chunk(cutoff: i64, limit: i64) -> String {
    format!(
        "DELETE FROM events WHERE id IN ( \
             SELECT id FROM events \
              WHERE delete_after < {cutoff} \
              ORDER BY delete_after, id \
              LIMIT {limit} \
         )"
    )
}

/// The same chunk with the `ORDER BY` removed — what the design would issue if the
/// clause were treated as decoration. Exists only for a control.
fn unordered_chunk(cutoff: i64, limit: i64) -> String {
    format!(
        "DELETE FROM events WHERE id IN ( \
             SELECT id FROM events \
              WHERE delete_after < {cutoff} \
              LIMIT {limit} \
         )"
    )
}

/// The chunk with only the `, id` tiebreak removed. Exists only for a control:
/// the tie-cohort claim's power depends on this spelling still disagreeing with
/// the full one, which is a fact about turso's planner and so needs pinning rather
/// than assuming.
fn delete_after_only_chunk(cutoff: i64, limit: i64) -> String {
    format!(
        "DELETE FROM events WHERE id IN ( \
             SELECT id FROM events \
              WHERE delete_after < {cutoff} \
              ORDER BY delete_after \
              LIMIT {limit} \
         )"
    )
}

/// Ids the correctly-ordered first chunk must remove: the three smallest
/// `(delete_after, id)` pairs.
const EXPECTED_FIRST_CHUNK: [i64; 3] = [10, 20, 30];

/// Ids an unordered scan takes instead, on an un-indexed table: the three smallest
/// *ids* among expired rows, since the scan arrives in rowid order.
const SCAN_ORDERED_CHUNK: [i64; 3] = [5, 10, 15];

/// Ids taken from the tail of the `100`-cohort when a plan following
/// `(delete_after, id DESC)` supplies the within-cohort order — i.e. what a chunk
/// missing its `, id` tiebreak removes on that shape. Reported id-ascending
/// because `removed_ids` derives from `surviving_ids`, which is `ORDER BY id`; the
/// raw `SELECT` returns the same three as `60, 50, 40`.
const DESC_INDEX_CHUNK: [i64; 3] = [40, 50, 60];

/// Ids that must survive every chunk, ascending. `70` sits exactly *at* the cutoff
/// and is the boundary case: a member spelling the predicate `<=` rather than `<`
/// would evict it, which is the same class of divergence this claim exists to
/// prevent. `900` and `901` carry `delete_after = NULL`, the never-evict marker;
/// they survive because a comparison against `NULL` evaluates to `NULL` rather
/// than `TRUE`, which is ANSI SQL and explicitly *not* a turso claim this crate
/// pins — see `setup`.
const UNEXPIRED: [i64; 6] = [1, 2, 3, 70, 900, 901];

/// Every expired row, as `(id, delete_after)`. Three cohorts, chosen so that
/// ordering by `(delete_after, id)` and arriving in rowid order pick different
/// sets: the `200`-cohort deliberately holds the smallest ids *among the expired
/// rows*, which is what makes `SCAN_ORDERED_CHUNK` `[5, 10, 15]`. (Ids `1, 2, 3`
/// are smaller still, but outlive the cutoff and so never enter a chunk.)
///
/// The six-row `100`-cohort is what forces the `id` tiebreak to exist at all —
/// `topic.changed { recalculateExisting, mode: absolute }` stamps an arbitrary
/// number of rows with an identical `delete_after`, so a `delete_after`-only order
/// leaves the chunk boundary undefined. `65` at `CUTOFF - 1` is the other half of
/// the boundary case: it must be evicted.
const EXPIRED: [(i64, i64); 9] = [
    (10, 100),
    (20, 100),
    (30, 100),
    (40, 100),
    (50, 100),
    (60, 100),
    (5, 200),
    (15, 200),
    (65, CUTOFF - 1),
];

/// The index shapes a member might plausibly have. `NONE` is where the query is
/// the only possible source of ordering; `ASCENDING` is production's; `DESC_ID` is
/// the one that makes the `id` tiebreak observable, because a plan following it
/// visits a tie cohort in descending id order and so disagrees with
/// `ORDER BY delete_after` alone.
const NO_INDEX: Option<&str> = None;
const ASCENDING_INDEX: Option<&str> = Some("delete_after, id");
const DESC_ID_INDEX: Option<&str> = Some("delete_after, id DESC");

/// `delete_after` is deliberately **nullable**, matching the production column:
/// `delete_after = NULL` is the design's never-evict marker, and
/// `issue-019f80ae-...-generational-archival.md` now leans on it too, since a
/// bytes-only archive keeps the row with `delete_after = NULL`.
///
/// This is fixture realism, **not** a pinned turso claim, and the distinction
/// matters on a file whose whole point is separating measured from assumed.
/// `issue-019f6bef-...-global-per-group-event-store.md:145-152` is explicit that
/// NULL exclusion needs no verification: "any comparison against `NULL` evaluates
/// to `NULL`, not `TRUE`, so `WHERE delete_after < now()` naturally excludes
/// null-`delete_after` rows ... This is ANSI SQL behavior, not a turso-specific
/// claim — doesn't need the same verify-don't-assume treatment as the
/// turso-specific claims elsewhere in this design." What a `NOT NULL` fixture
/// would cost is representability: this is the only test touching the eviction
/// predicate, and it would be testing a schema the design does not have. The NULL
/// rows ride along in 4d's survivor set for two lines.
fn setup(tag: &str, index_on: Option<&str>) -> (Scratch, Conn) {
    let scratch = Scratch::new(tag);
    let conn = open_mvcc(&scratch.db_path()).expect("open");
    conn.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, delete_after INTEGER)")
        .expect("create events table");
    if let Some(columns) = index_on {
        conn.execute(format!(
            "CREATE INDEX events_delete_after ON events ({columns})"
        ))
        .unwrap_or_else(|e| panic!("create index on ({columns}): {e:?}"));
    }

    for (id, delete_after) in EXPIRED {
        insert(&conn, id, delete_after);
    }
    insert(&conn, 70, CUTOFF); // at the cutoff: survives
    for id in [1, 2, 3] {
        insert(&conn, id, 9_999);
    }
    for id in [900, 901] {
        conn.execute(format!(
            "INSERT INTO events (id, delete_after) VALUES ({id}, NULL)"
        ))
        .expect("insert never-evict row");
    }

    let seeded = EXPIRED.len() + UNEXPIRED.len();
    assert_eq!(
        surviving_ids(&conn).len(),
        seeded,
        "fixture should seed {seeded} rows; a shortfall means surviving_ids is \
         silently dropping non-Integer values"
    );

    (scratch, conn)
}

fn insert(conn: &Conn, id: i64, delete_after: i64) {
    conn.execute(format!(
        "INSERT INTO events (id, delete_after) VALUES ({id}, {delete_after})"
    ))
    .unwrap_or_else(|e| panic!("insert id={id}: {e:?}"));
}

/// Every id still in the table, ascending.
fn surviving_ids(conn: &Conn) -> Vec<i64> {
    let mut stmt = conn
        .query("SELECT id FROM events ORDER BY id")
        .expect("query surviving ids")
        .expect("statement");
    let mut ids = Vec::new();
    stmt.run_with_row_callback(|row| {
        let value: &turso_core::Value = row.get(0)?;
        if let turso_core::Value::Numeric(turso_core::Numeric::Integer(n)) = value {
            ids.push(*n);
        }
        Ok(())
    })
    .expect("step surviving ids");
    ids
}

/// The ids a chunk removed, given what survived it.
fn removed_ids(before: &[i64], after: &[i64]) -> Vec<i64> {
    before
        .iter()
        .copied()
        .filter(|id| !after.contains(id))
        .collect()
}

/// What `ttl-manager` polls between chunks: is there any expired row left? An
/// existence probe rather than `count(*)`, since the loop only branches on
/// zero/nonzero and `count(*)` scans the whole backlog in exactly the
/// post-TTL-reduction case the loop exists to handle.
fn any_expired(conn: &Conn, cutoff: i64) -> bool {
    let mut stmt = conn
        .query(format!(
            "SELECT 1 FROM events WHERE delete_after < {cutoff} LIMIT 1"
        ))
        .expect("query expired probe")
        .expect("statement");
    let mut found = false;
    stmt.run_with_row_callback(|_row| {
        found = true;
        Ok(())
    })
    .expect("step expired probe");
    found
}

/// Runs one chunk and returns what it removed.
fn run_chunk(conn: &Conn, sql: String) -> Vec<i64> {
    let before = surviving_ids(conn);
    conn.execute(sql).expect("chunk");
    removed_ids(&before, &surviving_ids(conn))
}

/// **The control ADR 0003 requires** (`:56-60`: "Every claim needs a control that
/// must fail... Without one, a green claim is unfalsifiable").
///
/// Pins that on an un-indexed table the unordered chunk really does take a
/// different set from the ordered one. If this ever goes green-by-agreement — both
/// spellings returning `EXPECTED_FIRST_CHUNK` — then 4b and 4c have stopped
/// discriminating and their green means nothing, whatever it says on the tin.
#[test]
fn control_unordered_chunk_takes_the_scan_order() {
    let (_scratch, conn) = setup("control-unordered", NO_INDEX);

    let removed = run_chunk(&conn, unordered_chunk(CUTOFF, CHUNK));

    assert_eq!(
        removed, SCAN_ORDERED_CHUNK,
        "an unordered chunk removed {removed:?}, expected the scan-ordered \
         {SCAN_ORDERED_CHUNK:?}. If it now matches {EXPECTED_FIRST_CHUNK:?}, this \
         fixture can no longer tell an ordered chunk from an unordered one and \
         claims 4b/4c are vacuous until it can."
    );
}

/// **The control for the `, id` tiebreak specifically.**
///
/// `control_unordered_chunk_takes_the_scan_order` cannot cover this: it drops the
/// *whole* clause and runs un-indexed, where the tiebreak is provably invisible
/// (see the header table). So without this test, the tie-cohort claim's power
/// rests on turso continuing to pick `(delete_after, id DESC)` and walk it
/// descending — true today, asserted nowhere.
///
/// If a future turso normalises `id DESC` on a rowid alias, or costs that index
/// out of the plan, this cell becomes `EXPECTED_FIRST_CHUNK` by agreement rather
/// than by the query. `subselect_chunk` could then drop `, id` with every test
/// still green — which is precisely the unfalsifiable green ADR 0003 `:56-60`
/// forbids, and the second time this file has had it.
#[test]
fn control_tiebreak_omission_takes_the_index_order() {
    let (_scratch, conn) = setup("control-tiebreak", DESC_ID_INDEX);

    let removed = run_chunk(&conn, delete_after_only_chunk(CUTOFF, CHUNK));

    assert_eq!(
        removed, DESC_INDEX_CHUNK,
        "a chunk missing its `, id` tiebreak removed {removed:?} on the \
         (delete_after, id DESC) shape, expected {DESC_INDEX_CHUNK:?}. If it now \
         matches {EXPECTED_FIRST_CHUNK:?}, no shape in this file distinguishes \
         `ORDER BY delete_after` from `ORDER BY delete_after, id`, and \
         claim_4c_subselect_chunk_orders_within_a_tie_cohort is vacuous until one \
         does."
    );
}

/// 4b: the direct spelling is either refused outright or honours its `ORDER BY` —
/// never accepted-and-ignored.
///
/// Deliberately not "the direct form works": it does not, and asserting that it
/// should would leave a permanently-red test pinning something the design no
/// longer wants. The failure this guards against is the *other* way turso could
/// change — gaining the syntax while ordering arbitrarily, which looks like
/// support at the call site and diverges members. Un-indexed, so the query is the
/// only thing that could supply the ordering.
#[test]
fn claim_4b_direct_form_is_refused_rather_than_silently_unordered() {
    let (_scratch, conn) = setup("chunk-direct", NO_INDEX);
    let before = surviving_ids(&conn);

    let err = match conn.execute(direct_chunk(CUTOFF, CHUNK)) {
        Err(e) => e,
        Ok(()) => {
            let removed = removed_ids(&before, &surviving_ids(&conn));
            assert_eq!(
                removed,
                EXPECTED_FIRST_CHUNK,
                "turso has gained DELETE ... ORDER BY ... LIMIT, but it removed \
                 {removed:?} rather than {EXPECTED_FIRST_CHUNK:?}. {} A chunk's \
                 boundary must be a function of (delete_after, id) alone, or \
                 members whose plans differ delete different rows at the same log \
                 index. Keep using the subselect form (claim_4c).",
                if removed == SCAN_ORDERED_CHUNK {
                    "That is exactly the scan-ordered set, so the ORDER BY is \
                     being accepted and ignored."
                } else {
                    "That matches neither the ordered nor the scan-ordered set."
                }
            );
            return;
        }
    };

    // Not "any error will do": a `format!`-built statement broken for an unrelated
    // reason (a renamed column, say) would otherwise look exactly like the pinned
    // refusal, and this tripwire would sit green forever with nothing behind it.
    //
    // Matching on the message is not enough by itself, because the refusal happens
    // before any name is resolved: the `order_by` guard sits at the top of
    // `translate`, ahead of `translate_delete`, which is what would resolve the
    // table (`core/translate/mod.rs:287-289`). Measured at `4b59a37f`, both of
    // these return `ParseError("ORDER BY clause is not supported in DELETE")`:
    //
    //     DELETE FROM events WHERE expires_at   < 500 ORDER BY ... LIMIT 3
    //     DELETE FROM eventz WHERE delete_after < 500 ORDER BY ... LIMIT 3
    //
    // So the identifiers are probed separately, with a statement that *does* reach
    // name resolution — and the probe is **derived from `direct_chunk`'s own text**
    // rather than written beside it. An independently-written literal would
    // hardcode `events`/`delete_after` and keep succeeding against the real fixture
    // while `direct_chunk` drifted to `FROM eventz`, which is the very drift this
    // is here to catch.
    //
    // Only the verb is swapped — nothing is stripped. `SELECT` accepts `ORDER BY`
    // and `LIMIT` unconditionally, so the whole statement survives the rewrite and
    // *every* identifier gets resolved, the ordering columns included. An earlier
    // version cut the statement at `" ORDER BY "` and so left `ORDER BY expires_at,
    // id` undetectable — which matters directly below, where the `Ok` branch
    // compares against `EXPECTED_FIRST_CHUNK`, a constant that is only correct for
    // `delete_after, id`.
    let probe = direct_chunk(CUTOFF, CHUNK).replacen("DELETE FROM", "SELECT id FROM", 1);
    conn.query(probe.clone()).unwrap_or_else(|e| {
        panic!(
            "well-formedness probe `{probe}` failed ({e:?}): direct_chunk's \
             identifiers no longer match the fixture, so 4b is probing a statement \
             that would fail whatever turso did with ORDER BY. Fix the statement, \
             not this assertion."
        )
    });

    let message = format!("{err:?}");
    assert!(
        message.contains("ORDER BY"),
        "expected turso's refusal of ORDER BY in DELETE, got a different error: \
         {message}."
    );

    assert_eq!(
        surviving_ids(&conn),
        before,
        "the refused statement deleted rows before erroring. A partial chunk is \
         precisely the nondeterministic outcome this claim exists to exclude."
    );
}

/// 4c, un-indexed: the design's chunk both bounds and orders, with the query as
/// the only possible source of the ordering. **Blocking.**
///
/// Red here and ADR 0005's mechanism has no implementation at all: with the direct
/// spelling absent from turso, this is the only remaining way to write a chunk
/// that is simultaneously bounded (so it cannot stall the applier) and
/// deterministic (so every member removes the same rows).
#[test]
fn claim_4c_subselect_chunk_bounds_and_orders_without_index() {
    let (_scratch, conn) = setup("chunk-subselect-noindex", NO_INDEX);

    assert_chunk_is_bounded_and_ordered(&conn, "without the (delete_after, id) index");
}

/// 4c, indexed: the same chunk against production's shape. Weaker on its own —
/// the planner can supply this ordering unasked, which is what made the earlier
/// version of this file vacuous — but the pair together is the real property:
/// the chunk's result does not depend on whether the index is there.
#[test]
fn claim_4c_subselect_chunk_bounds_and_orders_with_index() {
    let (_scratch, conn) = setup("chunk-subselect-indexed", ASCENDING_INDEX);

    assert_chunk_is_bounded_and_ordered(&conn, "with the (delete_after, id) index");
}

/// 4c, descending-id index: **this is the variant that pins the `id` tiebreak.**
///
/// Neither of the two above does. A rowid full scan and a `(delete_after, id)`
/// range scan both visit a tie cohort in ascending id order, so on those shapes
/// `ORDER BY delete_after` and `ORDER BY delete_after, id` agree by construction —
/// dropping `, id` from the chunk leaves them green. See the `da` and `da, id`
/// columns of the module header's table; only `DESC_ID_INDEX` disagrees, so only
/// it can catch a chunk written as `ORDER BY delete_after LIMIT n`.
///
/// That matters because the tiebreak is the half of the clause the design leans on
/// hardest: a `topic.changed { recalculateExisting, mode: absolute }` stamps an
/// arbitrary number of rows with an identical `delete_after`, and without `id` the
/// boundary *inside* that cohort is once again a property of the plan.
///
/// The shape is not contrived, either — it is this module header's own argument
/// about "which of several candidate indexes a planner picks". That this shape
/// still disagrees is itself pinned, by
/// `control_tiebreak_omission_takes_the_index_order`.
#[test]
fn claim_4c_subselect_chunk_orders_within_a_tie_cohort() {
    let (_scratch, conn) = setup("chunk-subselect-desc-id", DESC_ID_INDEX);

    assert_chunk_is_bounded_and_ordered(&conn, "with the (delete_after, id DESC) index");
}

fn assert_chunk_is_bounded_and_ordered(conn: &Conn, shape: &str) {
    let removed = run_chunk(conn, subselect_chunk(CUTOFF, CHUNK));

    assert_eq!(
        removed.len() as i64,
        CHUNK,
        "{shape}: chunk removed {} rows, expected {CHUNK}. An unbounded chunk \
         stalls the serial applier for the length of a TTL-reduction backlog.",
        removed.len()
    );
    assert_eq!(
        removed, EXPECTED_FIRST_CHUNK,
        "{shape}: chunk removed {removed:?}, expected {EXPECTED_FIRST_CHUNK:?}. \
         The chunk's boundary must be a function of (delete_after, id) alone; if \
         it is not, members whose plans differ remove different rows at the same \
         log index and the event store stops being a function of the log prefix."
    );
}

/// 4d: repeated chunks converge on exactly the expired set, and the probe goes
/// quiet.
///
/// This, not single-chunk exactness, is what the `ttl-manager` loop leans on. A
/// chunk is *not* idempotent — running it twice removes up to 2n rows, not n — so
/// the
/// property that makes a duplicated chunk harmless is convergence: every chunk
/// removes only rows already below their cutoff, so extra chunks advance the sweep
/// rather than doing wrong work, and the loop terminates when the probe finds
/// nothing. ("Up to", because once the backlog is clear a further chunk removes
/// zero — which this test then relies on.) Run against production's indexed
/// shape.
#[test]
fn claim_4d_repeated_chunks_converge_on_the_expired_set() {
    let (_scratch, conn) = setup("chunk-convergence", ASCENDING_INDEX);

    let mut chunks = 0;
    while any_expired(&conn, CUTOFF) {
        conn.execute(subselect_chunk(CUTOFF, CHUNK))
            .expect("chunk during convergence loop");
        chunks += 1;
        assert!(
            chunks <= 10,
            "eviction loop did not converge after {chunks} chunks — a chunk that \
             removes nothing while the probe still reports work spins forever"
        );
    }

    // The loop above cannot see a `<=` chunk on its own, and this is the trap that
    // made id 70's boundary guard inert until it was caught: `any_expired` spells
    // the predicate `<`, so with a `<=` chunk the loop clears the rows expired
    // under `<`, the probe then reports nothing, and it exits one chunk before
    // anything could reach id 70. The row survives for the wrong reason.
    //
    // Asking for one more chunk closes it, and the property it pins is worth
    // naming: **ttl-manager's probe predicate and the chunk's predicate must be the
    // same predicate.** If they disagree the loop either spins (probe reports work
    // the chunk will not do) or stops early (the chunk would take rows the probe
    // does not count) — and the second is a silent over-eviction of exactly the
    // rows sitting on the boundary.
    let after_convergence = surviving_ids(&conn);
    conn.execute(subselect_chunk(CUTOFF, CHUNK))
        .expect("post-convergence chunk");
    let over_evicted = removed_ids(&after_convergence, &surviving_ids(&conn));
    assert!(
        over_evicted.is_empty(),
        "a chunk run after the probe went quiet still removed {over_evicted:?}. \
         The chunk and `any_expired` disagree about which rows are expired — a \
         `<=` chunk against a `<` probe takes the row seeded exactly at the cutoff."
    );

    assert_eq!(
        surviving_ids(&conn),
        UNEXPIRED.to_vec(),
        "convergence left the wrong rows. Only rows *below* the carried cutoff may \
         be removed; everything at or above it must survive however many chunks \
         run — including id 70, seeded exactly at the cutoff to catch a `<=` \
         spelling of the predicate."
    );

    let expected_chunks = EXPIRED.len().div_ceil(CHUNK as usize);
    assert_eq!(
        chunks,
        expected_chunks,
        "expected {expected_chunks} chunks to clear {} expired rows at {CHUNK} per \
         chunk, took {chunks} — a chunk is not removing its full bound.",
        EXPIRED.len()
    );
}
