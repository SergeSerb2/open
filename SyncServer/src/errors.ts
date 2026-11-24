export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly headers: Record<string, string>;

  constructor(status: number, code: string, message: string, headers: Record<string, string> = {}) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

export function validationError(message: string): ApiError {
  return new ApiError(400, "VALIDATION_ERROR", message);
}

export function unauthorized(message = "Missing or invalid access token."): ApiError {
  return new ApiError(401, "UNAUTHORIZED", message);
}
