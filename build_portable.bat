@echo off
REM Build a portable (loose-layout) version of SSH Panel using Enigma Virtual Box.
REM Requires: winget install Enigma.VirtualBox

cd /d "%~dp0"
echo Creating portable layout...
"%programfiles(x86)%\Enigma Virtual Box\enigmavbconsole.exe" ".\ssh_panel_portable.evb"

echo Done. Portable build in .\SSH_Panel_Portable.exe
set /p DUMMY=Press any key to exit...
