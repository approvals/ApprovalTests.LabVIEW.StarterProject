#! /usr/bin/bash

set -euo pipefail

CURRENT_DIRECTORY=$(cygpath -w $(pwd))
echo "CURRENT_DIRECTORY = $CURRENT_DIRECTORY"

CARAYA="C:\Program Files\National Instruments\LabVIEW 2020\vi.lib\addons\_JKI Toolkits\Caraya\CarayaCLIExecutionEngine.vi"
echo "CARAYA = $CARAYA"

g-cli vipc -- -v "20.0 (64-bit)" -t 1200 "$CURRENT_DIRECTORY\Approvals Starter Project.vipc"
g-cli "$CARAYA" -- -s "$CURRENT_DIRECTORY" -x "$CURRENT_DIRECTORY\UnitTestReport.xml"