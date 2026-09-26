@echo off
setlocal enabledelayedexpansion
title Pixel 9 Pro Fold - Emergency Wi-Fi Restore
echo ========================================================
echo   Pixel 9 Pro Fold Wi-Fi Emergency Restore Tool
echo ========================================================
echo.

set "ADB=adb"
where adb >nul 2>&1
if %errorlevel% neq 0 (
    if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" (
        set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
    )
)

set "SERIAL="
for /f "tokens=1" %%A in ('%ADB% devices 2^>nul ^| findstr /i "47111FDKD000XS comet"') do (
    set "SERIAL=%%A"
)

if "%SERIAL%"=="" (
    for /f "tokens=1" %%A in ('%ADB% devices -l 2^>nul ^| findstr /i "comet"') do (
        set "SERIAL=%%A"
    )
)

if "%SERIAL%"=="" (
    set "SERIAL=47111FDKD000XS"
)

echo Target Device: %SERIAL%
echo.
echo [1/3] Bringing down test interfaces (wondertap0, wonder0)...
%ADB% -s %SERIAL% shell "su -c 'ip link set wondertap0 down 2>/dev/null; /data/local/tmp/iw dev wonder0 del 2>/dev/null'"

echo [2/3] Cycling Android Wi-Fi service...
%ADB% -s %SERIAL% shell "su -c 'cmd wifi set-wifi-enabled disabled; sleep 2; cmd wifi set-wifi-enabled enabled'"

echo [3/3] Waiting for Wi-Fi reconnection...
%SystemRoot%\System32\ping.exe -n 6 127.0.0.1 >nul

echo.
echo ===================== Connection Status =====================
%ADB% -s %SERIAL% shell "su -c 'cmd wifi status'" | findstr /i "connected enabled SSID"
%ADB% -s %SERIAL% shell "su -c 'ip addr show wlan0'" | findstr /i "inet"
echo ============================================================
echo.
echo If your Wi-Fi icon is back, you are good to go!
pause
