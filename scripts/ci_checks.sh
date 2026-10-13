#!/usr/bin/env bash
set -euo pipefail
terraform fmt -check -recursive environments modules bootstrap
python3 -m compileall -q services scripts
# Separate processes: these older test suites each replace boto3 in sys.modules.
python3 scripts/test_handlers.py
python3 scripts/test_order_processor.py
python3 scripts/test_consumers.py
python3 scripts/test_audit.py
terraform -chdir=environments/dev init -backend=false -input=false -lockfile=readonly
terraform -chdir=environments/dev validate
