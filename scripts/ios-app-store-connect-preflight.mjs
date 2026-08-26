#!/usr/bin/env node

import { createPrivateKey, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const APPLE_API = "https://api.appstoreconnect.apple.com";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

export function createAppleToken(keyId, issuerId, privateKey, now = Math.floor(Date.now() / 1000)) {
  const key = createPrivateKey(privateKey);
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("IOS_APP private key must be an EC P-256 App Store Connect key");
  }
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = base64url(JSON.stringify({ iss: issuerId, iat: now, exp: now + 900, aud: "appstoreconnect-v1" }));
  const input = `${header}.${payload}`;
  const signature = sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${input}.${signature}`;
}

async function appleGet(path, token, fetchImpl = fetch) {
  const response = await fetchImpl(`${APPLE_API}${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`App Store Connect API returned HTTP ${response.status}`);
  return response.json();
}

export async function verifyBuildNumberAvailable(config, fetchImpl = fetch) {
  const privateKey = await readFile(resolve(config.credentialDir, "AuthKey.p8"), "utf8");
  const keyId = (await readFile(resolve(config.credentialDir, "key-id"), "utf8")).trim();
  const issuerId = (await readFile(resolve(config.credentialDir, "issuer-id"), "utf8")).trim();
  const token = createAppleToken(keyId, issuerId, privateKey);
  const apps = await appleGet(`/v1/apps?filter%5BbundleId%5D=${encodeURIComponent(config.bundleId)}&limit=1`, token, fetchImpl);
  const app = apps.data?.[0];
  if (!app) throw new Error("App Store Connect app was not found");
  const versions = await appleGet(`/v1/preReleaseVersions?filter%5Bapp%5D=${encodeURIComponent(app.id)}&filter%5Bversion%5D=${encodeURIComponent(config.marketingVersion)}&limit=1`, token, fetchImpl);
  const version = versions.data?.[0];
  if (!version) return;
  const builds = await appleGet(`/v1/builds?filter%5Bapp%5D=${encodeURIComponent(app.id)}&filter%5BpreReleaseVersion%5D=${encodeURIComponent(version.id)}&filter%5Bversion%5D=${encodeURIComponent(config.buildNumber)}&limit=1`, token, fetchImpl);
  if ((builds.data ?? []).length) throw new Error("Requested version/build already exists in App Store Connect");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await verifyBuildNumberAvailable({
      credentialDir: process.env.IOS_CREDENTIAL_DIR,
      bundleId: process.env.KOEON_BUNDLE_ID,
      marketingVersion: process.env.MARKETING_VERSION,
      buildNumber: process.env.BUILD_NUMBER,
    });
    console.log("APPLE_AUTHENTICATION=PASS");
    console.log("BUILD_NUMBER_AVAILABLE=PASS");
  } catch (error) {
    console.error(`App Store Connect preflight failed: ${error.message}`);
    process.exitCode = 1;
  }
}
