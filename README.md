# SBB-CLI 

A simple PowerShell-based CLI tool to query Swiss public transport data and weather information directly from the terminal.

This project uses public APIs to display:
- departure boards
- travel connections
- basic weather forecasts

---

## Features

- **Departure Boards**
  - Shows upcoming departures for selected stations
  - Supports custom station input
  - Displays platform, delay, and cancellation status

- **Connection Planner**
  - Predefined "Travel to Home" route
  - Custom route planner (From → To)
  - Step-by-step connections with duration and platform info

- **Weather Forecast**
  - City-based weather lookup (Switzerland)
  - Hourly forecast (next few hours)
  - Temperature, precipitation, and wind speed

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Internet connection

No additional modules required.

---

## Usage

Clone the repository:

```bash
git clone https://github.com/A12199A/SBB-CLI.git
cd SBB-CLI
```
Run the script:
```powershell
.\SBB_CLI.ps1
```
Use the interactive menu to navigate through the features.

### GUI (Local Web UI)

The repository also includes a lightweight local web GUI.

Run the GUI script:
```powershell
.\SBB_CLI_GUI.ps1
```
Open your browser at the URL shown in the terminal (default `http://localhost:8085/`).
If the default port is taken, the script will try the next available port in the range 8085-8095.


## APIs Used
transport.opendata.ch – Swiss public transport data
Open-Meteo – Weather data
OpenStreetMap Nominatim – City geocoding

## Disclaimer

This project is not affiliated with SBB.
All data is provided by public APIs without guarantee of accuracy.

 ## Author

Aaron Frehner
© 2025
