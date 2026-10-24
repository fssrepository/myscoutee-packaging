// Assertions shared by the release-packaged deployment verifier.
export class SmokeAssertionError extends Error {
  constructor(message, details = undefined) {
    super(message);
    this.name = 'SmokeAssertionError';
    this.details = details;
  }
}

export function assert(condition, message, details = undefined) {
  if (!condition) {
    throw new SmokeAssertionError(message, details);
  }
}

export function expectStatus(result, expected, label = result.requestUrl) {
  const allowed = Array.isArray(expected) ? expected : [expected];
  assert(
    allowed.includes(result.status),
    `${label} expected HTTP ${allowed.join(' or ')}, got ${result.status}`,
    responseDetails(result)
  );
}

export function expectContentType(result, expected, label = result.requestUrl) {
  const values = Array.isArray(expected) ? expected : [expected];
  const contentType = `${result.headers['content-type'] ?? ''}`.toLowerCase();
  assert(
    values.some(value => contentType.includes(value.toLowerCase())),
    `${label} returned unexpected content-type ${contentType || '(missing)'}`,
    responseDetails(result)
  );
}

export function expectObject(value, label) {
  assert(isObject(value), `${label} should be an object`, { value });
  return value;
}

export function expectArray(value, label) {
  assert(Array.isArray(value), `${label} should be an array`, { value });
  return value;
}

export function expectString(value, label, options = {}) {
  assert(typeof value === 'string', `${label} should be a string`, { value });
  if (!options.allowEmpty) {
    assert(value.trim().length > 0, `${label} should not be empty`, { value });
  }
  return value;
}

export function expectInteger(value, label, options = {}) {
  assert(Number.isInteger(value), `${label} should be an integer`, { value });
  if (options.min !== undefined) {
    assert(value >= options.min, `${label} should be at least ${options.min}`, { value });
  }
  return value;
}

export function expectJson(result, label = result.requestUrl) {
  assert(
    result.jsonError === null,
    `${label} did not return valid JSON: ${result.jsonError?.message}`,
    responseDetails(result)
  );
  assert(result.data !== undefined, `${label} returned no JSON body`, responseDetails(result));
  return result.data;
}

export function expectSameHostname(left, right, label) {
  const leftUrl = left instanceof URL ? left : new URL(left);
  const rightUrl = right instanceof URL ? right : new URL(right);
  assert(
    leftUrl.hostname.toLowerCase() === rightUrl.hostname.toLowerCase(),
    `${label} changed hostname from ${leftUrl.hostname} to ${rightUrl.hostname}`
  );
}

export function responseDetails(result) {
  return {
    requestUrl: result.requestUrl,
    responseUrl: result.responseUrl,
    status: result.status,
    contentType: result.headers['content-type'] ?? '',
    body: compactSnippet(result.text)
  };
}

export function compactSnippet(value, maxLength = 320) {
  const text = `${value ?? ''}`.replace(/\s+/g, ' ').trim();
  return text.length <= maxLength ? text : `${text.slice(0, maxLength)}…`;
}

export function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
