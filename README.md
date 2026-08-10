# Singularity 🕳️

A tiny Mac app that drops a black hole onto your screen and lets it eat everything.

Press one button and a small, glowing black hole appears over your desktop. It drifts around, bending and stretching whatever is on screen, slowly swallowing your windows, icons and wallpaper. It grows as it feeds, flares up into a huge ring of light, and in the end the whole screen is black. Press **Reset** and your desktop is back, completely unharmed.

| Feeding time | Growing up |
| --- | --- |
| ![The black hole pulling screen content into itself](assets/demo-feeding.png) | ![The black hole grown large, with a glowing ring](assets/demo-ring.png) |

## How to use it

1. Open **Singularity.app** — a small control panel appears.
2. Set the **Appetite** slider: from *gentle nibble* (a slow three-minute meal) to *ravenous* (everything gone in seconds). You can move it while the black hole is feeding.
3. Click **Unleash** and watch your screen get devoured.
4. Click **Reset** (or press **Esc**) any time to get your screen back instantly.

## Is my stuff safe?

Yes. The app takes a *photo* of your screen and feeds that photo to the black hole. Your real windows, files and apps sit untouched underneath the whole time. Reset simply removes the show.

## First launch

The app needs macOS's **Screen Recording** permission to take the photo of your screen. The first time you click Unleash, macOS will ask — allow it in **System Settings → Privacy & Security → Screen Recording**, then relaunch the app once.

## Building it yourself

You need a Mac with Apple Silicon and the Xcode command line tools. Then:

```bash
./build-app.sh
```

That produces `Singularity.app` in this folder. No Xcode project needed.

## How it works (the slightly nerdy version)

- The screen photo is captured with Apple's ScreenCaptureKit.
- The black hole is a small GPU simulation written in Metal: every frame, each pixel of the photo is pulled a tiny step closer to the hole and rotated around it, so the picture genuinely *flows* into the hole rather than just fading out. Anything crossing the event horizon is gone for good, and darkness also creeps in from the edges of the screen.
- The glowing ring is a fake "accretion disk", plus a bit of gravitational lensing so the light near the hole bends the way it would around a real one.

Made for fun on a rainy Sunday. Feed responsibly.
