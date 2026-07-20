import { describe, expect, it } from "vitest";
import { HtmlObservationParser } from "../../src/external-source/html-observation-parser.js";

const trusted = new Date("2026-07-20T08:00:00.000Z");

describe("HtmlObservationParser", () => {
  it("parses one count into the exact observation input", () => {
    const result = parser().parse(Buffer.from('<i data-avelren-count>1\u00a0234</i>'), trusted);
    expect(result).toMatchObject({ locationId: "location-placeholder", vehicleCount: 1234, observedAt: trusted.toISOString() });
    expect(Object.keys(result).sort()).toEqual(["locationId", "observedAt", "vehicleCount"]);
  });
  it.each([
    "<i>missing</i>",
    "<i data-avelren-count>1</i><i data-avelren-count>2</i>",
    "<i data-avelren-count>1,000</i>",
    "<i data-avelren-count>-1</i>",
    "<i data-avelren-count>01</i>",
    "<i data-avelren-count>1000001</i>",
  ])("rejects malformed or ambiguous count", (body) => {
    expect(() => parser().parse(Buffer.from(body), trusted)).toThrow("External source response could not be parsed");
  });
  it("rejects invalid UTF-8", () => {
    expect(() => parser().parse(Buffer.from([0xff, 0xfe]), trusted)).toThrow("External source response could not be parsed");
  });
  it("accepts only one canonical UTC timestamp", () => {
    const result = parser("[data-avelren-time]").parse(Buffer.from(
      '<i data-avelren-count>50</i><time data-avelren-time>2026-07-20T07:59:00.000Z</time>',
    ), trusted);
    expect(result.observedAt).toBe("2026-07-20T07:59:00.000Z");
  });
  it.each(["2026-07-20T07:59:00Z", "2026-07-20T10:59:00.000+03:00", "2026-99-99T07:59:00.000Z", "not-a-time"])(
    "rejects non-canonical timestamp", (timestamp) => {
      expect(() => parser("[data-avelren-time]").parse(Buffer.from(
        `<i data-avelren-count>50</i><time data-avelren-time>${timestamp}</time>`,
      ), trusted)).toThrow("External source response could not be parsed");
    },
  );
  it("does not execute scripts", () => {
    delete (globalThis as { unsafeMarker?: boolean }).unsafeMarker;
    expect(parser().parse(Buffer.from(
      '<script>globalThis.unsafeMarker=true</script><i data-avelren-count>5</i>',
    ), trusted).vehicleCount).toBe(5);
    expect((globalThis as { unsafeMarker?: boolean }).unsafeMarker).toBeUndefined();
  });
});

function parser(observedAtSelector?: string): HtmlObservationParser {
  return new HtmlObservationParser({ locationId: "location-placeholder", countSelector: "[data-avelren-count]", ...(observedAtSelector ? { observedAtSelector } : {}) });
}
