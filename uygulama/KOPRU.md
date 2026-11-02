# Uygulama ⇄ Ev Ekranı köprüsü (sürüm 2)

The Swift Playgrounds app ("Ev Ekranı", `uygulama/Ev Ekrani.swiftpm`) shows `index.html` in a WKWebView and does
the things a web page cannot: Bluetooth, real screen brightness, battery. The page owns all logic and settings;
the app is a thin, generic bridge so that new features normally need only web changes.

## Detection

At document start the app injects:

```js
window.EV_NATIVE = { climate: true, app: "2", ble: true, brightness: true, battery: true, sound: true, http: true, miio: true, web: true };
```

App v1 (already installed on the hallway iPad) injects `{climate:true, app:'1'}` and only calls
`window.evNativeClimate({t,h,mv})` / `window.evNativeClimate({status})`. The page must keep supporting that.

## App → page: `window.evNative(msg)`

The app calls `window.evNative && window.evNative(msg)` with one of:

| `type` | fields | when |
|---|---|---|
| `reading` | `id`, `kind:"thermo"`, `name`, `t` (°C, 2 decimals), `h` (% RH, integer), `mv` (battery mV, 0 if unknown), `rssi` | after each successful read of a thermometer (every 5 min per device) |
| `reading` | `id`, `kind:"flora"`, `name`, `t`, `moisture` (%), `light` (lux), `cond` (µS/cm), `bat` (%, may be -1) | after each read of a Mi Flora plant sensor (every 30 min) |
| `seen` | `id`, `kind:"tag"`, `name`, `rssi` | a watched presence tag is advertising; since app 2.2 the app listens in short bursts (about 5 s every 45 s), so expect one message per tag roughly every 45 s while it is home |
| `scan` | `devices: [{id, name, kind, rssi}]`, `done: bool` | during/after a discovery scan the page asked for (sent every ~2 s with the cumulative list, last one has `done:true`) |
| `battery` | `level` (0–100, -1 unknown), `charging` (bool), `full` (bool) | on change and every 5 min |
| `status` | `id` (optional), `text` | human-readable problem/state text (Bluetooth off, permission missing, a device not answering) |
| `listen` | `on` (bool), `labels` (all sound names the classifier knows, only when `on`), `text` (problem, optional) | sound recognition started / stopped / failed |
| `sound` | `label` (lower-case classifier name, e.g. `smoke_detector`, `door_bell`, `baby_crying`), `confidence` (0–1) | a recognised sound; same label at most every 8 s. Since app 2.2 the classifier pauses while the room is silent (below about -50 dBFS) and uses non-overlapping windows, to save battery. Only labels containing smoke, fire, alarm, door, knock, baby, cry, glass, shatter, dog, bark, siren, beep, bell, scream or water are passed on |

Also, for app-v1-era pages, after every thermometer reading of the **first** thermometer in the device list the app
also calls `window.evNativeClimate({t,h,mv})`.

`kind` is guessed from the advertised name: `LYWSD03*`, `ATC_*`, `MJWSD*` → `thermo`; `Flower care`, `Flower mate`
→ `flora`; `iTAG*`, `iTag*`, `ITAG*`, `Smart Tag*`, `Tag*` → `tag`; anything else with a name → `other`.
Unnamed devices are not listed.

`id` is the iPad's stable identifier for that Bluetooth device (a UUID string). It differs per iPad.

## Page → app: `window.webkit.messageHandlers.ev.postMessage(obj)`

| `cmd` | fields | effect |
|---|---|---|
| `devices` | `list: [{id, kind}]` (`kind` in `thermo`, `flora`, `tag`) | the devices the app should read (`thermo` every 5 min, `flora` every 30 min) or watch (`tag`). Replaces the previous list. Sent on load and whenever the list changes. An empty list means "auto": the app reads the first `LYWSD03*` it finds (app v1 behaviour) and reports it with its `id`, so the page can adopt it. |
| `scan` | `seconds` (5–60) | discovery: the app reports every named device it hears via `type:"scan"` messages |
| `brightness` | `value` (0.0–1.0) | sets the real screen brightness |
| `battery` | — | asks for an immediate `battery` message |
| `http` | `id`, `url` (private addresses 192.168.x, 10.x, 172.16–31.x, 169.254.x, *.local over http/https; since app 2.1 also any public **https** URL with normal certificate checks), `method`, `headers` (object of strings), `body` (string), `user`/`pass` (digest or basic login), `timeout` (s) | a request to a device on the home network; self-signed HTTPS accepted for private hosts. Answer: `{type:"http", id, ok, status, body, error?}` |
| `miio` | `id`, `ip` (private), `token` (32 hex), `method`, `params` | Xiaomi Mi Home device over the local miIO protocol (UDP 54321). Answer `{type:"miio", id, ok, result?, error?}` (app 2.1) |
| `listen` | `on` (bool), `threshold` (0.3–0.95, optional, default 0.6) | starts/stops on-device sound recognition (microphone permission is asked the first time). Nothing is recorded or sent; only labels come back |

Always guard: `if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.ev) …`.

## Data the page sends to the phones

Indoor climate and presence travel inside the existing state snapshot (no extra ntfy messages):

```js
cl: { t: 24.1, h: 49, at: 1793560000000,              // main (first) thermometer
      rooms: [ { n: "Banyo", t: 22.8, h: 71, at: … } ] }  // other thermometers, max 6
pr: [ { n: "Ali", home: true, at: 1793560000000 } ]       // presence tags; at = time of last change
```

Both are optional and must be omitted when there is nothing to report. Arrival/leave notifications for presence
and the low-tablet-battery warning are sent with the existing `sendToPhone(text)` (tag `house`).
