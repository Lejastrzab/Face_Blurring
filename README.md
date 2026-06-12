# Face Blur for Video Stimuli

A MATLAB tool for applying Gaussian face blur to video stimuli in social interaction research. Designed for experiments in social neuroscience, social robotics, and human-robot interaction (HRI) where facial identity and expression cues need to be controlled.

## What it does

`blurFacesInFolder.m` processes a folder of short video clips (e.g., 2.5 s dyadic interaction stimuli), applying a feathered Gaussian blur (σ = 55 px) to face regions while preserving head shape, body posture, and scene context. It handles both **human and robot faces** — including platforms like Pepper and NAO whose abstract faces are not detected by standard face recognition systems.

### Key features

- **Keyframe annotation with interpolation** — mark face positions every *N* frames; smooth spline interpolation fills in the rest, producing flicker-free blur that tracks head movement
- **Automatic human face detection** — RetinaFace (deep learning) auto-detects human faces at each keyframe, minimising manual clicking
- **Works with any agent type** — human faces are auto-detected; robot or non-human faces are annotated manually with a single click per keyframe
- **Flexible face count** — supports 1, 2, 3, or more faces per video
- **Mirror video support** — videos with a `_m` suffix automatically receive horizontally flipped coordinates from their parent video, halving annotation time
- **Saved annotations** — all click positions are saved to a `.mat` file; re-running the script reuses them without re-clicking
- **Adjustable parameters** — blur strength, ellipse size, feathering softness, keyframe interval, and detection confidence are all configurable

### Blur method

Faces are blurred using a Gaussian kernel (σ = 55 px by default) applied within soft, feathered elliptical masks. The ellipse boundary uses a cubic smoothstep function to create a gradual transition between blurred and sharp regions, avoiding visible edges. This eliminates internal facial features (eyes, nose, mouth) while preserving the overall head silhouette — consistent with established methods in the face perception literature (e.g., Goffaux & Rossion, 2006).

## Requirements

- **MATLAB R2025a** or later
- **Computer Vision Toolbox**
- **Image Processing Toolbox**
- **Deep Learning Toolbox**
- **Computer Vision Toolbox Model for RetinaFace Face Detection** (install via Add-Ons > Get Add-Ons)

## Quick start

```matlab
% Place blurFacesInFolder.m in your video folder, then:
cd('/path/to/stimuli')
blurFacesInFolder
```

Or specify paths explicitly:

```matlab
blurFacesInFolder('/path/to/stimuli', '/path/to/output')
```

Blurred videos are saved as `.mp4` files in a `_blurred` output folder alongside your source folder.

See [`USER_GUIDE.md`](USER_GUIDE.md) for detailed setup instructions, a walkthrough of the annotation workflow, parameter tuning guidance, and troubleshooting.

## Citation

If you use this tool in your research, please cite the repository and note the method in your stimulus preparation description. See the User Guide for suggested wording.

## Development note

This script was developed with the assistance of Claude (Anthropic, Opus 4.6), an AI language model, which contributed to code architecture, implementation, and documentation. All code was reviewed, tested, and validated by Laura Jastrzab.

## Licence

MIT License. 
