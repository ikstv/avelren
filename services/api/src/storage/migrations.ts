import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import type { Pool, PoolClient, QueryResultRow } from "pg";

const MIGRATION_FILE_PATTERN = /^(\d{3})_[a-z0-9_]+\.sql$/u;
const MIGRATION_LOCK_ID = "781663501821742011";
const migrationsDirectory = fileURLToPath(
  new URL("../../migrations/", import.meta.url),
);

interface AppliedMigrationRow extends QueryResultRow {
  version: string;
  checksum: string;
}

interface Migration {
  version: string;
  checksum: string;
  sql: string;
}

export async function runMigrations(pool: Pool): Promise<void> {
  const migrations = await loadMigrations();
  let client: PoolClient;
  try {
    client = await pool.connect();
  } catch {
    throw migrationError();
  }

  try {
    await client.query("BEGIN");
    await client.query("SELECT pg_advisory_xact_lock($1::bigint)", [
      MIGRATION_LOCK_ID,
    ]);
    await client.query(
      `CREATE TABLE IF NOT EXISTS avelren_schema_migrations (
         version text PRIMARY KEY,
         checksum char(64) NOT NULL,
         applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
       )`,
    );

    const appliedResult = await client.query<AppliedMigrationRow>(
      "SELECT version, checksum FROM avelren_schema_migrations",
    );
    const applied = new Map(
      appliedResult.rows.map((row) => [row.version, row.checksum]),
    );

    for (const migration of migrations) {
      const existingChecksum = applied.get(migration.version);
      if (existingChecksum !== undefined) {
        if (existingChecksum !== migration.checksum) {
          throw new Error("Applied migration checksum mismatch");
        }
        continue;
      }

      await client.query(migration.sql);
      await client.query(
        `INSERT INTO avelren_schema_migrations (version, checksum)
         VALUES ($1, $2)`,
        [migration.version, migration.checksum],
      );
    }

    await client.query("COMMIT");
  } catch {
    await rollbackMigrationQuietly(client);
    throw migrationError();
  } finally {
    client.release();
  }
}

async function loadMigrations(): Promise<Migration[]> {
  try {
    const filenames = (await readdir(migrationsDirectory))
      .filter((filename) => MIGRATION_FILE_PATTERN.test(filename))
      .sort((left, right) => left.localeCompare(right));
    if (filenames.length === 0) {
      throw new Error("No migrations found");
    }

    const migrations = await Promise.all(
      filenames.map(async (filename) => {
        const match = MIGRATION_FILE_PATTERN.exec(filename);
        if (match?.[1] === undefined) {
          throw new Error("Migration filename is invalid");
        }
        const sql = await readFile(`${migrationsDirectory}/${filename}`, "utf8");
        return {
          version: match[1],
          checksum: createHash("sha256").update(sql).digest("hex"),
          sql,
        };
      }),
    );

    const versions = new Set<string>();
    for (const migration of migrations) {
      if (versions.has(migration.version)) {
        throw new Error("Migration version is duplicated");
      }
      versions.add(migration.version);
    }
    return migrations;
  } catch {
    throw migrationError();
  }
}

async function rollbackMigrationQuietly(client: PoolClient): Promise<void> {
  try {
    await client.query("ROLLBACK");
  } catch {
    // Startup still fails with a normalized migration error.
  }
}

function migrationError(): Error {
  return new Error("PostgreSQL migration failed");
}
