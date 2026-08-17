<#
.SYNOPSIS
  Qulex - heteronym audio A/B + cache-seeding probe.

.DESCRIPTION
  WHY: our TTS model (eleven_multilingual_v2) ignores phoneme tags, so today we
  steer pronunciation by respelling the audio-only text ("wind" -> "wined").
  That works for vowel swaps and CANNOT work for stress shifts (REcord vs
  reCORD), where both senses respell to the same string and collide on one
  cache key.

  THE IDEA THIS TESTS: synthesis is not a runtime path. Every clip is generated
  once, server-side, and shared by all users forever. So a clip can be made by a
  DIFFERENT model than the one we normally call, as long as it lands at the
  cache key the app will ask for. eleven_flash_v2 supports phoneme tags. If the
  same voice_id sounds the same on both models, we can fix heteronyms today
  without migrating anything.

  WHY -Renders MATTERS: TTS output is stochastic. The first run of this script
  used one render per condition, and the same-input control (variant B, which
  sends identical text for both senses of "record") varied MORE between its two
  renders than the phoneme-tagged A pair differed from each other. A single
  sample therefore proves nothing. Render each condition N times and compare
  the between-sense difference against the within-sense spread.

  WHAT TO LISTEN FOR:
   1. Is variant A actually pronounced correctly?
   2. Does A sound like the SAME VOICE as B/C? This is the decisive question.
      A correct word in an audibly different voice is worse than a wrong word
      in a consistent one.
   3. For record/present/content, compare A against B. B is what ships now, and
      both senses of B receive byte-identical input - that is the collision.

.PARAMETER Renders
  How many times to render each condition. Default 5. Use 1 for a quick smoke
  test, but do not draw conclusions from it.

.PARAMETER Only
  Regex filtered against the slug (e.g. 'record|present|content' for just the
  stress-shift set, or 'lead' for one word). Default: everything.

.PARAMETER Force
  Skip the cost-estimate confirmation prompt.

.EXAMPLE
  $env:ELEVENLABS_API_KEY="sk_..."; $env:QULEX_VOICE_ID="..."
  .\seed_heteronym_audio.ps1 -Only 'record|present|content' -Renders 5
#>
param(
  [int]$Renders = 5,
  [string]$Only = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"
if (-not $env:ELEVENLABS_API_KEY) { Write-Error "Set ELEVENLABS_API_KEY first"; exit 1 }
if (-not $env:QULEX_VOICE_ID)     { Write-Error "Set QULEX_VOICE_ID first";     exit 1 }
if ($Renders -lt 1) { Write-Error "-Renders must be >= 1"; exit 1 }

$voice = $env:QULEX_VOICE_ID
$out   = Join-Path $PSScriptRoot "vo_heteronyms"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# Mirrors Voice._hash + _localCachePath in lib/services/voice.dart:
#   djb2 over "$langCode|$text", masked to 31 bits, printed as lowercase hex.
function Get-CacheKey([string]$lang, [string]$text) {
  $s = "$lang|$text"
  $h = [long]5381
  foreach ($ch in $s.ToCharArray()) {
    $h = ((($h -shl 5) + $h + [long][int]$ch) -band 0x7fffffff)
  }
  return $h.ToString('x')
}

# Self-check against values computed by the real Dart implementation. If these
# drift, the keys below are wrong and seeding would silently miss the cache.
$selfCheck = @{ "leed" = "6c11dd2e"; "wined" = "6f16e8cb"; "klohss" = "362cffa8"; "content" = "1aeec8cf" }
foreach ($k in $selfCheck.Keys) {
  $got = Get-CacheKey "en" $k
  if ($got -ne $selfCheck[$k]) {
    Write-Error "Cache-key self-check FAILED for '$k': got $got, expected $($selfCheck[$k]). Do not seed."
    exit 1
  }
}
Write-Host "Cache-key self-check passed." -ForegroundColor Green

# word | sense | ARPAbet | appText = what ttsRespell() currently produces, and
# therefore the string whose cache key the app looks up at play time.
#
# Vowel-swap pairs: respelling already works, so these test voice identity.
# Stress-shift pairs (last six): respelling cannot express them at all, both
# senses share one appText, and phoneme tags are the only possible fix.
# Per r/LanguageTechnology feedback the unstressed vowels are REDUCED in the
# ARPAbet below rather than just moving the stress mark - in English, stress
# and vowel quality move together.
$items = @(
  @{ w="lead";    sense="sales-position"; ph="L IY1 D";           app="leed"    },
  @{ w="lead";    sense="metal";          ph="L EH1 D";           app="led"     },
  @{ w="wind";    sense="to-coil";        ph="W AY1 N D";         app="wined"   },
  @{ w="wind";    sense="air";            ph="W IH1 N D";         app="winned"  },
  @{ w="wound";   sense="injury";         ph="W UW1 N D";         app="woond"   },
  @{ w="wound";   sense="past-of-wind";   ph="W AW1 N D";         app="wownd"   },
  @{ w="tear";    sense="rip";            ph="T EH1 R";           app="tare"    },
  @{ w="tear";    sense="crying";         ph="T IH1 R";           app="tier"    },
  @{ w="read";    sense="present";        ph="R IY1 D";           app="reed"    },
  @{ w="read";    sense="past";           ph="R EH1 D";           app="red"     },
  @{ w="bow";     sense="bend-or-ship";   ph="B AW1";             app="bough"   },
  @{ w="bow";     sense="ribbon";         ph="B OW1";             app="beau"    },
  @{ w="close";   sense="verb";           ph="K L OW1 Z";         app="klohz"   },
  @{ w="close";   sense="adjective";      ph="K L OW1 S";         app="klohss"  },
  @{ w="minute";  sense="time";           ph="M IH1 N AH0 T";     app="minit"   },
  @{ w="minute";  sense="tiny";           ph="M AY0 N Y UW1 T";   app="mynoot"  },
  @{ w="record";  sense="noun-REcord";    ph="R EH1 K ER0 D";     app="record"  },
  @{ w="record";  sense="verb-reCORD";    ph="R IH0 K AO1 R D";   app="record"  },
  @{ w="present"; sense="noun-PREsent";   ph="P R EH1 Z AH0 N T"; app="present" },
  @{ w="present"; sense="verb-preSENT";   ph="P R IH0 Z EH1 N T"; app="present" },
  @{ w="content"; sense="noun-CONtent";   ph="K AA1 N T EH0 N T"; app="content" },
  @{ w="content"; sense="adj-conTENT";    ph="K AH0 N T EH1 N T"; app="content" }
)

if ($Only) {
  $items = @($items | Where-Object { "$($_.w)_$($_.sense)" -match $Only })
  if ($items.Count -eq 0) { Write-Error "-Only '$Only' matched no items."; exit 1 }
}

# Estimate billable characters before spending anything. ElevenLabs bills on
# submitted text, and the phoneme markup is far longer than the bare word.
$charsPerItem = 0
foreach ($it in $items) {
  $tagged = '<phoneme alphabet="cmu-arpabet" ph="' + $it.ph + '">' + $it.w + '</phoneme>'
  $charsPerItem += $tagged.Length + $it.app.Length + $it.w.Length
}
$totalReq   = $items.Count * 3 * $Renders
$totalChars = $charsPerItem * $Renders

Write-Host ""
Write-Host "Items:    $($items.Count)$(if($Only){" (filtered by '$Only')"})"
Write-Host "Renders:  $Renders each, x3 variants  =  $totalReq requests"
Write-Host "Estimated billable characters: ~$totalChars" -ForegroundColor Cyan
if ($Renders -eq 1) {
  Write-Host "WARNING: -Renders 1 cannot separate a real effect from TTS randomness." -ForegroundColor Yellow
}
if (-not $Force) {
  $ans = Read-Host "Proceed? (y/N)"
  if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted."; exit 0 }
}
Write-Host ""

$headers = @{ "xi-api-key" = $env:ELEVENLABS_API_KEY; "Accept" = "audio/mpeg" }

function Invoke-Tts([string]$text, [string]$model, [string]$file) {
  $body  = @{ text = $text; model_id = $model } | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $uri   = "https://api.elevenlabs.io/v1/text-to-speech/$voice"
  Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
    -ContentType "application/json; charset=utf-8" -Body $bytes -OutFile $file
}

$manifest = @()
$n = 0
foreach ($it in $items) {
  $slug   = "$($it.w)_$($it.sense)"
  $key    = Get-CacheKey "en" $it.app
  $tagged = '<phoneme alphabet="cmu-arpabet" ph="' + $it.ph + '">' + $it.w + '</phoneme>'

  for ($r = 1; $r -le $Renders; $r++) {
    $suffix = "_r$r"
    # A: flash_v2 + phoneme tag. The candidate fix.
    Invoke-Tts $tagged  "eleven_flash_v2"        (Join-Path $out "${slug}_A_flash_phoneme${suffix}.mp3")
    # B: multilingual_v2 + current respelling. What ships today. For the
    #    stress-shift items both senses send IDENTICAL text, so the spread
    #    across these renders IS the noise floor to beat.
    Invoke-Tts $it.app  "eleven_multilingual_v2" (Join-Path $out "${slug}_B_multi_respell${suffix}.mp3")
    # C: multilingual_v2 + the bare word. The unaided baseline.
    Invoke-Tts $it.w    "eleven_multilingual_v2" (Join-Path $out "${slug}_C_multi_plain${suffix}.mp3")

    $manifest += [PSCustomObject]@{
      word = $it.w; sense = $it.sense; render = $r; arpabet = $it.ph
      appText = $it.app; cacheKey = "$key.mp3"
    }
    $n++
    Write-Host ("[{0}/{1}] {2,-24} r{3}  appText='{4}'  cacheKey={5}.mp3" -f `
      $n, ($items.Count * $Renders), $slug, $r, $it.app, $key)
  }
}

$manifest | Export-Csv -NoTypeInformation -Path (Join-Path $out "manifest.csv")

$dupes = $manifest | Select-Object word,sense,appText -Unique | Group-Object appText | Where-Object { $_.Count -gt 1 }
if ($dupes) {
  Write-Host "`nCACHE-KEY COLLISIONS (two senses, one key - respelling cannot separate these):" -ForegroundColor Yellow
  foreach ($d in $dupes) {
    Write-Host ("  {0} -> {1}" -f $d.Name, (($d.Group | ForEach-Object { $_.sense }) -join ' AND '))
  }
  Write-Host "  For these, seeding by cache key is impossible without also giving each" -ForegroundColor Yellow
  Write-Host "  sense its own Word.say string (e.g. 'record-noun' / 'record-verb')." -ForegroundColor Yellow
}

Write-Host "`nDone. $($items.Count) items x 3 variants x $Renders renders -> $out"
Write-Host "Compare BETWEEN-sense difference against WITHIN-sense spread before concluding anything."
