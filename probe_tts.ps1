<#
  Asks the Supabase `tts` Edge Function for the exact strings the app asks for,
  saves what comes back, and reports the size of each clip.

  This settles where the truncation happens. If the server returns a full-length
  clip for "identified potential sales contact" and the app still says half of
  it, the fault is client-side playback. If the clip itself is short, the fault
  is the Edge Function or the ElevenLabs call behind it, and no amount of
  client work will fix it.

  Usage:  .\probe_tts.ps1
#>
$ErrorActionPreference = "Stop"

$SUPABASE_URL = "https://fzhguqoodojugeuyosnj.supabase.co"
$ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ6aGd1cW9vZG9qdWdldXlvc25qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYzMTE1MTUsImV4cCI6MjEwMTg4NzUxNX0.j028Mj6fKsw-9jJugUqNGMgMXWrWSu5iTpu3Dsk7JrA"

$out = Join-Path $PSScriptRoot "vo_probe"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# The exact text the app sends, short and long.
$items = @(
  @{ name="w_always";      text="always" },
  @{ name="def_always";    text="at all times" },
  @{ name="w_key";         text="key" },
  @{ name="def_key";       text="a tool that opens locks" },
  @{ name="def_lead";      text="identified potential sales contact" },
  @{ name="def_batard";    text="a short oval bread loaf" },
  @{ name="long_control";  text="This is a deliberately longer sentence used only to check whether the service returns audio of the expected length." }
)

$headers = @{ "apikey" = $ANON; "Authorization" = "Bearer $ANON"; "Content-Type" = "application/json" }

foreach ($it in $items) {
  $body = @{ text = $it.text; lang = "en" } | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  try {
    $resp = Invoke-RestMethod -Uri "$SUPABASE_URL/functions/v1/tts" -Method Post -Headers $headers -Body $bytes
    $url = $resp.url
    if (-not $url) {
      Write-Host ("{0,-14} NO URL RETURNED. raw: {1}" -f $it.name, ($resp | ConvertTo-Json -Compress)) -ForegroundColor Red
      continue
    }
    $file = Join-Path $out "$($it.name).mp3"
    Invoke-WebRequest -Uri $url -OutFile $file | Out-Null
    $kb = [math]::Round((Get-Item $file).Length / 1024, 1)
    Write-Host ("{0,-14} chars={1,-4} {2,7} KB   {3}" -f $it.name, $it.text.Length, $kb, $it.text)
  } catch {
    Write-Host ("{0,-14} REQUEST FAILED: {1}" -f $it.name, $_.Exception.Message) -ForegroundColor Red
  }
}
Write-Host "`nClips saved to $out"
