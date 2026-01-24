Clear-Host
Write-Host "Welcome to the SBB CLI Launcher"
Write-Host ""

while ($true) {
    $choice = Read-Host "Choose an option: (G)UI or (C)LI"
    
    switch ($choice.ToLower()) {
        'g' {
            Write-Host "Starting GUI version..."
            # Assuming SBB_CLI_GUI.ps1 is in the same directory
            & ".\SBB_CLI_GUI.ps1"
            break
        }
        'c' {
            Write-Host "Starting CLI version..."
            # Assuming SBB_CLI.ps1 is in the same directory
            & ".\SBB_CLI.ps1"
            break
        }
        default {
            Write-Host "Invalid choice. Please choose 'G' or 'C'."
        }
    }
}
