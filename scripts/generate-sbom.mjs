#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const evidenceDir = resolve(root, "sbom", "evidence");

function protocolPackages() {
  const lines = readFileSync(resolve(root, "protocol", "pnpm-lock.yaml"), "utf8").split(/\r?\n/u);
  const packages = [];
  let inside = false;
  for (const line of lines) {
    if (line === "packages:") { inside = true; continue; }
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
  const scopes = new Map([
    ["android-debug-runtime.txt", "runtime"],
    ["android-debug-unit-test.txt", "test"],
    ["android-build-classpath.txt", "build"],
  ]);
  const packages = new Map();
  for (const [file, scope] of scopes) {
    for (const coordinate of readFileSync(resolve(evidenceDir, file), "utf8").split(/\r?\n/u).filter(Boolean)) {
      const first = coordinate.indexOf(":");
      const second = coordinate.indexOf(":", first + 1);
      const group = coordinate.slice(0, first);
      const name = coordinate.slice(first + 1, second);
      const version = coordinate.slice(second + 1);
      const key = `${group}:${name}:${version}`;
      const current = packages.get(key) || { ecosystem: "maven", group, name, version, scopes: [] };
      if (!current.scopes.includes(scope)) current.scopes.push(scope);
      packages.set(key, current);
    }
  }
  return [...packages.values()];
}

const iosPackages = JSON.parse(readFileSync(resolve(evidenceDir, "ios-swiftpm.json"), "utf8"));
const components = [...protocolPackages(), ...androidPackages(), ...iosPackages];
const evidence = JSON.parse(readFileSync(resolve(evidenceDir, "license-evidence.json"), "utf8"));
const evidenceMap = new Map(evidence.map((item) => [`${item.ecosystem}:${item.group || ""}:${item.name}:${item.version}`, item]));

function identifier(component) {
  return `SPDXRef-Package-${createHash("sha256").update(`${component.ecosystem}:${component.group || ""}:${component.name}:${component.version}`).digest("hex").slice(0, 20)}`;
}

function purl(component) {
  if (component.ecosystem === "npm") return `pkg:npm/${encodeURIComponent(component.name).replaceAll("%2F", "/")}@${component.version}`;
  if (component.ecosystem === "maven") return `pkg:maven/${component.group}/${component.name}@${component.version}`;
  return `pkg:swift/${component.name}@${component.version}`;
}

const packageEntries = components.map((component) => {
  const license = evidenceMap.get(`${component.ecosystem}:${component.group || ""}:${component.name}:${component.version}`) || {};
  return {
    name: component.group ? `${component.group}:${component.name}` : component.name,
    SPDXID: identifier(component),
    versionInfo: component.version,
    downloadLocation: component.sourceUrl || license.sourceUrl || license.evidenceUrl || "NOASSERTION",
    filesAnalyzed: false,
    licenseConcluded: "NOASSERTION",
    licenseDeclared: license.licenseDeclared || component.licenseDeclared || "NOASSERTION",
    copyrightText: "NOASSERTION",
    supplier: "NOASSERTION",
    sourceInfo: `ecosystem=${component.ecosystem}; scope=${component.scopes?.join(",") || "resolved"}; evidence=${license.evidenceStatus || "curated exact-version metadata"}`,
    externalRefs: [{ referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: purl(component) }],
  };
});

const keyDigest = createHash("sha256")
  .update(packageEntries.map((item) => `${item.name}@${item.versionInfo}`).sort().join("\n"))
  .digest("hex");
const rootId = "SPDXRef-Package-KOEON-Client";
const document = {
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: "KOEON Client A6 public-release candidate",
  documentNamespace: `https://koeon.example.invalid/spdx/koeon-client/${keyDigest}`,
  creationInfo: {
    created: "2026-08-25T00:00:00Z",
    creators: ["Tool: koeon-client/scripts/generate-sbom.mjs", "Organization: KOEON (pre-publication staging)"],
  },
  documentDescribes: [rootId],
  packages: [
    {
      name: "koeon-client",
      SPDXID: rootId,
      versionInfo: "0.1-pre-publication",
      downloadLocation: "NOASSERTION",
      filesAnalyzed: false,
      licenseConcluded: "NOASSERTION",
      licenseDeclared: "MPL-2.0",
      copyrightText: "NOASSERTION",
      supplier: "NOASSERTION",
    },
    ...packageEntries,
  ],
  relationships: packageEntries.map((item) => ({
    spdxElementId: rootId,
    relationshipType: "DEPENDS_ON",
    relatedSpdxElement: item.SPDXID,
    comment: "Resolved component. Exact transitive edge topology remains available from the source lockfile/Gradle evidence; this SBOM conservatively relates each resolved component to the candidate root.",
  })),
};

mkdirSync(resolve(root, "sbom"), { recursive: true });
writeFileSync(resolve(root, "sbom", "koeon-client.spdx.json"), `${JSON.stringify(document, null, 2)}\n`, "utf8");
console.log(`SBOM_COMPONENTS=${packageEntries.length}`);
console.log(`SBOM_PROTOCOL_COMPONENTS=${components.filter((item) => item.ecosystem === "npm").length}`);
console.log(`SBOM_ANDROID_COMPONENTS=${components.filter((item) => item.ecosystem === "maven").length}`);
console.log(`SBOM_IOS_COMPONENTS=${components.filter((item) => item.ecosystem === "swift").length}`);
console.log(`SBOM_NOASSERTION_LICENSES=${packageEntries.filter((item) => item.licenseDeclared === "NOASSERTION").length}`);
