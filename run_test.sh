#! /usr/bin/bash

set -euo pipefail


g-cli vipc -- -v "20.0 (64-bit)" "Approvals Starter Project.vipc"
g-cli "C:\Program Files\National Instruments\LabVIEW 2020\vi.lib\addons\_JKI Toolkits\Caraya\CarayaCLIExecutionEngine.vi" -- -s "C:\Users\SAS\Documents\GitHub\ApprovalTests.LabVIEW.StarterProject" -x "C:\Users\SAS\Documents\GitHub\ApprovalTests.LabVIEW.StarterProject\UnitTestReport.xml"