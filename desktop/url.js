function privateHost(hostname) {
  if (hostname === 'localhost' || hostname.endsWith('.local')) return true;
  const parts = hostname.split('.').map(Number);
  if (parts.length !== 4 || parts.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  return parts[0] === 10 || parts[0] === 127 ||
    (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168);
}

function parseServerURL(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('Enter a complete server URL.'); }
  if (url.username || url.password || url.search || url.hash || (url.pathname !== '/' && url.pathname !== '')) {
    throw new Error('Use the server origin only, without a path or credentials.');
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && privateHost(url.hostname))) {
    throw new Error('Use HTTPS, or HTTP only on a private local network.');
  }
  return url.origin;
}

module.exports = { parseServerURL, privateHost };
