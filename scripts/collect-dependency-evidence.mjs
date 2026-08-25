#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const evidenceDir = resolve(root, "sbom", "evidence");
mkdirSync(evidenceDir, { recursive: true });

function runGradle(args) {
  const wrapper = resolve(root, "android", process.platform === "win32" ? "gradlew.bat" : "gradlew");
  const gradleArgs = ["-p", "android", ...args, "--no-daemon"];
  if (gradleArgs.some((argument) => !/^[A-Za-z0-9:._-]+$/u.test(argument))) {
    throw new Error("Unsafe Gradle argument rejected");
  }
  const result = spawnSync(wrapper, gradleArgs, {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    // Windows requires a command shell for .bat execution. Every argument is
    // fixed by this script and rejected above unless it is shell-metacharacter-free.
    shell: process.platform === "win32",
  });
  const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  if (result.status !== 0) {
    throw new Error(`Gradle failed (${args.join(" ")}):\n${output.slice(-12000)}`);
  }
  return output;
}

function resolvedCoordinates(output) {
  const coordinates = new Set();
  for (const line of output.split(/\r?\n/u)) {
    const match = line.match(/[+\\]---\s+([^:\s]+):([^:\s]+):([^\s(]+)(?:\s+->\s+([^\s(]+))?/u);
    if (!match) continue;
    const version = match[4] || match[3];
    if (!version || version.startsWith("{") || version.startsWith("project")) continue;
    coordinates.add(`${match[1]}:${match[2]}:${version}`);
  }
  return [...coordinates].sort((a, b) => a.localeCompare(b));
}

function writeLines(name, values) {
  writeFileSync(resolve(evidenceDir, name), `${values.join("\n")}\n`, "utf8");
}

const runtime = resolvedCoordinates(
  runGradle([":app:dependencies", "--configuration", "debugRuntimeClasspath"]),
);
const unitTest = resolvedCoordinates(
  runGradle([":app:dependencies", "--configuration", "debugUnitTestRuntimeClasspath"]),
);
const build = resolvedCoordinates(runGradle(["buildEnvironment"]));

writeLines("android-debug-runtime.txt", runtime);
writeLines("android-debug-unit-test.txt", unitTest);
writeLines("android-build-classpath.txt", build);

const directSource = readFileSync(resolve(root, "android", "app", "build.gradle.kts"), "utf8");
const direct = new Set();
for (const match of directSource.matchAll(/(?:implementation|testImplementation|androidTestImplementation|debugImplementation)\((?:platform\()?"([^"\r\n]+)"/gu)) {
  direct.add(match[1]);
}
writeLines("android-direct-declarations.txt", [...direct].sort((a, b) => a.localeCompare(b)));

console.log(`ANDROID_DEBUG_RUNTIME_COMPONENTS=${runtime.length}`);
console.log(`ANDROID_DEBUG_UNIT_TEST_COMPONENTS=${unitTest.length}`);
console.log(`ANDROID_BUILD_CLASSPATH_COMPONENTS=${build.length}`);
console.log(`ANDROID_DIRECT_DECLARATIONS=${direct.size}`);
