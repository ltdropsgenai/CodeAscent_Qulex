# Qbit reel narration — generates ElevenLabs voiceovers into a local folder.
# Prereq: an ElevenLabs API key. Get one at https://elevenlabs.io (Profile -> API Keys).
# Usage (PowerShell):  $env:ELEVENLABS_API_KEY="sk_..."; .\generate_vo.ps1
$ErrorActionPreference = "Stop"
if (-not $env:ELEVENLABS_API_KEY) { Write-Error "Set ELEVENLABS_API_KEY first: $env:ELEVENLABS_API_KEY='sk_...'"; exit 1 }
$out = Join-Path $PSScriptRoot "vo"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$items = @(
  @{ file="reel01_w_genuine.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does genuine mean? It means truly what it is said to be; real." };
  @{ file="reel01_w_reluctant.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does reluctant mean? It means unwilling and hesitant to act." };
  @{ file="reel01_w_abundant.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does abundant mean? It means existing in large quantities; plentiful." };
  @{ file="reel01_w_optimistic.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does optimistic mean? It means hopeful and confident about the future." };
  @{ file="reel01_w_scarce.mp3"; voice="SKteVxaO2G9VRPS3WgDN"; text="What does scarce mean? It means too little for the demand; in short supply." };
  @{ file="reel02_w_rigid.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does rigid mean? It means stiff and not easily bent." };
  @{ file="reel02_w_pragmatic.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does pragmatic mean? It means dealing with things practically, not ideally." };
  @{ file="reel02_w_profound.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does profound mean? It means very deep or intense." };
  @{ file="reel02_w_prudent.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does prudent mean? It means careful and sensible about risks." };
  @{ file="reel02_w_blunt.mp3"; voice="XoUkt2bf6DlvSzRmvA8X"; text="What does blunt mean? It means having a dull edge; not sharp." };
  @{ file="reel03_w_laudable.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does laudable mean? It means deserving praise." };
  @{ file="reel03_w_cacophony.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does cacophony mean? It means a harsh, jarring mixture of sounds." };
  @{ file="reel03_w_capricious.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does capricious mean? It means given to sudden, unpredictable change." };
  @{ file="reel03_w_intransigent.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does intransigent mean? It means unwilling to change one's views; stubborn." };
  @{ file="reel03_w_esoteric.mp3"; voice="nPpkc230TdYdntJKFNby"; text="What does esoteric mean? It means understood by only a small group." };
)
$headers = @{ "xi-api-key" = $env:ELEVENLABS_API_KEY; "Accept" = "audio/mpeg" }
$n = 0
foreach ($it in $items) {
  $body = @{ text = $it.text; model_id = "eleven_multilingual_v2" } | ConvertTo-Json -Compress
  $uri = "https://api.elevenlabs.io/v1/text-to-speech/" + $it.voice
  Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType "application/json" -Body $body -OutFile (Join-Path $out $it.file)
  $n++; Write-Host "[$n/$($items.Count)] $($it.file)"
}
Write-Host "Done. $($items.Count) clips saved to $out"