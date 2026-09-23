# Historical status step from .github/workflows/ci.yml before deletion in
# 9c269a6. Keep its failure-propagation contract without restoring automation.
set -euo pipefail
python3 -m tools.phase6_development --ci-status | tee phase6-architectural-status.txt
cat phase6-architectural-status.txt >> "$GITHUB_STEP_SUMMARY"
