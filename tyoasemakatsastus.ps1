<#
.SYNOPSIS
    Työasemakatsastus - Windows-koneen peruskunnon tarkistus.

.DESCRIPTION
    Käy läpi samat asiat, jotka helpdeskissä tarkistetaan ensimmäisenä, kun
    käyttäjä kertoo koneen olevan hidas tai jonkin asian ei toimivan:
    levytila, Windows Update, tärkeät palvelut, virhelokit, verkko,
    käynnissäoloaika ja muistin käyttö.

    Tuloksista tehdään HTML-raportti skriptin kansioon ja lyhyt yhteenveto
    tulostetaan konsoliin. Toimii Windows PowerShell 5.1:llä ja PowerShell 7:llä,
    eikä vaadi admin-oikeuksia.

.EXAMPLE
    .\tyoasemakatsastus.ps1
#>

# --- Asetukset ---------------------------------------------------------------
# Kynnysarvot ovat yhdessä paikassa, jotta niitä on helppo muuttaa.
$DiskWarningPercent   = 15    # vapaata tilaa alle tämän = huomio
$DiskCriticalPercent  = 5     # vapaata tilaa alle tämän = kriittinen
$UpdateWarningDays    = 30    # viimeisimmästä päivityksestä yli näin monta päivää = huomio
$EventWarningCount    = 10    # virheitä 24 h aikana yli tämän = huomio
$UptimeWarningDays    = 14    # käynnissä ilman uudelleenkäynnistystä yli tämän = huomio
$MemoryWarningPercent = 90    # muistin käyttö yli tämän = huomio

# Palvelut, joiden tila tarkistetaan
$ServicesToCheck = @('wuauserv', 'Dnscache', 'Dhcp', 'WinDefend')


# --- Apufunktiot -------------------------------------------------------------

# Kaikki tarkistukset palauttavat samanmuotoisen tuloksen.
# Tila on aina yksi näistä: OK, Huomio, Kriittinen, Ei saatavilla.
# Nimi täytetään pääohjelmassa.
function New-CheckResult {
    param($Tila, $Yhteenveto, $Tiedot = @())

    [PSCustomObject]@{
        Nimi       = ''
        Tila       = $Tila
        Yhteenveto = $Yhteenveto
        Tiedot     = @($Tiedot)
    }
}

# Muuttaa tekstin HTML-turvalliseksi (esim. < ja > lokiviesteissä)
function ConvertTo-HtmlText {
    param($Text)
    ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}


# --- Tarkistukset ------------------------------------------------------------

function Test-DiskSpace {
    # DriveType 3 = paikallinen kiintolevy (ei USB-tikkuja eikä verkkolevyjä)
    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop

    $tila = 'OK'
    $tiedot = @()
    $lowest = $null

    foreach ($disk in $disks) {
        if (-not $disk.Size) { continue }

        $freePercent = [math]::Round($disk.FreeSpace / $disk.Size * 100, 1)
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $tiedot += "$($disk.DeviceID) $freeGB Gt vapaana / $sizeGB Gt ($freePercent %)"

        if ($freePercent -lt $DiskCriticalPercent) {
            $tila = 'Kriittinen'
        }
        elseif ($freePercent -lt $DiskWarningPercent -and $tila -ne 'Kriittinen') {
            $tila = 'Huomio'
        }

        if ($null -eq $lowest -or $freePercent -lt $lowest.Percent) {
            $lowest = @{ Drive = $disk.DeviceID; Percent = $freePercent }
        }
    }

    if (-not $lowest) {
        return New-CheckResult 'Ei saatavilla' 'Kiintolevyjä ei löytynyt'
    }

    $yhteenveto = "Levyjä $($tiedot.Count), vähiten vapaata: $($lowest.Drive) $($lowest.Percent) %"
    New-CheckResult $tila $yhteenveto $tiedot
}


function Test-WindowsUpdates {
    $tila = 'OK'
    $tiedot = @()
    $yhteenveto = @()
    $failed = 0

    # 1) Viimeisin asennettu päivitys. Joiltain päivityksiltä puuttuu
    #    asennuspäivä, joten ne suodatetaan pois.
    try {
        $latest = Get-HotFix -ErrorAction Stop |
            Where-Object { $_.InstalledOn } |
            Sort-Object InstalledOn -Descending |
            Select-Object -First 1

        if ($latest) {
            $days = ((Get-Date) - $latest.InstalledOn).Days
            $tiedot += "Viimeisin päivitys: $($latest.HotFixID), asennettu $($latest.InstalledOn.ToString('d.M.yyyy')) ($days vrk sitten)"
            $yhteenveto += "viimeisin päivitys $days vrk sitten"
            if ($days -gt $UpdateWarningDays) { $tila = 'Huomio' }
        }
        else {
            $tiedot += 'Asennettuja päivityksiä ei löytynyt'
            $tila = 'Huomio'
        }
    }
    catch {
        $tiedot += "Päivityshistoria: ei saatavilla ($($_.Exception.Message))"
        $failed++
    }

    # 2) Odottavat päivitykset Windows Updaten omasta rajapinnasta.
    #    Online = $false tarkoittaa, että käytetään Windowsin viimeisimmän
    #    päivitystarkistuksen tietoja eikä haeta mitään netistä.
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $searcher.Online = $false
        $pending = $searcher.Search('IsInstalled=0 and IsHidden=0').Updates

        if ($pending.Count -gt 0) {
            $tila = 'Huomio'
            $yhteenveto += "$($pending.Count) odottaa asennusta"
            foreach ($update in $pending) {
                $tiedot += "Odottaa: $($update.Title)"
            }
        }
        else {
            $yhteenveto += 'ei odottavia päivityksiä'
            $tiedot += 'Ei odottavia päivityksiä'
        }
    }
    catch {
        $tiedot += "Odottavat päivitykset: ei saatavilla ($($_.Exception.Message))"
        $failed++
    }

    # 3) Odottaako kone uudelleenkäynnistystä päivitysten takia
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $tila = 'Huomio'
        $yhteenveto += 'uudelleenkäynnistys odottaa'
        $tiedot += 'Uudelleenkäynnistys odottaa päivitysten asennusta'
    }

    if ($failed -eq 2) {
        return New-CheckResult 'Ei saatavilla' 'Päivitystietoja ei voitu lukea' $tiedot
    }

    # Iso alkukirjain yhteenvedon alkuun
    $text = $yhteenveto -join ', '
    $text = $text.Substring(0, 1).ToUpper() + $text.Substring(1)
    New-CheckResult $tila $text $tiedot
}


function Test-CriticalServices {
    $tila = 'OK'
    $tiedot = @()
    $problems = 0

    foreach ($name in $ServicesToCheck) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue

        if (-not $service) {
            # Esim. Defenderin tilalla voi olla jokin muu virustorjunta
            $tiedot += "${name}: palvelua ei löydy"
            if ($tila -eq 'OK') { $tila = 'Huomio' }
            $problems++
            continue
        }

        $label = "$($service.DisplayName) ($name)"

        if ($service.Status -eq 'Running') {
            $tiedot += "${label}: käynnissä"
        }
        elseif ($service.StartType -eq 'Disabled') {
            $tiedot += "${label}: poistettu käytöstä"
            $tila = 'Kriittinen'
            $problems++
        }
        elseif ($service.StartType -eq 'Automatic') {
            $tiedot += "${label}: pysäytetty, vaikka pitäisi käynnistyä automaattisesti"
            $tila = 'Kriittinen'
            $problems++
        }
        else {
            # Manual-palvelut (esim. Windows Update) käynnistyvät vain tarvittaessa,
            # joten pysäytetty tila on niille normaali.
            $tiedot += "${label}: pysäytetty, käynnistyy tarvittaessa"
        }
    }

    if ($problems -eq 0) {
        $yhteenveto = "$($ServicesToCheck.Count) palvelua tarkistettu, kaikki kunnossa"
    }
    else {
        $yhteenveto = "$($ServicesToCheck.Count) palvelua tarkistettu, ongelmia: $problems"
    }
    New-CheckResult $tila $yhteenveto $tiedot
}


function Test-EventLogErrors {
    $since = (Get-Date).AddDays(-1)
    $logs = [ordered]@{ 'System' = 'Järjestelmä'; 'Application' = 'Sovellus' }
    $allErrors = @()
    $tiedot = @()
    $readOk = 0

    # Lokit luetaan erikseen, ettei yhden lokin ongelma estä toisen lukemista
    foreach ($log in $logs.Keys) {
        try {
            $events = Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 2; StartTime = $since } -ErrorAction Stop
            $allErrors += $events
            $tiedot += "$($logs[$log])-loki: $(@($events).Count) virhettä"
            $readOk++
        }
        catch {
            # Get-WinEvent heittää virheen myös silloin, kun tapahtumia ei ole yhtään.
            # Se ei ole oikea ongelma, vaan tarkoittaa nollaa virhettä.
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                $tiedot += "$($logs[$log])-loki: 0 virhettä"
                $readOk++
            }
            else {
                $tiedot += "$($logs[$log])-loki: ei saatavilla ($($_.Exception.Message))"
            }
        }
    }

    if ($readOk -eq 0) {
        return New-CheckResult 'Ei saatavilla' 'Tapahtumalokeja ei voitu lukea' $tiedot
    }

    # 5 uusinta virhettä otsikkotasolla (viestin ensimmäinen rivi)
    $newest = $allErrors | Sort-Object TimeCreated -Descending | Select-Object -First 5
    foreach ($event in $newest) {
        $message = '(ei kuvausta)'
        if ($event.Message) {
            $message = ($event.Message -split "`r?`n")[0]
            if ($message.Length -gt 120) { $message = $message.Substring(0, 120) + '...' }
        }
        $time = $event.TimeCreated.ToString('d.M. HH:mm')
        $tiedot += "$time | $($logs[$event.LogName]) | $($event.ProviderName) (ID $($event.Id)) | $message"
    }

    $count = @($allErrors).Count
    $tila = 'OK'
    if ($count -gt $EventWarningCount) { $tila = 'Huomio' }
    New-CheckResult $tila "$count virhettä viimeisen 24 tunnin aikana" $tiedot
}


function Test-Network {
    # Aktiivinen yhteys = verkkosovitin, jolla on oletusyhdyskäytävä
    $config = Get-NetIPConfiguration -ErrorAction Stop |
        Where-Object { $_.IPv4DefaultGateway } |
        Select-Object -First 1

    if (-not $config) {
        return New-CheckResult 'Kriittinen' 'Ei aktiivista verkkoyhteyttä (oletusyhdyskäytävä puuttuu)'
    }

    $ip = $config.IPv4Address.IPAddress -join ', '
    $gateway = $config.IPv4DefaultGateway.NextHop -join ', '
    # AddressFamily 2 = IPv4
    $dns = ($config.DNSServer | Where-Object { $_.AddressFamily -eq 2 }).ServerAddresses -join ', '

    $tiedot = @(
        "Verkkosovitin: $($config.InterfaceAlias)"
        "IP-osoite: $ip"
        "Oletusyhdyskäytävä: $gateway"
        "DNS-palvelimet: $dns"
    )

    # Toimiiko yhteys ulos (ping) ja toimiiko nimipalvelu (DNS)
    $pingOk = Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet
    try {
        Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction Stop | Out-Null
        $dnsOk = $true
    }
    catch {
        $dnsOk = $false
    }

    if ($pingOk) { $tiedot += 'Ping 8.8.8.8: onnistui' } else { $tiedot += 'Ping 8.8.8.8: EI vastausta' }
    if ($dnsOk)  { $tiedot += 'DNS-kysely (www.microsoft.com): onnistui' } else { $tiedot += 'DNS-kysely (www.microsoft.com): EPÄONNISTUI' }

    if ($pingOk -and $dnsOk) {
        return New-CheckResult 'OK' "Yhteys toimii, IP $ip" $tiedot
    }
    if (-not $pingOk -and -not $dnsOk) {
        return New-CheckResult 'Kriittinen' 'Ei yhteyttä internetiin' $tiedot
    }
    if (-not $dnsOk) {
        return New-CheckResult 'Kriittinen' 'Ping toimii, mutta DNS-nimipalvelu ei' $tiedot
    }
    New-CheckResult 'Kriittinen' 'DNS toimii, mutta ping 8.8.8.8 ei vastaa' $tiedot
}


function Test-Uptime {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $uptime = (Get-Date) - $os.LastBootUpTime
    $days = [math]::Floor($uptime.TotalDays)

    $tiedot = @("Käynnistetty viimeksi: $($os.LastBootUpTime.ToString('d.M.yyyy HH:mm'))")
    $tila = 'OK'
    if ($days -gt $UptimeWarningDays) {
        $tila = 'Huomio'
        $tiedot += 'Suositus: käynnistä kone uudelleen (Käynnistä uudelleen, ei Sammuta)'
    }

    New-CheckResult $tila "Käynnissä $days vrk $($uptime.Hours) h" $tiedot
}


function Test-Memory {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop

    # Arvot ovat kilotavuina, joten jakamalla 1MB:llä saadaan gigatavut
    $totalGB = $os.TotalVisibleMemorySize / 1MB
    $freeGB = $os.FreePhysicalMemory / 1MB
    $usedPercent = [math]::Round(($totalGB - $freeGB) / $totalGB * 100)

    $tiedot = @("Käytössä $([math]::Round($totalGB - $freeGB, 1)) Gt / $([math]::Round($totalGB, 1)) Gt")

    # Eniten muistia käyttävät ohjelmat. Samannimiset prosessit lasketaan
    # yhteen, koska esim. selaimella on kymmeniä prosesseja.
    $top = Get-Process | Group-Object ProcessName | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            MB   = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        }
    } | Sort-Object MB -Descending | Select-Object -First 5

    foreach ($process in $top) {
        $tiedot += "$($process.Name): $($process.MB) Mt"
    }

    $tila = 'OK'
    if ($usedPercent -gt $MemoryWarningPercent) { $tila = 'Huomio' }
    New-CheckResult $tila "Muistia käytössä $usedPercent %" $tiedot
}


# --- Raportti ----------------------------------------------------------------

# Yhteenvetorivi: "X kriittistä ongelmaa, Y huomiota, kaikki muu OK"
function Get-SummaryText {
    param($Results)

    $critical = @($Results | Where-Object { $_.Tila -eq 'Kriittinen' }).Count
    $warnings = @($Results | Where-Object { $_.Tila -eq 'Huomio' }).Count
    $unavailable = @($Results | Where-Object { $_.Tila -eq 'Ei saatavilla' }).Count

    if ($critical -eq 1) { $text = '1 kriittinen ongelma' } else { $text = "$critical kriittistä ongelmaa" }
    if ($warnings -eq 1) { $text += ', 1 huomio' } else { $text += ", $warnings huomiota" }
    if ($unavailable -eq 1) { $text += ', 1 tarkistus ei saatavilla' }
    elseif ($unavailable -gt 1) { $text += ", $unavailable tarkistusta ei saatavilla" }
    $text + ', kaikki muu OK'
}


function New-HtmlReport {
    param($Results, $ComputerName, $Created, $SummaryText)

    $cards = foreach ($result in $Results) {
        $class = switch ($result.Tila) {
            'OK'         { 'ok' }
            'Huomio'     { 'huomio' }
            'Kriittinen' { 'kriittinen' }
            default      { 'eisaatavilla' }
        }
        $items = ($result.Tiedot | ForEach-Object { "      <li>$(ConvertTo-HtmlText $_)</li>" }) -join "`n"

        @"
  <div class="kortti $class">
    <div class="otsikko">
      <h2>$(ConvertTo-HtmlText $result.Nimi)</h2>
      <span class="tila">$($result.Tila)</span>
    </div>
    <p>$(ConvertTo-HtmlText $result.Yhteenveto)</p>
    <ul>
$items
    </ul>
  </div>
"@
    }

    # Yhteenvetolaatikon väri tulee pahimman löydöksen mukaan
    $summaryClass = 'ok'
    if ($Results.Tila -contains 'Huomio') { $summaryClass = 'huomio' }
    if ($Results.Tila -contains 'Kriittinen') { $summaryClass = 'kriittinen' }

    @"
<!DOCTYPE html>
<html lang="fi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Työasemakatsastus - $(ConvertTo-HtmlText $ComputerName)</title>
<style>
  body { font-family: "Segoe UI", Arial, sans-serif; background: #f3f3f3; color: #222; margin: 0; padding: 24px; }
  .sivu { max-width: 900px; margin: 0 auto; }
  h1 { font-size: 26px; margin: 0 0 4px 0; }
  .meta { color: #555; margin: 0 0 20px 0; }
  .yhteenveto { background: #fff; border: 1px solid #ccc; border-left: 6px solid #999; padding: 14px 16px; margin-bottom: 20px; font-size: 18px; font-weight: 600; }
  .kortti { background: #fff; border: 1px solid #ccc; border-left: 6px solid #999; padding: 12px 16px; margin-bottom: 12px; }
  .ok { border-left-color: #2e7d32; }
  .huomio { border-left-color: #e0a800; }
  .kriittinen { border-left-color: #c62828; }
  .eisaatavilla { border-left-color: #888; }
  .otsikko { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
  h2 { font-size: 18px; margin: 0; }
  .tila { font-size: 13px; font-weight: bold; padding: 2px 10px; white-space: nowrap; }
  .ok .tila { background: #e3f1e4; color: #1b5e20; }
  .huomio .tila { background: #fff4cc; color: #7a5a00; }
  .kriittinen .tila { background: #fbe3e3; color: #b71c1c; }
  .eisaatavilla .tila { background: #e8e8e8; color: #444; }
  .kortti p { margin: 8px 0 4px 0; }
  ul { margin: 6px 0 0 0; padding-left: 20px; color: #444; font-size: 14px; }
  li { margin: 2px 0; word-break: break-word; }
  footer { color: #777; font-size: 13px; margin-top: 20px; }
</style>
</head>
<body>
<div class="sivu">
  <h1>Työasemakatsastus</h1>
  <p class="meta">Kone: <strong>$(ConvertTo-HtmlText $ComputerName)</strong> &nbsp;|&nbsp; Raportti luotu: $Created</p>
  <div class="yhteenveto $summaryClass">$SummaryText</div>
$($cards -join "`n")
  <footer>Raportin teki tyoasemakatsastus.ps1 (PowerShell $($PSVersionTable.PSVersion))</footer>
</div>
</body>
</html>
"@
}


function Write-ConsoleSummary {
    param($Results, $SummaryText, $ReportPath)

    Write-Host ''
    Write-Host "Työasemakatsastus: $env:COMPUTERNAME"
    Write-Host '----------------------------------------'
    foreach ($result in $Results) {
        $color = switch ($result.Tila) {
            'OK'         { 'Green' }
            'Huomio'     { 'Yellow' }
            'Kriittinen' { 'Red' }
            default      { 'Gray' }
        }
        Write-Host ("[{0}] {1}: {2}" -f $result.Tila.ToUpper(), $result.Nimi, $result.Yhteenveto) -ForegroundColor $color
    }
    Write-Host '----------------------------------------'
    Write-Host $SummaryText
    Write-Host "Raportti tallennettu: $ReportPath"
    Write-Host ''
}


# --- Pääohjelma --------------------------------------------------------------

# Tarkistukset ajetaan tässä järjestyksessä. Uuden tarkistuksen saa lisättyä
# kirjoittamalla Test-funktion ja lisäämällä sen tähän listaan.
$checks = [ordered]@{
    'Levytila'                  = 'Test-DiskSpace'
    'Windows Update'            = 'Test-WindowsUpdates'
    'Tärkeät palvelut'          = 'Test-CriticalServices'
    'Virheet tapahtumalokeissa' = 'Test-EventLogErrors'
    'Verkkoyhteys'              = 'Test-Network'
    'Käynnissäoloaika'          = 'Test-Uptime'
    'Muistin käyttö'            = 'Test-Memory'
}

$results = foreach ($name in $checks.Keys) {
    Write-Host "Tarkistetaan: $name..." -ForegroundColor DarkGray
    try {
        $result = & $checks[$name]
    }
    catch {
        # Jos tarkistus kaatuu, se näkyy raportissa eikä koko skripti pysähdy
        $result = New-CheckResult 'Ei saatavilla' 'Tarkistusta ei voitu tehdä' $_.Exception.Message
    }
    $result.Nimi = $name
    $result
}

$computerName = $env:COMPUTERNAME
$created = Get-Date -Format 'd.M.yyyy HH:mm'
$summaryText = Get-SummaryText $results

# Raportti tallennetaan samaan kansioon kuin skripti
$folder = $PSScriptRoot
if (-not $folder) { $folder = (Get-Location).Path }
$fileName = 'tyoasemakatsastus_{0}_{1}.html' -f $computerName, (Get-Date -Format 'yyyy-MM-dd')
$reportPath = Join-Path $folder $fileName

$html = New-HtmlReport -Results $results -ComputerName $computerName -Created $created -SummaryText $summaryText
$html | Out-File -FilePath $reportPath -Encoding utf8

Write-ConsoleSummary -Results $results -SummaryText $summaryText -ReportPath $reportPath
