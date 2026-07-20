export interface CycleLease {
  runIfAcquired(
    action: (leaseSignal: AbortSignal) => Promise<void>,
  ): Promise<boolean>;
}
