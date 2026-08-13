# Qulex reel narration v2 (EN) -- TWO clips per word (question + answer).
# Produces a separate QUESTION clip and ANSWER clip for each word so the mux can
# place the answer exactly at the visual reveal. ElevenLabs -> local vo\ folder.
# Prereq: an ElevenLabs API key. Get one at https://elevenlabs.io (Profile -> API Keys).
# Usage (PowerShell):  $env:ELEVENLABS_API_KEY="sk_..."; .\generate_vo_v2.ps1
# Voices: reel01 Grant, reel02 Victoria, reel03 Mia.
$ErrorActionPreference = "Stop"
if (-not $env:ELEVENLABS_API_KEY) { Write-Error "Set ELEVENLABS_API_KEY first: $env:ELEVENLABS_API_KEY='sk_...'"; exit 1 }
$out = Join-Path $PSScriptRoot "vo"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$items = @(
  @{ file="reel01_w_genuine_q.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does genuine mean?" };
  @{ file="reel01_w_genuine_a.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="It means truly what it is said to be; real." };
  @{ file="reel01_w_reluctant_q.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does reluctant mean?" };
  @{ file="reel01_w_reluctant_a.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="It means unwilling and hesitant to act." };
  @{ file="reel01_w_abundant_q.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does abundant mean?" };
  @{ file="reel01_w_abundant_a.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="It means existing in large quantities; plentiful." };
  @{ file="reel01_w_optimistic_q.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does optimistic mean?" };
  @{ file="reel01_w_optimistic_a.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="It means hopeful and confident about the future." };
  @{ file="reel01_w_scarce_q.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does scarce mean?" };
  @{ file="reel01_w_scarce_a.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="It means too little for the demand; in short supply." };
  @{ file="reel02_w_rigid_q.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does rigid mean?" };
  @{ file="reel02_w_rigid_a.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="It means stiff and not easily bent." };
  @{ file="reel02_w_pragmatic_q.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does pragmatic mean?" };
  @{ file="reel02_w_pragmatic_a.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="It means dealing with things practically, not ideally." };
  @{ file="reel02_w_profound_q.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does profound mean?" };
  @{ file="reel02_w_profound_a.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="It means very deep or intense." };
  @{ file="reel02_w_prudent_q.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does prudent mean?" };
  @{ file="reel02_w_prudent_a.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="It means careful and sensible about risks." };
  @{ file="reel02_w_blunt_q.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does blunt mean?" };
  @{ file="reel02_w_blunt_a.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="It means having a dull edge; not sharp." };
  @{ file="reel03_w_laudable_q.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does laudable mean?" };
  @{ file="reel03_w_laudable_a.mp3"; voice="nPpkc230TdYdntJKFNby"; text="It means deserving praise." };
  @{ file="reel03_w_cacophony_q.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does cacophony mean?" };
  @{ file="reel03_w_cacophony_a.mp3"; voice="nPpkc230TdYdntJKFNby"; text="It means a harsh, jarring mixture of sounds." };
  @{ file="reel03_w_capricious_q.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does capricious mean?" };
  @{ file="reel03_w_capricious_a.mp3"; voice="nPpkc230TdYdntJKFNby"; text="It means given to sudden, unpredictable change." };
  @{ file="reel03_w_intransigent_q.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does intransigent mean?" };
  @{ file="reel03_w_intransigent_a.mp3"; voice="nPpkc230TdYdntJKFNby"; text="It means unwilling to change one's views; stubborn." };
  @{ file="reel03_w_esoteric_q.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does esoteric mean?" };
  @{ file="reel03_w_esoteric_a.mp3"; voice="nPpkc230TdYdntJKFNby"; text="It means understood by only a small group." };
)
$headers = @{ "xi-api-key" = $env:ELEVENLABS_API_KEY; "Accept" = "audio/mpeg" }
$n = 0
foreach ($it in $items) {
  $body = @{ text = $it.text; model_id = "eleven_multilingual_v2" } | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $uri = "https://api.elevenlabs.io/v1/text-to-speech/" + $it.voice
  Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bytes -OutFile (Join-Path $out $it.file)
  $n++; Write-Host "[$n/$($items.Count)] $($it.file)"
}
Write-Host "Done. $($items.Count) clips saved to $out"
