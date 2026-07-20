export function parseDemoMode(rawValue: string | undefined): boolean {
  if (rawValue === undefined) {
    return false;
  }

  if (rawValue === "true" || rawValue === "false") {
    return rawValue === "true";
  }

  throw new Error("AVELREN_DEMO_MODE must be either \"true\" or \"false\"");
}

export type StorageMode = "memory" | "postgres";

export interface RuntimeStorageConfig {
  mode: StorageMode;
  databaseUrl?: string;
}

export function parseStorageConfig(
  environment: NodeJS.ProcessEnv,
): RuntimeStorageConfig {
  const production = environment.NODE_ENV === "production";
  const rawMode = environment.AVELREN_STORAGE_MODE;

  if (rawMode === undefined) {
    if (production) {
      throw new Error(
        "AVELREN_STORAGE_MODE must be set to postgres in production",
      );
    }
    return { mode: "memory" };
  }
  if (rawMode !== "memory" && rawMode !== "postgres") {
    throw new Error("AVELREN_STORAGE_MODE must be memory or postgres");
  }
  if (production && rawMode !== "postgres") {
    throw new Error("Production storage must use PostgreSQL");
  }
  if (rawMode === "memory") {
    return { mode: "memory" };
  }

  const databaseUrl = environment.DATABASE_URL;
  if (!isValidPostgresUrl(databaseUrl)) {
    throw new Error("DATABASE_URL must be a valid PostgreSQL connection URL");
  }
  return { mode: "postgres", databaseUrl };
}

function isValidPostgresUrl(value: string | undefined): value is string {
  if (value === undefined || value.length > 2_048) {
    return false;
  }
  try {
    const parsed = new URL(value);
    return (
      (parsed.protocol === "postgres:" || parsed.protocol === "postgresql:") &&
      parsed.hostname.length > 0 &&
      parsed.pathname.length > 1 &&
      parsed.hash.length === 0
    );
  } catch {
    return false;
  }
}
