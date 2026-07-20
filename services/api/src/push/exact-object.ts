export class PayloadValidationError extends Error {
  constructor() {
    super("Invalid request payload");
    this.name = "PayloadValidationError";
  }
}

export function readExactObject(
  value: unknown,
  requiredFields: readonly string[],
): Readonly<Record<string, unknown>> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new PayloadValidationError();
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype) {
    throw new PayloadValidationError();
  }
  const keys = Reflect.ownKeys(value);
  if (keys.length !== requiredFields.length || keys.some(
    (key) => typeof key !== "string" || !requiredFields.includes(key),
  )) {
    throw new PayloadValidationError();
  }
  for (const field of requiredFields) {
    const descriptor = Object.getOwnPropertyDescriptor(value, field);
    if (descriptor === undefined || !("value" in descriptor)) {
      throw new PayloadValidationError();
    }
  }
  return value as Readonly<Record<string, unknown>>;
}
