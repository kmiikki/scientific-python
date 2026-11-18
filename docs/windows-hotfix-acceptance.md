Scientific Python: paikallinen Windows-hotfix ja hyväksymistestaus

Tämä on paikallinen validointiversio. Asennuksen saa hyväksyä vain käyttäjä.
OpenCV-tavoite on 5.1.0 Qt6; yhteensopiva HDF5 1.14.6 hyväksytään.
Käyttäjän konfiguraatioon ei lisätä HDF5 2.2.0 -pinnausta.

1. Sulje Science-Python- ja Spyder-prosessit ja deaktivoi science, jos se on aktiivinen.
2. Käynnistä tämän toimituksen Windows-valikko. Käytä korjattua paikallista hakemistoa;
   aiempia patch-tiedostoja ei tarvitse eikä pidä soveltaa siihen uudelleen.
3. Valitse 1. Tarkista poistettavien riippuvuuksien nimet ja vastaa vain hyväksymällesi
   listalle `y`. Sen jälkeen tarkista koko transaktio, myös HDF5:n version alennus.
   Koko transaktiolla on toinen erillinen hyväksyntä; molempien oletus on No.
4. Jos nimet, versiot tai buildit eroavat toimituksen suunnitelmasta, arvioi uusi
   näkyvä suunnitelma ennen hyväksyntää. Lukumäärien yhtäläisyys ei riitä.
5. Kun käyttäjän hyväksymä asennus on onnistunut, suorita alla oleva datatesti.

Esimerkki paikallisen ZIPin purkamisen jälkeen. Korvaa bundle-polku omalla purkuhakemistollasi:

```powershell
$bundle = 'C:\local\scientific-python-windows-hotfix'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$bundle\windows\00-menu.ps1" -Mode Home
```

Päivityksen jälkeinen datatesti

Avaa uusi PowerShell-istunto, jossa tämän toimituksen skriptit voidaan suorittaa:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass
```

Suorita siinä seuraavat rivit. Muuta bundle-polku vastaamaan ZIPin purkuhakemistoa. Tämän koneen täsmälliset komennot ovat toimitusraportissa.

```powershell
$bundle = 'C:\local\scientific-python-windows-hotfix'
$installer = Join-Path $bundle 'windows'
$samples = Join-Path $bundle 'acceptance-samples'
$report = Join-Path $bundle 'post-install-acceptance.json'
& "$installer\08-data-acceptance.ps1" -Output $report -SampleHdf5 @("$samples\hdf5-2.2.0-earliest.h5", "$samples\hdf5-2.2.0-latest.h5")
$LASTEXITCODE
```

Testin oletukset ovat OpenCV 5.1.0 ja HDF5 1.14.6. Älä ohita näitä odotuksia
ExpectedOpenCV/ExpectedHDF5-parametreilla päivityksen jälkeisessä hyväksymistestissä.
Raportin success-arvon tulee olla true, kaikkien tarkistusten PASS ja exit-koodin 0.

Testi tarkistaa Python 3.14:n, Spyder 6.1.8:n, OpenCV 5.1.0 Qt6:n, FFmpeg 9 GPL:n,
h5py:n ja netCDF4:n käyttämät HDF5-runtime-versiot sekä libnetcdf-runtime-version.
Se tekee seuraavat toiminnot uusille tilapäistiedostoille:

- HDF5: moniulotteinen NumPy-taulukko, gzip, shuffle, Fletcher32 ja metadata-
  attribuutit; tietojen täsmällinen takaisinluku.
- netCDF4: moniulotteinen pakattu aineisto, dimensioiden ja numeeristen arvojen
  takaisinluku sekä xarray/netCDF4-kierros.
- PyArrow: taulukon Parquet-kirjoitus ja täsmällinen takaisinluku.
- OpenCV: PNG-koodaus/dekoodaus ja kuuden FFV1-videokehyksen häviötön
  kirjoitus/takaisinluku nimenomaan FFmpeg-backendilla.
- Qt6 HighGUI- ja FFmpeg Video I/O -tuki OpenCV:n build-tiedoista. Automaattinen
  testi ei avaa GUI-ikkunaa eikä kameraa. Natiivi ikkuna-/Spyder-testi tehdään erikseen.

Roundtrip-tiedostot poistetaan testin päättyessä. HDF5 2.2.0:lla ennen päivitystä
luodut pienet sample-tiedostot ovat toimituksen testisyötteitä. Ne avataan vain
read-only-tilassa ja niiden SHA-256 tarkistetaan ennen ja jälkeen. Testi ei poista
syötetiedostoja eikä koske olemassa oleviin tieteellisiin aineistoihin.

Samplet kattavat tavallisen float64-taulukon, gzip/shuffle/Fletcher32-suodattimet,
attribuutit ja earliest/latest-kirjoitusasetukset. Onnistunut testi ei todista
kaikkien HDF5 2.x -tiedostopiirteiden, suodattimien tai datatyyppien tukea.
Mahdollinen lukemisvirhe raportoidaan FAIL-tuloksena. Omia HDF5 2.x -näytteitä
voi antaa SampleHdf5-listassa; alkuperäisiä tiedostoja ei muokata.

Lopuksi käynnistä Spyder tavallisella Scientific Python -pikakuvakkeella ja
tarkista samat importit/versionumerot sen kernelissä. GPU/CUDA-toimivuutta ei
ole varmennettu näillä CPU-/data-/media-testeillä.

Kehityksen aikana datatestin toiminta tarkistettiin vanhalla, toimivalla
OpenCV 5.0.0 / HDF5 2.2.0 -runtimella odotuksia erikseen muuttamalla.
Tämä todentaa testin roundtrip-koodin, ei vielä päivitetyn runtimen toimivuutta.

Patchit Niobiumia varten

scientific-python-windows-all-hotfixes.patch sisältää kaikki Windows-hotfixit
alkuperäiseen kehityslähteeseen. scientific-python-windows-callback-hotfix.patch
sisältää vain tämän kierroksen eron edelliseen paikalliseen hotfixiin.
Valitse lähtöversiota vastaava patch. Älä sovella molempia tai vanhoja patcheja
päällekkäin. Ennen myöhempää soveltamista käytä git apply --check -tarkistusta.
GitHubia, tageja ja julkaistua v0.1.0-pakettia ei muutettu.
