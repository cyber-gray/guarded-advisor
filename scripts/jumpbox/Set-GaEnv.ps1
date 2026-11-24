function Set-GaEnv {
  $raw = [string](Get-Clipboard -Raw)
  $re = '(?:export\s+)?\b(GA_TENANT_ID|COSMOS_ENDPOINT|FOUNDRY_PROJECT_ENDPOINT|AUDIT_INGEST_ENDPOINT|AUDIT_DCR_ID)\s*=\s*["'']?([^\s"'']+)'
  $m = [regex]::Matches($raw, $re)
  foreach ($x in $m) { Set-Item -Path "Env:$($x.Groups[1].Value)" -Value $x.Groups[2].Value }
  Set-Clipboard -Value ' '
  "clipboard chars: $($raw.Length) | pairs found: $($m.Count)"
  'GA_TENANT_ID','COSMOS_ENDPOINT','FOUNDRY_PROJECT_ENDPOINT','AUDIT_INGEST_ENDPOINT','AUDIT_DCR_ID' | % { "{0} {1}" -f $_, [bool](Get-Item "Env:$_" -ErrorAction SilentlyContinue) }
}
