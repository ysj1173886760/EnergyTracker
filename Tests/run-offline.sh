#!/bin/zsh
# Run from the repository root: Tests/run-offline.sh (offline, no app launch).
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "Tests/.offline-checks.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Compile the real calculations, models and backup service without launching the app or networking.
python3 - "$work" <<'PY'
from pathlib import Path
import sys
work=Path(sys.argv[1])
s=Path('EnergyTracker/Services/OpenRouterClient.swift').read_text()
work.joinpath('JSONValue.swift').write_text('import Foundation\n'+s[s.index('enum JSONValue {'):])
PY
xcrun swiftc -swift-version 5 -parse-as-library -o "$work/checks" \
  EnergyTracker/Models/*.swift \
  EnergyTracker/Services/GoalCalculator.swift \
  EnergyTracker/Services/TargetCalibration.swift \
  EnergyTracker/Services/EstimateUncertainty.swift \
  EnergyTracker/Services/HealthGuard.swift \
  EnergyTracker/Services/NutritionTotals.swift \
  EnergyTracker/Services/ProfileStore.swift \
  EnergyTracker/Services/BackupService.swift \
  "$work/JSONValue.swift" Tests/OfflineChecks.swift
"$work/checks"
