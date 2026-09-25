const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseServerURL } = require('./url');

test('accepts HTTPS and private LAN HTTP', () => {
  assert.equal(parseServerURL('https://share.denby.dev/'), 'https://share.denby.dev');
  assert.equal(parseServerURL('http://192.168.1.2:8080'), 'http://192.168.1.2:8080');
});

test('rejects insecure public and credential URLs', () => {
  for (const value of ['http://example.com', 'https://user:pass@example.com', 'https://example.com/private', 'javascript:alert(1)']) {
    assert.throws(() => parseServerURL(value));
  }
});
