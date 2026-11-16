// Keycraft licence keys: "KC1.<payload>.<signature>", both parts base64url.
// payload = JSON {p: product, t: Paddle transaction id, e: email, i: issue date}
// signature = Ed25519 over the ASCII text "KC1.<payload>" (so the JSON never needs re-encoding).
// The website's licence endpoint (thistleware repo, functions/api/keycraft-licence.js) signs the same way.
//
//   node Scripts/licence.mjs keygen <private-key-file>   new key pair; prints the public key only
//   node Scripts/licence.mjs vectors                     test vectors for Tests/.../LicenseTests.swift
import { webcrypto as crypto } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const b64url = bytes => Buffer.from(bytes).toString('base64url');
const PKCS8_ED25519 = Buffer.from('302e020100300506032b657004220420', 'hex'); // DER prefix before a 32-byte seed

export async function sign(payload, privateKey) {
  const head = 'KC1.' + b64url(Buffer.from(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign('Ed25519', privateKey, Buffer.from(head, 'ascii'));
  return head + '.' + b64url(sig);
}

const importSeed = seed => crypto.subtle.importKey('pkcs8', Buffer.concat([PKCS8_ED25519, seed]), 'Ed25519', true, ['sign']);
const publicRaw = async priv => {
  const jwk = await crypto.subtle.exportKey('jwk', priv);   // jwk.x is the raw public key, base64url
  return jwk.x;
};

const [cmd, arg] = process.argv.slice(2);
if (cmd === 'keygen') {
  if (!arg) throw new Error('usage: keygen <private-key-file>');
  const seed = crypto.getRandomValues(new Uint8Array(32));
  writeFileSync(arg, Buffer.concat([PKCS8_ED25519, seed]).toString('base64') + '\n', { mode: 0o600, flag: 'wx' });
  console.log('public key (base64url):', await publicRaw(await importSeed(Buffer.from(seed))));
} else if (cmd === 'vectors') {
  // Fixed TEST seed: these keys only ever sign test data.
  const priv = await importSeed(Buffer.alloc(32, 7));
  const other = await importSeed(Buffer.alloc(32, 9));
  const good = { p: 'keycraft', t: 'txn_01testtesttesttesttesttest', e: 'buyer@example.com', i: '2026-11-16' };
  const out = {
    testPublicKey: await publicRaw(priv),
    valid: await sign(good, priv),
    wrongProduct: await sign({ ...good, p: 'reel' }, priv),
    otherSigner: await sign(good, other),
  };
  console.log(JSON.stringify(out, null, 2));
} else {
  console.log('usage: node Scripts/licence.mjs keygen <file> | vectors');
}
