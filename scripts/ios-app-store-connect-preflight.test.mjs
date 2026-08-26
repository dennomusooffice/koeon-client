import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import { createAppleToken } from "./ios-app-store-connect-preflight.mjs";

test("creates a bounded three-part ES256 token from a P-256 key", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const token = createAppleToken(
    "KEYID",
    "11111111-1111-1111-1111-111111111111",
    privateKey.export({ type: "pkcs8", format: "pem" }),
    1_700_000_000,
  );
  assert.equal(token.split(".").length, 3);
});

test("rejects a non-Apple EC curve", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "secp384r1" });
  assert.throws(() => createAppleToken(
    "KEYID",
    "11111111-1111-1111-1111-111111111111",
    privateKey.export({ type: "pkcs8", format: "pem" }),
  ));
});
