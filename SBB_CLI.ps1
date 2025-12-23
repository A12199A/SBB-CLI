function Show-DepartureBoards {
    Write-Host "~~~~~~~~~~~~~~~~~~~~~~"
    Write-Host "Select a station:"
    Write-Host "1 = Zürich Flughafen"
    Write-Host "2 = Andelfingen"
    Write-Host "3 = Zürich HB"
    Write-Host "4 = Winterthur"
    Write-Host "5 = Custom Station"
    Write-Host "~~~~~~~~~~~~~~~~~~~~~~"

    $stationChoice = Read-Host "Your choice (1-5)"
    switch ($stationChoice) {
        "1" { $station = "Zürich Flughafen" }
        "2" { $station = "Andelfingen" }
        "3" { $station = "Zürich HB" }
        "4" { $station = "Winterthur" }
        "5" { 
            Write-Host "Enter station name:"
            $station = Read-Host
        }
        default { Write-Host "Invalid selection"; return }
    }

    $limit = 10
    $url = "https://transport.opendata.ch/v1/stationboard?station=$([uri]::EscapeDataString($station))&limit=$limit"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get
    } catch {
        Write-Host "Invalid station or API error."
        return
    }

    if (-not $response.stationboard -or $response.stationboard.Count -eq 0) {
        Write-Host "No departures found for station '$station'. Please check the name."
        return
    }

    $response.stationboard | ForEach-Object {
        if ($_.category -notmatch '^(S|R|IC|IR|EC|ICN|TGV|ICE|RE)$') { return }

        $train = ($_.category + $_.number).Trim()
        $destination = $_.to
        $time = (Get-Date $_.stop.departure).ToLocalTime().ToString("HH:mm")
        $platform = if ($_.stop.platform) { $_.stop.platform } else { "-" }

        if ($_.stop.cancelled -eq $true) {
            $status = "Cancelled"
        } elseif ($null -ne $_.stop.prognosis.platform -and $_.stop.prognosis.platform -ne $_.stop.platform) {
            $status = "Platform changed to " + $_.stop.prognosis.platform
        } elseif ($null -ne $_.stop.delay -and $_.stop.delay -gt 0) {
            $status = "+" + $_.stop.delay + " min"
        } else {
            $status = "OK"
        }

        [PSCustomObject]@{
            Train       = $train
            Destination = $destination
            Time        = $time
            Platform    = $platform
            Status      = $status
        }
    } | Format-Table -AutoSize
}

$global:EasterEggBestTries = $null

# ============================================================
# Unified function used for BOTH Travel Home + Custom Planner
# ============================================================
function Show-Connections {
    param(
        [string]$From,
        [string]$To
    )

    $fromEsc = [uri]::EscapeDataString($From)
    $toEsc   = [uri]::EscapeDataString($To)
    $limit   = 5
    $currentIndex = 0

    $url = "https://transport.opendata.ch/v1/connections?from=$fromEsc&to=$toEsc&limit=$limit"

    try {
        $response = Invoke-RestMethod -Uri $url
        $connections = $response.connections
    } catch {
        Write-Host "Invalid departure or destination."
        return
    }

    if (-not $connections) {
        Write-Host "No connections found."
        return
    }

    do {
        if ($currentIndex -ge $connections.Count) {
            Write-Host "`nNo more connections."
            break
        }

        $conn = $connections[$currentIndex]
        $duration = [System.TimeSpan]::Parse($conn.duration.Replace("00d",""))
        Write-Host "`n=== Connection $($currentIndex+1) " -NoNewline
        Write-Host "(Duration: $($duration.Hours)h $($duration.Minutes)m)" -ForegroundColor Cyan -NoNewline
        Write-Host " ===`n"

        $conn.sections | ForEach-Object {
            if (-not $_.journey) { return }

            $departure = (Get-Date $_.departure.departure).ToLocalTime().ToString("HH:mm")
            $arrival   = (Get-Date $_.arrival.arrival).ToLocalTime().ToString("HH:mm")
            $fromStop  = $_.departure.station.name
            $toStop    = $_.arrival.station.name
            $line      = $_.journey.category + $_.journey.number

            $departurePlatform = if ($_.departure.platform) { $_.departure.platform } else { "-" }
            $arrivalPlatform   = if ($_.arrival.platform) { $_.arrival.platform } else { "-" }

            if ($_.departure.cancelled -eq $true) {
                $status = "Cancelled"
            } elseif ($_.departure.delay -gt 0) {
                $status = "+" + $_.departure.delay + " min"
            } elseif ($_.departure.prognosis.platform -and $_.departure.prognosis.platform -ne $_.departure.platform) {
                $status = "Platform changed to " + $_.departure.prognosis.platform
            } else {
                $status = "OK"
            }

            [PSCustomObject]@{
                From               = $fromStop
                To                 = $toStop
                Line               = $line
                Departure          = $departure
                DeparturePlatform  = $departurePlatform
                Arrival            = $arrival
                ArrivalPlatform    = $arrivalPlatform
                Status             = $status
            }
        } | Format-Table -AutoSize

        Write-Host "`n1 = Exit, 2 = Load next connection"
        $choiceNext = Read-Host "Your choice"
        if ($choiceNext -eq "2") {
            $currentIndex++
        } else {
            break
        }

    } while ($true)
}


# Travel to Home — now uses the new unified function
function Show-TravelToHome {
    Show-Connections -From "Glattpark" -To "Andelfingen"
}

# Custom Planner — also uses the unified function
function Show-CustomPlanner {
    Write-Host "Enter Departure Station:"
    $dep = Read-Host
    Write-Host "Enter Destination Station:"
    $dest = Read-Host

    if ($dep.Trim().ToLower() -eq $dest.Trim().ToLower()) {
        Start-EasterEggGame
        return
    }

    Show-Connections -From $dep -To $dest
}


# =====================
# Weather API
# =====================

function WeatherForecast {
    param (
        [string]$city = $(Read-Host "Please enter your City")
    )

    $encodedCity = [uri]::EscapeDataString($city)

    $url = "https://nominatim.openstreetmap.org/search?city=$encodedCity&countrycodes=ch&format=json&limit=1"

    $response = Invoke-RestMethod -Uri $url -Method Get -Headers @{ "User-Agent" = "MyPSWeatherApp" }

    if (-not $response) {
        Write-Host "`nCity not found. Please try again." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "Location resolved to: $($response[0].display_name)" -ForegroundColor Cyan

    $lat = $response[0].lat
    $lon = $response[0].lon

    $weatherUrl = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&hourly=temperature_2m,precipitation,windspeed_10m" 

    $weatherResponse = Invoke-RestMethod -Uri $weatherUrl -Method Get

    $now = Get-Date
    $roundedHour = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute 0 -Second 0

    $startIndex = 0
    for ($j=0; $j -lt $weatherResponse.hourly.time.Count; $j++) {
        $t = Get-Date $weatherResponse.hourly.time[$j]
        if ($t -ge $roundedHour) {
            $startIndex = $j
            break
        }
    }

    $forecast = @()

    for ($i = $startIndex; $i -lt ($startIndex + 5); $i++) {
        $dt   = Get-Date $weatherResponse.hourly.time[$i]
        $temp = $weatherResponse.hourly.temperature_2m[$i]
        $pr   = $weatherResponse.hourly.precipitation[$i]
        $wd   = $weatherResponse.hourly.windspeed_10m[$i]

        $entry = [PSCustomObject]@{
            Time          = $dt.ToString("dd.MM HH:mm")
            Temperature   = "$temp °C"
            Precipitation = "$pr mm"
            Wind          = "$wd km/h"
        }

        $forecast += $entry
    }

    $forecast | Format-Table -AutoSize
}

function Start-EasterEggGame {
    Write-Host "`n=== Easter Egg: Guess the Number ===" -ForegroundColor Cyan
    Write-Host "I picked a number between 1 and 20."
    Write-Host "Type 'q' to quit."
    Write-Host "Type 'r' to reset high score.`n"

    $secret = Get-Random -Minimum 1 -Maximum 21
    $tries = 0

    while ($true) {
        $guess = Read-Host "Your guess"

        if ($guess -eq "q") {
            Write-Host "Leaving the game. The number was $secret."
            break
        }
        if ($guess -eq "r") {
            $global:EasterEggBestTries = $null
            Write-Host "High score reset."
            continue
        }

        $num = 0
        $ok = [int]::TryParse($guess, [ref]$num)
        if (-not $ok) {
            Write-Host "Please enter a number between 1 and 20, or 'q'."
            continue
        }

        $tries++
        if ($num -lt $secret) {
            Write-Host "Too low."
        } elseif ($num -gt $secret) {
            Write-Host "Too high."
        } else {
            Write-Host "Correct! You needed $tries tries."
            if ($null -eq $global:EasterEggBestTries -or $tries -lt $global:EasterEggBestTries) {
                $global:EasterEggBestTries = $tries
                Write-Host "New best score!"
            }
            break
        }
    }
}


# =====================
# MAIN MENU
# =====================

do {
    Write-Host "====================="
    Write-Host "       SBB CLI" -ForegroundColor Red
    Write-Host "1 = Departure Boards"
    Write-Host "2 = Travel to Home"
    Write-Host "3 = Custom Planner"
    Write-Host "4 = WeatherAPI"
    Write-Host "5 = Exit"
    Write-Host "6 = About"
    Write-Host "====================="
    Write-Host "(C) 2025 Aaron Frehner"

    $mainChoice = Read-Host "Your choice (1-6)"

    switch ($mainChoice) {
        "1" { Show-DepartureBoards }
        "2" { Show-TravelToHome }
        "3" { Show-CustomPlanner }
        "4" { WeatherForecast }
        "5" { Write-Host "Exiting..."; break }
        "6" { 
            Clear-Host
            Write-Host "SBB-CLI"
            Write-Host "Version 3.30"
            Write-Host "Environment: Powershell"
            Write-Host "(C) Aaron Frehner"
            if ($null -ne $global:EasterEggBestTries) {
                Write-Host "Easter Egg Best Score: $global:EasterEggBestTries tries"
            }
        }
        default { Write-Host "Invalid choice, please select 1-5" }
    }

    if ($mainChoice -eq "5") { break }

    Write-Host "`nPress Enter to return to Main Menu..."
    Read-Host

} while ($true)
