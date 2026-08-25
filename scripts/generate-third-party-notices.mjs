#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const evidence = JSON.parse(readFileSync(resolve(root, "sbom", "evidence", "license-evidence.json"), "utf8"));

function coordinate(item) {
  return item.group ? `${item.group}:${item.name}` : item.name;
}

function classification(item) {
  if (item.licenseDeclared === "NOASSERTION") {
    return /ML Kit Terms|Android Software Development Kit License/iu.test(item.rawLicense || "")
      ? "LEGAL_REVIEW_REQUIRED"
      : "UNKNOWN";
  }
  if (["EPL-1.0", "EDL-1.0", "LGPL-2.1-only", "MPL-1.1"].includes(item.licenseDeclared)) {
    return "LEGAL_REVIEW_REQUIRED";
  }
  return "TECHNICALLY_COMPATIBLE_CANDIDATE";
}

function cell(value) {
  return String(value || "—").replaceAll("|", "\\|").replaceAll("\n", " ");
}

const counts = new Map();
for (const item of evidence) counts.set(item.licenseDeclared, (counts.get(item.licenseDeclared) || 0) + 1);
const noAssertion = evidence.filter((item) => item.licenseDeclared === "NOASSERTION").length;
const legalReview = evidence.filter((item) => classification(item) === "LEGAL_REVIEW_REQUIRED").length;
const unknown = evidence.filter((item) => classification(item) === "UNKNOWN").length;

const lines = [
  "# Third-Party Notices — technical A6 evidence",
  "",
  "> This inventory is generated from exact lock/Gradle/SwiftPM evidence. It is not legal advice or a final license-compatibility decision. Component license text, copyright notices, binary redistribution duties, Google service terms, and reciprocal-license obligations require Human/counsel review before publication.",
  "",
  "```text",
  `COMPONENTS = ${evidence.length}`,
  `NOASSERTION = ${noAssertion}`,
  `LEGAL_REVIEW_REQUIRED = ${legalReview}`,
  `UNKNOWN = ${unknown}`,
  "BLOCK_PUBLICATION = 0 (technical audit found no clear blocker; this is not legal approval)",
  "```",
  "",
  "## License metadata summary",
  "",
  "| Declared license metadata | Components |",
  "|---|---:|",
  ...[...counts.entries()].sort((a, b) => b[1] - a[1]).map(([license, count]) => `| ${cell(license)} | ${count} |`),
  "",
  "## Exact component inventory",
  "",
  "The authoritative machine-readable inventory is `sbom/koeon-client.spdx.json`; raw exact-version evidence is `sbom/evidence/license-evidence.json`.",
  "",
  "| Ecosystem | Component | Version | Declared license | Raw metadata | Review classification | Evidence |",
  "|---|---|---|---|---|---|---|",
  ...evidence.map((item) => {
    const url = item.licenseUrl || item.licenseEvidenceUrl || item.evidenceUrl || item.sourceUrl;
    const link = url ? `[source](${url})` : "—";
    return `| ${cell(item.ecosystem)} | ${cell(coordinate(item))} | ${cell(item.version)} | ${cell(item.licenseDeclared)} | ${cell(item.rawLicense)} | ${classification(item)} | ${link} |`;
  }),
  "",
  "## Notice handling",
  "",
  "- `NOASSERTION` means exact component presence/version is known but the collector did not obtain unambiguous SPDX license metadata; no license was guessed.",
  "- Google ML Kit/Android SDK terms are recorded as legal review items, not treated as open-source license grants.",
  "- Runtime, test, and build-tool components are retained with scope evidence; counsel may determine which notices must ship in source and binary distributions.",
  "- License conclusions remain `NOASSERTION` in SPDX even when declared-license metadata exists.",
  "- Full upstream license/copyright text must be checked at the linked exact-version source before A7 approval.",
  "",
];

writeFileSync(resolve(root, "THIRD_PARTY_NOTICES.md"), `${lines.join("\n")}\n`, "utf8");
console.log(`THIRD_PARTY_NOTICE_COMPONENTS=${evidence.length}`);
console.log(`THIRD_PARTY_NOTICE_NOASSERTION=${noAssertion}`);
console.log(`THIRD_PARTY_NOTICE_LEGAL_REVIEW_REQUIRED=${legalReview}`);
console.log(`THIRD_PARTY_NOTICE_UNKNOWN=${unknown}`);

