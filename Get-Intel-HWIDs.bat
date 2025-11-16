@echo off
setlocal enabledelayedexpansion

:: Intel Chipset HW_ID Detection Tool
:: Lists all Intel devices with their Hardware IDs for platform identification

:: Set console window size to 75 columns and 50 lines
mode con: cols=80 lines=25

echo /**************************************************************************
echo **                  INTEL CHIPSET HW_ID DETECTION TOOL                   **
echo ** --------------------------------------------------------------------- **
echo **                                                                       **
echo **         Detects Intel hardware IDs for platform identification        **
echo **                                                                       **
echo **                 by Marcin Grygiel / www.firstever.tech                **
echo **                                                                       **
echo ** --------------------------------------------------------------------- **
echo **     Use this tool if the main updater cannot detect your platform     **
echo **     Report the detected HW_IDs for adding to compatibility list       **
echo ** --------------------------------------------------------------------- **
echo **                                                                       **
echo **     GitHub: https://github.com/FirstEver-eu/Intel-Chipset-Updater     **
echo **                                                                       **
echo *************************************************************************/
echo.

:: Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"

:: Check if PowerShell script exists in the same directory
if not exist "!SCRIPT_DIR!Get-Intel-HWIDs.ps1" (
    echo Error: Get-Intel-HWIDs.ps1 not found in current directory!
    echo.
    echo Please ensure the PowerShell script is in the same folder as this BAT file.
    pause
    exit /b 1
)

echo Running Intel HW_ID detection...
echo.

:: Change to script directory to ensure proper file access
cd /d "!SCRIPT_DIR!"

:: Run PowerShell script with execution policy bypass
powershell -ExecutionPolicy Bypass -File "Get-Intel-HWIDs.ps1"

echo.
pause