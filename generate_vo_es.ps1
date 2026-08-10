# Qbit reel narration (ES) -- TWO clips per word (question + answer), Spanish.
# Produces a separate QUESTION clip and ANSWER clip for each word so the mux can
# place the answer exactly at the visual reveal. ElevenLabs -> local vo\ folder.
# Spanish accents are sent as UTF-8 so they survive (no mojibake).
# Prereq: an ElevenLabs API key. Get one at https://elevenlabs.io (Profile -> API Keys).
# Usage (PowerShell):  $env:ELEVENLABS_API_KEY="sk_..."; .\generate_vo_es.ps1
# Voices: reel01 Lorena, reel02 Fernanda, reel03 Lorena.
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $env:ELEVENLABS_API_KEY) { Write-Error "Set ELEVENLABS_API_KEY first: $env:ELEVENLABS_API_KEY='sk_...'"; exit 1 }
$out = Join-Path $PSScriptRoot "vo"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$items = @(
  @{ file="reel01_w_genuine_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa genuine?" };
  @{ file="reel01_w_genuine_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa que es de verdad lo que dice ser." };
  @{ file="reel01_w_reluctant_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa reluctant?" };
  @{ file="reel01_w_reluctant_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa poco dispuesto y vacilante." };
  @{ file="reel01_w_abundant_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa abundant?" };
  @{ file="reel01_w_abundant_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa que existe en gran cantidad." };
  @{ file="reel01_w_optimistic_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa optimistic?" };
  @{ file="reel01_w_optimistic_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa esperanzado y confiado en el futuro." };
  @{ file="reel01_w_scarce_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa scarce?" };
  @{ file="reel01_w_scarce_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa insuficiente para la demanda; escaso." };
  @{ file="reel02_w_rigid_q_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="¿Qué significa rigid?" };
  @{ file="reel02_w_rigid_a_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="Significa tieso y difícil de doblar." };
  @{ file="reel02_w_pragmatic_q_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="¿Qué significa pragmatic?" };
  @{ file="reel02_w_pragmatic_a_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="Significa que trata las cosas de forma práctica." };
  @{ file="reel02_w_profound_q_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="¿Qué significa profound?" };
  @{ file="reel02_w_profound_a_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="Significa muy hondo o intenso." };
  @{ file="reel02_w_prudent_q_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="¿Qué significa prudent?" };
  @{ file="reel02_w_prudent_a_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="Significa cuidadoso y sensato ante los riesgos." };
  @{ file="reel02_w_blunt_q_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="¿Qué significa blunt?" };
  @{ file="reel02_w_blunt_a_es.mp3"; voice="ARmPWZKt7WpXh6QDHA6x"; text="Significa con filo romo; poco afilado." };
  @{ file="reel03_w_laudable_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa laudable?" };
  @{ file="reel03_w_laudable_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa digno de elogio." };
  @{ file="reel03_w_cacophony_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa cacophony?" };
  @{ file="reel03_w_cacophony_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa una mezcla áspera y discordante de sonidos." };
  @{ file="reel03_w_capricious_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa capricious?" };
  @{ file="reel03_w_capricious_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa dado a cambios súbitos e imprevisibles." };
  @{ file="reel03_w_intransigent_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa intransigent?" };
  @{ file="reel03_w_intransigent_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa que no cambia de opinión; terco." };
  @{ file="reel03_w_esoteric_q_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="¿Qué significa esoteric?" };
  @{ file="reel03_w_esoteric_a_es.mp3"; voice="dvIBbCEt41yUyHBRbI5A"; text="Significa entendido solo por unos pocos." };
)
$headers = @{ "xi-api-key" = $env:ELEVENLABS_API_KEY; "Accept" = "audio/mpeg" }
$n = 0
foreach ($it in $items) {
  # Build the JSON body and POST as UTF-8 bytes so Spanish accents survive.
  $body = @{ text = $it.text; model_id = "eleven_multilingual_v2" } | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $uri = "https://api.elevenlabs.io/v1/text-to-speech/" + $it.voice
  Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bytes -OutFile (Join-Path $out $it.file)
  $n++; Write-Host "[$n/$($items.Count)] $($it.file)"
}
Write-Host "Done. $($items.Count) clips saved to $out"
