Windows: native commitin diagnostiikka ja keskeytynyt viimeistely

Native-prosessin success=true ei yksin tarkoita hyväksyttyä transaktiota.
Suorittaja tarkistaa edelleen exit-koodin, yhden täydellisen JSON-objektin,
success-arvon, prefixin, hyväksytyt LINK/UNLINK-identiteetit ja asennetun
lopputilan identiteetit. Koodi ei hyväksy nonzero-exitiä JSONin perusteella.

Pakettien post-link-skriptit voivat kirjoittaa stdoutiin ennen Micromamban
JSON-objektia. Esimerkiksi spyder-base siirtää gui-64.exe:n spyder.exe:ksi
ja move-komento tulostaa siirtoviestin. Transaction JSON luetaan nyt yhdestä
loppuun päättyvästä objektista käyttäen myös yhteistä StrictJson-tarkistusta.
Useita objekteja, perässä olevaa muuta tekstiä tai identiteettieroja ei hyväksytä.

Jokainen natiivi vaihe tallentaa transaktion evidence-hakemistoon alihakemiston:

- native-approved-archive-extraction
- native-locked-preflight
- native-locked-commit

Niissä ovat result.json (todellinen prosessin exit-koodi ja peitetyt argumentit),
stdout.txt ja stderr.txt. URL:t, tunnukset ja tokenit peitetään ennen kirjoitusta.
Tiedostot tallennetaan ennen exit-koodin tarkistusta tai JSON-jäsennystä.

commit-verification.json kertoo tarkan viimeisen vaiheen:

- native-commit: natiivikutsun käynnistys
- save-native-diagnostics: paluukoodin ja tulosteiden tallennus
- native-exit: natiivin prosessin exit-koodin tarkistus
- native-json: JSON-jäsennys
- native-success: JSONin success-arvon tarkistus
- reported-prefix: native-vastauksen kohdeprefix
- approved-link-unlink-identities: hyväksyttyjen toimintojen identiteettivertailu
- write-committed-plan: committed-plan.json-tallennus
- installed-identities: asennettujen pakettien lopputila
- restore-source-metadata: alkuperäisten HTTPS-lähdetietojen palautus metatietoihin
- final-input-integrity: lukon ja syötetiedostojen lopputarkistus
- complete: kaikki yllä olevat tarkistukset päättyivät onnistuneesti

completed=true asetetaan vain viimeisessä vaiheessa. Myös committed-plan.jsonin
olemassaolo yksin on riittämätön todiste asennuksen koko viimeistelyn onnistumisesta.

Puuttuvien käynnistimien erillinen korjaus

09-repair-launchers.ps1 ei käynnistä asenninta, solveria tai pakettitransaktiota.
Se vertaa nykyisiä paketti-identiteettejä valitun transaktion approved-lock.jsonin
after-joukkoon ja tarkistaa konfiguraation, Micromamban hashin, tuetun Home/Safe-
rootin sekä perustapakettien rajaukset. Oletuksena se vain raportoi suunnitelman.

Esimerkki PowerShellissä (korvaa polut todellisella evidence-hakemistolla):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\local\scientific-python-windows-hotfix\windows\09-repair-launchers.ps1" -Mode Home -TransactionDirectory "C:\Users\YOUR_USER\micromamba\tmp\science-transaction-EXACT_ID"
```

Vasta tarkistuksen jälkeen voit lisätä -Apply-valinnan. Skripti vaatii interaktiivisen
konsolin, varmistaa ettei ympäristö ole käytössä ja kysyy erillisen hyväksynnän,
jonka oletus on No. Sulje Spyder ja deaktivoi science ennen korjausta. Korjaus
käyttää alkuperäisen eheystarkistetun asentimen Install-SpyderLauncher-funktiota;
se kopioi myös science-launcher-common.ps1-aputiedoston samaan rootiin.
Asentimen runkoa ei suoriteta. Olemassa olevien eri kohteeseen osoittavien
pikakuvakkeiden suojaukset säilyvät.

Launcher-only-korjaus luo start-spyder.ps1:n, science-spyder.cmd:n ja työpöydän
Spyder-pikakuvakkeen. Se ei luo jälkikäteen väitettyä native commit -kuittia eikä
muuta conda-meta-tietoja, package-source-URL:eja tai installerin last_sync-aikaa.
Niiden mahdollinen viimeistely on erillinen, saman identiteettivarmennuksen vaativa
huoltotoimi; pakettien uudelleenasennusta ei tarvita pelkkään metadata-/launcher-
viimeistelyyn. Vanhaa tuntematonta native exit-koodia ei pidä keksiä.

Havaittu tuore asennus oli paketti-identiteettien osalta valmis, vaikka viimeistely
keskeytyi. Vanhoista evidence-tiedostoista puuttuivat native exit/stdout/stderr,
joten historiallisen ajon poistumiskoodi jää epävarmaksi. Siirtoviestin aiheuttama
JSON-jäsennysvirhe toistettiin erillisessä inertissä fikstuurissa, eikä tämän
diagnoosin aikana ajettu uutta live-pakettitransaktiota.
