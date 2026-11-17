# Studio Switch

Studio Switch is a macOS menu-bar utility for moving a **wireless Apple keyboard
and trackpad** between two Apple silicon MacBook Pros by moving their Studio
Display's Thunderbolt cable. Closed-lid operation is the intended workflow and
must be verified on the actual Macs and accessories.

Version 1.3 requests visible wake once when the display is attached or the system
resumes with it attached, and starts
Bluetooth acquisition immediately. It keeps the Mac available while it owns the physical display, while
allowing the screen to turn off and the session to lock. Screen sleep preserves
the keyboard and trackpad connections. Moving the cable releases the peripherals;
an actual system-sleep request also releases them before the Mac finishes sleeping.
The destination reacquires them after waking. No network connection or
acknowledgment from the other Mac is required.

## What this can guarantee

The app orders its own commands and verifies the Bluetooth state it can observe.
It cannot guarantee a successful wireless transfer for every Magic accessory,
macOS release, or sleep transition. An app cannot guarantee handling cable removal
when the Mac is already asleep: hardware may wake it, but that is not a reliable
app execution path. Forced sleep cannot be prevented indefinitely. Apple documents
a limited delay for handling `SystemWillSleep`, not permission to keep running
through sleep.
[Apple sleep/wake documentation](https://developer.apple.com/library/archive/qa/qa1340/_index.html)

Pairing records on both Macs do not prove that the accessory retains usable bonds
for both. The app does not alter pairing records or automate pairing dialogs.
**Verify an A → B → A transfer without re-pairing before relying on this setup.**
If the accessory requires re-pairing on each return, retrying connections cannot
solve that device-side limitation. Apple documents cable-based setup and pairing
for Magic accessories. [Apple pairing guide](https://support.apple.com/en-ca/119917)

`IOBluetoothDevice.isConnected()` reports a baseband link, not working keyboard
input or trackpad gestures. The UI therefore reports Bluetooth links connected
and asks you to check input. Newer accessory/transport combinations may not be
fully controllable through this API; a successful build is not compatibility
proof. [Apple IOBluetooth documentation](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice)

## Handoff sequence

1. **Watch the physical display.** The app watches the Studio Display's USB service
   over its Thunderbolt connection. This is display detection; the keyboard and
   trackpad remain wireless. Once that service is observed, it takes precedence
   over stale screen state. Online-display detection is a fallback. A two-second
   refresh catches missed notifications and delayed enumeration. A screen going
   dark alone does not transfer ownership. The fallback remembers display names
   while their IDs remain online; failed queries do not reuse stale ownership.
2. **Prevent idle system sleep while attached.** `IdleSleepGuard` holds a
   `PreventUserIdleSystemSleep` assertion while this Mac owns the physical display.
   This leaves display sleep and locking enabled. The keyboard and trackpad stay
   connected when the screen goes dark, so normal input can light it again.
3. **Invalidate acquisition immediately.** Display removal changes the desired
   state to released and advances a generation counter. Old asynchronous work
   cannot start another connection for an obsolete generation. The existing idle
   sleep assertion remains held during release, then is dropped after verified
   release or a reported failure at the nominal five-second deadline. A separate
   eight-second watchdog drops this hold if Bluetooth work stalls; retries do not
   extend that cap. It never acquires a new hold on a Mac without the display.
4. **Release before actual system sleep, regardless of notification order.** An I/O Kit
   `SystemWillSleep` callback independently requests release of every selected
   device, even if display removal has not been reported. A delayed display
   callback cannot restart acquisition during this phase. The app drops its idle
   sleep assertion immediately; that assertion does not oppose manual or forced
   sleep.
5. **Verify release, then acknowledge sleep.** Bluetooth commands run on one live run loop.
   Each disconnect is checked against actual connection state. All selected
   devices must be observed released twice, with 200 ms between successful
   passes. The coordinator normally spends up to five seconds retrying release.
   It acknowledges sleep on success or reports failure and acknowledges at the
   deadline. An independent eight-second watchdog acknowledges even if Bluetooth
   work stalls. Apple's documented acknowledgment window is 30 seconds; the app
   deliberately stays below it. These are best-effort budgets, not a hard timeout
   for an unresponsive operating-system call.
6. **Let the source sleep.** There is no timer or peer request that must execute
   there afterward. While the source remains awake without the display, it checks
   every three seconds and releases selected devices that reconnect themselves.
7. **Request visible wake on attachment and reconcile.** The USB-C plug may wake
   the Mac only briefly for its power-connection notification. A confirmed
   absent-to-present display observation calls `IOPMAssertionDeclareUserActivity`
   once to request visible wake. A failed presence query cannot manufacture this
   edge. Screen sleep, canceled sleep, and repeated polls do not reset the display
   timer. A genuine system resume with the display present also requests visible
   wake once: the entire unplug/replug cycle may have happened while asleep.
   This can also light the display after an incidental system resume; the public
   callback does not prove that a cable transfer caused that resume.
   An attachment observed during system-sleep preparation is deferred
   until wake and a fresh confirmed presence query. This still requires macOS to
   execute the app; it does not bypass forced sleep or accessory authorization.
   [Apple user-activity API](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity)

   `SystemHasPoweredOn` triggers a fresh
   display query, even when its attachment value has not changed. A Mac without
   the display continues releasing. A Mac with it immediately requests
   authenticated connections to locally paired devices; readiness failures retry.
8. **Connect asynchronously and show the real outcome.** A retained callback
   receives each native connection result. A pending connection does not occupy
   the command run loop, so release can be requested without waiting for it.
   The one-second radio paging parameter is not a wall-clock timeout: observed
   native calls can take much longer. Pending operations retain their callback
   and cannot be mistaken for completed release. Acquisition retries for a nominal 45 seconds, then reports
   incomplete devices and continues maintenance every three seconds while awake.
   A stale connection that completes after display loss or sleep is immediately
   released on the same command run loop. Missing pairing, Bluetooth off/not ready,
   and command errors appear in diagnostics; partial success is not full success.

`PowerMonitor` owns sleep acknowledgment and its watchdog. `DisplayWakeRequest`
owns the attachment-edge policy and visible-wake request. `IdleSleepGuard` owns
the idle system-sleep assertion. `DisplayMonitor` owns attachment detection.
`HandoffCoordinator` owns intent, deadlines, verification, retries, and the bounded
idle hold during detach. `BluetoothController` owns serialized commands and generation checks.
Neither cancellation alone nor a fixed delay on the receiving Mac is the safety
boundary. Bluetooth power and the pairing database are left under macOS control.

To cover sleep arriving before the unplug notification, the app releases selected
devices on **every actual system sleep**, including manual Sleep with the display
still attached. This does not apply to screen sleep or locking. After actual
system sleep, a disconnected peripheral might reconnect and wake the Mac, but
that behavior is not guaranteed. Another wake method may be needed before the app
can reacquire it. Disconnecting does not remove pairing or disable Bluetooth.

## Setup on both Macs

1. Start with both lids open. Log in on each Mac, connect the Studio Display, and
   approve the display and accessories when macOS asks. Apple requires approving
   the external display, keyboard, and pointing device before closed-lid use.
   A Mac locked for three or more days may require unlocking again for accessory
   access. [Apple accessory approval](https://support.apple.com/en-us/102282)
2. Pair the keyboard and trackpad with each Mac using Apple's setup procedure.
   A cable may be needed for initial pairing or recovery; unplug those accessory
   cables for the wireless transfer test. Confirm both devices appear in each
   Mac's Bluetooth settings.
3. Build and install on each Mac with `make install`, then open **Studio Switch**
   from Applications. Allow Bluetooth access if prompted.
4. Select the same keyboard and trackpad on each Mac. Keep the display-name match
   at `Studio Display`, unless your display reports a different name. Confirm the
   app detects attachment and does not report missing sleep protection.
5. Enable **Launch at login** on both. Keep both users logged in and the app
   running; handoff is designed for a locked existing session. The app does not run at
   FileVault preboot, before login, or after logout.
6. Complete the acceptance checks below before using both Macs with closed lids.

Touch ID is separate from typing. Apple permits secure Touch ID pairing with
only one Mac at a time; Studio Switch does not transfer that secure pairing.
[Apple Touch ID security](https://support.apple.com/en-om/guide/security/secf60513daa/web)

### Recovering a pairing-key failure

A locally paired entry and even a baseband connection can coexist with
`BT_ERROR_INVALID_LINK_KEY` in the Bluetooth system log. This means the existing
credentials failed for that attempt; repeatedly connecting does not repair them.
It does not establish which side changed the key or whether another accessory
has the same problem.

For the affected Magic accessory, Apple's supported recovery is to connect it to
the affected Mac by its charging/pairing cable for one minute, then disconnect
the cable and verify wireless input. Leave the other device's pairing untouched.
[Apple recovery instructions](https://support.apple.com/en-gb/102498)
Use **Retry handoff** after repair. Then test A → B → A without any further
pairing or accessory cables before relying on closed-lid transfers. A repeated
invalid-key failure needs investigation of bond retention; a sleep-policy change
cannot fix that condition. Studio Switch does not erase keys or silently re-pair.

## Normal sleep settings

AC settings with **system sleep disabled (`sleep 0`)** and **display sleep
after 10 minutes (`displaysleep 10`)**, are compatible with this behavior. Leave
display sleep enabled: after ten idle minutes the screen may go black while the
app and wireless input remain available. The app uses a temporary idle-sleep
assertion and does not modify these system settings. Manual Sleep, lid/power
conditions, and other forced system-sleep events still take the pre-sleep release
path.

## Physical acceptance checks

Run these on your actual Macs, accessory models, and macOS versions. Automated
state-machine tests cannot establish radio, firmware, sleep, or HID behavior.
Keep a recovery input method available while testing.

| Check | Required observation |
| --- | --- |
| Wireless A → B → A, lids open | Typing and trackpad gestures work after each transfer without re-pairing. |
| Both lids closed; destination asleep | Source logs verified release before sleep; destination wakes, detects display, and accepts both inputs. |
| Reverse direction repeatedly | Both directions work without losing pairing or reconnecting to the old Mac. |
| Move cable quickly, then return it | Obsolete connection work is canceled or compensated; only the current display owner acquires. |
| Source sleeps before detach is observed | Pre-sleep release still runs; no dependence on screen callback ordering. |
| Sleep and wake with display unchanged | Wake starts a fresh acquisition; typing and gestures recover. |
| Leave the attached Mac idle for 10 minutes on AC | Screen goes black; the app remains running and neither peripheral is released. A keyboard key lights the same screen without triggering a handoff. |
| Lock the attached Mac | Locking alone leaves both peripherals connected; input can wake the screen and unlock normally. |
| One peripheral off or out of range | Partial failure is shown; the other device and sleep acknowledgment are not reported as a complete handoff. |
| Bluetooth off, then on at destination | Readiness failure is shown, then maintenance retries recover if pairing remains valid. |
| Locked sessions on both Macs | Handoff works after wake without opening a lid; distinguish accessory approval from Bluetooth failure. |
| Wake old Mac without the display | It releases selected devices instead of claiming them. |

## Build, tests, and diagnostics

Requires macOS 13 or later and Swift 6 tools. `make app` creates an ad-hoc signed
app at `build/Studio Switch.app`; `make install` copies it to Applications.
Launch-at-login registration requires the packaged app.
The test target uses Swift Testing, without an XCTest dependency.
`make test` explicitly loads its bundled macro plugin when present, working around
plugin discovery failures in some Command Line Tools releases.

```sh
swift build
make test
make app
log stream --style compact --level info --predicate 'subsystem == "com.saftanas.studioswitch"'
```

Capture logs on both Macs during a failing transfer. Look for verified release,
the eight-second watchdog, wake-time acquisition, and per-device error codes.
**Retry handoff** restarts reconciliation for the current display state. If the app
reports connected links but input does not work, check Bluetooth settings and
actual typing/gestures; a baseband result alone cannot diagnose the HID path.
