#!/usr/bin/env bash
echo "=== NPM AUDIT REPORT ===" > npm-audit-report.txt
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> npm-audit-report.txt
echo "" >> npm-audit-report.txt

echo "--- app/ ---" >> npm-audit-report.txt
(cd app && npm audit) >> npm-audit-report.txt 2>&1

echo "" >> npm-audit-report.txt
echo "--- infra/ ---" >> npm-audit-report.txt
(cd infra && npm audit) >> npm-audit-report.txt 2>&1

cat npm-audit-report.txt

cd infra
echo "=== CDK-NAG REPORT ===" > ../cdk-nag-report.txt
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> ../cdk-nag-report.txt
echo "" >> ../cdk-nag-report.txt

for f in cdk.out/AwsSolutions-PrPreview*-NagReport.csv; do
  echo "--- $(basename "$f") ---" >> ../cdk-nag-report.txt
  cat "$f" >> ../cdk-nag-report.txt
  echo "" >> ../cdk-nag-report.txt
done

cat ../cdk-nag-report.txt
