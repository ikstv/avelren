export interface SourceClient<T> {
  fetch(signal: AbortSignal): Promise<T>;
}
