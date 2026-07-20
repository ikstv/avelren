export function parseDemoMode(rawValue: string | undefined): boolean {
  if (rawValue === undefined) {
    return false;
  }

  if (rawValue === "true" || rawValue === "false") {
    return rawValue === "true";
  }

  throw new Error("AVELREN_DEMO_MODE must be either \"true\" or \"false\"");
}
