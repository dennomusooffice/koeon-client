#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const LABEL = "certificate SHA-256 digest";
const BYTE_SEQUENCE = /(?<![0-9a-f])((?:[0-9a-f]{2}(?:[\s:-]?)){31}[0-9a-f]{2})(?![0-9a-f])/iu;

export function parseSignerCertificateSha256(report) {
  for (const line of report.split(/\r?\n/u)) {
    const labelIndex = line.indexOf(LABEL);
    if (labelIndex < 0) continue;
    const match = line.slice(labelIndex + LABEL.length).match(BYTE_SEQUENCE);
    if (!match) continue;
    const normalized = match[1].toLowerCase().replace(/[^0-9a-f]/gu, "");
    if (/^[0-9a-f]{64}$/u.test(normalized)) return normalized;
  }
  throw new Error("APK_SIGNER_CERT_FORMAT=FAIL");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const reportPath = process.argv[2];
    if (!reportPath) throw new Error("APK_SIGNER_CERT_FORMAT=FAIL");
    process.stdout.write(`${parseSignerCertificateSha256(await readFile(reportPath, "utf8"))}\n`);
  } catch {
    console.error("APK_SIGNER_CERT_FORMAT=FAIL");
    process.exitCode = 1;
  }
}
