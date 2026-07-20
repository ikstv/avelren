import { load } from "cheerio";
import { normalizeSourceObservation, type SourceObservation } from "../collector/source-observation.js";

export interface HtmlObservationParserOptions {
  locationId: string;
  countSelector: string;
  observedAtSelector?: string;
}

export class HtmlObservationParser {
  public constructor(private readonly options: HtmlObservationParserOptions) {
    validateSelector(options.countSelector);
    if (options.observedAtSelector !== undefined) validateSelector(options.observedAtSelector);
  }

  public parse(body: Uint8Array, trustedObservedAt: Date): SourceObservation {
    let document: string;
    try { document = new TextDecoder("utf-8", { fatal: true }).decode(body); }
    catch { throw parseError(); }
    const $ = load(document, { scriptingEnabled: false });
    const countNodes = $(this.options.countSelector);
    if (countNodes.length !== 1) throw parseError();
    const normalizedCount = countNodes.text().trim();
    if (!/^(0|[1-9][0-9]*)$/u.test(normalizedCount)) throw parseError();
    const vehicleCount = Number(normalizedCount);
    if (!Number.isSafeInteger(vehicleCount)) throw parseError();
    let observedAt = trustedObservedAt.toISOString();
    if (this.options.observedAtSelector !== undefined) {
      const nodes = $(this.options.observedAtSelector);
      if (nodes.length !== 1) throw parseError();
      observedAt = nodes.text().trim();
      const milliseconds = Date.parse(observedAt);
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(observedAt) ||
          !Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== observedAt) throw parseError();
    }
    try {
      return normalizeSourceObservation({ locationId: this.options.locationId, vehicleCount, observedAt });
    } catch { throw parseError(); }
  }
}

function validateSelector(value: string): void {
  try { load("", { scriptingEnabled: false })(value); }
  catch { throw new Error("External source parser configuration is invalid"); }
}
function parseError(): Error { return new Error("External source response could not be parsed"); }
