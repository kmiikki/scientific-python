# Itsenäisen Spyder-käynnistinkorjauksen skriptikonteksti

`09-repair-launchers.ps1` lukee vain `Install-SpyderLauncher`-funktion AST:n
eheystarkistetusta `02-install-science.ps1`:stä. Asentimen runkoa ei suoriteta.
`[scriptblock]::Create(functionText)` ei säilytä alkuperäisen tiedoston kontekstia:
funktion sisäinen `$PSScriptRoot` on tyhjä. Ensimmäinen
`Join-Path $PSScriptRoot 'science-launcher-common.ps1'` epäonnistui hyväksynnän
jälkeen ennen käynnistinten kirjoitusta. Layout.Root/Bin/Science ja SystemRoot
eivät olleet tämän virheen syy.

Funktiolla on nyt `SourceDirectory`-parametri, jonka oletus on `$PSScriptRoot`
tavallista asenninta varten. Itsenäinen korjausskripti välittää oman
eheystarkistetun hakemistonsa eksplisiittisesti:

```powershell
Install-SpyderLauncher -Layout $layout -SourceDirectory $PSScriptRoot
```

Molemmat lähdetiedostojen Join-Path-kutsut käyttävät tätä parametria. Kohteet
valitaan edelleen Layoutista ja yhteisestä launcher-polkujen funktiosta.
Käyttäjäkohtaisia polkuja ei lisätty. Identiteettivertailut, konfiguraation ja
Micromamban tiivisteet, interaktiivinen [y/N]-hyväksyntä, käyttämättömyystarkistus,
update-lukko ja vieraan pikakuvakkeen suojaus säilyvät.

`tests/test_launcher_repair.ps1` käynnistää oikean 09-entry pointin oikeasta
.ps1-tiedostosta erillisellä Windows PowerShell 5.1 -prosessilla. Testien
bootstrap-tiedostot ohjaavat vain käyttäjä-/käyttöjärjestelmärajat tilapäisiin
fixture-polkuihin ja simuloivat konsolivastaukset. Varsinaiset 490 synteettisen
identiteetin vertailut, release-perustan tarkistukset ja launcher-funktio ovat
tuotantokoodia. WScript.Shell luo ja lukee oikeita .lnk-tiedostoja vain testien
tilapäishakemistossa. Testit eivät käynnistä Pythonia, Spyderiä tai Micromambaa.

Testit kattavat hyväksynnän, toiston, pelkän tarkistuksen, No-/tyhjän vastauksen,
ei-interaktiivisuuden, identiteetti-/konfiguraatio-/executable-erojen eston,
käytössä olevan ympäristön, hyväksynnän aikaisen syötemuutoksen ja vieraan
pikakuvakkeen. Vanha kontekstivirhe toistetaan jättämällä parametri välittämättä;
tavallisen tiedostosta määritellyn funktion oletusparametri testataan erikseen.

Manuaalinen korjaus tapahtuu edelleen 09-skriptillä: ilman `-Apply`-valintaa se
vain tarkistaa; `-Apply` vaatii aidon interaktiivisen konsolin ja erillisen
hyväksynnän (oletus No). Sulje Spyder/Python ja deaktivoi science ensin.
Tämä luo vain käynnistimet ja niiden yhteisen apuskriptin. Se ei viimeistele
keskeytyneen asennuksen pakettilähteitä, tilaraportteja tai historiallista kuittia.
