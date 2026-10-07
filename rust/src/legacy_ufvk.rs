//! A pre-migration repair for wallet databases that predate `full_account_ids`.
//!
//! `zcash_client_sqlite`'s `full_account_ids` migration decides whether the caller's seed is
//! relevant by comparing the unified full viewing key string the old `accounts` table stores
//! with `UnifiedFullViewingKey::encode` of the key it derives from the seed. Databases written
//! before that migration hold ZIP 316 revision 0 strings (`uview1…`), and on the NU7 crates the
//! encoder produces revision 2 (`uvf1…`), so the comparison fails for every such database and
//! the migration reports `SeedNotRelevant` for the wallet's own seed.
//!
//! Re-encoding the stored strings with the current encoder, before the migrations run, makes
//! the comparison hold again. Nothing else reads the column: the migration rebuilds the
//! `accounts` table from the parsed key, and the old table goes away with it. A database that
//! has already passed the migration is left alone.

use anyhow::anyhow;
use rusqlite::{Connection, named_params};
use zcash_client_backend::keys::UnifiedFullViewingKey;
use zcash_protocol::consensus::Parameters;

/// Re-encodes every `accounts.ufvk` of a pre-`full_account_ids` database with the current
/// encoder, so that migration's seed check compares like with like. Returns the number of
/// rows rewritten, `0` for a database that is not at that schema.
pub(crate) fn realign_legacy_ufvk_encodings(
    conn: &Connection,
    params: &impl Parameters,
) -> anyhow::Result<usize> {
    let columns: Vec<String> = conn
        .prepare("PRAGMA table_info(accounts)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<_, _>>()?;
    let has = |name: &str| columns.iter().any(|c| c == name);
    // The pre-migration table is keyed by the ZIP 32 account index and has no `id`; the table
    // the migration builds has `id` and a `ufvk` column of its own, which is already current.
    if !(has("account") && has("ufvk") && !has("id")) {
        return Ok(0);
    }

    let rows: Vec<(u32, String)> = conn
        .prepare("SELECT account, ufvk FROM accounts")?
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<Result<_, _>>()?;
    let mut rewritten = 0;
    for (account, stored) in rows {
        // A string that does not decode is left for the migration to report as corrupted.
        let Ok(ufvk) = UnifiedFullViewingKey::decode(params, &stored) else {
            continue;
        };
        let current = ufvk.encode(params);
        if current != stored {
            conn.execute(
                "UPDATE accounts SET ufvk = :ufvk WHERE account = :account",
                named_params! { ":ufvk": current, ":account": account },
            )
            .map_err(|e| anyhow!("Error re-encoding a legacy viewing key: {e}"))?;
            rewritten += 1;
        }
    }
    Ok(rewritten)
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;
    use zcash_client_backend::keys::{UnifiedFullViewingKey, UnifiedSpendingKey};
    use zcash_protocol::consensus::{MAIN_NETWORK, Parameters as _};

    use super::realign_legacy_ufvk_encodings;

    fn legacy_accounts_table(ufvk: &str) -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE accounts (
                account INTEGER PRIMARY KEY,
                ufvk TEXT NOT NULL,
                birthday_height INTEGER NOT NULL,
                recover_until_height INTEGER
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO accounts (account, ufvk, birthday_height) VALUES (0, ?1, 1)",
            [ufvk],
        )
        .unwrap();
        conn
    }

    fn stored(conn: &Connection) -> String {
        conn.query_row("SELECT ufvk FROM accounts WHERE account = 0", [], |r| {
            r.get(0)
        })
        .unwrap()
    }

    #[test]
    fn rewrites_a_revision_0_key_to_the_current_encoding() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .unwrap();
        let ufvk = usk.to_unified_full_viewing_key();
        // The revision 0 spelling an older SDK stored: the same items, re-encoded at revision 0.
        let r0 = {
            use zcash_address::unified::{Container as _, Encoding as _, Revision, Ufvk};
            let (_, _, container) = Ufvk::decode(&ufvk.encode(&MAIN_NETWORK)).unwrap();
            Ufvk::try_from_items(Revision::R0, container.items_as_parsed().to_vec())
                .unwrap()
                .encode(&MAIN_NETWORK.network_type())
        };
        assert!(r0.starts_with("uview1"), "{r0}");
        let conn = legacy_accounts_table(&r0);

        assert_eq!(
            realign_legacy_ufvk_encodings(&conn, &MAIN_NETWORK).unwrap(),
            1
        );

        let now = stored(&conn);
        assert_eq!(now, ufvk.encode(&MAIN_NETWORK));
        assert_ne!(now, r0);
        // The same key, under a different spelling.
        let decoded = UnifiedFullViewingKey::decode(&MAIN_NETWORK, &now).unwrap();
        assert_eq!(decoded.encode(&MAIN_NETWORK), ufvk.encode(&MAIN_NETWORK));
        // A second pass finds nothing to do.
        assert_eq!(
            realign_legacy_ufvk_encodings(&conn, &MAIN_NETWORK).unwrap(),
            0
        );
    }

    #[test]
    fn leaves_an_undecodable_key_for_the_migration_to_report() {
        let conn = legacy_accounts_table("uview1notakey");
        assert_eq!(
            realign_legacy_ufvk_encodings(&conn, &MAIN_NETWORK).unwrap(),
            0
        );
        assert_eq!(stored(&conn), "uview1notakey");
    }

    #[test]
    fn ignores_a_database_that_has_passed_the_migration() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE accounts (id INTEGER PRIMARY KEY, ufvk TEXT, uuid BLOB);
             INSERT INTO accounts (id, ufvk) VALUES (0, 'uview1whatever');",
        )
        .unwrap();
        assert_eq!(
            realign_legacy_ufvk_encodings(&conn, &MAIN_NETWORK).unwrap(),
            0
        );
    }

    #[test]
    fn ignores_a_database_without_an_accounts_table() {
        let conn = Connection::open_in_memory().unwrap();
        assert_eq!(
            realign_legacy_ufvk_encodings(&conn, &MAIN_NETWORK).unwrap(),
            0
        );
    }
}

/// The bundled pre-`full_account_ids` fixture wallet, migrated end to end through the FFI with
/// the seed the Swift tests use. This is the failure the Swift `OfflineTests` saw on the NU7
/// crates: `zcashlc_init_data_database` answered `2` (seed not relevant) and left the schema
/// where it was.
#[cfg(test)]
mod fixture_tests {
    #[test]
    fn the_legacy_fixture_migrates_with_its_own_seed() {
        let src = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/Tests/TestUtils/Resources/darkside_data.db"
        );
        let dst = std::env::temp_dir().join(format!("legacy-ufvk-{}.db", std::process::id()));
        std::fs::copy(src, &dst).expect("the fixture copies");
        // `Environment.seedBytes` in `Tests/TestUtils/Tests+Utils.swift`.
        let seed = base64_seed();
        let path = dst.to_str().unwrap().as_bytes();
        let rc = unsafe {
            crate::zcashlc_init_data_database(
                path.as_ptr(),
                path.len(),
                seed.as_ptr(),
                seed.len(),
                crate::NETWORK_ID_MAINNET,
            )
        };
        let conn = rusqlite::Connection::open(&dst).unwrap();
        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(accounts)")
            .unwrap()
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        let _ = std::fs::remove_file(&dst);
        assert_eq!(rc, 0, "the fixture's own seed must be accepted");
        assert!(
            columns.iter().any(|c| c == "id") && columns.iter().any(|c| c == "uuid"),
            "the accounts table must have been rebuilt by full_account_ids: {columns:?}"
        );
    }

    fn base64_seed() -> Vec<u8> {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD
            .decode("9VDVOZZZOWWHpZtq1Ebridp3Qeux5C+HwiRR0g7Oi7HgnMs8Gfln83+/Q1NnvClcaSwM4ADFL1uZHxypEWlWXg==")
            .unwrap()
    }
}
