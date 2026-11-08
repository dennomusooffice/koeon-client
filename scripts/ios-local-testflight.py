#!/usr/bin/env python3
"""Run the TestFlight pipeline with an explicit distribution audience on a Mac with local credentials."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / ".secret/testflight/config.json"
FIELDS = (
    "APPLE_TEAM_ID", "KOEON_BUNDLE_ID", "KOEON_API_BASE_URL",
    "KOEON_ASSOCIATED_DOMAIN", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_config(path):
    require(path.is_file(), "Local configuration is missing. Run the init command first.")
    require(path.stat().st_mode & 0o077 == 0, "Configuration permissions must be 600 (chmod 600).")
    try:
        config = json.loads(path.read_text())
    except (ValueError, UnicodeError):
        raise ValueError("Configuration must be valid UTF-8 JSON.") from None
    require(isinstance(config, dict), "Configuration must be a JSON object.")
    for name in FIELDS:
        require(isinstance(config.get(name), str) and config[name].strip(), f"Missing configuration: {name}")
        require(config[name] == config[name].strip(), f"Remove surrounding whitespace: {name}")
        require(not any(ord(c) < 32 for c in config[name]), f"Control characters are forbidden: {name}")
    require(re.fullmatch(r"[A-Z0-9]{10}", config["APPLE_TEAM_ID"]), "APPLE_TEAM_ID must contain 10 uppercase letters/digits.")
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", config["KOEON_BUNDLE_ID"]), "KOEON_BUNDLE_ID is invalid.")
    require(not config["KOEON_BUNDLE_ID"].startswith("org.example."), "Replace the example Bundle ID.")
    require(re.fullmatch(r"[A-Z0-9]{10}", config["ASC_KEY_ID"]), "ASC_KEY_ID must contain 10 uppercase letters/digits.")
    require(re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", config["ASC_ISSUER_ID"]), "ASC_ISSUER_ID must be a UUID (team API key).")
    try:
        endpoint = urlsplit(config["KOEON_API_BASE_URL"])
        valid = (endpoint.scheme == "https" and endpoint.hostname and
                 not endpoint.hostname.endswith(".invalid") and
                 not endpoint.username and not endpoint.password and
                 not endpoint.query and not endpoint.fragment and
                 not re.search(r'[\s\\"<>]', config["KOEON_API_BASE_URL"]))
    except ValueError:
        valid = False
    require(valid, "KOEON_API_BASE_URL must be a real HTTPS URL without credentials, query, or fragment.")
    require(re.fullmatch(r"applinks:[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", config["KOEON_ASSOCIATED_DOMAIN"]), "KOEON_ASSOCIATED_DOMAIN must be applinks: followed by the domain.")
    key = Path(config["ASC_KEY_PATH"]).expanduser()
    require(key.is_absolute() and key.is_file(), "ASC_KEY_PATH must point to an existing absolute .p8 path.")
    require(key.stat().st_mode & 0o077 == 0, "API key permissions must be 600 (chmod 600).")
    config["ASC_KEY_PATH"] = str(key.resolve())
    return config


def validate_request(args):
    require(getattr(args, "audience", "internal") in ("internal", "external"), "Invalid TestFlight audience.")
    if args.action in ("preflight", "candidate", "upload"):
        require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", args.version or ""), "Supply --version (for example 1.0.8).")
        require(re.fullmatch(r"[1-9][0-9]*", args.build or ""), "Supply an unused positive --build number.")
    if args.action == "upload":
        require(args.confirm == "UPLOAD_TESTFLIGHT", "Uploading requires --confirm UPLOAD_TESTFLIGHT.")


def git_value(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True, stderr=subprocess.DEVNULL).strip()


def run_step(label, command, env, log):
    print(f"{label}: running", flush=True)
    result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
    require(result.returncode == 0, f"{label} failed. Inspect the private log locally; do not publish it.")
    print(f"{label}: PASS", flush=True)


def execute(args, config):
    require(sys.platform == "darwin", "This command requires macOS.")
    require(shutil.which("node"), "Node.js 22+ is required. Open a new terminal after installation.")
    node_major = subprocess.check_output(["node", "-p", "process.versions.node.split('.')[0]"], text=True).strip()
    require(int(node_major) >= 22, "Node.js 22+ is required.")
    sha = tree = None
    if args.action in ("candidate", "upload"):
        require(not git_value("status", "--porcelain=v1", "--untracked-files=all"), "Commit all source changes before building a candidate or uploading.")
        sha = git_value("rev-parse", "HEAD")
        tree = git_value("rev-parse", "HEAD^{tree}")

    private_dir = DEFAULT_CONFIG.parent
    private_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="koeon-testflight-") as temporary:
        work = Path(temporary)
        credentials = work / "credentials"
        credentials.mkdir(mode=0o700)
        for name, value in (("AuthKey.p8", Path(config["ASC_KEY_PATH"]).read_bytes()),
                            ("key-id", config["ASC_KEY_ID"].encode()),
                            ("issuer-id", config["ASC_ISSUER_ID"].encode())):
            target = credentials / name
            target.write_bytes(value)
            target.chmod(0o600)
        env = dict(os.environ)
        for name in ("GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_STEP_SUMMARY", "IOS_APP_CREDENTIAL"):
            env.pop(name, None)
        env.update({name: config[name] for name in FIELDS[:4]})
        env.update(IOS_CREDENTIAL_DIR=str(credentials), MARKETING_VERSION=args.version or "",
                   BUILD_NUMBER=args.build or "", RUNNER_TEMP=str(work),
                   IOS_TESTFLIGHT_AUDIENCE=getattr(args, "audience", "internal"))
        fd, log_path = tempfile.mkstemp(prefix=f"{args.action}-", suffix=".log", dir=private_dir)
        print(f"Private log: {log_path}", flush=True)
        with os.fdopen(fd, "w") as log:
            run_step("Xcode setup", ["xcodebuild", "-checkFirstLaunchStatus"], env, log)
            # Validate the EC key locally, without printing or persisting the JWT.
            key_check = (
                "const fs=require('node:fs');const c=require('node:crypto');"
                "const k=c.createPrivateKey(fs.readFileSync(process.env.IOS_CREDENTIAL_DIR+'/AuthKey.p8'));"
                "if(k.asymmetricKeyType!=='ec'||k.asymmetricKeyDetails.namedCurve!=='prime256v1')process.exit(1);"
            )
            run_step("API key format", ["node", "-e", key_check], env, log)
            if args.action == "check":
                print("LOCAL_CONFIGURATION=PASS (Apple account access and signing are not yet checked)")
                return
            run_step("Apple access and unused build number", ["node", str(ROOT / "scripts/ios-app-store-connect-preflight.mjs")], env, log)
            if args.action == "preflight":
                return
            source = work / "source"
            run_step("Isolate committed source", ["git", "clone", "--local", "--no-hardlinks", "--no-checkout", str(ROOT), str(source)], env, log)
            run_step("Select exact commit", ["git", "-C", str(source), "checkout", "--detach", sha], env, log)
            env.update(CLIENT_SOURCE_DIR=str(source), INFRA_ROOT=str(source), CLIENT_SHA=sha,
                       EXPECTED_TREE_SHA=tree,
                       RELEASE_MODE="TESTFLIGHT_UPLOAD" if args.action == "upload" else "CANDIDATE_ONLY")
            print(f"Source: {sha}\nTree: {tree}\nVersion/build: {args.version} ({args.build})", flush=True)
            run_step("Signed TestFlight release" if args.action == "upload" else "Signed candidate",
                     ["/bin/bash", str(source / "scripts/ios-public-release.sh")], env, log)
        print("Temporary credential copies, archive, and IPA removed.")
        if args.action == "upload":
            print("Upload submitted. Check processing, compliance, beta review, and tester group access in App Store Connect.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "check", "preflight", "candidate", "upload"))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--confirm")
    parser.add_argument("--audience", choices=("internal", "external"), default="internal",
                        help="External permits beta review; it does not distribute to testers automatically.")
    args = parser.parse_args()
    try:
        validate_request(args)
        if args.action == "init":
            args.config.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with args.config.open("x") as stream:
                json.dump(dict.fromkeys(FIELDS, ""), stream, indent=2)
                stream.write("\n")
            args.config.chmod(0o600)
            print(f"Created {args.config}. Fill in local settings; never commit this file.")
            return 0
        execute(args, read_config(args.config))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # OSError and subprocess errors may contain private paths/command data.
        message = str(error) if isinstance(error, ValueError) else "Local operation failed. Check file access, tools, and private logs."
        print(f"TestFlight: {message}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("TestFlight interrupted; temporary files cleaned up.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
