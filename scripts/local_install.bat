@echo off
setlocal

:: Define source directory (parent of scripts folder)
set "SOURCE_DIR=%~dp0.."

:: Define target directory
set "TARGET_DIR=E:\Games\World of Warcraft\_retail_\Interface\AddOns\near"

:: Create target directory if it doesn't exist
if not exist "%TARGET_DIR%" (
    echo Creating directory: %TARGET_DIR%
    mkdir "%TARGET_DIR%"
)

:: Copy .toc and .lua files
echo Copying files to %TARGET_DIR%...
copy "%SOURCE_DIR%\*.toc" "%TARGET_DIR%\" /Y
copy "%SOURCE_DIR%\*.lua" "%TARGET_DIR%\" /Y

echo.
echo Installation complete!
pause
