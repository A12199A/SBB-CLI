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

    $url = "https://transport.opendata.ch/v1/stationboard?station=$([uri]::EscapeDataString($Station))&limit=$Limit"
    $response = Invoke-RestMethod -Uri $url -Method Get

    if (-not $response.stationboard -or $response.stationboard.Count -eq 0) {
        return @()
    }

    $response.stationboard | ForEach-Object {
        if ($_.category -notmatch '^(S|R|IC|IR|EC|ICN|TGV|ICE|RE)$') { return }

        $train = ($_.category + $_.number).Trim()
        $time = (Get-Date $_.stop.departure).ToLocalTime().ToString('HH:mm')
        $platform = if ($_.stop.platform) { $_.stop.platform } else { '-' }

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
    $url = "https://transport.opendata.ch/v1/connections?from=$fromEsc&to=$toEsc&limit=$Limit"

    $response = Invoke-RestMethod -Uri $url
    if (-not $response.connections) {
        return @()
    }

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
    $loc = Invoke-RestMethod -Uri $locUrl -Method Get -Headers @{ 'User-Agent' = 'MyPSWeatherApp' }

    if (-not $loc) {
        return @()
    }

    $lat = $loc[0].lat
    $lon = $loc[0].lon
    $weatherUrl = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&hourly=temperature_2m,precipitation,windspeed_10m"
    $weather = Invoke-RestMethod -Uri $weatherUrl -Method Get

    $now = Get-Date
    $roundedHour = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute 0 -Second 0

    $startIndex = 0
    for ($j = 0; $j -lt $weather.hourly.time.Count; $j++) {
        $t = Get-Date $weather.hourly.time[$j]
        if ($t -ge $roundedHour) {
            $startIndex = $j
            break
        }
    }

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
header { padding: 18px 20px; background: var(--accent); color: #fff; font-weight: 700; letter-spacing: 0.5px; }
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
</style>
</head>
<body>
<header>SBB CLI - Web GUI (Local)</header>
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

<script>
function el(id){ return document.getElementById(id); }

function renderTable(rows){
  if (!rows || rows.length === 0) return '<div class="small">No data.</div>';
  const cols = Object.keys(rows[0]);
  const head = cols.map(c => `<th>${c}</th>`).join('');
  const body = rows.map(r => `<tr>${cols.map(c => `<td>${r[c]}</td>`).join('')}</tr>`).join('');
  return `<table class="table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
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

$listener = [System.Net.HttpListener]::new()
$prefix = 'http://localhost:8085/'
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "SBB CLI GUI running at $prefix"
Write-Host 'Press Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
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
    $listener.Stop()
    $listener.Close()
}
