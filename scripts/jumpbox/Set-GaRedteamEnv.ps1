# Used only for the Mon 11-16 row 4a AMPLS test (w3-harness, D-045): one SMOKE row from the jumpbox. Outcome open: V3
# (2026-10-23) found the Direct DCR endpoint reachable from the VNet. Ground truth for the runs is registered on the laptop.
# Dot-source on the jumpbox from the repo root, in T's session before any case manager signs in:
#   . .\scripts\jumpbox\Set-GaRedteamEnv.ps1; Set-GaRedteamEnv     # then row 4a, then Clear-GaRedteamEnv
# Set-GaRedteamEnv sets REDTEAM_INGEST_ENDPOINT and REDTEAM_DCR_ID from the clipboard, the same way Set-GaEnv sets the
# other five (it empties the clipboard and prints only counts and True/False). Nothing here changes AZURE_CONFIG_DIR.
function Set-GaRedteamEnv {
  $raw = [string](Get-Clipboard -Raw)
  $re = '(?:export\s+)?\b(REDTEAM_INGEST_ENDPOINT|REDTEAM_DCR_ID)\s*=\s*["'']?([^\s"'']+)'
  $m = [regex]::Matches($raw, $re)
  foreach ($x in $m) { Set-Item -Path "Env:$($x.Groups[1].Value)" -Value $x.Groups[2].Value }
  Set-Clipboard -Value ' '
  "clipboard chars: $($raw.Length) | pairs found: $($m.Count)"
  'REDTEAM_INGEST_ENDPOINT','REDTEAM_DCR_ID' | % { "{0} {1}" -f $_, [bool](Get-Item "Env:$_" -ErrorAction SilentlyContinue) }
}

# After row 4a: the red-team settings leave the session, so no later run on the jumpbox can reach the red-team DCR.
function Clear-GaRedteamEnv {
  Remove-Item Env:REDTEAM_INGEST_ENDPOINT, Env:REDTEAM_DCR_ID -ErrorAction SilentlyContinue
  'REDTEAM_INGEST_ENDPOINT','REDTEAM_DCR_ID' | % { "{0} {1}" -f $_, [bool](Get-Item "Env:$_" -ErrorAction SilentlyContinue) }
}
