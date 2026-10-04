@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem  capture these BEFORE any shift - "shift" also shifts %0, which would
rem  collapse the script path and send the logs to the root of the drive
set "ALLARGS=%*"
set "SCRIPT=%~f0"
set "SCRIPTDIR=%~dp0"
title Network Refresh - no reboot required

rem =====================================================================
rem  net-reset-lite.bat  -  refresh the network WITHOUT a reboot
rem
rem  The little sibling of net-reset-reboot.bat, and a rewrite of
rem  netSoftReset.bat. Same idea as the original - release, flush, renew -
rem  but it finishes the job, keeps a log, and checks whether it helped.
rem
rem  THE ONE RULE OF THIS SCRIPT: NOTHING IN IT REQUIRES A REBOOT.
rem
rem  Everything here clears a cache or re-requests a lease. All of it takes
rem  effect the moment it runs. There is no shutdown or restart command
rem  anywhere in this file, and there is no "you must reboot" step.
rem
rem  Deliberately NOT included, because these DO need a reboot to apply:
rem      netsh int ip reset        netsh int ipv6 reset
rem      netsh winsock reset       netsh advfirewall reset
rem  Those live in net-reset-reboot.bat. If this script does not fix the
rem  problem, that one is the next step up - it says so at the end.
rem
rem  Because the stack is never reset, statically configured DNS servers
rem  are never wiped, so unlike the reboot version this script needs no
rem  save-and-restore dance for them. It just records them in the log.
rem
rem  Usage:
rem    net-reset-lite.bat [/adapter] [/proxy] [/y] [/force] [/dryrun]
rem    net-reset-lite.bat /verify
rem
rem    /adapter   also bounce the physical network adapters - a harder
rem               reset of the link itself, still no reboot. Virtual
rem               adapters - VMware, Hyper-V - are left alone on purpose.
rem    /proxy     also clear the system-wide WinHTTP proxy. Off by default
rem               because it changes configuration rather than refreshing
rem               state - if a proxy is needed here, this removes it.
rem    /y         skip the "are you sure" prompt
rem    /force     run even from a remote/RDP session
rem    /dryrun    print every command without running anything
rem    /verify    run ONLY the connectivity checks. Changes nothing, needs
rem               no admin rights. The normal run already checks before and
rem               after, so this is for looking again later.
rem
rem  A NOTE ON HOW SUCCESS IS JUDGED, because it matters here. None of the
rem  three tools you would reach for first can actually be trusted, and all
rem  three were checked rather than assumed:
rem    ipconfig returns exit code 0 even when it fails - a /renew that
rem      cannot reach a DHCP server still reports success. So ipconfig steps
rem      are marked [run] rather than [ ok ]: they ran, and the verdict comes
rem      from the state check afterwards, not from their exit code. netsh
rem      does report real exit codes, so netsh steps get a true [ok]/[FAIL].
rem    nslookup returns 0 for a domain that does not exist, so DNS is tested
rem      with Resolve-DnsName -ErrorAction Stop instead.
rem    ping can return 0 when a router answers "destination host
rem      unreachable" for the target, so reachability is tested with
rem      Test-Connection, which yields a result only for a real reply.
rem      Matching ping's output for "TTL=" would have worked too, but only
rem      on an English Windows.
rem
rem  Exit codes, so this can be driven from another script:
rem      0   network is up afterwards, or a dry run
rem      1   cancelled at the confirmation prompt
rem      2   refused: remote session and no /force
rem      3   ran, but the network is still down - escalate
rem      64  bad argument, nothing was run
rem
rem  Files written to netreset-logs\ next to this script - the same folder
rem  net-reset-reboot.bat uses, so the history of both sits together:
rem    netlite_<stamp>.log     step-by-step record, plus before/after
rem =====================================================================

set "DO_ADAPTER=0"
set "DO_PROXY=0"
set "ASSUME_YES=0"
set "DRYRUN=0"
set "FORCE=0"
set "VERIFY=0"
set "STEPNUM=0"
set "FAILS=0"
rem  exit code, overwritten by the verdict at the end
set "RC=0"

rem  how long to let DHCP settle before the after-checks, in seconds
set "SETTLE=6"

rem ---------- parse arguments ------------------------------------------
rem  Every flag also sets ARGOK, and anything that leaves ARGOK at 0 stops
rem  the script. That matters more here than it looks: without it a typo
rem  like /dryun is silently ignored, and instead of the preview you asked
rem  for you get the real thing.
:parse
if "%~1"=="" goto :parsed
set "ARGOK=0"
if /i "%~1"=="/adapter" ( set "DO_ADAPTER=1" & set "ARGOK=1" )
if /i "%~1"=="/proxy"   ( set "DO_PROXY=1"   & set "ARGOK=1" )
if /i "%~1"=="/y"       ( set "ASSUME_YES=1" & set "ARGOK=1" )
if /i "%~1"=="/force"   ( set "FORCE=1"      & set "ARGOK=1" )
if /i "%~1"=="/verify"  ( set "VERIFY=1"     & set "ARGOK=1" )
if /i "%~1"=="/dryrun"  ( set "DRYRUN=1"     & set "ARGOK=1" )
if /i "%~1"=="/?"       goto :usage
if /i "%~1"=="-h"       goto :usage
if /i "%~1"=="--help"   goto :usage
if "%ARGOK%"=="0" goto :badarg
shift /1
goto :parse
:parsed

rem ---------- re-launch as administrator if needed ----------------------
rem  The path and the arguments get embedded in a single-quoted PowerShell
rem  string below, so a single quote in either one would end that string
rem  early - a folder like C:\Users\Bob's PC breaks the launch outright,
rem  and an argument could inject PowerShell of its own. PowerShell escapes
rem  a quote inside a single-quoted string by doubling it, so do that.
rem  The "if defined" guard is not decorative: on an undefined variable cmd
rem  does not perform the substitution at all and leaks the literal text,
rem  and the substitution has to be !delayed! so it happens after the guard.
set "PSSCRIPT=%SCRIPT:'=''%"
set "PSARGS="
if defined ALLARGS set "PSARGS=!ALLARGS:'=''!"

rem  /verify only reads and /dryrun only prints, so neither needs elevating
if "%DRYRUN%"=="0" if "%VERIFY%"=="0" (
    net session >nul 2>&1
    if errorlevel 1 (
        echo Administrator rights are required - re-launching elevated...
        if not defined PSARGS (
            powershell -NoProfile -Command "try { Start-Process -FilePath '!PSSCRIPT!' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
        ) else (
            powershell -NoProfile -Command "try { Start-Process -FilePath '!PSSCRIPT!' -ArgumentList '!PSARGS!' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
        )
        if errorlevel 1 (
            echo.
            echo Elevation was declined - nothing has been changed.
            echo.
            pause
        )
        exit /b
    )
)

rem elevation drops us in C:\Windows\System32, so go back to the script
cd /d "%SCRIPTDIR%"

rem ---------- set up logging -------------------------------------------
set "LOGDIR=%SCRIPTDIR%netreset-logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" 2>nul
>"%LOGDIR%\write.test" echo ok 2>nul
if not exist "%LOGDIR%\write.test" (
    set "LOGDIR=%TEMP%\netreset-logs"
    if not exist "!LOGDIR!" mkdir "!LOGDIR!" 2>nul
)
del "%LOGDIR%\write.test" 2>nul

set "STAMP=%RANDOM%"
for /f "delims=" %%A in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmmss"') do set "STAMP=%%A"
set "LOG=%LOGDIR%\netlite_%STAMP%.log"
set "DNSTMP=%LOGDIR%\dns-seen_%STAMP%.tmp"

if "%VERIFY%"=="1" goto :verify_mode

>"%LOG%" echo Network refresh - no reboot - started %DATE% %TIME%
>>"%LOG%" echo Computer: %COMPUTERNAME%   User: %USERNAME%   Session: %SESSIONNAME%
>>"%LOG%" echo Options: adapter=%DO_ADAPTER% proxy=%DO_PROXY% dryrun=%DRYRUN% force=%FORCE%
>>"%LOG%" echo.

rem ---------- refuse to cut the branch we are sitting on -----------------
rem  the release/renew pair drops the IP for a few seconds. Over RDP that
rem  kills the session. The script keeps running on the machine and will
rem  renew, so it usually comes back - but "usually" is not good enough to
rem  do without asking.
set "REMOTE=0"
if defined SESSIONNAME if /i not "%SESSIONNAME%"=="Console" set "REMOTE=1"
if defined CLIENTNAME set "REMOTE=1"
if "%REMOTE%"=="1" if "%FORCE%"=="0" goto :remote_abort

rem ---------- what are we working with ----------------------------------
call :inventory

cls
echo ===============================================================
echo   NETWORK REFRESH - NO REBOOT REQUIRED
echo ===============================================================
echo.
echo   Flushes the DNS, NetBIOS, ARP, destination and neighbour
echo   caches, then releases and renews the DHCP leases.
echo.
echo   Nothing here needs a reboot. The TCP/IP and Winsock stacks
echo   are NOT touched - that is net-reset-reboot.bat's job.
echo.
if "%DO_ADAPTER%"=="1" echo   /adapter: the physical adapters will also be bounced.
if "%DO_PROXY%"=="1"   echo   /proxy:   the WinHTTP proxy will also be cleared.
echo   Expect to be offline for a few seconds around the renew.
echo.
echo   Physical adapters up: %INV_PHYUP%      Virtual adapters up: %INV_VIRTUP%
if not "%INV_VIRTUP%"=="0" echo   Heads up: release/renew also cycles the virtual adapters,
if not "%INV_VIRTUP%"=="0" echo   so VM networking will blink too.
echo.
echo   Log: %LOG%
if "%DRYRUN%"=="1" echo   *** DRY RUN - nothing will actually be changed ***
echo.

rem  set /p rather than choice, so a mistyped key does not beep at the
rem  console - choice.exe always beeps on a key outside its list and no
rem  flag turns that off. Only Y continues, same as before.
rem  The attempt counter matters: set /p returns an empty string instantly
rem  when stdin is not a console, which would otherwise spin this loop
rem  forever if the script were ever driven non-interactively without /y.
if "%ASSUME_YES%"=="1" goto :confirmed
if "%DRYRUN%"=="1" goto :confirmed
set "TRIES=0"
:confirm
set "YN="
set /p "YN=  Continue? [Y/N] "
if /i "!YN!"=="Y" goto :confirmed
if /i "!YN!"=="YES" goto :confirmed
if /i "!YN!"=="N" goto :aborted
if /i "!YN!"=="NO" goto :aborted
set /a TRIES+=1
if !TRIES! GEQ 10 (
    echo.
    echo   No usable answer after 10 attempts - cancelling.
    goto :aborted
)
echo   Type Y to continue, or N to cancel.
goto :confirm
:confirmed

echo.
echo ---------------------------------------------------------------
echo  BEFORE
echo ---------------------------------------------------------------
>>"%LOG%" echo --- BEFORE ---
>>"%LOG%" echo Physical adapters up: %INV_PHYUP%   Virtual adapters up: %INV_VIRTUP%

rem ---------- note the DNS servers, for the record ----------------------
rem  read from the registry, not from the live adapters: locale independent,
rem  it only returns servers that were set by hand, and it does not miss an
rem  adapter that happens to be down. Nothing here modifies them - this
rem  script never resets the stack, so they cannot be lost.
echo.
echo Statically configured DNS servers:
call :show_dns

rem  a full ipconfig /all into the log. This is a record, not an action, so
rem  it is not one of the numbered steps - counting a read as a "step" would
rem  overstate what the script actually did.
echo.
echo Recording the full adapter configuration in the log...
>>"%LOG%" echo --- ipconfig /all, before the refresh ---
if "%DRYRUN%"=="0" (
    ipconfig /all >>"%LOG%" 2>&1
    echo      [ ok ]
) else (
    echo      [dry ] skipped
)

rem  a proxy nobody remembers setting is a common cause of "the internet is
rem  broken while the network is fine", and clearing it needs no reboot.
rem  Printed as-is rather than parsed, so no assumption about the language
rem  Windows is running in.
echo.
echo System-wide WinHTTP proxy:
call :show_proxy

rem  if these services are not running, no amount of releasing and renewing
rem  will get an address - and starting them does not need a reboot either
echo.
echo Services the refresh depends on:
call :show_services

rem ---------- baseline, to compare against afterwards -------------------
echo.
echo Connectivity before:
call :probe_state
set "B_IPGW=%PS_IPGW%"
set "B_APIPA=%PS_APIPA%"
echo      Adapters with an IP and a gateway: %B_IPGW%
echo      Adapters stuck on a 169.254 address: %B_APIPA%
>>"%LOG%" echo State: adapters with IP+gateway=%B_IPGW% apipa=%B_APIPA%
call :run_checks
set "B_GWR=%CHK_GW%"
set "B_NET=%CHK_NET%"
set "B_DNS=%CHK_DNS%"

rem ---------- the actual work -------------------------------------------
echo.
echo ---------------------------------------------------------------
echo  REFRESH
echo ---------------------------------------------------------------

set "CMD=ipconfig /flushdns"
call :runstep "Flush the DNS resolver cache"

rem  NetBIOS is legacy and -RR only really means anything where there is a
rem  WINS server to refresh against, so on a home network these two are
rem  close to no-ops. Kept deliberately: they cost milliseconds, they cannot
rem  do any harm, and they still matter on an older LAN.
set "CMD=nbtstat -R"
call :step "Purge the NetBIOS name cache"

set "CMD=nbtstat -RR"
call :step "Release and refresh NetBIOS names"

set "CMD=netsh interface ipv4 delete arpcache"
call :step "Flush the ARP cache"

set "CMD=netsh interface ipv4 delete destinationcache"
call :step "Clear the IPv4 destination cache"

set "CMD=netsh interface ipv6 delete destinationcache"
call :step "Clear the IPv6 destination cache"

set "CMD=netsh interface ipv6 delete neighbors"
call :step "Clear the IPv6 neighbour cache"

if "%DO_PROXY%"=="1" (
    set "CMD=netsh winhttp reset proxy"
    call :step "Clear the system-wide WinHTTP proxy"
)

set "CMD=ipconfig /release"
call :runstep "Release the IPv4 DHCP leases"

set "CMD=ipconfig /release6"
call :runstep "Release the IPv6 DHCP leases"

rem  bouncing the link while the lease is released is the cleanest moment
if "%DO_ADAPTER%"=="1" call :bounce_adapters

set "CMD=ipconfig /renew"
call :runstep "Request fresh IPv4 leases"

set "CMD=ipconfig /renew6"
call :runstep "Request fresh IPv6 leases"

rem  this asks the DNS server to update this machine's record, which only
rem  does anything where the server accepts dynamic updates - an Active
rem  Directory domain, essentially - so on a home network it is close to a
rem  no-op. Kept for the same reason as the nbtstat pair: free, harmless,
rem  and it does the right thing the day this machine joins a domain.
set "CMD=ipconfig /registerdns"
call :runstep "Re-register this machine in DNS"

rem  flush a second time, now that the new lease and its DNS servers are
rem  in place. Two reasons: anything cached against the old lease is gone,
rem  and it means the DNS check below has to do a real lookup instead of
rem  being handed the answer the BEFORE check already cached.
set "CMD=ipconfig /flushdns"
call :runstep "Flush the DNS cache again, against the new lease"

rem ---------- let DHCP settle, then look again --------------------------
echo.
echo ---------------------------------------------------------------
echo  AFTER
echo ---------------------------------------------------------------
>>"%LOG%" echo --- AFTER ---

if "%DRYRUN%"=="0" (
    echo.
    echo Giving DHCP %SETTLE% seconds to settle...
    rem  ping as the sleep: timeout.exe fails when stdin is redirected
    ping -n %SETTLE% 127.0.0.1 >nul 2>&1
)

echo.
echo Connectivity after:
call :probe_state
set "A_IPGW=%PS_IPGW%"
set "A_APIPA=%PS_APIPA%"
echo      Adapters with an IP and a gateway: %A_IPGW%
echo      Adapters stuck on a 169.254 address: %A_APIPA%
>>"%LOG%" echo State: adapters with IP+gateway=%A_IPGW% apipa=%A_APIPA%
call :run_checks
set "A_GWR=%CHK_GW%"
set "A_NET=%CHK_NET%"
set "A_DNS=%CHK_DNS%"

rem ---------- summary ---------------------------------------------------
echo.
echo ===============================================================
echo   BEFORE / AFTER
echo ===============================================================
echo.
echo                                    BEFORE     AFTER
call :row "Default gateway reachable"      "%B_GWR%"   "%A_GWR%"
call :row "Internet reachable"             "%B_NET%"   "%A_NET%"
call :row "DNS resolving"                  "%B_DNS%"   "%A_DNS%"
call :row "Adapters with IP + gateway"     "%B_IPGW%"  "%A_IPGW%"
call :row "Adapters on a 169.254 address"  "%B_APIPA%" "%A_APIPA%"
echo.
>>"%LOG%" echo.
>>"%LOG%" echo BEFORE/AFTER  gateway %B_GWR%/%A_GWR%  internet %B_NET%/%A_NET%  dns %B_DNS%/%A_DNS%
>>"%LOG%" echo BEFORE/AFTER  ip+gw %B_IPGW%/%A_IPGW%  apipa %B_APIPA%/%A_APIPA%

if "%FAILS%"=="0" (
    echo   %STEPNUM% steps ran, none reported an error.
) else (
    echo   %STEPNUM% steps ran, %FAILS% reported an error - check the log.
)
echo   Log: %LOG%
>>"%LOG%" echo.
>>"%LOG%" echo Finished %DATE% %TIME% - %STEPNUM% steps, %FAILS% failures.

if "%DRYRUN%"=="1" (
    echo.
    echo   Dry run complete - no changes were made.
    goto :done
)

echo.
echo ===============================================================
if /i "%A_NET%"=="up" if /i "%A_DNS%"=="up" goto :verdict_good
goto :verdict_bad

:verdict_good
set "RC=0"
echo   Network is up. NO REBOOT NEEDED - you are done.
>>"%LOG%" echo VERDICT: up - no reboot needed.
goto :verdict_end

:verdict_bad
set "RC=3"
echo   Still not working.
echo.
echo   This script only clears caches and re-requests leases, which
echo   is everything that can be fixed without a reboot. If the
echo   problem survived that, it is likely in the TCP/IP or Winsock
echo   stack itself, and resetting those DOES require a reboot:
echo.
echo       net-reset-reboot.bat /dryrun     see what it would do
echo       net-reset-reboot.bat             do it
echo.
rem  the "?" guard matters: if the state probe could not run, A_APIPA is "?"
rem  rather than a number, and without it this fires a false DHCP warning
if not "%A_APIPA%"=="0" if not "%A_APIPA%"=="?" echo   An adapter is on a 169.254 address, which means DHCP did not
if not "%A_APIPA%"=="0" if not "%A_APIPA%"=="?" echo   answer at all - check the cable, the Wi-Fi and the router too.
if "%DO_ADAPTER%"=="0" echo   Worth trying first, still no reboot:  net-reset-lite.bat /adapter
>>"%LOG%" echo VERDICT: still down - net-reset-reboot.bat suggested.
goto :verdict_end

:verdict_end
echo ===============================================================

:done
echo.
if "%ASSUME_YES%"=="0" pause
rem  exit code so this can be used from another script:
rem    0 = network is up (or a dry run)   3 = still down after the refresh
rem    1 = cancelled   2 = refused, remote session   64 = bad argument
endlocal & exit /b %RC%

rem =====================================================================
rem  /verify - the checks on their own, changing nothing
rem =====================================================================
:verify_mode
set "PREVLOG="
for /f "delims=" %%A in ('dir /b /a-d /o-d "%LOGDIR%\netlite_*.log" 2^>nul') do if not defined PREVLOG set "PREVLOG=%LOGDIR%\%%A"
if defined PREVLOG (set "LOG=%PREVLOG%") else (set "LOG=%LOGDIR%\netlite_verify_%STAMP%.log")

cls
echo ===============================================================
echo   CONNECTIVITY CHECK - read only
echo ===============================================================
echo.
if defined PREVLOG (
    echo   Appending to the log from the last run:
) else (
    echo   No previous run found, starting a new log:
)
echo   %LOG%
echo.
>>"%LOG%" echo.
>>"%LOG%" echo --- VERIFY - %DATE% %TIME% ---

call :probe_state
echo      Adapters with an IP and a gateway: %PS_IPGW%
echo      Adapters stuck on a 169.254 address: %PS_APIPA%
>>"%LOG%" echo State: adapters with IP+gateway=%PS_IPGW% apipa=%PS_APIPA%
echo.
call :run_checks

echo.
echo Statically configured DNS servers right now:
call :show_dns

echo.
echo System-wide WinHTTP proxy:
call :show_proxy

echo.
echo Services the refresh depends on:
call :show_services

echo.
echo ===============================================================
echo   Nothing was changed. Compare against the BEFORE/AFTER
echo   sections in: %LOG%
echo ===============================================================
echo.
pause
endlocal
exit /b 0

rem =====================================================================
rem  helpers
rem
rem  The PowerShell one-liners live in their own subroutines on purpose.
rem  Inside a parenthesised IF block cmd would read the pipes and brackets
rem  in them as its own syntax and the line would not parse.
rem =====================================================================

rem  :row <label> <before> <after> - one line of the before/after table.
rem  The values are padded here, at display time, rather than being stored
rem  padded. Storing them padded is what broke the verdict once already:
rem  "up  " does not equal "up", so the end-of-run check never fired and it
rem  reported failure on a working network.
:row
set "L=%~1                                   "
set "B=%~2    "
set "A=%~3    "
echo   !L:~0,33!!B:~0,4!       !A:~0,4!
exit /b 0

rem  :inventory - count adapters that are up, physical vs virtual
:inventory
set "INV_PHYUP=?"
set "INV_VIRTUP=?"
for /f "delims=" %%A in ('powershell -NoProfile -Command "@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }).Count"') do set "INV_PHYUP=%%A"
for /f "delims=" %%A in ('powershell -NoProfile -Command "@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Virtual -eq $true -and $_.Status -eq 'Up' }).Count"') do set "INV_VIRTUP=%%A"
exit /b 0

rem  :probe_state - the two numbers that say whether DHCP actually worked.
rem  APIPA is only counted on adapters that are UP: a disconnected adapter
rem  always holds a stale 169.254 address and would be a false alarm.
:probe_state
set "PS_IPGW=?"
set "PS_APIPA=?"
for /f "delims=" %%A in ('powershell -NoProfile -Command "@(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway }).Count"') do set "PS_IPGW=%%A"
for /f "delims=" %%A in ('powershell -NoProfile -Command "@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '169.254.*' -and (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Status -eq 'Up' }).Count"') do set "PS_APIPA=%%A"
exit /b 0

rem  :find_gateway - lowest-metric IPv4 default gateway, into GW
:find_gateway
set "GW="
for /f "delims=" %%A in ('powershell -NoProfile -Command "(Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop"') do set "GW=%%A"
exit /b 0

rem  :run_checks - the three probes, into CHK_GW / CHK_NET / CHK_DNS
:run_checks
call :find_gateway
if defined GW (
    call :check_ping "Default gateway !GW!" "!GW!"
    set "CHK_GW=!CHKRESULT!"
) else (
    echo      Default gateway              [none]
    >>"%LOG%" echo CHECK: default gateway - none found
    set "CHK_GW=none"
)
call :check_ping "Internet 8.8.8.8" "8.8.8.8"
set "CHK_NET=!CHKRESULT!"
call :check_dns
set "CHK_DNS=!CHKRESULT!"
exit /b 0

rem  :check_ping <label> <target> - is this host actually answering?
rem
rem  Test-Connection rather than ping.exe, for two reasons that both came
rem  out of testing this script:
rem    1. ping's exit code alone is not trustworthy - a router answering
rem       "destination host unreachable" on the target's behalf can still
rem       produce exit code 0. Test-Connection returns a result object only
rem       for a real echo reply, so there is nothing to misread.
rem    2. the obvious fix for that - grepping the output for "TTL=" - only
rem       works on an English Windows. Test-Connection needs no text
rem       matching at all, so it behaves the same in any UI language.
rem  It also replaces two ping invocations per check with one call that both
rem  logs the detail and returns the verdict.
rem
rem  A failure here is information, not a script error: no connectivity is
rem  usually the whole reason someone is running this. It never counts
rem  towards FAILS.
:check_ping
set "CHKRESULT=down"
>>"%LOG%" echo CHECK: %~1
if "%DRYRUN%"=="1" (
    echo      %~1  [dry ]
    >>"%LOG%" echo     result: skipped - dry run
    set "CHKRESULT=dry"
    exit /b 0
)
powershell -NoProfile -Command "$t = '%~2'; $r = Test-Connection -ComputerName $t -Count 2 -ErrorAction SilentlyContinue; if ($r) { $r | Format-Table -AutoSize | Out-String; exit 0 } else { 'no reply from ' + $t; exit 1 }" >>"%LOG%" 2>&1
if errorlevel 1 (
    echo      %~1  [down]
    >>"%LOG%" echo     result: unreachable
) else (
    echo      %~1  [ up ]
    >>"%LOG%" echo     result: reachable
    set "CHKRESULT=up"
)
exit /b 0

rem  :check_dns - Resolve-DnsName, not nslookup: nslookup exits 0 even for
rem  a domain that does not exist, so its exit code proves nothing.
:check_dns
set "CHKRESULT=down"
>>"%LOG%" echo CHECK: DNS resolution of www.microsoft.com
if "%DRYRUN%"=="1" (
    echo      DNS resolution              [dry ]
    >>"%LOG%" echo     result: skipped - dry run
    set "CHKRESULT=dry"
    exit /b 0
)
powershell -NoProfile -Command "try { $r = Resolve-DnsName -Name www.microsoft.com -DnsOnly -ErrorAction Stop; $r | Select-Object -First 4 | Out-String; exit 0 } catch { $_.Exception.Message; exit 1 }" >>"%LOG%" 2>&1
if errorlevel 1 (
    echo      DNS resolution              [down]
    >>"%LOG%" echo     result: failed
) else (
    echo      DNS resolution              [ up ]
    >>"%LOG%" echo     result: ok
    set "CHKRESULT=up"
)
exit /b 0

rem  :capture_dns - list adapters with hand-set DNS as  name|servers
:capture_dns
powershell -NoProfile -Command "Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $_.InterfaceGuid; $ns = (Get-ItemProperty -Path $p -Name NameServer -ErrorAction SilentlyContinue).NameServer; if ($ns) { $_.Name + '|' + $ns } }" > "%DNSTMP%" 2>nul
exit /b 0

rem  :show_dns - print the static DNS servers as they stand right now
:show_dns
call :capture_dns
set "FOUND=0"
for %%F in ("%DNSTMP%") do if %%~zF GTR 0 set "FOUND=1"
if "%FOUND%"=="1" (
    for /f "usebackq tokens=1,* delims=|" %%A in ("%DNSTMP%") do (
        echo      %%A  ^>  %%B
        >>"%LOG%" echo     DNS: %%A = %%B
    )
    echo      Left untouched - this script never resets the stack.
) else (
    echo      None - every adapter takes its DNS from DHCP.
    >>"%LOG%" echo     DNS: none set statically
)
del "%DNSTMP%" 2>nul
exit /b 0

rem  :show_proxy - print the WinHTTP proxy exactly as netsh reports it.
rem  Deliberately not parsed: netsh output is localised, so matching on
rem  "Proxy Server" would quietly stop working on a non-English Windows.
rem  for /f skips blank lines for us, so this just indents what netsh says.
:show_proxy
>>"%LOG%" echo --- WinHTTP proxy before the refresh ---
for /f "delims=" %%A in ('netsh winhttp show proxy 2^>nul') do (
    echo      %%A
    >>"%LOG%" echo     %%A
)
if "%DO_PROXY%"=="0" echo      Not changed. Pass /proxy to clear it.
exit /b 0

rem  :show_services - the two services a DHCP refresh cannot work without.
rem  Status comes back as a .NET enum name, so "Running" is the same string
rem  in every UI language - safe to compare against, unlike netsh's text.
:show_services
for %%S in (Dhcp Dnscache) do call :one_service %%S
exit /b 0

:one_service
set "SVCSTATE=?"
for /f "delims=" %%A in ('powershell -NoProfile -Command "(Get-Service -Name '%~1' -ErrorAction SilentlyContinue).Status"') do set "SVCSTATE=%%A"
if /i "%SVCSTATE%"=="Running" (
    echo      %~1 service: Running
    >>"%LOG%" echo     service %~1 = Running
) else (
    echo      %~1 service: %SVCSTATE%  ^<-- not running, this is the problem
    echo        start it with:  sc start %~1
    >>"%LOG%" echo     service %~1 = %SVCSTATE% - NOT RUNNING
)
exit /b 0

rem  :bounce_adapters - disable and re-enable the physical adapters.
rem  Scoped to -Physical so VMware and Hyper-V switches are left alone;
rem  bouncing those would disrupt running VMs for no benefit here.
rem  Still no reboot - the driver reloads on its own.
:bounce_adapters
set /a STEPNUM+=1
set "N=0!STEPNUM!"
echo.
echo [!N:~-2!] Bounce the physical network adapters
echo      Restart-NetAdapter on every physical adapter that is up
>>"%LOG%" echo === [!N:~-2!] Bounce the physical network adapters
if "%DRYRUN%"=="1" (
    echo      [dry ] skipped
    >>"%LOG%" echo     result: skipped - dry run
    exit /b 0
)
powershell -NoProfile -Command "$a = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }); if ($a.Count -eq 0) { 'no physical adapters are up - nothing to bounce'; exit 0 }; $a | ForEach-Object { $_.Name }; $a | Restart-NetAdapter -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 5; exit 0" >>"%LOG%" 2>&1
if errorlevel 1 (
    set /a FAILS+=1
    echo      [FAIL] see the log
    >>"%LOG%" echo     result: FAILED
) else (
    echo      [ ok ]
    >>"%LOG%" echo     result: ok
)
>>"%LOG%" echo.
exit /b 0

rem  :step - a command whose exit code can be trusted - netsh, nbtstat.
rem  Counts towards FAILS.
:step
set /a STEPNUM+=1
set "N=0!STEPNUM!"
echo.
echo [!N:~-2!] %~1
echo      %CMD%
>>"%LOG%" echo === [!N:~-2!] %~1
>>"%LOG%" echo     command: %CMD%
if "%DRYRUN%"=="1" (
    echo      [dry ] skipped
    >>"%LOG%" echo     result: skipped - dry run
    exit /b 0
)
%CMD% >>"%LOG%" 2>&1
if errorlevel 1 (
    set /a FAILS+=1
    echo      [FAIL] exit code !errorlevel!
    >>"%LOG%" echo     result: FAILED
) else (
    echo      [ ok ]
    >>"%LOG%" echo     result: ok
)
>>"%LOG%" echo.
exit /b 0

rem  :runstep - an ipconfig command. ipconfig exits 0 even when it fails,
rem  so there is nothing honest to report beyond "it ran" - the real answer
rem  comes from the AFTER section. Marked [run] so the output does not
rem  claim a success it cannot actually verify, and never counts a failure.
:runstep
set /a STEPNUM+=1
set "N=0!STEPNUM!"
echo.
echo [!N:~-2!] %~1
echo      %CMD%
>>"%LOG%" echo === [!N:~-2!] %~1
>>"%LOG%" echo     command: %CMD%
if "%DRYRUN%"=="1" (
    echo      [dry ] skipped
    >>"%LOG%" echo     result: skipped - dry run
    exit /b 0
)
%CMD% >>"%LOG%" 2>&1
echo      [run ]
>>"%LOG%" echo     result: ran - ipconfig does not report a usable exit code
>>"%LOG%" echo.
exit /b 0

:remote_abort
echo.
echo ===============================================================
echo   REMOTE SESSION DETECTED
echo ===============================================================
echo.
echo   Session: %SESSIONNAME%   Client: %CLIENTNAME%
echo.
echo   Releasing the IP will drop this Remote Desktop session. The
echo   script renews straight afterwards and keeps running on the
echo   machine, so the connection usually comes back on its own -
echo   but "usually" is not a promise, and if it does not there is
echo   no way back in.
echo.
echo   Run it from the console, or re-run with  /force  to accept
echo   the risk. There is no reboot involved either way.
echo.
>>"%LOG%" echo ABORTED: remote session detected and /force was not given.
pause
endlocal
exit /b 2

:badarg
echo.
echo ===============================================================
echo   UNRECOGNISED OPTION: %~1
echo ===============================================================
echo.
echo   Nothing has been run. Valid options are:
echo.
echo      /adapter  /proxy  /y  /force  /dryrun  /verify  /?
echo.
echo   This stops rather than ignoring the option on purpose. A typo
echo   such as  /dryun  instead of  /dryrun  would otherwise be
echo   silently dropped, and you would get the real refresh when you
echo   were expecting a harmless preview.
echo.
pause
endlocal & exit /b 64

:aborted
echo.
echo Cancelled - nothing was changed.
>>"%LOG%" echo ABORTED: user declined at the confirmation prompt.
echo.
pause
endlocal
exit /b 1

:usage
echo net-reset-lite.bat [/adapter] [/proxy] [/y] [/force] [/dryrun]
echo net-reset-lite.bat /verify
echo.
echo   Refreshes the network without a reboot: flushes the DNS, NetBIOS,
echo   ARP, destination and neighbour caches, then releases and renews
echo   the DHCP leases. Checks connectivity before and after.
echo.
echo   /adapter   also bounce the physical adapters - still no reboot.
echo              Virtual adapters are left alone.
echo   /proxy     also clear the system-wide WinHTTP proxy
echo   /y         skip the confirmation prompt
echo   /force     run even from a remote session
echo   /dryrun    print the commands without running them
echo   /verify    connectivity checks only. Changes nothing, no admin.
echo.
echo   Exit codes: 0 up, 1 cancelled, 2 remote refused, 3 still down,
echo               64 bad argument.
echo.
echo   Nothing in this script requires a reboot. For the TCP/IP and
echo   Winsock stack resets, which do, see net-reset-reboot.bat
endlocal & exit /b 0