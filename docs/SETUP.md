# Setup

This takes you from a fresh Mac to your Mac's screen on your iPhone. It assumes nothing is installed except
macOS. You build both apps yourself and sign them with your own Apple account; nothing goes through a
third-party service. Allow about 30 minutes the first time, most of it Xcode downloading.

For everyday use once it's running, see [USAGE.md](USAGE.md). To work on the code, see
[DEVELOPMENT.md](DEVELOPMENT.md).

**Tested with:** MacBook Pro M5 on macOS 27.2, Xcode 27.2 (Swift 6.4), iPhone Duo on iOS 27.

## 0. What you need

- A Mac on **macOS 26 or later**, and an iPhone on **iOS 26 or later**. An iPhone Duo gets the fold-aware
  layouts; any other iPhone works with the laptop (portrait) and flat (landscape) layouts.
- An **Apple Account**. A free one works; see §7 for what a paid Developer Program membership changes.
- A USB-C cable for the first install on the phone.

## 1. Prepare the Mac and the phone (once)

1. **Xcode 27.1 or later** from the App Store. Open it once, accept the licence and let it install its
   components, including the iOS platform when it offers.
2. **Sign in to Xcode** with your Apple Account: Xcode › Settings › Accounts › +. Select your team (a free
   account shows "(Personal Team)"), click **Manage Certificates…**, then **+ › Apple Development**.
3. **Homebrew** (https://brew.sh), then:
   ```bash
   brew install xcodegen
   ```
   `xcodegen` creates the Xcode projects from each app's `project.yml`.
4. **On the iPhone:** connect it to the Mac with the cable, unlock it and tap **Trust**. Then turn on
   Settings › Privacy & Security › **Developer Mode** (the phone restarts; confirm afterwards). If Developer
   Mode isn't listed, open Xcode › Window › Devices and Simulators with the phone connected once, and it appears.

## 2. Your signing config (once)

From the repository folder:

```bash
tools/scripts/configure.sh
```

It finds your team ID from the Apple Development certificate you just made and writes
`mac-host/Config/Local.xcconfig`, which both apps build with (gitignored). The apps get the bundle IDs
`dev.<your user name>.clamshell.host`, `.client` and `.client.widget` (the phone's widget). To choose them
yourself, or if you have several teams:

```bash
tools/scripts/configure.sh <TEAM_ID> com.yourname.clamshell
```

(Your team ID is also at developer.apple.com › Account › Membership details. If Xcode later says a bundle ID
"is not available", someone else has it: run `configure.sh --force <TEAM_ID> <another prefix>`. A free Apple
Account can register at most 10 App IDs in 7 days, and Clamshell uses three, so avoid changing the prefix
again and again.)

> **Why a team and not ad-hoc signing:** with an ad-hoc signature every build is a new app to macOS, so the
> Screen Recording and Accessibility grants stop applying and the Keychain asks again on each launch. With
> your team, grants survive rebuilds.

## 3. Build and install

Keep the phone connected (or on the same Wi-Fi as the Mac) and unlocked, then:

```bash
tools/scripts/release.sh
```

It checks the tools and your config first and tells you what's missing. Then it:
- builds the **Mac host** (Release), installs it as `/Applications/ClamshellHost.app` and starts it (a zip
  is also left in `dist/`);
- builds the **iPhone app** (Release) and installs it on the connected phone. With several phones,
  `CLAMSHELL_DEVICE=<name or UDID> tools/scripts/release.sh` picks one;
- `--no-install` only builds.

The full build log is `dist/build.log`. The first build takes a few minutes; later ones are faster.

## 4. First run on the Mac

The host is a menu-bar app (no Dock icon): look for the laptop symbol at the top right of the screen and
click it for the menu.

1. **Local Network:** click **Allow** if macOS asks.
2. **Screen Recording:** click **Allow Screen Recording…** in the menu, then in System Settings › Privacy &
   Security › **Screen & System Audio Recording** turn **ClamshellHost** on. Quit the host (menu › **Quit
   Clamshell Host**) and open it again from /Applications: macOS applies the grant only to a new process.
3. **Keyboard & mouse:** click **Allow keyboard & mouse control…**, then turn **ClamshellHost** on in
   System Settings › Privacy & Security › **Accessibility** (called **Device Control** on macOS 27). Until
   then the phone shows the picture but its keys and trackpad do nothing. The same grant lets the host
   turn this Mac's own keyboard and trackpad off during a session, if you choose that in the menu.
4. **Privacy screen:** by default the Mac's displays go black while a phone uses it from away (the phone
   still sees the real screen). Choose **Always** or **Never** under **Hide this Mac's screen during a
   session** in the menu. Nothing to grant: it uses the Screen Recording permission from step 2.
5. **Notifications:** allow them to get a notice whenever a phone connects.
6. **Open at login** in the menu, if you want the host always running.
7. **The phone's microphone (optional):** to use the phone as the Mac's microphone, install the Clamshell
   Microphone driver. It goes into `/Library/Audio/Plug-Ins/HAL`, which needs your password, so run it
   yourself in Terminal:

   ```bash
   tools/scripts/install-microphone.sh
   ```

   Sound on the Mac stops for a second while Core Audio restarts. Then **Clamshell Microphone** is listed in
   System Settings › Sound › Input, and the host menu says it's installed. Run it again after updating if the
   changelog says the driver changed. `tools/scripts/test-microphone-driver.sh` checks the built driver
   without installing it.

If you rebuild later and a menu item asks for a permission again, remove the old ClamshellHost entry in that
System Settings list with − and add the new one.

## 5. First run on the phone

1. Open **Clamshell**. If iOS says **Untrusted Developer** (free accounts), go to Settings › General ›
   **VPN & Device Management**, tap your Apple Account under Developer App and tap **Trust**.
2. **Local Network:** tap **Allow** (the app finds the Mac with Bonjour).
3. **Pair** (once, at home, with the phone on the same Wi-Fi as the Mac):
   - on the Mac, menu › **Pair new iPhone…** and confirm with your password or Touch ID. A window shows a QR
     code and a 16-character code for 120 s;
   - on the phone, tap **Scan the Mac's pairing code** (or type the code);
   - both screens show 6 digits. If they match, click **Pair** on the Mac.

   Pairing only works from your own network, nothing goes through a server, and up to 8 phones can pair.
4. Tap your Mac under **Macs on this network**. Within about a second the phone shows the Mac's screen.

By default the phone shows the Mac's own screen. The menu switch **Show this Mac's own screen** turns that
off and gives the phone its own screen, sized for it (it appears in System Settings › Displays as
"Clamshell"; drag windows onto it). See [USAGE.md](USAGE.md) for the layouts, keyboard and settings.

## 6. Away from home

On another network the phone can't find the Mac with Bonjour, so it connects to your home's public address
through a port forward on your router. It races two paths: UDP (fast) and TLS + WebSocket on TCP 443 (gets
through networks that only allow web traffic), and uses whichever answers first.

1. **Fix the Mac's UDP port** (otherwise it's random at each launch), then quit and reopen the host:
   ```bash
   defaults write <your prefix>.host udpPort -int 51820
   ```
2. **Give the Mac a fixed LAN address** on your router (a DHCP reservation).
3. **Forward UDP 51820 and TCP 443** on the router to that address. On a TP-Link Archer, for example, that's
   Advanced › NAT Forwarding › Virtual Servers. Keep UPnP off and the router's own **remote management off**
   (it would otherwise want port 443).
4. **The public address:** the menu shows **Public address: …**. The Mac asks the router for it (NAT-PMP, read
   only, it opens no ports) every 10 minutes. If your router doesn't answer, type the address (or a DNS name
   you own) in the pairing window's **Away-from-home address** field. If it starts with 100.64–100.127, your
   ISP uses carrier-grade NAT and nothing can reach your Mac from outside without a relay server, which this
   project deliberately doesn't use.
5. The phone learns the address when it pairs and again at every session at home, and fills **Away from
   home** itself; you can also type `address:51820` there. On the phone, **Check connection** tries each path
   on its own and shows which answer.

Away from home the Mac sends a lighter stream (at most 1600 px wide, 60 Hz, starting at 3 Mbit/s and adapting
to the connection), and switches back to full quality when the phone is home again. The menu shows
"· internet" while it's on.

**Testing it:** unplug the phone's cable and turn off the phone's Wi-Fi Auto-Join for your home network
(Settings › Wi-Fi › ⓘ). Otherwise the phone quietly uses the cable or the home Wi-Fi instead, which is
always preferred. The host log's `streaming to` line shows `· internet · udp` when it really went out and back.

## 7. Updating, and the 7-day limit

To update, pull the new code and run the same script; pairings and settings are kept:

```bash
git pull && tools/scripts/release.sh
```

With a **free** Apple Account the phone app's provisioning profile lasts **7 days**. The script prints when it
expires, and after that the app won't open until you run the script again. The app warns 3 days ahead and
sends a reminder the day before, and the Mac's menu shows the date for each phone. A paid Apple Developer Program
membership makes it a year, and also allows Developer ID signing and notarization, which you need only to
give the Mac app to other people (see [app-store.md](app-store.md)).

## 8. Uninstalling

- **Phone:** delete the Clamshell app.
- **Mac:** menu › turn **Open at login** off, **Quit Clamshell Host**, then delete
  `/Applications/ClamshellHost.app`. Remove ClamshellHost from System Settings › Privacy & Security (Screen
  & System Audio Recording, Accessibility / Device Control). The host's identity and pairings are in the
  login Keychain under `dev.clamshell.host` (Keychain Access › search "clamshell"); its settings are
  `defaults delete <your prefix>.host`; its log is `~/Library/Logs/Clamshell`. If you installed the
  microphone driver: `tools/scripts/install-microphone.sh --uninstall`.

## 9. Troubleshooting

| Problem | Fix |
|---|---|
| `release.sh` stops with ✗ | It says what's missing (Xcode, xcodegen, signing config). Fix that and run it again. |
| "No profiles for … were found" / "No Account for Team" | Sign in to Xcode › Settings › Accounts with the account that owns the team in `Local.xcconfig`. With a free account, connect the phone once before the first build so Xcode can register it. |
| "… is not available" (bundle ID) | Someone else registered it: `tools/scripts/configure.sh --force <TEAM_ID> <another prefix>`. |
| "no iPhone connected" | Unlock the phone, connect the cable, tap Trust, and check Developer Mode is on. Then run the script again. |
| "Untrusted Developer" on the phone | Settings › General › VPN & Device Management › your account › Trust. |
| The app won't open after a week | The free provisioning profile expired: run `tools/scripts/release.sh` again. |
| Phone can't find the Mac | Same Wi-Fi on both (not a guest network, no client isolation)? Host running? Local Network allowed on the phone (Settings › Privacy & Security › Local Network) and on the Mac? |
| "Could not connect" | Paired with this Mac? After **Revoke** on the Mac, or reinstalling the app, pair again. |
| Black screen, menu says "Screen Recording permission is needed" | §4 step 2, then quit and reopen the host. |
| Keys and trackpad do nothing, phone shows a banner | §4 step 3. Also, using the Mac's own keyboard or trackpad pauses the phone for 3 s. |
| "This phone's key could not be read from the Keychain" | The app was built without your team: check `mac-host/Config/Local.xcconfig`. |
| Away from home doesn't connect | Port forwards (§6), the address in **Away from home**, and **Check connection** on the phone. CGNAT (a 100.64–100.127 address) can't work. |
| Text soft while scrolling, sharp a moment later | Expected: the refinement pass sharpens the picture once it's still. |
| "Maximum App ID limit reached" (free account) | 10 new App IDs per 7 days: wait, or keep the prefix you already used. |
| Clamshell Microphone missing from Sound › Input | Run `tools/scripts/install-microphone.sh` (§4 step 6); if still missing, log out and back in. |
| The phone's mic is silent in an app | The app's input must be **Clamshell Microphone**, and the mic button in the phone's bar must be on. |
| "Send to iPhone with Clamshell" missing from Services | Log out and back in once after installing the host, or run `/System/Library/CoreServices/pbs -update`. |

**Logs.** The host writes `~/Library/Logs/Clamshell/host.log`. Every 10 s while streaming it adds a
`stats:` line (fps, bitrate, encode time, drops), a `path:` line (what the phone received and lost, delay,
round trip) and an `input:` line (touches received and applied, or dropped because someone used the Mac).
On the phone, the gauge button in the bar shows the same numbers live. For the phone's own log, see
[DEVELOPMENT.md](DEVELOPMENT.md#logs).
