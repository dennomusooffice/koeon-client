#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const evidenceDir = resolve(root, "sbom", "evidence");
mkdirSync(evidenceDir, { recursive: true });

function protocolPackages() {
  const lines = readFileSync(resolve(root, "protocol", "pnpm-lock.yaml"), "utf8").split(/\r?\n/u);
  const packages = [];
  let inside = false;
  for (const line of lines) {
    if (line === "packages:") {
      inside = true;
      continue;
    }
    if (line === "snapshots:") break;
    if (!inside) continue;
    const match = line.match(/^  ([^ ].+):$/u);
    if (!match) continue;
    const key = match[1].replace(/^'|'$/gu, "");
    const separator = key.lastIndexOf("@");
    if (separator > 0) packages.push({ ecosystem: "npm", name: key.slice(0, separator), version: key.slice(separator + 1) });
  }
  return packages;
}

function androidPackages() {
  const names = ["android-debug-runtime.txt", "android-debug-unit-test.txt", "android-build-classpath.txt"];
  const packages = new Map();
  for (const file of names) {
    for (const coordinate of readFileSync(resolve(evidenceDir, file), "utf8").split(/\r?\n/u).filter(Boolean)) {
      const first = coordinate.indexOf(":");
      const second = coordinate.indexOf(":", first + 1);
      if (first < 1 || second < 0) continue;
      const item = {
        ecosystem: "maven",
        group: coordinate.slice(0, first),
        name: coordinate.slice(first + 1, second),
        version: coordinate.slice(second + 1),
      };
      packages.set(`${item.group}:${item.name}:${item.version}`, item);
    }
  }
  return [...packages.values()];
}

function decodeXml(value = "") {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .trim();
}

function element(xml, name) {
  return decodeXml(xml.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${name}>`, "iu"))?.[1]);
}

function mapLicense(name, url) {
  const value = `${name} ${url}`.toLowerCase();
  if (/apache(?: software)?(?: license)?(?:, version)?\s*v?2(?:\.0)?|apache\.org\/licenses\/license-2\.0/u.test(value)) return "Apache-2.0";
  if (/\bmit\b|opensource\.org\/licenses\/mit/u.test(value)) return "MIT";
  if (/eclipse public license.*1(?:\.0)?|eclipse\.org\/legal\/epl-v10/u.test(value)) return "EPL-1.0";
  if (/eclipse public license.*2(?:\.0)?|eclipse\.org\/legal\/epl-2\.0/u.test(value)) return "EPL-2.0";
  if (/eclipse distribution license.*1(?:\.0)?/u.test(value)) return "EDL-1.0";
  if (/bsd.*3|bsd-3-clause/u.test(value)) return "BSD-3-Clause";
  if (/isc license|opensource\.org\/licenses\/isc/u.test(value)) return "ISC";
  if (/mozilla public license.*2(?:\.0)?|mozilla\.org\/mpl\/2\.0/u.test(value)) return "MPL-2.0";
  if (/mozilla public license.*1\.1|mpl 1\.1/u.test(value)) return "MPL-1.1";
  if (/lgpl,? version 2\.1/u.test(value)) return "LGPL-2.1-only";
  return "NOASSERTION";
}

async function fetchText(url) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(20000), headers: { "user-agent": "koeon-a6-license-evidence" } });
    if (!response.ok) return null;
    return await response.text();
  } catch {
    return null;
  }
}

async function npmEvidence(item) {
  const url = `https://registry.npmjs.org/${encodeURIComponent(item.name)}/${encodeURIComponent(item.version)}`;
  const text = await fetchText(url);
  if (!text) return { ...item, licenseDeclared: "NOASSERTION", evidenceStatus: "UNAVAILABLE", evidenceUrl: url };
  const metadata = JSON.parse(text);
  const rawLicense = typeof metadata.license === "string" ? metadata.license : metadata.license?.type || "";
  const declared = /^[A-Za-z0-9-.+]+$/u.test(rawLicense) ? rawLicense : mapLicense(rawLicense, "");
  const repository = typeof metadata.repository === "string" ? metadata.repository : metadata.repository?.url;
  return {
    ...item,
    licenseDeclared: declared || "NOASSERTION",
    rawLicense: rawLicense || null,
    sourceUrl: repository || metadata.homepage || null,
    evidenceStatus: "REGISTRY_METADATA",
    evidenceUrl: url,
  };
}

async function mavenEvidence(item) {
  const relative = `${item.group.replaceAll(".", "/")}/${item.name}/${item.version}/${item.name}-${item.version}.pom`;
  const candidates = [
    `https://dl.google.com/dl/android/maven2/${relative}`,
    `https://repo1.maven.org/maven2/${relative}`,
    `https://jitpack.io/${relative}`,
  ];
  for (const url of candidates) {
    const xml = await fetchText(url);
    if (!xml) continue;
    const licenseBlock = xml.match(/<license(?:\s[^>]*)?>([\s\S]*?)<\/license>/iu)?.[1] || "";
    const rawLicense = element(licenseBlock, "name");
    const licenseUrl = element(licenseBlock, "url");
    const projectUrl = element(xml, "url");
    return {
      ...item,
      licenseDeclared: mapLicense(rawLicense, licenseUrl),
      rawLicense: rawLicense || null,
      licenseUrl: licenseUrl || null,
      sourceUrl: projectUrl || null,
      evidenceStatus: licenseBlock ? "POM_LICENSE_METADATA" : "POM_NO_LICENSE_METADATA",
      evidenceUrl: url,
    };
  }
  return { ...item, licenseDeclared: "NOASSERTION", evidenceStatus: "POM_UNAVAILABLE", evidenceUrl: null };
}

async function mapConcurrent(items, limit, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  async function run() {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await worker(items[index]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
  return results;
}

const ios = JSON.parse(readFileSync(resolve(evidenceDir, "ios-swiftpm.json"), "utf8"));
const npm = await mapConcurrent(protocolPackages(), 12, npmEvidence);
const maven = await mapConcurrent(androidPackages(), 16, mavenEvidence);
const all = [...npm, ...maven, ...ios].sort((a, b) =>
  `${a.ecosystem}:${a.group || ""}:${a.name}:${a.version}`.localeCompare(`${b.ecosystem}:${b.group || ""}:${b.name}:${b.version}`),
);

writeFileSync(resolve(evidenceDir, "license-evidence.json"), `${JSON.stringify(all, null, 2)}\n`, "utf8");
const noAssertion = all.filter((item) => item.licenseDeclared === "NOASSERTION").length;
console.log(`LICENSE_EVIDENCE_COMPONENTS=${all.length}`);
console.log(`LICENSE_NOASSERTION=${noAssertion}`);
