# Solution Steps

1. Update scripts/Export-CustomerBundle.ps1 to select CSV files per customer instead of bundling all CSVs: parse the JSON manifest for customer name and extract wildcard match patterns/rules, then filter source .csv files using -like pattern matching.

2. Add required warning behavior: when a manifest rule/pattern matches zero source CSV files for a customer, emit Write-Warning that includes both the customer name and the missing pattern (so Pester can assert on 'EmptyCo' and 'missing-*.csv').

3. Implement a proper verification manifest: for each bundled CSV file, compute SHA256 (Get-FileHash -Algorithm SHA256), capture byte size (FileInfo.Length), and write manifest.txt lines containing file name, byte size, and hash; keep lines sorted by file name for determinism.

4. Fix dry-run safety: when -DryRun is set, do not create the output directory, staging folders, manifest.txt, or ZIP archives. Instead, only Write-Output/Write-Verbose information about what would be created.

5. Prevent ZIP overwrites on repeated runs: generate a unique archive name per run (e.g., include yyyyMMdd-HHmmss-fff and/or a counter) and never remove or overwrite existing ZIPs; do not use -Force with Compress-Archive for that destination.

6. Ensure staging includes only selected CSVs: before copying files for a customer, clear the customer staging directory (remove and recreate it) so stale CSVs from earlier runs cannot be accidentally zipped.

7. Run /root/task/run.sh (and/or Invoke-Pester) iteratively until the provided Pester tests pass on Ubuntu with pwsh 7+.

