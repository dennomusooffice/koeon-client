#!/usr/bin/env python3
"""Generate export options; external eligibility does not grant tester access."""
import plistlib
from pathlib import Path
import sys


def export_options(audience, team):
    if audience not in ("internal", "external"):
        raise ValueError("Invalid TestFlight audience")
    return {
        "method": "app-store-connect", "destination": "export",
        "signingStyle": "automatic", "signingCertificate": "Apple Distribution",
        "teamID": team, "manageAppVersionAndBuildNumber": False,
        "testFlightInternalTestingOnly": audience == "internal", "uploadSymbols": True,
    }


if __name__ == "__main__":
    Path(sys.argv[3]).write_bytes(plistlib.dumps(export_options(sys.argv[1], sys.argv[2])))
