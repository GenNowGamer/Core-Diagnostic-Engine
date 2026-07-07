# CDE Bench Release Gate Metrics

Date: 2026-07-07

This gate evaluates bench-run evidence from CDE_Bench_TestCase_Sheet.csv.

> Important: the built-in BenchLab automation pack is safe-only. If you use only the shipped marker/config scenarios, the gate primarily measures workflow, remediation, reboot cleanliness, and stability. For malware-conviction release testing, supplement the CSV with approved positive-detection cases and score only the applicable rows as detection scenarios.

## Metric Definitions

- DetectionRate = applicable conviction scenarios with ScoreDetection=1 / applicable conviction scenarios
- ClassificationRate = scenarios with ScoreClassification=1 / total scenarios
- RemediationRate = scenarios with ScoreRemediation=1 / total scenarios
- RebootCleanRate = scenarios with ScoreCleanReboot=1 / total scenarios
- NoRegressionRate = scenarios with ScoreNoRegression=1 / total scenarios
- AverageScenarioScore = avg(ScenarioScore)
- HighSeverityFalsePositiveRate = scenarios with FalsePositiveCount > 0 and Tier in benign corpus set / benign corpus scenarios
- StabilityFailureRate = scenarios with CoverageStatus != Full or ScanErrors > 0 / total scenarios

## Bench Gate Thresholds

- DetectionRate >= 0.95 (only when the input CSV includes approved positive-detection scenarios)
- RemediationRate >= 0.95
- RebootCleanRate >= 0.95
- HighSeverityFalsePositiveRate <= 0.02
- StabilityFailureRate <= 0.02
- AverageScenarioScore >= 4.5

## Gate Result

PASS only if all thresholds pass.

## Required Input Data

- CDE_Bench_TestCase_Sheet.csv with completed scenario rows
- CST release-gate outputs from CST perf_reports
- CDE publish verification output JSON

## Suggested Operational Cadence

- Daily during active engine tuning: run top 10 scenarios
- Weekly: run full 24 scenarios
- Release candidate: run full 24 plus repeatability set, then add any approved positive-detection sample rows needed for malware-conviction gating
