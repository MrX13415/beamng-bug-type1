@echo off

cls
pushd %~dp0..\bug

:: Get git abbreviated commit hash ...
for /f "delims=" %%i in ('git log -1 --pretty^=%%h') do set gitHash=%%i

echo.
echo. Publishing using commit %gitHash% ...
echo.

:: Compress ...
set "zip=awbug-%gitHash%.zip"
echo.
echo.   Compress "%zip%" ...
echo.
if not exist "..\Publish-AW\" mkdir "..\Publish-AW\"
if exist "..\Publish-AW\%zip%" del "..\Publish-AW\%zip%"
pwsh -Command "Compress-Archive -Path '.\*' -DestinationPath '..\Publish-AW\%zip%'"

:: Open output folder in explorer ...
explorer ..\Publish

echo. Done

popd
pause
