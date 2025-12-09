# 👓 Ray-Ban Price Scanner — AR-first demo

A quick prototype of what’s possible with Ray-Ban Meta glasses as an ambient shopping companion: glance at a barcode and a phone instantly returns price and context. It’s intentionally narrow, focused on proving the loop (see → know → act) and hinting at where AR utility could go next.

## Why I built it
- A layoff + a brand-new Meta wearables SDK + a pair of Ray-Ban Meta glasses sent me down an AR rabbit hole I didn’t expect.
- I’m frugal and constantly price-checking—so the question became: what if I could just look at something and instantly see the price?


## AI-assisted build
I built roughly 95% of this entire project with ChatGPT—and it was incredible! Watching an idea turn into a plan and then into a working prototype, with AI doing most of the heavy lifting, felt downright magical. This is a huge leap forward for product managers: we can now rapidly prototype ideas at lightning speed before ever looping in engineering for full-scale development. It honestly feels like having a supercharged 3D printer for software—the barrier to fast, creative experimentation has never been lower, and it’s unbelievably exciting.


## Screenshots & demos
- Live Stream UI (status pill, overlays): `docs/screenshots/live-stream.png`  
- Barcode overlay with tooltip: `docs/screenshots/overlay-tooltip.png`  
- Phone scanner flow: `docs/screenshots/phone-scan.png`  
- Demo previews (full-length GIF) stacked:

**Live Preview Boudning Box with Price Return**

<img src="docs/demos/LiveScanDemoWithtBoundingBox.gif" alt="Live scan demo" width="320"/><br/>
[Full video](docs/demos/LiveScanDemoWithtBoundingBox.mp4)

**Scan with Meta Glasses and Return Price on UI**

<img src="docs/demos/RaybanScanToPriceDemo.gif" alt="Meta UI scan demo" width="320"/><br/>
[Full video](docs/demos/RaybanScanToPriceDemo.mp4)


## Feature highlights
- 👓📱 Glasses + phone scanning, plus photo-library scanning for debugging.
- 🎥 Live Stream viewer with still capture, save/share, menu-driven FPS (no auto-restart), and Vision barcode overlays.
- 🟡 Live overlay auto-detection: highlights barcodes in the preview and auto-runs a lookup; tooltip shows title/price when found.
- 🔗 Lookup chain: UPCItemDB → BarcodeLookup (API key) → Barcode Monster → OpenFoodFacts (first useful hit wins).
- 🛠️ CLI detector: `Scripts/BarcodeTest.swift` to exercise the Vision/OCR stack on still images.

## Setup
1. Install Meta Wearables SDK (`MWDATCore`, `MWDATCamera`) per Meta docs.  
2. Open `RayBanPriceScanner/RayBanPriceScanner.xcodeproj`, set signing, adjust bundle ID if needed.  
3. In `Info.plist`, set `MWDAT.MetaAppID`, align `MWDAT.AppLinkURLScheme` with your bundle ID + `://`, optionally add `BARCODE_LOOKUP_KEY` for richer pricing.  
4. Build/run on device. In-app Registration pairs the glasses via Meta AI (Developer Mode on), then tap Play in Live Stream.

## How to use
- 📱 Phone: “Scan with iPhone Camera” (AVCapture + Vision + OCR fallback) → lookup + speech.  
- 👓 Glasses: Live Stream → Play to pull frames, capture a high-quality still, see barcode overlays, and get auto tooltip lookups. FPS via the speedometer menu; no auto-reconnects.  
- 🖼️ Photos: “Pick Photo” runs the same Vision/OCR pipeline on saved images.

## Design guardrails
- 🙅 User-agency: start/stop throttled to avoid churn; FPS changes stop the stream until Play is pressed.
- 🛡️ Stability: explicit Reset button, minimal logging by default.
- 🔍 Transparency: combined status pill (state + resolution + fps + auto/manual) and live barcode outlines/tooltips.

## Future directions
- 🤖 Beyond barcodes: gentle object/framing cues to guide capture.  
- ⚡ Smarter capture policy: auto-still only when confidence spikes, tuned for thermals/battery.  
- 🛒 Context: price comparisons, “better price nearby,” or “save for later” once confidence is high.

## Known limitations
- Barcode detection is tuned for larger/clear barcodes; small/low-contrast codes may miss.
- “Hey Meta” voice triggers are not integrated; registration and streaming are initiated in-app.
- The current Meta SDK can’t render price/context on-glasses; the app speaks the result on phone instead.

## Requirements
- Xcode 15+ and current iOS SDK (deployment target ~26.1; lower in Project Settings if needed).  
- Ray-Ban Meta smart glasses + Meta Wearables SDK.  
- iOS device with camera/Bluetooth/mic/photo permissions granted.

## CLI detector
```sh
swift -D BARCODE_SCRIPT RayBanPriceScanner/RayBanPriceScanner/Scripts/BarcodeTest.swift /path/to/image.jpg
```
Add `VERBOSE=1` to see Vision observations.

## Architecture (high level)
```
Ray-Ban Glasses ─(MWDAT)→ StreamSessionViewModel → LiveStreamView (UI)
                                   │                  │
                                   │                  ├─ Vision overlay + tooltip lookup
                                   │                  └─ User controls (Play/Stop/FPS/Reset)
                                   ▼
                            ContentView / QRScannerView (phone scan)
                                   │
                                   ▼
                         ProductLookupService (multi-provider)
                                   │
                                   ▼
                       ProductInfo → SpeechService → UI status
```



## Notes
- `ProductLookupService` trims UPC input and stops at the first provider with data; swap providers as needed.  
- Lightweight by design: this repo is for showcasing AR product thinking, not a full commerce stack.  
- Built with Apple Vision/AVFoundation/SwiftUI and the Meta Wearables SDK (MWDATCore/MWDATCamera).
