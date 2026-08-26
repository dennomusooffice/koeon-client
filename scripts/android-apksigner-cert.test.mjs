import assert from "node:assert/strict";
import test from "node:test";

import { parseSignerCertificateSha256 } from "./android-apksigner-cert.mjs";

const compact = "0123456789abcdef".repeat(4);
const colonSeparated = compact.match(/../gu).join(":").toUpperCase();
const spaceSeparated = compact.match(/../gu).join(" ");

test("parses compact apksigner SHA-256 output", () => {
  assert.equal(parseSignerCertificateSha256(
    `Number of signers: 1\nSigner #1 certificate SHA-256 digest: ${compact}\n`,
  ), compact);
});

test("parses separated digest and ignores trailing diagnostic text", () => {
  assert.equal(parseSignerCertificateSha256(
    `Signer #1 certificate SHA-256 digest: ${colonSeparated} (verified)\n`,
  ), compact);
  assert.equal(parseSignerCertificateSha256(
    `Signer #1 certificate SHA-256 digest = ${spaceSeparated}\n`,
  ), compact);
});

test("rejects malformed or missing certificate digest", () => {
  assert.throws(() => parseSignerCertificateSha256("Number of signers: 1\n"), /APK_SIGNER_CERT_FORMAT=FAIL/u);
  assert.throws(() => parseSignerCertificateSha256(
    `Signer #1 certificate SHA-256 digest: ${compact.slice(2)}\n`,
  ), /APK_SIGNER_CERT_FORMAT=FAIL/u);
});
