const failure = message => Object.assign(new Error(message), { userMessage: message });

export async function request(url, options = {}) {
  let response;
  try {
    // Caller-supplied headers also keep Herdr fetch from following cross-origin redirects.
    response = await fetch(url, { ...options, headers: { accept: "application/json", ...options.headers } });
  } catch {
    throw failure("Couldn't reach sympp. Check the connection and retry.");
  }
  if (response.redirected || response.url !== url) {
    throw Object.assign(failure("sympp redirected the request. Check the local sympp connection."), { status: response.status });
  }
  return response;
}

export async function remoteAuthorization(endpoint, loadConfig) {
  const config = await loadConfig();
  if (config.endpoint !== endpoint) throw failure("sympp server changed. Reinstall the panel connection.");
  return config.token ? `Bearer ${config.token}` : null;
}

// Bind authentication to one configured origin and, for a board action, the credentials that read it.
export function remoteRequest(endpoint, loadConfig, boardAuthorization) {
  return async (url, options = {}) => {
    if (new URL(url).origin !== endpoint) throw failure("sympp request does not match the configured server.");
    const expected = boardAuthorization?.();
    const authorization = await remoteAuthorization(endpoint, loadConfig);
    if (boardAuthorization && expected !== authorization) throw failure("Refresh the board before trying again.");
    return request(url, { ...options, headers: { ...options.headers, ...(authorization ? { Authorization: authorization } : {}) } });
  };
}
