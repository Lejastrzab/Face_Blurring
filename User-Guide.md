# User Guide: Face Blur for Video Stimuli

A step-by-step guide to using `blurFacesInFolder.m` for preparing face-blurred video stimuli in social interaction research.

---

## Contents

1. [Installation and setup](#1-installation-and-setup)
2. [Preparing your video files](#2-preparing-your-video-files)
3. [Running the script](#3-running-the-script)
4. [The annotation workflow](#4-the-annotation-workflow)
5. [Understanding the parameters](#5-understanding-the-parameters)
6. [Re-running and editing annotations](#6-re-running-and-editing-annotations)
7. [Output files](#7-output-files)
8. [Troubleshooting](#8-troubleshooting)
9. [How it works (technical overview)](#9-how-it-works-technical-overview)
10. [Suggested methods text](#10-suggested-methods-text)

---

## 1. Installation and setup

### MATLAB version

You need **MATLAB R2025a or later**. The script uses the built-in `faceDetector` function (RetinaFace), which was introduced in R2025a.

### Required toolboxes

Install the following via the MATLAB Add-On Manager (Home tab → Add-Ons → Manage Add-Ons):

| Toolbox | What it's used for |
|---|---|
| Computer Vision Toolbox | Face detection, video I/O |
| Image Processing Toolbox | Gaussian blur (`imgaussfilt`) |
| Deep Learning Toolbox | RetinaFace neural network backbone |

### RetinaFace model add-on

This must be installed separately:

1. In MATLAB, go to **Home → Add-Ons → Get Add-Ons**
2. Search for **"Computer Vision Toolbox Model for RetinaFace Face Detection"**
3. Click **Install**
4. Restart MATLAB

To verify the installation, run:

```matlab
detector = faceDetector;
```

If this runs without error, you're ready to go.

### Placing the script

You have two options:

- **Option A**: Copy `blurFacesInFolder.m` into the folder that contains your video files.
- **Option B**: Keep the script anywhere on your MATLAB path and pass the video folder as an argument.

---

## 2. Preparing your video files

### Supported formats

`.mp4`, `.avi`, `.mov`, `.mkv`, `.wmv`, `.m4v`

### Mirror video convention

If you have mirrored versions of your videos (horizontally flipped), name them with a `_m` suffix before the extension. For example:

```
trial_01.mp4        ← original
trial_01_m.mp4      ← mirror (horizontally flipped)
trial_02.mp4        ← original
trial_02_m.mp4      ← mirror
```

The script will automatically apply horizontally flipped face coordinates to mirror videos. You only annotate the originals — mirrors are processed for free.

If your mirror convention uses a different suffix, change `MIRROR_SUFFIX` in the configuration section of the script (line ~117).

### Folder structure

Place all videos (originals and mirrors) in a single folder. The script will create a sibling `_blurred` folder for the output:

```
Desktop/
├── stimuli/                    ← your source folder
│   ├── trial_01.mp4
│   ├── trial_01_m.mp4
│   ├── trial_02.mp4
│   ├── trial_02_m.mp4
│   └── ...
└── stimuli_blurred/            ← created automatically
    ├── trial_01_blurred.mp4
    ├── trial_01_m_blurred.mp4
    └── ...
```

---

## 3. Running the script

### Option A: From inside the video folder

```matlab
cd('/path/to/stimuli')
blurFacesInFolder
```

### Option B: With explicit paths

```matlab
blurFacesInFolder('/path/to/stimuli', '/path/to/output')
```

### What happens when you run it

1. The script scans the folder and reports how many original and mirror videos it found.
2. It loads the RetinaFace detector.
3. It asks how many faces to track per video (e.g., 2 for a dyad).
4. It shows the **ellipse size setup** screen (first video only).
5. It walks you through **keyframe annotation** for each original video.
6. After all annotations are complete, it processes every video (originals + mirrors) and saves the blurred output.

---

## 4. The annotation workflow

### Step 1: Set the ellipse size

On the first video, you'll see a frame with a green ellipse in the centre and a slider at the bottom. This sets how large the blur region will be — it should be big enough to cover a full head but not so large that it bleeds onto the body.

- Adjust the **slider** until the ellipse size looks right for your stimuli
- Click the green **CONFIRM** button
- This size is used for all videos

### Step 2: Annotate keyframes

For each original video, the script shows you a frame at regular intervals (every 8 frames by default). At each keyframe:

**What you'll see:**
- **Green ellipses** = faces auto-detected by RetinaFace (typically the human faces)
- The frame number, video name, and face count are shown in the title bar

**What to do:**
- If all faces are correctly detected → click **CONFIRM**
- If a face is missing (e.g., the robot) → **left-click** on its centre, then click **CONFIRM**
- If there's a false detection → **right-click** near it to remove it, then click **CONFIRM**

**Colour coding:**
- Green ellipses = auto-detected (RetinaFace)
- Yellow ellipses = manually clicked by you

### Typical annotation pattern for a human-robot dyad

At each keyframe, you'll typically see:
- 1 green ellipse on the human face (auto-detected) ✓
- Nothing on the robot face (not detected — expected) ✗

So your action is: **left-click on the robot's head, then click CONFIRM**. This takes about 3 seconds per keyframe.

### Time estimate

For a 2.5-second video at 30 fps with keyframe interval of 8:
- ~10 keyframes per video
- ~3 seconds per keyframe
- ~30 seconds per original video

For 150 original videos: approximately **75 minutes** of annotation. Mirror videos require no annotation.

---

## 5. Understanding the parameters

All parameters are in the **CONFIGURATION** section near the top of the script. Here are the ones you're most likely to adjust:

### `KEYFRAME_INTERVAL` (default: 8)

How many frames between each annotation keyframe. For 2.5-second clips at 30 fps (~75 frames):

| Value | Keyframes per clip | Best for |
|---|---|---|
| 5 | ~15 | Fast head movement, high precision needed |
| 8 | ~10 | **Good default balance** |
| 10 | ~8 | Moderate movement |
| 12 | ~7 | Minimal movement, faster annotation |

### `GAUSSIAN_SIGMA` (default: 55)

Controls blur strength. The blur kernel spans approximately 6σ pixels.

| Value | Kernel size | Effect |
|---|---|---|
| 30–40 | ~180–240 px | Partial feature removal (features faintly visible) |
| **55** | **~330 px** | **Full feature elimination (recommended)** |
| 60–80 | ~360–480 px | Very strong blur (for large faces or close-up shots) |

The value of 55 is consistent with the face perception literature for removing diagnostic facial information (see Goffaux & Rossion, 2006; Collishaw & Hole, 2000).

### `CONFIDENCE_THRESHOLD` (default: 0.4)

Minimum confidence score for RetinaFace detections. Lower values detect more faces but may produce false positives.

| Value | Trade-off |
|---|---|
| 0.3 | More sensitive — catches difficult angles, but may detect non-faces |
| **0.4** | **Good balance for profile views** |
| 0.5 | More conservative — fewer false positives |
| 0.7 | Very strict — may miss profile or partially turned faces |

### `MASK_FALLOFF` (default: 0.45)

Controls how gradually the blur fades at the ellipse boundary (feathering). Higher values produce a softer, less visible edge.

| Value | Effect |
|---|---|
| 0.15 | Sharp edge (ellipse outline faintly visible) |
| 0.30 | Moderate feathering |
| **0.45** | **Heavily feathered (boundary invisible)** |
| 0.70 | Very wide fade (blur extends well beyond ellipse) |

### `NUM_FACES` (default: 0 = ask me)

Set to 0 to be prompted on first run. Or set to a specific number (e.g., 2 for dyads) to skip the prompt.

### `ELLIPSE_W_PROP` / `ELLIPSE_H_PROP` (defaults: 0.09 / 0.12)

Starting size of the blur ellipse as a proportion of frame height. These set the default slider position — you can adjust interactively during the first video.

---

## 6. Re-running and editing annotations

### Reusing saved annotations

All annotations are saved to `face_blur_annotations.mat` in your source folder. When you re-run the script, it will ask:

```
Found saved annotations: /path/to/stimuli/face_blur_annotations.mat
Reuse saved annotations? (y/n):
```

- Press **y** to skip annotation and go straight to processing (useful after changing blur parameters)
- Press **n** to re-annotate from scratch

### Re-annotating specific videos

If you need to re-annotate only some videos, delete the `.mat` file and re-run. The script annotates videos in order and saves after each one, so if you interrupt it partway through, the completed videos will be saved.

### Changing parameters without re-annotating

If you want to adjust `GAUSSIAN_SIGMA`, `MASK_FALLOFF`, or other blur parameters without re-clicking all the faces, simply change the values in the script and re-run. When prompted, choose **y** to reuse saved annotations. Only the blur rendering will change.

---

## 7. Output files

### Blurred videos

Saved as `.mp4` (H.264 codec, 95% quality) in the output folder with `_blurred` appended to the filename:

```
stimuli_blurred/
├── trial_01_blurred.mp4
├── trial_01_m_blurred.mp4
├── trial_02_blurred.mp4
└── ...
```

### Annotation file

`face_blur_annotations.mat` — saved in the source folder. Contains all keyframe face positions, ellipse dimensions, and the number of faces. Keep this file if you want to reprocess videos with different parameters later.

### Processing log

`processing_log.txt` — saved in the output folder. Records the status of each video (success/failure, frame count, processing time).

---

## 8. Troubleshooting

### "No video files found"

- Check that your video files are in the folder you specified
- Ensure the file extensions match the supported formats (`.mp4`, `.avi`, `.mov`, `.mkv`, `.wmv`, `.m4v`)

### RetinaFace not detecting human faces

- Try lowering `CONFIDENCE_THRESHOLD` to 0.3 or 0.2
- Ensure the face is at least partially visible (the detector struggles with fully turned-away heads)
- If faces are very small in frame, the detector may still miss them — click manually

### Robot faces not detected

This is expected. RetinaFace is trained on human faces only. Robot faces (Pepper, NAO, Furhat, etc.) must be annotated manually by clicking. This is by design — no current face detector reliably handles abstract robot faces.

### Blur appears too large / too small

Re-run the script and choose **n** when asked to reuse saved annotations. This will let you re-set the ellipse size with the slider. Alternatively, adjust `ELLIPSE_W_PROP` and `ELLIPSE_H_PROP` in the configuration section before re-running.

### Blur edge is visible

Increase `MASK_FALLOFF` (e.g., from 0.45 to 0.60) for softer feathering.

### Head movement not tracked smoothly

Decrease `KEYFRAME_INTERVAL` (e.g., from 8 to 5) to annotate more frequently. This gives the interpolation more data points and tracks movement more precisely.

### Script interrupted midway

Annotations are saved after each completed video, so progress is not lost. Re-run the script and choose **y** to reuse saved annotations — already-annotated videos will be skipped.

### False positive detections on body/clothing

- Right-click near the false detection to remove it at each keyframe
- If this happens frequently, increase `CONFIDENCE_THRESHOLD` to 0.5 or 0.6

---

## 9. How it works (technical overview)

### Detection

Human faces are detected using **RetinaFace** (Lin et al., 2020), a deep-learning face detector trained on the WIDER FACE dataset (~32,000 images, ~400,000 faces). It uses a feature pyramid network with a ResNet-50 or MobileNet-0.25 backbone, achieving high accuracy on small, profile, and partially occluded faces. The MATLAB implementation is provided via the `faceDetector` function (R2025a+).

Robot and non-human faces are not detected automatically (no current detector handles abstract robot faces reliably) and are annotated manually.

### Interpolation

Between keyframes, face positions are interpolated using **piecewise cubic Hermite interpolation** (MATLAB's `pchip`). This produces smooth, natural-looking motion without the overshoot artefacts that standard cubic spline interpolation can produce. For videos with fewer than 3 keyframes, linear interpolation is used as a fallback.

### Blur method

A **Gaussian blur** (σ = 55 px, kernel ≈ 330 px) is applied within **soft elliptical masks**. The process for each frame:

1. The entire frame is blurred with `imgaussfilt`
2. For each face, an elliptical alpha mask is computed using a **smoothstep function** (cubic Hermite: 3t² − 2t³) that creates a feathered transition at the boundary
3. The output is an alpha-blend: `output = mask × blurred + (1 − mask) × original`

This eliminates internal facial features while preserving head shape, consistent with established methods in the face perception literature.

### Mirror handling

Videos whose filename ends with `_m` (before the extension) are treated as horizontally mirrored versions of their parent video. Face coordinates are flipped by computing `x_mirror = frame_width − x_original`. No additional annotation is required.

---

## 10. Suggested methods text

### For a paper or thesis

> Face-blurred stimulus variants were generated using a custom MATLAB script (R2025b). Face positions were annotated at keyframe intervals (every 8 frames) and interpolated across all frames using piecewise cubic Hermite interpolation. Human faces were auto-detected at each keyframe using RetinaFace (Lin et al., 2020; MathWorks Computer Vision Toolbox); robot faces were annotated manually. A Gaussian blur (σ = 55 px) was applied within feathered elliptical masks (smoothstep falloff = 0.45) to eliminate internal facial features while preserving head shape and position. The script was developed with assistance from Claude (Anthropic, Opus 4.6), an AI language model, and validated by Laura Jastrzab.

### For a data availability statement

> The face-blurring tool used to prepare stimuli is available at github.com/Lejastrzab/Face_Blurring.

---

## References

- Collishaw, S. M., & Hole, G. J. (2000). Featural and configurational processes in the recognition of faces of different familiarity. *Perception*, 29(8), 893–909.
- Goffaux, V., & Rossion, B. (2006). Faces are "spatial"—Holistic face perception is supported by low spatial frequencies. *Journal of Experimental Psychology: Human Perception and Performance*, 32(4), 1023–1039.
- Lin, C., et al. (2020). RetinaFace: Single-shot multi-level face localisation in the wild. *Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition*, 5203–5212.
