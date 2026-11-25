//! Shared helpers for the turso conformance claims.
//!
//! Every unverified turso behaviour this project depends on gets one test under
//! `tests/`. See `docs/adr/0003-turso-conformance-crate.md` for why this crate is
//! excluded from the workspace and expected to be red.

use std::path::Path;
use std::sync::Arc;

/// Opens a turso file with MVCC on, which is what `BEGIN CONCURRENT` requires —
/// `core/vdbe/execute.rs` rejects concurrent transactions outright otherwise
/// ("Concurrent transaction mode is only supported when MVCC is enabled"), and
/// `core/lib.rs` notes MVCC "is controlled only by the database header (set via
/// PRAGMA journal_mode)".
pub fn open_mvcc(path: &Path) -> turso_core::Result<Arc<turso_core::Connection>> {
    let io: Arc<dyn turso_core::IO> = Arc::new(turso_core::PlatformIO::new()?);
    let db = turso_core::Database::open(
        io,
        path.to_str().expect("utf8 path"),
        turso_core::OpenOptions::new(Arc::new(turso_core::SqliteDialect)),
    )?;
    let conn = db.connect()?;
    conn.execute("PRAGMA journal_mode = mvcc")?;
    Ok(conn)
}

/// Opens a second, independent connection to an already-created file. Two
/// connections is the whole point: a single mutex-guarded connection, which is
/// what `event-sorcerer-sdk/src/storage/` holds today, cannot exhibit concurrent
/// transactions at any granularity.
pub fn reopen_mvcc(path: &Path) -> turso_core::Result<Arc<turso_core::Connection>> {
    open_mvcc(path)
}

/// True when the error is turso's commit-time write-write conflict — the signal
/// that conflict detection considered these two transactions to overlap.
pub fn is_write_write_conflict(err: &turso_core::LimboError) -> bool {
    matches!(err, turso_core::LimboError::WriteWriteConflict)
}

/// A scratch file path that is removed on drop, including turso's sidecar files.
pub struct Scratch {
    dir: std::path::PathBuf,
}

impl Scratch {
    pub fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "turso-conformance-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create scratch dir");
        Self { dir }
    }

    pub fn db_path(&self) -> std::path::PathBuf {
        self.dir.join("conformance.db")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
