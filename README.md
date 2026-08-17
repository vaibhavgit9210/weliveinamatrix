# simulation cam

A webcam toy that renders "the tracking layer of the simulation" over your camera feed. It does not sprinkle labels over everything that moves. It decides what the frame is *about*, locks onto every instance of that one thing, and floods those locks with numbers — the machine-vision overlay aesthetic, without any actual machine vision.

Live at https://vaibhavgit9210.github.io/weliveinamatrix/ (also deployed as a copy at https://vaibhavgit9210.github.io/simulation-cam/, part of the portfolio arcade). There is a native iOS and macOS build in `xcode/`.

## What it tracks

One class of subject at a time, and never anything outside it.

| in frame | mode | what you get |
|---|---|---|
| a face, a hand, a bird, a cat | `LIVING` | a corner-bracket box on the whole subject, its class and id, a scan line, and the numeric flood **inside** the box; face and hand get wired together with link lines |
| a shaft of light with dust in it | `TYNDALL` | the shaft's silhouette, flooded with numbers clipped to the beam — nothing else on screen is marked at all |
| bees, ants, dust, anything numerous and small | `SWARM` | one small box and one id each, plus a web of lines between neighbours |
| one moving thing that fits nothing above | `OBJECT` | a single lock |

How busy the overlay gets is set by how much chaos is in the frame: hold still and a face carries a dozen marks, wave both hands and it carries fifty. The readout in the corner shows which class the frame was locked to, how many locks and marks are live, and the chaos figure driving it.

## How it works

There is still no ML model, and nothing is recorded or uploaded.

1. **Sample.** Each camera frame is drawn cover-cropped to a fullscreen canvas (mirrored for the front camera), then reduced to a luminance grid plus a skin mask. The skin test is a chroma box (Chai & Ngan), which is why it holds across skin tones where a brightness rule would not.
2. **Difference and light.** Motion is frame differencing with a neighbour-confirmation check. A separate pass looks for cells that are bright *and* smooth, which is what a shaft of light is and a textured wall is not.
3. **Group.** Connected components turn "cells that changed" into "things that moved". Two scales matter: motes are measured on the raw motion mask, subject-sized masses on a mask grown by two cells, because one bee grown by two cells is neither a mote nor a body and would fall through the classifier entirely.
4. **Find skin without motion.** Skin components are found on their own. A face held still barely differences at all, and locking the hand because it was the only thing that moved is exactly the wrong answer.
5. **Find grains without motion either.** If too few things moved to call it a swarm, a summed-area table finds small high-contrast grains instead, so a line of crawling ants or dust hanging in still air still counts. Two caps stop a brick wall reading as a thousand insects.
6. **Pick one class.** Living wins if there is any; then a beam, but only if the small movers are mostly *inside* it, which is the difference between dust in a shaft and bees in a garden; then a swarm; then a single object. A new class has to hold for a few frames before the display follows it, and when it does, the old locks are dropped rather than relabelled.
7. **Track.** Each instance gets a persistent id and a box eased onto the measurement, so it lags slightly and looks like it is tracking rather than snapping. Overlapping duplicates are culled.
8. **Flood.** The old confetti still exists, but it is penned inside whatever is locked, and its density follows the chaos figure.

Two details that are easy to get wrong and were:

- **A shaft of light must be long, thin, and bright against darkness.** Without the contrast and elongation tests, a white wall, a lit window or a sheet of paper all read as Tyndall — the one thing this mode is not allowed to get wrong.
- **The ink adapts to the frame.** White labels are invisible on a bright beam or a pale wall, so the ink is picked from the luminance under each mark.

The skin rule is a heuristic: terracotta, bare wood and some brick fall inside the same chroma box, so pointing the camera at a wooden table can produce a `BODY` lock. That is the price of doing it without a model.

## Running locally

No build step, no dependencies — one `index.html`.

Open `index.html` directly in a browser (the camera API requires `https://` or `file://`, not plain `http://`) and click **OPEN CAMERA**.

For headless testing and screenshots there are synthetic scenes that drive the whole pipeline with no camera at all:

```
index.html?test=face          # a face plus a moving hand   -> LIVING
index.html?test=swarm         # twenty small movers         -> SWARM
index.html?test=beam          # a shaft with motes in it    -> TYNDALL
index.html?test=object        # one moving block            -> OBJECT
index.html?test=beam&frames=80&seed=7
```

`frames=N` runs N steps synchronously and stops, which is the only way to screenshot this under a virtual-time budget; `seed=N` pins the run.

## Native app

`xcode/` has the same thing as a real iOS and macOS app: SwiftUI shell, AVFoundation camera, SpriteKit overlay, one target for both platforms, no packages. Same detector, same classes, same numbers.

```
open xcode/SimulationCam.xcodeproj
```

See `xcode/README.md` for how it is put together and what has and has not been verified.
