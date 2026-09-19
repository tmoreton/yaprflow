const COOKIE_MAX_AGE = 30 * 24 * 60 * 60;
const SECURE_COOKIE = '__Host-yaprflow-purchase';
const LOCAL_COOKIE = 'yaprflow-purchase-dev';

function validSessionId(value, mode) {
  return (mode === 'test' || mode === 'live') && typeof value === 'string' &&
    /^cs_(?:test|live)_[A-Za-z0-9]{10,}$/.test(value) && value.startsWith(`cs_${mode}_`);
}

function cookieSettings(request, environment) {
  const url = new URL(request.url);
  if (url.protocol === 'https:') return { name: SECURE_COOKIE, secure: true };
  if (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) &&
      ['development', 'test'].includes(environment.NODE_ENV) && environment.VERCEL_ENV !== 'production') {
    return { name: LOCAL_COOKIE, secure: false };
  }
  return null;
}

export function purchaseCookieHeader(request, sessionId, mode, environment = process.env) {
  const settings = cookieSettings(request, environment);
  if (!settings || !validSessionId(sessionId, mode)) return null;
  return `${settings.name}=${encodeURIComponent(sessionId)}; Path=/; Max-Age=${COOKIE_MAX_AGE}; HttpOnly; SameSite=Lax${settings.secure ? '; Secure' : ''}`;
}

export function requestedPurchaseSessionId(request, mode, environment = process.env) {
  const params = new URL(request.url).searchParams;
  if (params.has('session_id')) {
    const values = params.getAll('session_id');
    // An explicit invalid query must not silently authenticate with an old purchase cookie.
    return values.length === 1 && validSessionId(values[0], mode) ? values[0] : null;
  }
  const settings = cookieSettings(request, environment);
  if (!settings) return null;
  const values = (request.headers.get('Cookie') || '').split(';')
    .map((part) => part.trim()).filter((part) => part.startsWith(`${settings.name}=`));
  if (values.length !== 1) return null;
  try {
    const value = decodeURIComponent(values[0].slice(settings.name.length + 1));
    return validSessionId(value, mode) ? value : null;
  } catch {
    return null;
  }
}
