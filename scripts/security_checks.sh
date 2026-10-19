#!/usr/bin/env bash
set -euo pipefail

echo "Checking Python code"
ruff check services scripts

echo "Checking Python formatting"
ruff format --check services scripts

echo "Scanning Python for security issues"
bandit -r services scripts --exclude scripts/test_*.py


