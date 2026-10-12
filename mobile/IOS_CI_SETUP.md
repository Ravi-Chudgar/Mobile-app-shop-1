# Building the iOS app with GitHub Actions (no Mac needed)

> **Current status:** the Apple Developer membership has expired, so use
> `.github/workflows/build-ios-unsigned.yml` instead. It produces an
> **unsigned** IPA that gets signed on-device with a free Apple ID via
> AltStore/SideStore (7-day expiry, max 3 apps). The signed pipeline below
> works again as soon as the membership is renewed — no code changes needed,
> just the portal steps and secrets.



`.github/workflows/build-ios.yml` builds a **signed** IPA on GitHub's macOS
runners and (optionally) uploads it to TestFlight. Everything on Apple's side
can be done from Linux in a browser + terminal.

## 1. One-time setup in the Apple Developer portal

All at <https://developer.apple.com/account> → Certificates, Identifiers & Profiles.

### a. Register the App ID

Identifiers → **+** → App IDs → App. Description: `Cafe App`,
Bundle ID: **Explicit** → `com.ravi.cafeapp` (matches `ios/Runner.xcodeproj`).

### b. Create a distribution certificate (no Mac required)

```bash
openssl genrsa -out dist.key 2048
openssl req -new -key dist.key -out CertificateSigningRequest.certSigningRequest \
  -subj "/emailAddress=you@example.com/CN=iOS Distribution/C=IN"
```

Portal → Certificates → **+** → *Apple Distribution* → upload the CSR →
download `dist.cer`. Then pack the key + cert into a P12:

```bash
# If the downloaded .cer is PEM already, skip this conversion:
openssl x509 -in dist.cer -inform DER -out dist.pem -outform PEM

openssl pkcs12 -export -out dist.p12 -inkey dist.key -in dist.pem
base64 -w0 dist.p12 > dist.p12.b64      # -> BUILD_CERTIFICATE_BASE64 secret
```

Keep `dist.key` and `dist.p12` private; you cannot re-download the private key.

### c. Create the provisioning profile

Profiles → **+** → Distribution → **App Store Connect** → pick App ID
`com.ravi.cafeapp` → select the certificate → download `.mobileprovision`.

```bash
base64 -w0 profile.mobileprovision > profile.b64   # -> BUILD_PROVISION_PROFILE_BASE64
```

Your Team ID is on the Membership details page.

## 2. GitHub repo settings

Settings → Secrets and variables → Actions.

| Type | Name | Value |
|---|---|---|
| Secret | `BUILD_CERTIFICATE_BASE64` | contents of `dist.p12.b64` |
| Secret | `P12_PASSWORD` | password you gave `openssl pkcs12 -export` |
| Secret | `BUILD_PROVISION_PROFILE_BASE64` | contents of `profile.b64` |
| Secret | `TEAM_ID` | your Team ID |
| Secret | `KEYCHAIN_PASSWORD` | any random string |
| Variable | `API_BASE_URL` | `http://<your-kali-lan-ip>:9999` |

Optional TestFlight upload — also create an API key first
(App Store Connect → Users and Access → Integrations → **+**, role *App Manager*):

| Type | Name | Value |
|---|---|---|
| Secret | `ASC_KEY_ID` | the key's ID |
| Secret | `ASC_ISSUER_ID` | the issuer ID shown above it |
| Secret | `ASC_P8_BASE64` | `base64 -w0 AuthKey_XXXX.p8` |
| Variable | `UPLOAD_TO_TESTFLIGHT` | `true` |

## 3. Run it

Actions tab → **Build iOS IPA** → Run workflow. The signed IPA appears under
Artifacts; if `UPLOAD_TO_TESTFLIGHT=true` it is also uploaded automatically.

## 4. Install on your iPhone via TestFlight

1. App Store Connect → Apps → **+** → New App (bundle ID `com.ravi.cafeapp`).
2. TestFlight tab → add yourself as an **internal tester**.
3. Install the *TestFlight* app on the iPhone, accept the invite.
4. After each CI run, processing takes ~10–30 min, then the build appears
   over the air. Builds expire after 90 days; just re-run the workflow.

The phone must be on the same Wi-Fi as the machine running Flask, and the
backend must be reachable at `API_BASE_URL` (`backend/run.py` already binds
`0.0.0.0`, so it is).

## Ad-hoc alternative (skip TestFlight)

Create an **Ad Hoc** profile instead (register your iPhone's UDID first — plug
it into Kali and run `pymobiledevice3 usbmux list`), change `method` in the
workflow's ExportOptions to `ad-hoc`, download the IPA artifact, and install
over USB:

```bash
pip install pymobiledevice3
pymobiledevice3 apps install cafe_app.ipa
```
