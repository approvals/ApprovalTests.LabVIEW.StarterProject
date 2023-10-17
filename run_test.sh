#! /usr/bin/bash

set -euo pipefail

HERE=$(cygpath -w $(pwd))

g-cli vipc -- -v "20.0 (64-bit)" -t 1200 "Approvals Starter Project.vipc"
g-cli caraya -- -s . -x "UnitTestReport.xml"