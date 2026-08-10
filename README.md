# Singularity 🕳️

A tiny Mac app that drops a black hole onto your screen and lets it eat everything.

Press one button and a small, glowing black hole appears over your desktop. It drifts around, bending and stretching whatever is on screen, slowly swallowing your windows, icons and wallpaper. And the screen stays *alive* while it happens — a playing video keeps playing right up until the moment it stretches, smears and disappears into the hole. The hole grows as it feeds, flares up into a huge ring of light, and in the end the whole screen is black. Press **Reset** and your desktop is back, completely unharmed.

| Feeding time | Growing up |
| --- | --- |
| ![The black hole pulling screen content into itself](assets/demo-feeding.png) | ![The black hole grown large, with a glowing ring](assets/demo-ring.png) |

## How to use it

1. Open **Singularity.app** — a small control panel appears.
2. Set the **Appetite** slider: from *gentle nibble* (a slow three-minute meal) to *ravenous* (everything gone in seconds). You can move it while the black hole is feeding.
3. Click **Unleash** and watch your screen get devoured.
4. Click **Reset** (or press **Esc**) any time to get your screen back instantly.

## Is my stuff safe?

Yes. The app watches a live *video feed* of your screen (the same mechanism screen-sharing apps use) and feeds that video to the black hole. Your real windows, files and apps sit untouched underneath the whole time. Reset simply removes the show.

## First launch

The app needs macOS's **Screen Recording** permission to see your screen. The first time you click Unleash, macOS will ask — allow it in **System Settings → Privacy & Security → Screen Recording**, then relaunch the app once.

## Building it yourself

You need a Mac with Apple Silicon and the Xcode command line tools. Then:

```bash
./build-app.sh
```

That produces `Singularity.app` in this folder. No Xcode project needed.

**One gotcha if you rebuild often:** macOS ties the Screen Recording permission to the app's code signature. The build script signs with a throwaway ("ad-hoc") signature by default, which changes on every build — so after each rebuild, macOS thinks it's a brand-new app and asks for permission again. To make the permission stick, create a self-signed code-signing certificate once (Keychain Access → Certificate Assistant → Create a Certificate → type *Code Signing*), put its name in the `IDENTITY` variable in `build-app.sh`, and every rebuild will be recognized as the same app.

## How it works (the slightly nerdy version)

- The screen is captured live at 60 fps with Apple's ScreenCaptureKit, with the app's own windows excluded from the capture — otherwise the overlay would film itself and recurse into an infinite mirror.
- The black hole is a small GPU simulation written in Metal. It doesn't warp the video frames directly — it warps a *flow field*: a map that records, for every point on screen, where that point should fetch its picture from. Every frame each map entry is pulled a tiny step closer to the hole and rotated around it, so screen content genuinely *flows* into the hole — while regions that haven't been eaten yet keep showing live, moving video. Anything crossing the event horizon is gone for good, and darkness also creeps in from the edges of the screen.
- The glowing ring is a fake "accretion disk", plus a bit of gravitational lensing so the light near the hole bends the way it would around a real one.
- There's a hidden test mode for hacking on the effect without any permissions: `Singularity.app/Contents/MacOS/Singularity --test --out=/some/folder` runs the whole simulation against a built-in synthetic image and writes checkpoint PNGs (that's how the pictures above were made).

Made for fun on a rainy Sunday. Feed responsibly.
