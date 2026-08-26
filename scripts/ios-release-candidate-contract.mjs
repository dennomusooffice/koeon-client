#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export function validateRuntimeEndpoint(value) {
  const trimmed = value?.trim() ?? "";
  let endpoint;
  try {
    endpoint = new URL(trimmed);
  } catch {
    throw new Error("KOEON_API_BASE_URL must be a valid absolute URL");
  }
  if (endpoint.protocol !== "https:" || !endpoint.hostname) throw new Error("KOEON_API_BASE_URL must use HTTPS and include a host");
  if (endpoint.hostname === "example.invalid") throw new Error("KOEON_API_BASE_URL must not use the Public-safe placeholder");
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error("KOEON_API_BASE_URL must not contain credentials, query, or fragment data");
  }
}

export function parseXcodeBuildSettings(contents) {
  const settings = new Map();
  for (const raw of contents.split(/\r?\n/u)) {
    const line = raw.trim();
    const separator = line.indexOf(" = ");
    if (separator <= 0) continue;
    const name = line.slice(0, separator).trim();
    if (name) settings.set(name, line.slice(separator + 3));
  }
  return settings;
}

export function validateReleaseBuildSettings(contents, expected) {
  const settings = parseXcodeBuildSettings(contents);
  const failed = Object.entries(expected)
    .filter(([name, value]) => settings.get(name) !== value)
    .map(([name]) => name);
  if (failed.length) throw new Error(`Effective Release build setting validation failed: ${failed.join(", ")}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    validateRuntimeEndpoint(process.env.KOEON_API_BASE_URL);
    if (process.argv.includes("--validate-release-settings")) {
      validateReleaseBuildSettings(readFileSync(process.env.RELEASE_SETTINGS, "utf8"), {
        PRODUCT_BUNDLE_IDENTIFIER: process.env.KOEON_BUNDLE_ID,
        DEVELOPMENT_TEAM: process.env.APPLE_TEAM_ID,
        CODE_SIGN_ENTITLEMENTS: process.env.GENERATED_RELEASE_ENTITLEMENTS,
        KOEON_API_BASE_URL: process.env.KOEON_API_BASE_URL,
        MARKETING_VERSION: process.env.MARKETING_VERSION,
        CURRENT_PROJECT_VERSION: process.env.BUILD_NUMBER,
      });
      console.log("RELEASE_BUILD_SETTINGS=PASS");
    }
    console.log("RUNTIME_ENDPOINT_CONFIGURED=YES");
    console.log("EFFECTIVE_EXAMPLE_INVALID=NO");
  } catch (error) {
    console.error(`Release candidate contract failed: ${error.message}`);
    process.exitCode = 1;
  }
}
