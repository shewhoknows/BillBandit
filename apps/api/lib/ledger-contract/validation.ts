export class LedgerContractValidationError extends Error {
  constructor(
    public readonly path: string,
    message: string
  ) {
    super(`${path}: ${message}`)
    this.name = 'LedgerContractValidationError'
  }
}

