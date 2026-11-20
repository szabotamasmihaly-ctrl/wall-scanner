# Wall Scanner (iPhone, LiDAR + AR)

Scan a wall during construction while pipes, cables and rebar are visible. Later,
point the phone at the finished wall and the app projects the saved photo and
markings onto it through the camera, with a crosshair that tells you how far you
are from the nearest hidden feature before you drill.

The app has two tabs: **Walls** (what is inside a wall) and **Buildings** (blueprint of
the whole building from LiDAR measurements tied to fixed known points).

## Walls tab

1. **Scan a wall with live video** – tap the bottom-left and bottom-right corners where the wall
   meets the floor, set the height, press **Record** and sweep the phone slowly over the open
   wall (about 1 m away). Every good video frame is straightened onto the wall and painted into
   one to-scale wall picture; a coverage bar shows how much of the wall you have filmed.
   Frames that are too far, too oblique or badly tracked are skipped automatically.
   (Or skip recording and save a single shot.)
   While the wall is open you can also **mark in AR**: pick Spot or Run and a type (pipe,
   electrical, rebar, void), then tap on the wall in the camera view; marks are drawn in place.
   To put the wall on the building blueprint, pick the building and measure 2 of its known
   points with the green crosshair in the same scan. The app:
   - builds the straightened, true-to-scale wall picture,
   - saves an ARKit room map (uses LiDAR mesh when available) so it can find the wall again,
   - stores the wall size and the two corners as reference points.
2. **Mark what is inside** – on the wall's page, tap the photo to add:
   - *Spot* marks (sockets, boxes, holes), *Run* marks (pipes, cables, rebar – tap several points, then Finish),
   - *Reference points* (optionally with surveyed coordinates for later georeferencing).
3. **Show on the wall (AR)** – opens the camera, recognises the room and lays the
   photo + marks over the real wall. Controls: transparency, photo / marks / grid toggles.
   - **No-drill zones**: red bands within 5 cm and orange bands within 15 cm of every mark.
   - Crosshair readout: position (cm from left corner, cm above floor) and distance to
     the nearest mark. Green = more than 15 cm, orange = 5–15 cm, red = under 5 cm.
   - If the room is not recognised (likely after plastering/painting, because it looks
     different), use **Align manually**: tap the same two bottom corners. Then tap
     **Remember this room** to save a new map of the finished room, so next time it is automatic.

Data is stored on the phone in the app's Documents/Walls folder (one folder per wall:
`wall.json`, `photo.jpg`, `map.arworldmap`). "Export wall data (JSON)" shares the record.

## Buildings tab: blueprint from known points

**Site setup.** Under *Site reference points*, add the 4 points your surveyor gave you
(name + easting/northing/elevation, e.g. EOV). Measure each with the phone during your scans.
Every scan, room and wall is then placed on the survey grid, and each point shows its fit
in cm (green < 3 cm, orange < 10 cm, red = probably mis-tapped or a wrong coordinate).

1. **New building**, then **Measure outside with LiDAR**. Aim the crosshair and add:
   - **Known points**: outside building corners at ground level, survey marks, door frame corners.
     Measure at least 2 in every session. Corners are joined in list order to draw the outline.
   - **Windows / doors / openings**: left edge then right edge. **Point**: anything else.
   The screen shows the live distance to the aim point and from the last point. Stay within
   ~5 m for LiDAR accuracy; walk along the facade and keep the session running.
2. **Scan rooms (RoomPlan)**: Apple's RoomPlan scans walls, doors, windows and openings.
   Press **Room done**, walk into the next room and **Scan next room** – all rooms are scanned
   in one session and merged into one floor plan. While scanning, **Mark known point** on at
   least 2 points also measured outside (e.g. both sides of the entrance door frame) to line
   the rooms up with the outside.
3. **Blueprint**: building outline, windows and doors with chain dimensions
   (corner → window → window → corner), interior walls, known points, north arrow and scale bar.
   Pinch/drag to move, tap two points to measure between them, export as an image.
   Each RoomPlan scan can also be shared as a 3D USDZ model. Walls scanned during construction
   and linked to the building appear as pink lines labelled with how many pipes/cables they hold.

**Coordinates.** If no known point has surveyed coordinates, the first session with two known
points defines a local frame (first point = 0/0, second due east). Enter surveyed coordinates
(e.g. EOV) on 2+ known points and everything – outline, rooms, measurements – is placed on that
grid. Sessions chain together through shared points; each shows its fit error in cm.

## Requirements

- A Mac with **Xcode 16 or newer** (Xcode 26 is fine).
- An iPhone/iPad with **LiDAR** (iPhone 12 Pro / Pro Max or newer Pro models, iPad Pro 2020+), iOS 17+.
  It also runs on non-LiDAR devices, with lower accuracy.
- An Apple ID (a free one works for running on your own phone; apps signed with a free account expire after 7 days).

## Build and run

1. Copy the `WallScanner` folder to your Mac (unzip `WallScanner.zip`).
2. Double-click `WallScanner.xcodeproj` to open it in Xcode.
3. In the left sidebar click the blue **WallScanner** project → target **WallScanner** →
   **Signing & Capabilities**:
   - Team: choose your Apple ID (Xcode → Settings → Accounts to add one),
   - Bundle Identifier: change `com.example.wallscanner` to something unique, e.g. `com.yourname.wallscanner`.
4. Connect the iPhone with a cable, unlock it, and pick it as the run destination at the top of Xcode.
   On the phone, enable **Settings → Privacy & Security → Developer Mode** if asked (phone restarts).
5. Press **Run** (▶ or ⌘R). The first time, on the phone go to
   **Settings → General → VPN & Device Management** and trust your developer certificate.
6. Allow camera access when the app asks.

The simulator cannot run AR – use a real device.

If Xcode refuses to open the project file, install XcodeGen (`brew install xcodegen`)
and run `xcodegen` in this folder; it rebuilds `WallScanner.xcodeproj` from `project.yml`.

## Tips for good results

- Before tapping corners, walk around the room for 5–10 s so tracking and the map ("Map: good") settle.
- Include stable features in view while scanning (window frames, door frames, floor, ceiling) –
  these are what let the phone recognise the room later, because the wall itself will look different once finished.
- When saving, stand back so the **whole blue frame** is on screen; anything outside shows grey in the photo.
- Use several walls per room rather than one huge one.

## Accuracy and safety

Expect a few centimetres of error (LiDAR, tracking and where you tapped the corners all add up).
The overlay is a guide, not a guarantee: keep the traffic-light margins, and use a
detector before drilling near live cables or pressurised pipes.

## Code map

| File | What it does |
|---|---|
| `ScanController.swift`, `ScanView.swift` | AR scanning: corner taps, wall frame preview, capture & save |
| `WallGeometry.swift` | Wall coordinate frame, ray/plane math, photo straightening (Core Image perspective correction) |
| `OverlayController.swift`, `OverlayView.swift` | Relocalisation with the saved map, manual alignment, overlay plane, crosshair clearance |
| `OverlayRenderer.swift` | Draws photo + grid + marks into the texture shown in AR |
| `WallDetailView.swift` | Mark editor on the straightened photo, reference points / survey coordinates |
| `Models.swift`, `WallStore.swift` | Data model and on-device storage |
| `WallMosaic.swift` | Live video scanning: straightens each good frame onto the wall and blends it in |
| `BuildingModels.swift`, `BuildingStore.swift` | Building, known points, measurement sessions, storage |
| `BuildingSolver.swift` | Ties sessions together through shared known points (least-squares fit) |
| `ExteriorMeasure.swift` | LiDAR point measuring outside (corners, windows, doors) |
| `RoomScan.swift` | RoomPlan multi-room scanning and merging |
| `Blueprint.swift` | Floor plan drawing, chain dimensions, tap-to-measure, image export |
| `BuildingViews.swift` | Building list, details, known point editor |

## Data model and georeferencing

Everything on a wall is stored in **wall coordinates** (metres, origin bottom-left corner,
x to the right, y up), independent of any AR session. `ReferencePoint` records a point on
the wall and, optionally, a `SurveyedCoordinate` (easting, northing, elevation, system name).
With 2+ surveyed points a later version can compute the wall's position in the building /
national grid (a 2D similarity transform along the wall plus elevation), so all walls can be
placed into one building model and matched against BIM/CAD data.

## Possible next steps

- Several photos per wall stitched together; video/mesh capture for larger walls.
- Auto-detect pipes/cables in the photo with a Vision/Core ML model.
- Cloud sync and sharing between construction team and owner.
