# Cross-platform GUI via local web UI (PowerShell 7+ recommended)
# Run: pwsh -File .\SBB_CLI_GUI.ps1

$ErrorActionPreference = 'Stop'

function Get-DepartureBoardData {
    param(
        [string]$Station,
        [int]$Limit = 10
    )

    if ([string]::IsNullOrWhiteSpace($Station)) {
        throw 'Station is required.'
    }

    # Build stationboard API request
    $url = "https://transport.opendata.ch/v1/stationboard?station=$([uri]::EscapeDataString($Station))&limit=$Limit"
    $response = Invoke-RestMethod -Uri $url -Method Get

    if (-not $response.stationboard -or $response.stationboard.Count -eq 0) {
        return @()
    }

    # Map API response to a compact table-friendly object
    $response.stationboard | ForEach-Object {
        if ($_.category -notmatch '^(S|R|IC|IR|EC|ICN|TGV|ICE|RE)$') { return }

        $train = ($_.category + $_.number).Trim()
        $time = (Get-Date $_.stop.departure).ToLocalTime().ToString('HH:mm')
        $platform = if ($_.stop.platform) { $_.stop.platform } else { '-' }

        # Derive status with priority: cancelled > platform change > delay
        if ($_.stop.cancelled -eq $true) {
            $status = 'Cancelled'
        } elseif ($null -ne $_.stop.prognosis.platform -and $_.stop.prognosis.platform -ne $_.stop.platform) {
            $status = 'Platform changed to ' + $_.stop.prognosis.platform
        } elseif ($null -ne $_.stop.delay -and $_.stop.delay -gt 0) {
            $status = '+' + $_.stop.delay + ' min'
        } else {
            $status = 'OK'
        }

        [PSCustomObject]@{
            Train       = $train
            Destination = $_.to
            Time        = $time
            Platform    = $platform
            Status      = $status
        }
    } | Where-Object { $_ }
}

function Get-ConnectionsData {
    param(
        [string]$From,
        [string]$To,
        [int]$Limit = 5
    )

    if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) {
        throw 'From and To are required.'
    }

    $fromEsc = [uri]::EscapeDataString($From)
    $toEsc   = [uri]::EscapeDataString($To)
    # Build connections API request
    $url = "https://transport.opendata.ch/v1/connections?from=$fromEsc&to=$toEsc&limit=$Limit"

    $response = Invoke-RestMethod -Uri $url
    if (-not $response.connections) {
        return @()
    }

    # Each connection contains multiple sections
    $response.connections | ForEach-Object {
        $duration = [System.TimeSpan]::Parse($_.duration.Replace('00d',''))
        $sections = @()

        $_.sections | ForEach-Object {
            if (-not $_.journey) { return }

            $departure = (Get-Date $_.departure.departure).ToLocalTime().ToString('HH:mm')
            $arrival   = (Get-Date $_.arrival.arrival).ToLocalTime().ToString('HH:mm')
            $line      = $_.journey.category + $_.journey.number

            $departurePlatform = if ($_.departure.platform) { $_.departure.platform } else { '-' }
            $arrivalPlatform   = if ($_.arrival.platform) { $_.arrival.platform } else { '-' }

            # Derive section status with priority: cancelled > delay > platform change
            if ($_.departure.cancelled -eq $true) {
                $status = 'Cancelled'
            } elseif ($_.departure.delay -gt 0) {
                $status = '+' + $_.departure.delay + ' min'
            } elseif ($_.departure.prognosis.platform -and $_.departure.prognosis.platform -ne $_.departure.platform) {
                $status = 'Platform changed to ' + $_.departure.prognosis.platform
            } else {
                $status = 'OK'
            }

            $sections += [PSCustomObject]@{
                From              = $_.departure.station.name
                To                = $_.arrival.station.name
                Line              = $line
                Departure         = $departure
                DeparturePlatform = $departurePlatform
                Arrival           = $arrival
                ArrivalPlatform   = $arrivalPlatform
                Status            = $status
            }
        }

        [PSCustomObject]@{
            Duration = "{0}h {1}m" -f $duration.Hours, $duration.Minutes
            Sections = $sections
        }
    }
}

function Get-WeatherData {
    param(
        [string]$City
    )

    if ([string]::IsNullOrWhiteSpace($City)) {
        throw 'City is required.'
    }

    $encodedCity = [uri]::EscapeDataString($City)
    $locUrl = "https://nominatim.openstreetmap.org/search?city=$encodedCity&countrycodes=ch&format=json&limit=1"
    # Resolve city name to coordinates (Nominatim)
    $loc = Invoke-RestMethod -Uri $locUrl -Method Get -Headers @{ 'User-Agent' = 'MyPSWeatherApp' }

    if (-not $loc) {
        return @()
    }

    $lat = $loc[0].lat
    $lon = $loc[0].lon
    $weatherUrl = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&hourly=temperature_2m,precipitation,windspeed_10m"
    # Fetch hourly weather data (Open-Meteo)
    $weather = Invoke-RestMethod -Uri $weatherUrl -Method Get

    $now = Get-Date
    $roundedHour = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute 0 -Second 0

    # Find the first hour at or after current time
    $startIndex = 0
    for ($j = 0; $j -lt $weather.hourly.time.Count; $j++) {
        $t = Get-Date $weather.hourly.time[$j]
        if ($t -ge $roundedHour) {
            $startIndex = $j
            break
        }
    }

    # Build a short forecast window (next 5 hours)
    $forecast = @()
    for ($i = $startIndex; $i -lt ($startIndex + 5); $i++) {
        $dt   = Get-Date $weather.hourly.time[$i]
        $temp = $weather.hourly.temperature_2m[$i]
        $pr   = $weather.hourly.precipitation[$i]
        $wd   = $weather.hourly.windspeed_10m[$i]

        $forecast += [PSCustomObject]@{
            Time          = $dt.ToString('dd.MM HH:mm')
            Temperature   = "$temp C"
            Precipitation = "$pr mm"
            Wind          = "$wd km/h"
        }
    }

    $forecast
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [object]$Data,
        [int]$StatusCode = 200
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    # Consistent JSON serialization for API responses
    $json = $Data | ConvertTo-Json -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>SBB CLI GUI</title>
<style>
:root { --bg: #f7f4ef; --ink: #1d1d1d; --card: #ffffff; --accent: #c21f1f; }
* { box-sizing: border-box; }
body { margin: 0; font-family: "Segoe UI", "Noto Sans", sans-serif; background: var(--bg); color: var(--ink); }
header { padding: 18px 20px; background: var(--accent); color: #fff; font-weight: 700; letter-spacing: 0.5px; display: flex; align-items: center; justify-content: space-between; }
.header-actions { display: flex; gap: 8px; }
.info-btn { background: #fff; color: var(--accent); border: 1px solid rgba(255,255,255,0.6); padding: 6px 10px; border-radius: 8px; font-weight: 700; cursor: pointer; }
.info-btn:hover { filter: brightness(0.95); }
main { padding: 18px; display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
.card { background: var(--card); padding: 16px; border-radius: 12px; box-shadow: 0 8px 20px rgba(0,0,0,0.08); }
.card h2 { margin: 0 0 10px 0; font-size: 16px; text-transform: uppercase; letter-spacing: 1px; }
label { display: block; font-size: 12px; margin: 8px 0 4px; }
input, select, button { width: 100%; padding: 8px 10px; border: 1px solid #ddd; border-radius: 8px; }
button { background: var(--accent); color: #fff; border: none; cursor: pointer; margin-top: 10px; }
button:hover { filter: brightness(0.95); }
pre { background: #f2f2f2; padding: 10px; border-radius: 8px; overflow: auto; }
.table { width: 100%; border-collapse: collapse; }
.table th, .table td { padding: 6px 8px; border-bottom: 1px solid #eee; font-size: 13px; text-align: left; }
.small { font-size: 12px; color: #666; }
.modal-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.35); display: none; align-items: center; justify-content: center; padding: 16px; }
.modal { background: #fff; border-radius: 12px; max-width: 360px; width: 100%; padding: 16px; box-shadow: 0 12px 28px rgba(0,0,0,0.18); }
.modal h3 { margin: 0 0 10px 0; font-size: 16px; }
.modal p { margin: 4px 0; font-size: 13px; color: #333; }
.modal .actions { margin-top: 12px; text-align: right; }
.modal .actions button { width: auto; padding: 6px 12px; }
</style>
</head>
<body>
<header>
  <div>SBB CLI - Web GUI (Local)</div>
  <div class="header-actions">
    <button class="info-btn" onclick="openInfo()">Info</button>
  </div>
</header>
<main>
  <section class="card">
    <h2>Departure Board</h2>
    <label>Station</label>
    <select id="station">
      <option>Zurich Flughafen</option>
      <option>Andelfingen</option>
      <option>Zurich HB</option>
      <option>Winterthur</option>
    </select>
    <label>Custom station</label>
    <input id="stationCustom" placeholder="Type station name" />
    <button onclick="loadDepartures()">Load Departures</button>
    <div id="departures" class="small"></div>
  </section>

  <section class="card">
    <h2>Connections</h2>
    <label>From</label>
    <input id="from" placeholder="Departure station" value="Glattpark" />
    <label>To</label>
    <input id="to" placeholder="Destination station" value="Andelfingen" />
    <button onclick="loadConnections()">Load Connections</button>
    <div id="connections" class="small"></div>
  </section>

  <section class="card">
    <h2>Weather</h2>
    <label>City</label>
    <input id="city" placeholder="City in CH" />
    <button onclick="loadWeather()">Load Weather</button>
    <div id="weather" class="small"></div>
  </section>
</main>

<div id="infoModal" class="modal-backdrop" onclick="closeInfo(event)">
  <div class="modal" role="dialog" aria-modal="true">
    <h3>SBB-CLI</h3>
    <p>Version 4.10</p>
    <p>Environment: Powershell</p>
    <p>(C) Aaron Frehner</p>
    <p id="bestScoreInfo"></p>
    <div class="actions">
      <button onclick="closeInfo()">Close</button>
    </div>
  </div>
</div>

<script>
function el(id){ return document.getElementById(id); }
const easterEgg = {
  secret: null,
  tries: 0,
  bestKey: 'sbb_cli_easteregg_best'
};

function resetEasterEgg(){
  // New random number and reset tries
  easterEgg.secret = Math.floor(Math.random() * 20) + 1;
  easterEgg.tries = 0;
  renderEasterEgg('New game started. Pick a number between 1 and 20.');
}

function bestTries(){
  const val = localStorage.getItem(easterEgg.bestKey);
  return val ? parseInt(val, 10) : null;
}

function updateBest(tries){
  const current = bestTries();
  if (current === null || tries < current){
    localStorage.setItem(easterEgg.bestKey, String(tries));
    return true;
  }
  return false;
}

function renderEasterEgg(message){
  // Render the game UI in the Connections card
  const best = bestTries();
  const bestLine = best !== null ? `<div class="small">Best score: ${best} tries</div>` : '';
  el('connections').innerHTML = `
    <div class="small"><strong>Easter Egg: Guess the Number</strong></div>
    <div class="small">${message || 'I picked a number between 1 and 20.'}</div>
    ${bestLine}
    <label>Guess</label>
    <input id="eggGuess" placeholder="1-20" />
    <button onclick="submitEasterEgg()">Submit Guess</button>
    <button onclick="resetEasterEgg()">New Game</button>
    <button onclick="clearEasterEggBest()">Reset Best Score</button>
  `;
}

function submitEasterEgg(){
  // Validate and compare guess
  const input = el('eggGuess');
  const guess = parseInt((input.value || '').trim(), 10);
  if (Number.isNaN(guess) || guess < 1 || guess > 20){
    renderEasterEgg('Please enter a number between 1 and 20.');
    return;
  }

  easterEgg.tries += 1;
  if (guess < easterEgg.secret){
    renderEasterEgg('Too low.');
  } else if (guess > easterEgg.secret){
    renderEasterEgg('Too high.');
  } else {
    const newBest = updateBest(easterEgg.tries);
    const bestMsg = newBest ? ' New best score!' : '';
    renderEasterEgg(`Correct! You needed ${easterEgg.tries} tries.${bestMsg}`);
  }
}

function clearEasterEggBest(){
  localStorage.removeItem(easterEgg.bestKey);
  renderEasterEgg('Best score reset.');
}

function renderTable(rows){
  if (!rows || rows.length === 0) return '<div class="small">No data.</div>';
  const cols = Object.keys(rows[0]);
  const head = cols.map(c => `<th>${c}</th>`).join('');
  const body = rows.map(r => `<tr>${cols.map(c => `<td>${r[c]}</td>`).join('')}</tr>`).join('');
  return `<table class="table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function openInfo(){
  // Mirror the CLI "About" info in a modal
  const best = bestTries();
  el('bestScoreInfo').textContent = best !== null ? `Easter Egg Best Score: ${best} tries` : '';
  el('infoModal').style.display = 'flex';
}

function closeInfo(evt){
  if (!evt || evt.target.id === 'infoModal') {
    el('infoModal').style.display = 'none';
  }
}

async function loadDepartures(){
  const station = el('stationCustom').value.trim() || el('station').value;
  const res = await fetch(`/api/departures?station=${encodeURIComponent(station)}`);
  const data = await res.json();
  el('departures').innerHTML = renderTable(data);
}

async function loadConnections(){
  const from = el('from').value.trim();
  const to = el('to').value.trim();
  if (from.toLowerCase() === to.toLowerCase()){
    // Trigger Easter egg if same station is entered twice
    if (easterEgg.secret === null){
      resetEasterEgg();
    } else {
      renderEasterEgg('I picked a number between 1 and 20.');
    }
    return;
  }
  const res = await fetch(`/api/connections?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`);
  const data = await res.json();
  if (!data || data.length === 0){
    el('connections').innerHTML = '<div class="small">No data.</div>';
    return;
  }
  const html = data.map((c, idx) => {
    const title = `<div class="small">Connection ${idx+1} - ${c.Duration}</div>`;
    return title + renderTable(c.Sections);
  }).join('<br/>');
  el('connections').innerHTML = html;
}

async function loadWeather(){
  const city = el('city').value.trim();
  const res = await fetch(`/api/weather?city=${encodeURIComponent(city)}`);
  const data = await res.json();
  el('weather').innerHTML = renderTable(data);
}
</script>
</body>
</html>
'@

$portCandidates = 8085..8095  # Fallback range if 8085 is taken
$listener = $null
$prefix = $null
foreach ($p in $portCandidates) {
    $testListener = [System.Net.HttpListener]::new()
    $testPrefix = "http://localhost:$p/"
    $testListener.Prefixes.Add($testPrefix)
    try {
        $testListener.Start()
        $listener = $testListener
        $prefix = $testPrefix
        break
    } catch {
        $testListener.Close()
    }
}

if (-not $listener) {
    throw 'Failed to bind to any port in range 8085-8095.'
}

Write-Host "SBB CLI GUI running at $prefix"
Write-Host 'Press Ctrl+C to stop.'
$script:ShouldStop = $false
$cancelSub = $null
try {
    # Handle Ctrl+C cleanly across hosts
    $cancelSub = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action {
        $script:ShouldStop = $true
        $EventArgs.Cancel = $true
        if ($listener.IsListening) {
            $listener.Stop()
        }
    }
} catch {
    Write-Host 'Warning: Ctrl+C handler could not be registered in this host.'
}

try {
    while ($listener.IsListening -and -not $script:ShouldStop) {
        $asyncResult = $null
        try {
            # Non-blocking accept so stop events are honored
            $asyncResult = $listener.BeginGetContext($null, $null)
        } catch {
            break
        }

        while (-not $asyncResult.AsyncWaitHandle.WaitOne(250)) {
            if ($script:ShouldStop -or -not $listener.IsListening) {
                break
            }
        }

        if ($script:ShouldStop -or -not $listener.IsListening) {
            break
        }

        try {
            $context = $listener.EndGetContext($asyncResult)
        } catch {
            break
        }
        $req = $context.Request
        $res = $context.Response

        switch ($req.Url.AbsolutePath) {
            '/' {
                $res.StatusCode = 200
                $res.ContentType = 'text/html; charset=utf-8'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $res.OutputStream.Close()
            }
            '/api/departures' {
                try {
                    $station = $req.QueryString['station']
                    $data = Get-DepartureBoardData -Station $station
                    Send-Json -Response $res -Data $data
                } catch {
                    Send-Json -Response $res -Data @{ error = $_.Exception.Message } -StatusCode 400
                }
            }
            '/api/connections' {
                try {
                    $from = $req.QueryString['from']
                    $to = $req.QueryString['to']
                    $data = Get-ConnectionsData -From $from -To $to
                    Send-Json -Response $res -Data $data
                } catch {
                    Send-Json -Response $res -Data @{ error = $_.Exception.Message } -StatusCode 400
                }
            }
            '/api/weather' {
                try {
                    $city = $req.QueryString['city']
                    $data = Get-WeatherData -City $city
                    Send-Json -Response $res -Data $data
                } catch {
                    Send-Json -Response $res -Data @{ error = $_.Exception.Message } -StatusCode 400
                }
            }
            default {
                $res.StatusCode = 404
                $res.ContentType = 'text/plain; charset=utf-8'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $res.OutputStream.Close()
            }
        }
    }
}
finally {
    if ($cancelSub) {
        Unregister-Event -SourceIdentifier $cancelSub.Name
        $cancelSub = $null
    }
    $listener.Stop()
    $listener.Close()
}
