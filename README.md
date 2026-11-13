# Trail keyboard for iPhone

A private swipe keyboard. It reads swipes by their shape, learns from the words you pick
(and the ones you reject), keeps separate word sets for English and Spanish, and can learn how
*you* swipe from short training rounds. Everything it learns stays inside the keyboard on your
iPhone, where you can see and delete it.

## Install with Sideloadly (Windows)

You need: the iPhone and its USB cable, a Windows PC, and a spare Apple ID (free) with
two-factor authentication on.

### 1. On the PC: install iTunes, iCloud and Sideloadly

Sideloadly needs the **web** versions of iTunes and iCloud, not the Microsoft Store ones.

Open **Windows PowerShell** (Start menu → type *PowerShell* → *Windows PowerShell*; a normal
window, not *Run as administrator*) and run these one block at a time:

```powershell
# Remove the Microsoft Store iTunes and iCloud, if you have them
Get-AppxPackage *AppleInc.iTunes* | Remove-AppxPackage
Get-AppxPackage *AppleInc.iCloud* | Remove-AppxPackage
```

```powershell
# Download the installers and the keyboard into your Downloads folder
# (-UseBasicParsing avoids the security question Windows PowerShell asks since its December 2025 update)
$ProgressPreference = 'SilentlyContinue'
$d = "$env:USERPROFILE\Downloads"
Invoke-WebRequest -UseBasicParsing https://www.apple.com/itunes/download/win64 -OutFile "$d\iTunes64Setup.exe"
Invoke-WebRequest -UseBasicParsing https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe -OutFile "$d\iCloudSetup.exe"
Invoke-WebRequest -UseBasicParsing https://sideloadly.io/SideloadlySetup64.exe -OutFile "$d\SideloadlySetup64.exe"
Invoke-WebRequest -UseBasicParsing https://github.com/Audnovie/trail-keyboard/releases/latest/download/Trail.ipa -OutFile "$d\Trail.ipa"
Invoke-WebRequest -UseBasicParsing https://github.com/Audnovie/trail-keyboard/releases/latest/download/Trail.ipa.sha256 -OutFile "$d\Trail.ipa.sha256"
```

```powershell
# Check the download (the two hashes must match)
(Get-FileHash "$d\Trail.ipa" -Algorithm SHA256).Hash.ToLower()
(Get-Content "$d\Trail.ipa.sha256").Split(' ')[0]
```

```powershell
# Install them, one after the other (each opens its own installer; click through it)
Start-Process "$d\iTunes64Setup.exe" -Wait
Start-Process "$d\iCloudSetup.exe" -Wait
Start-Process "$d\SideloadlySetup64.exe" -Wait
```

Restart the PC after the installers finish.

### 2. Connect the iPhone

1. Plug the iPhone into the PC and unlock it. Tap **Trust** and enter your passcode.
2. Open **iTunes** on the PC and click the small iPhone button near the top left.
3. Under **Options**, tick **Sync with this iPhone over Wi-Fi** and click **Apply**. (This is what
   lets Sideloadly refresh the keyboard later without the cable.)

### 3. Install Trail with Sideloadly

1. Open **Sideloadly**. Your iPhone should show under *iDevice*.
2. Type the spare Apple ID's email in *Apple account*.
3. Drag `Trail.ipa` from your Downloads folder onto the IPA box.
4. Leave the other options as they are. In particular, don't tick **Remove Extensions** under
   Advanced options: the keyboard *is* the app's extension. Automatic refresh is on by default:
   once the install succeeds, Sideloadly's background daemon (it starts with Windows) re-signs
   the app before it expires.
5. Click **Start**, enter the Apple ID's password (and the two-factor code if asked), and wait
   for **Done.**

### 4. On the iPhone

1. **Trust the developer:** Settings → General → VPN & Device Management → under *Developer
   App*, tap the spare Apple ID's email → **Trust** → **Trust**.
2. **Developer Mode** (needed since iOS 16 for apps installed this way): Settings → Privacy &
   Security → Developer Mode (near the bottom) → turn it on → **Restart**. After the restart,
   unlock and tap **Turn On**, then enter your passcode.
3. **Turn on the keyboard:** Settings → General → Keyboard → Keyboards → Add New Keyboard… →
   **Trail**. Leave **Allow Full Access** off.
4. In any app, touch and hold the globe 🌐 (or the emoji key) below the keyboard and pick
   **Trail**.

The Trail app on your home screen has the same steps, a box to try the keyboard in, and notes on
what it keeps.

### Keeping it working

- With a free Apple ID, the app and keyboard stop opening **7 days** after they were signed.
  Sideloadly's daemon refreshes them when the PC is on and the iPhone is plugged in or on the same
  Wi-Fi (it waits and tries again if the phone locks or drops off). Your learned words are kept
  across refreshes.
- Apps installed with a free Apple ID are limited to **3** active on a device, and **10** new app IDs
  a week. Trail is one app but registers **2** app IDs (the app and its keyboard).
- If it has expired, plug the iPhone in and press Start in Sideloadly again with the same file.

## Using it

- **Swipe** across the letters, or tap. The best guess goes in; the other two are in the bar above
  the keys. Tap one to swap: the keyboard learns from that (the word you picked comes up more,
  the wrong guess less).
- **Delete** right after a swipe removes the whole word. Swiping again soon after counts the
  first guess as wrong.
- **Shift** right after a swipe cycles the word: lowercase, Capitalized, ALL CAPS.
- **Hold a suggestion** to never see it again ("Never suggest").
- **Hold a key** for accents (á é í ó ú ü ñ) and the top row's numbers; hold **.** for ? ! ¿ ¡ …
- **Drag the space bar** to move the cursor. With Spanish on, **hold the space bar** to pick the
  language (Auto picks it from the words before the cursor).
- **Settings:** when no word is in progress, tap the sliders button at the left of the bar.

### Training rounds

Settings → **Start a training round**. Swipe the word shown, 20 words a round. Each swipe
teaches the keyboard where your finger really goes: how far short of (or past) the last letter
you stop, where you start, and which way your path drifts. It starts adjusting after 20 swipes
and keeps improving up to about 150. Words you miss come back in later rounds, and the round
summary shows how many it got right with your profile and without it.

## Privacy

- **No network.** The keyboard doesn't ask for Full Access, so iOS gives it no network access.
- **No text kept.** It never stores sentences or swipes. It counts single words you use, words
  you rejected or blocked, a running summary of how you swipe, and training results.
- **Not in sensitive fields.** Password fields always get Apple's keyboard. In email, web
  address, username, one-time code, phone, address and card fields Trail doesn't learn at all
  (and in email, web address, code and card fields it doesn't suggest either).
- **Only on this iPhone, and visible.** It's one file inside the keyboard's own storage, left out
  of iCloud and computer backups. Settings → *Learned words*, *Never suggest*, *Training results*
  and *What the keyboard keeps* show all of it, with buttons to delete any of it.

## How it's built

- `Shared/Engine`: the typing engine (swipe reader, suggestions, learning, swipe profile, typing
  logic), ported line for line from the JavaScript web trial in `tools/reference/core.js`.
- `Resources/Lexicon`: the English (51,025 words) and Spanish (59,746 words) lists, built by
  `tools/build_lexicon.py` into files the keyboard maps into memory instead of loading.
- `Shared/KeyboardUI`: the keys, suggestion bar, panels and training rounds.
- `Keyboard`: the keyboard extension. `App`: the companion app and the UI-test harness.
- `Tests/EngineTests`: replays fixtures recorded from the JavaScript engine
  (`tools/fixtures/gen.js`) and checks the Swift engine gives the same answers.
- `Tests/EngineTests/ProxyTargetTests.swift`: the same sessions through the iPhone's way of
  editing text (insert and delete-backwards only) against a stand-in app field, including smart
  quotes, short context and an app that reports changes late.
- `UITests`: the keyboard hosted in the app (`-UITestHarness`), driven with real taps and drags
  plus scripted swipes; and a best-effort test of the real keyboard extension in the Simulator.
- CI (`.github/workflows/build.yml`) runs the engine tests on a Mac, builds the app and runs unit
  and UI tests on the iPhone Simulator, then builds the unsigned `Trail.ipa` and publishes it as
  the `latest` release. Logs and screenshots go to the `ci-logs-engine` and `ci-logs-ios`
  branches.
