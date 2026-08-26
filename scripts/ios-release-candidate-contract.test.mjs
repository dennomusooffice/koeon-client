import assert from "node:assert/strict";
import test from "node:test";
import {
  parseXcodeBuildSettings,
  validateReleaseBuildSettings,
  validateRuntimeEndpoint,
} from "./ios-release-candidate-contract.mjs";

test("accepts a credential-free HTTPS runtime endpoint", () => {
  assert.doesNotThrow(() => validateRuntimeEndpoint("https://api.example.test"));
});

test("rejects missing, placeholder, non-HTTPS, and secret-bearing URLs", () => {
  for (const value of ["", "https://example.invalid", "http://api.example.test", "https://u:p@api.example.test", "https://api.example.test?q=x", "https://api.example.test/#x"]) {
    assert.throws(() => validateRuntimeEndpoint(value), value);
  }
});

test("parses robust xcodebuild settings without failing on empty or diagnostic lines", () => {
  const text = [
    "Build settings for action build and target KOEON:",
    "    = ",
    "    PRODUCT_BUNDLE_IDENTIFIER = com.example.koeon",
    "    CODE_SIGN_ENTITLEMENTS = /tmp/KOEON.Release.entitlements",
    "    KOEON_API_BASE_URL = https://api.example.test",
  ].join("\n");
  const parsed = parseXcodeBuildSettings(text);
  assert.equal(parsed.size, 3);
  assert.doesNotThrow(() => validateReleaseBuildSettings(text, {
    PRODUCT_BUNDLE_IDENTIFIER: "com.example.koeon",
    CODE_SIGN_ENTITLEMENTS: "/tmp/KOEON.Release.entitlements",
    KOEON_API_BASE_URL: "https://api.example.test",
  }));
  assert.throws(() => validateReleaseBuildSettings(text, { DEVELOPMENT_TEAM: "TEAM" }));
});
