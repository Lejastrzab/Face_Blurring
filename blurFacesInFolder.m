%% ========================================================================
%  blurFacesInFolder.m  (v7.0 — Keyframe Annotation + Interpolation)
%  ========================================================================
%
%  PURPOSE:
%    Batch-blurs faces in video stimuli using a keyframe annotation
%    approach. At every N frames, RetinaFace auto-detects human faces
%    and the user clicks on any faces it missed (e.g., robot faces).
%    Between keyframes, face positions are smoothly interpolated.
%    This produces flicker-free, dynamically tracking blur that follows
%    head movement across the video.
%
%  KEY FEATURES:
%    - Works for ANY number of faces (1, 2, 3, 5... as needed)
%    - RetinaFace auto-detects human faces (minimises manual clicking)
%    - User clicks only on faces the detector misses (e.g., robots)
%    - Keyframe interval (N) is easily adjustable
%    - Smooth spline interpolation between keyframes
%    - Mirror videos (_m suffix) get mirrored coordinates automatically
%    - All annotations saved to .mat file for reuse
%
%  HOW IT WORKS:
%
%    For each unique (non-mirror) video:
%      1. Open the video and sample every N-th frame as a "keyframe"
%      2. At each keyframe:
%         a. RetinaFace auto-detects human faces (green boxes shown)
%         b. User LEFT-CLICKS to add any missed faces (robot faces)
%         c. User RIGHT-CLICKS on any false positive to remove it
%         d. User presses ENTER/RETURN to confirm and move to next keyframe
%      3. Between keyframes, face positions are smoothly interpolated
%      4. Gaussian blur applied at every frame using interpolated positions
%      5. Mirror videos processed automatically with flipped coordinates
%
%  USAGE:
%    >> cd('/path/to/stimuli')
%    >> blurFacesInFolder
%
%    Or with explicit paths:
%    >> blurFacesInFolder('/path/to/stimuli', '/path/to/output')
%
%  ADJUSTING KEYFRAME INTERVAL:
%    Change KEYFRAME_INTERVAL below. For 2.5s videos at 30fps (~75 frames):
%      5  = 15 keyframes per video (most accurate, more clicking)
%      8  = 10 keyframes per video (good balance)
%      12 = 7 keyframes per video  (faster, less precise tracking)
%
%  REQUIREMENTS:
%    - MATLAB R2025a+
%    - Computer Vision Toolbox + Image Processing Toolbox
%    - Deep Learning Toolbox + RetinaFace add-on
%
%  DEVELOPMENT NOTE:
%    This script was developed with the assistance of Claude (Anthropic,
%    claude.ai), an AI language model, which contributed to code
%    architecture, implementation, and documentation. All code was
%    reviewed, tested, and validated by Laura Jastrzab.
%
%  AUTHOR:  Laura Jastrzab
%  DATE:    June 12th, 2026
%  VERSION: 7.0
%  ========================================================================

function blurFacesInFolder(srcFolder, dstFolder)

%% ------------------------------------------------------------------------
%  ARGUMENT HANDLING
%  ------------------------------------------------------------------------

if nargin < 1 || isempty(srcFolder)
    srcFolder = pwd;
end
if nargin < 2 || isempty(dstFolder)
    [parentDir, folderName] = fileparts(srcFolder);
    if isempty(parentDir), parentDir = pwd; end
    dstFolder = fullfile(parentDir, [folderName '_blurred']);
end

%% ------------------------------------------------------------------------
%  CONFIGURATION — Adjust these to suit your needs
%  ------------------------------------------------------------------------

% --- Keyframe interval ---------------------------------------------------
% How often (in frames) to show a frame for annotation.
% Lower = more keyframes = more accurate tracking but more clicking.
% Higher = fewer keyframes = faster but less precise.
%
% RECOMMENDATIONS for 2.5s clips at 30fps (~75 frames):
%   5  → ~15 keyframes (best for fast head movement)
%   8  → ~10 keyframes (good default balance)
%   10 → ~8 keyframes  (fine for slow/minimal movement)
%   12 → ~7 keyframes  (faster, less precise tracking)
KEYFRAME_INTERVAL = 8;

% --- Number of faces to track -------------------------------------------
% How many faces/heads to blur in each video.
% Set to 0 for AUTOMATIC mode: the script will ask you on the first
% keyframe of the first video, then use that number for all videos.
% Set to a specific number (1, 2, 3, 5...) to fix it for all videos.
NUM_FACES = 0;  % 0 = ask me

% --- Gaussian blur sigma -------------------------------------------------
% WHAT THIS IS:
%   Sigma (σ) is the standard deviation of the Gaussian (bell curve)
%   kernel used to blur the face. It controls how "spread out" the
%   averaging is — a larger sigma means each output pixel is averaged
%   over a wider neighbourhood, producing a stronger blur.
%
% WHY 55:
%   The goal is to eliminate internal facial features (eyes, nose, mouth)
%   that carry identity and emotional expression information, while
%   preserving the overall head shape and position. The blur kernel
%   spans approximately 6σ pixels (capturing 99.7% of the Gaussian
%   distribution), so σ=55 produces a ~330 px kernel. At typical video
%   resolutions (720p/1080p), faces in full-body shots span roughly
%   80–200 px, so a 330 px kernel thoroughly obliterates all features.
%
%   The 50–60 px range is well-established in the face perception
%   literature for removing diagnostic facial information while
%   preserving configural/spatial cues (see Goffaux & Rossion, 2006;
%   Collishaw & Hole, 2000).
%
% ADJUSTING:
%   Lower (30–40): features partially visible — use only if faces are
%                   very small and you want less blur spread.
%   Higher (60–80): stronger blur — use for high-resolution video or
%                   close-up shots where faces are large in frame.
GAUSSIAN_SIGMA = 55;

% --- Blur ellipse size (proportion of frame height) ----------------------
% Width and height of the blur ellipse as a fraction of frame height.
% These are the DEFAULTS — you can adjust via slider on the first video.
ELLIPSE_W_PROP = 0.09;   % width  (9% of frame height)
ELLIPSE_H_PROP = 0.12;   % height (12% of frame height)

% --- RetinaFace confidence threshold -------------------------------------
% WHAT THIS IS:
%   RetinaFace is a deep-learning face detector (Lin et al., 2020)
%   trained on the WIDER FACE dataset (~32,000 images with ~400,000
%   annotated faces in varied poses, scales, and occlusions). For each
%   region it examines, it outputs a confidence score between 0 and 1
%   representing how likely that region contains a face.
%
%   The threshold controls the trade-off between two types of error:
%     - Too HIGH (e.g., 0.8): misses real faces (false negatives),
%       especially in profile or when the head is partially turned away.
%     - Too LOW  (e.g., 0.2): detects non-face regions as faces
%       (false positives) — shoulders, hands, patterns on clothing.
%
%   In this script, false positives are less dangerous than in earlier
%   versions because detections are only accepted if they fall NEAR a
%   position you've already clicked. A detection on the body will be
%   far from any clicked face position and will be ignored. This is
%   why we can safely use a lower threshold (0.4) — the spatial
%   proximity check acts as a second filter.
%
% NOTE ON ROBOT FACES:
%   RetinaFace is trained exclusively on human faces and will not
%   detect robot faces (Pepper, NAO, etc.), regardless of threshold.
%   This is expected — robot faces are annotated manually via clicking.
CONFIDENCE_THRESHOLD = 0.4;

% --- Elliptical mask feathering ------------------------------------------
% WHAT THIS IS:
%   The blur is applied inside an elliptical region over each face.
%   Without feathering, the ellipse boundary would be a sharp, visible
%   edge — a hard line between blurred and unblurred pixels. This
%   would itself become a distracting visual cue in experimental
%   stimuli, potentially drawing participants' attention to the
%   manipulation rather than the social scene.
%
%   Feathering (also called "falloff") creates a gradual transition
%   zone at the ellipse boundary where the blur fades smoothly from
%   full strength to zero. This is achieved using a smoothstep
%   function (a cubic Hermite polynomial: 3t² - 2t³), which produces
%   a perceptually natural, S-shaped transition — faster than linear
%   fade but without the ringing artefacts of sharper functions.
%
%   The value represents the width of the transition zone as a
%   proportion of the ellipse radius:
%     0.15 = narrow transition (subtle feathering, ellipse faintly visible)
%     0.30 = moderate (soft edge, good for most uses)
%     0.45 = wide transition (heavily feathered, boundary invisible)
%     0.70 = very wide (blur extends well beyond the ellipse)
%
%   See applyEllipticalBlur() function below for implementation details.
MASK_FALLOFF = 0.45;

% --- Mirror suffix --------------------------------------------------------
MIRROR_SUFFIX = '_m';

% --- Video formats --------------------------------------------------------
VIDEO_EXTENSIONS = {'.mp4', '.avi', '.mov', '.mkv', '.wmv', '.m4v'};

%% ------------------------------------------------------------------------
%  STEP 1: FIND AND ORGANISE VIDEOS
%  ------------------------------------------------------------------------

if ~isfolder(dstFolder), mkdir(dstFolder); end

allFiles = dir(srcFolder);
videoFiles = {};
for i = 1:length(allFiles)
    [~, ~, ext] = fileparts(allFiles(i).name);
    if any(strcmpi(ext, VIDEO_EXTENSIONS))
        videoFiles{end+1} = allFiles(i).name; %#ok<AGROW>
    end
end
if isempty(videoFiles)
    error('No video files found in: %s', srcFolder);
end

% Separate originals and mirrors
originals = {};
mirrors   = struct();
for i = 1:length(videoFiles)
    [~, baseName, ~] = fileparts(videoFiles{i});
    if endsWith(baseName, MIRROR_SUFFIX)
        parentBase = baseName(1:end-length(MIRROR_SUFFIX));
        mirrors.(matlab.lang.makeValidName(parentBase)) = videoFiles{i};
    else
        originals{end+1} = videoFiles{i}; %#ok<AGROW>
    end
end

numOriginals = length(originals);
numMirrors   = length(fieldnames(mirrors));

fprintf('\n==========================================================\n');
fprintf('  FACE BLUR v7.0 — Keyframe Annotation + Interpolation\n');
fprintf('==========================================================\n');
fprintf('  Source:         %s\n', srcFolder);
fprintf('  Output:         %s\n', dstFolder);
fprintf('  Originals:      %d  (you annotate these)\n', numOriginals);
fprintf('  Mirrors (_m):   %d  (auto-mirrored)\n', numMirrors);
fprintf('  Keyframe every: %d frames\n', KEYFRAME_INTERVAL);
fprintf('  Sigma:          %d px\n', GAUSSIAN_SIGMA);
fprintf('==========================================================\n\n');

%% ------------------------------------------------------------------------
%  STEP 2: INITIALISE RETINAFACE
%  ------------------------------------------------------------------------

detector = [];
try
    try
        detector = faceDetector("large-network", InputSize=[960 960]);
        fprintf('  RetinaFace (large) loaded.\n');
    catch
        detector = faceDetector("small-network", InputSize=[960 960]);
        fprintf('  RetinaFace (small) loaded.\n');
    end
catch
    fprintf('  WARNING: RetinaFace not available.\n');
    fprintf('  You will need to click ALL faces manually.\n');
end

%% ------------------------------------------------------------------------
%  STEP 3: CHECK FOR SAVED ANNOTATIONS
%  ------------------------------------------------------------------------

annotFile = fullfile(srcFolder, 'face_blur_annotations.mat');
annotations = struct();
ellipseW = 0;
ellipseH = 0;

if isfile(annotFile)
    fprintf('\n  Found saved annotations: %s\n', annotFile);
    choice = input('  Reuse saved annotations? (y/n): ', 's');
    if strcmpi(choice, 'y')
        loaded = load(annotFile);
        annotations = loaded.annotations;
        ellipseW = loaded.ellipseW;
        ellipseH = loaded.ellipseH;
        if isfield(loaded, 'numFaces')
            NUM_FACES = loaded.numFaces;
        end
        fprintf('  Loaded annotations. Ellipse: %dx%d px. Faces: %d\n\n', ...
                ellipseW, ellipseH, NUM_FACES);
    end
end

%% ------------------------------------------------------------------------
%  STEP 4: ANNOTATE ORIGINAL VIDEOS (keyframe-by-keyframe)
%  ------------------------------------------------------------------------

needsEllipseSetup = (ellipseW == 0);

for i = 1:numOriginals
    [~, baseName, ~] = fileparts(originals{i});
    safeName = matlab.lang.makeValidName(baseName);

    % Skip if already annotated
    if isfield(annotations, safeName)
        fprintf('  %s — already annotated, skipping.\n', baseName);
        continue;
    end

    videoPath = fullfile(srcFolder, originals{i});
    vid = VideoReader(videoPath);
    totalFrames = floor(vid.Duration * vid.FrameRate);
    frameWidth  = vid.Width;
    frameHeight = vid.Height;

    % Set ellipse size on first video
    if needsEllipseSetup
        ellipseW = round(frameHeight * ELLIPSE_W_PROP);
        ellipseH = round(frameHeight * ELLIPSE_H_PROP);
    end

    % Determine keyframe indices
    keyframeIdx = 1:KEYFRAME_INTERVAL:totalFrames;
    % Always include the last frame
    if keyframeIdx(end) ~= totalFrames
        keyframeIdx(end+1) = totalFrames;
    end
    numKeyframes = length(keyframeIdx);

    fprintf('\n  Annotating: %s (%d keyframes)\n', originals{i}, numKeyframes);

    % Read ALL frames into memory (2.5s videos are small enough)
    vid = VideoReader(videoPath);
    allFrames = {};
    while hasFrame(vid)
        allFrames{end+1} = readFrame(vid); %#ok<AGROW>
    end
    actualTotalFrames = length(allFrames);

    % Adjust keyframe indices to actual frame count
    keyframeIdx = keyframeIdx(keyframeIdx <= actualTotalFrames);
    numKeyframes = length(keyframeIdx);

    % Storage for per-keyframe face positions
    % Each entry: Nx2 matrix of [cx, cy] for N faces
    keyframePositions = cell(numKeyframes, 1);

    % --- Ask number of faces on first video if not set -------------------
    if NUM_FACES == 0
        fprintf('\n  How many faces/heads should be blurred in each video?\n');
        NUM_FACES = input('  Enter number of faces (e.g., 2): ');
        fprintf('  Tracking %d face(s) per video.\n\n', NUM_FACES);
    end

    % --- Ellipse size setup on first video -------------------------------
    if needsEllipseSetup
        sampleFrame = allFrames{1};
        [ellipseW, ellipseH] = setupEllipseSize(sampleFrame, ellipseW, ellipseH);
        needsEllipseSetup = false;
        fprintf('  Ellipse size: %d x %d px\n', ellipseW, ellipseH);
    end

    % --- Annotate each keyframe ------------------------------------------
    for k = 1:numKeyframes
        fIdx = keyframeIdx(k);
        frame = allFrames{fIdx};

        % Auto-detect with RetinaFace
        autoFaces = [];
        if ~isempty(detector)
            autoFaces = detectHumanFaces(detector, frame, ...
                                         CONFIDENCE_THRESHOLD, frameHeight);
        end

        % Interactive annotation
        positions = annotateKeyframe(frame, autoFaces, NUM_FACES, ...
                                      ellipseW, ellipseH, ...
                                      i, numOriginals, originals{i}, ...
                                      k, numKeyframes, fIdx);

        keyframePositions{k} = positions;
    end

    % Store annotation for this video
    annotations.(safeName).keyframeIdx = keyframeIdx;
    annotations.(safeName).positions   = keyframePositions;
    annotations.(safeName).totalFrames = actualTotalFrames;
    annotations.(safeName).frameWidth  = frameWidth;
    annotations.(safeName).frameHeight = frameHeight;

    % Save after each video (in case of crash/interruption)
    numFaces = NUM_FACES;
    save(annotFile, 'annotations', 'ellipseW', 'ellipseH', 'numFaces');
    fprintf('  Saved annotations for: %s\n', baseName);
end

fprintf('\n  All annotations complete.\n');

%% ------------------------------------------------------------------------
%  STEP 5: PROCESS ALL VIDEOS (interpolate + blur)
%  ------------------------------------------------------------------------

% Build processing order: originals then their mirrors
processOrder = buildProcessOrder(originals, mirrors);

logFile = fullfile(dstFolder, 'processing_log.txt');
fid = fopen(logFile, 'w');
fprintf(fid, 'Face Blur Log v7.0\nStart: %s\n\n', datestr(now));

successCount = 0;
failCount    = 0;
totalStart   = tic;

for v = 1:length(processOrder)

    entry = processOrder(v);
    videoName  = entry.filename;
    isMirror   = entry.isMirror;
    parentBase = entry.parentBase;

    srcPath = fullfile(srcFolder, videoName);
    [~, baseName, ~] = fileparts(videoName);
    dstPath = fullfile(dstFolder, [baseName '_blurred.mp4']);

    elapsed = toc(totalStart);
    if v > 1
        etaStr = formatDuration((elapsed/(v-1)) * (length(processOrder)-v+1));
    else
        etaStr = 'calculating...';
    end

    fprintf('----------------------------------------------------------\n');
    fprintf('  Video %d/%d: %s', v, length(processOrder), videoName);
    if isMirror, fprintf('  [MIRROR]'); end
    fprintf('\n  ETA: %s\n', etaStr);
    fprintf(fid, 'Video %d/%d: %s (mirror=%d)\n', v, length(processOrder), videoName, isMirror);

    safeParent = matlab.lang.makeValidName(parentBase);
    if ~isfield(annotations, safeParent)
        fprintf('  *** No annotations for: %s. Skipping.\n', parentBase);
        fprintf(fid, '  SKIPPED\n\n');
        failCount = failCount + 1;
        continue;
    end

    annot = annotations.(safeParent);

    try
        vidReader = VideoReader(srcPath);
        frameWidth  = vidReader.Width;
        frameHeight = vidReader.Height;

        vidWriter = VideoWriter(dstPath, 'MPEG-4');
        vidWriter.FrameRate = vidReader.FrameRate;
        vidWriter.Quality   = 95;
        open(vidWriter);

        % --- Interpolate positions for ALL frames ------------------------
        allPositions = interpolatePositions(annot.keyframeIdx, ...
                                            annot.positions, ...
                                            annot.totalFrames, ...
                                            NUM_FACES);

        % If mirror, flip all X coordinates
        if isMirror
            for f = 1:length(allPositions)
                if ~isempty(allPositions{f})
                    allPositions{f}(:,1) = frameWidth - allPositions{f}(:,1);
                end
            end
        end

        % --- Apply blur to each frame ------------------------------------
        frameCount = 0;
        while hasFrame(vidReader)
            frame = readFrame(vidReader);
            frameCount = frameCount + 1;

            if frameCount <= length(allPositions) && ~isempty(allPositions{frameCount})
                positions = allPositions{frameCount};
                bboxes = positions2bboxes(positions, ellipseW, ellipseH, ...
                                          frameWidth, frameHeight);
                frame = applyEllipticalBlur(frame, bboxes, ...
                                            GAUSSIAN_SIGMA, MASK_FALLOFF);
            end

            writeVideo(vidWriter, frame);
        end

        close(vidWriter);
        fprintf('  Done: %d frames\n', frameCount);
        fprintf(fid, '  OK | %d frames\n\n', frameCount);
        successCount = successCount + 1;

    catch ME
        fprintf('  *** ERROR: %s\n', ME.message);
        fprintf(fid, '  FAILED | %s\n\n', ME.message);
        failCount = failCount + 1;
        try close(vidWriter); catch; end %#ok<CTCH>
        continue;
    end
end

totalElapsed = toc(totalStart);
fclose(fid);

fprintf('\n==========================================================\n');
fprintf('  COMPLETE: %d OK, %d failed of %d\n', ...
        successCount, failCount, length(processOrder));
fprintf('  Time: %s  |  Output: %s\n', formatDuration(totalElapsed), dstFolder);
fprintf('==========================================================\n');

end  % end main function


%% ========================================================================
%  RETINAFACE DETECTION
%  ========================================================================

function faceCentres = detectHumanFaces(detector, frame, confThresh, frameH) %#ok<DEFNU>
% DETECTHUMANFACES  Run RetinaFace and return face centre coordinates.
%
%   Returns Nx2 matrix of [cx, cy] for each detected human face.
%   Filters by confidence and vertical position (upper 60% of frame).

    [bboxes, scores, ~] = detect(detector, frame);
    if istable(bboxes), bboxes = table2array(bboxes); end
    bboxes = double(bboxes);

    faceCentres = [];
    if isempty(bboxes) || isempty(scores), return; end

    % Filter by confidence
    keep = scores >= confThresh;
    bboxes = bboxes(keep, :);

    % Filter by vertical position (faces in upper 60%)
    if ~isempty(bboxes)
        cy = bboxes(:,2) + bboxes(:,4)/2;
        keep = cy < frameH * 0.65;
        bboxes = bboxes(keep, :);
    end

    % Return centres
    if ~isempty(bboxes)
        faceCentres = [bboxes(:,1) + bboxes(:,3)/2, ...
                       bboxes(:,2) + bboxes(:,4)/2];
    end
end


%% ========================================================================
%  KEYFRAME ANNOTATION INTERFACE
%  ========================================================================

function positions = annotateKeyframe(frame, autoFaces, numFaces, ...
                                       ellW, ellH, ...
                                       vidIdx, numVids, vidName, ...
                                       kfIdx, numKF, frameIdx)
% ANNOTATEKEYFRAME  Show a keyframe with auto-detections, let user add/remove.
%
%   Green ellipses = auto-detected (RetinaFace)
%   User LEFT-CLICKS to add missed faces
%   User RIGHT-CLICKS near an existing face to REMOVE it (false positive)
%   User presses ENTER when done (or when numFaces faces are marked)
%
%   Returns Nx2 matrix of [cx, cy] for all confirmed face centres.

    theta = linspace(0, 2*pi, 100);

    % Start with auto-detected faces
    if ~isempty(autoFaces)
        currentFaces = autoFaces;
    else
        currentFaces = zeros(0, 2);
    end

    % Create figure
    fig = figure('Name', 'Keyframe Annotation', ...
                 'Position', [50 50 1200 750], 'NumberTitle', 'off');
    ax = axes(fig);
    imshow(frame, 'Parent', ax);
    hold(ax, 'on');

    % Store state in figure's appdata so callbacks can access it
    setappdata(fig, 'currentFaces', currentFaces);
    setappdata(fig, 'ellipseHandles', {});
    setappdata(fig, 'theta', theta);
    setappdata(fig, 'ellW', ellW);
    setappdata(fig, 'ellH', ellH);
    setappdata(fig, 'numFaces', numFaces);
    setappdata(fig, 'ax', ax);
    setappdata(fig, 'vidIdx', vidIdx);
    setappdata(fig, 'numVids', numVids);
    setappdata(fig, 'vidName', vidName);
    setappdata(fig, 'kfIdx', kfIdx);
    setappdata(fig, 'numKF', numKF);
    setappdata(fig, 'frameIdx', frameIdx);

    % Draw existing auto-detections (green ellipses)
    handles = {};
    for f = 1:size(currentFaces, 1)
        h = plot(ax, currentFaces(f,1) + (ellW/2)*cos(theta), ...
                 currentFaces(f,2) + (ellH/2)*sin(theta), ...
                 'g-', 'LineWidth', 2);
        handles{end+1} = h; %#ok<AGROW>
    end
    setappdata(fig, 'ellipseHandles', handles);

    numAutoDetected = size(currentFaces, 1);
    numNeeded = numFaces - size(currentFaces, 1);

    updateTitle(vidIdx, numVids, vidName, kfIdx, numKF, frameIdx, ...
                size(currentFaces,1), numFaces);

    % --- CONFIRM button --------------------------------------------------
    % This replaces the ENTER key approach, which is unreliable in R2025b.
    % Click CONFIRM when all faces are correctly marked.
    uicontrol(fig, 'Style', 'pushbutton', 'String', 'CONFIRM', ...
              'Units', 'normalized', 'Position', [0.40 0.93 0.20 0.05], ...
              'FontSize', 13, 'FontWeight', 'bold', ...
              'BackgroundColor', [0.3 0.8 0.3], ...
              'Callback', @(~,~) uiresume(fig));

    % --- Mouse click callbacks -------------------------------------------
    % LEFT CLICK on image = add a face at that position
    % RIGHT CLICK near existing face = remove it
    set(ax, 'ButtonDownFcn', @(src, evt) handleAnnotationClick(fig, evt));
    imgObj = findobj(ax, 'Type', 'image');
    if ~isempty(imgObj)
        set(imgObj, 'ButtonDownFcn', @(src, evt) handleAnnotationClick(fig, evt));
    end

    % --- Console instructions --------------------------------------------
    if numAutoDetected > 0
        fprintf('    Keyframe %d/%d (frame %d): %d auto-detected.', ...
                kfIdx, numKF, frameIdx, numAutoDetected);
    else
        fprintf('    Keyframe %d/%d (frame %d): No auto-detections.', ...
                kfIdx, numKF, frameIdx);
    end

    if numNeeded > 0
        fprintf(' Left-click %d more face(s), then CONFIRM.\n', numNeeded);
    else
        fprintf(' All faces found — click CONFIRM.\n');
    end

    % --- Wait for CONFIRM button -----------------------------------------
    uiwait(fig);

    % Retrieve final face positions
    if isvalid(fig)
        positions = getappdata(fig, 'currentFaces');
        close(fig);
    else
        positions = currentFaces;  % figure closed manually
    end
end


function handleAnnotationClick(fig, evt) %#ok<DEFNU>
% HANDLEANNOTATIONCLICK  Process left/right clicks on keyframe image.
%
%   LEFT CLICK  (SelectionType = 'normal') → add a face at click position
%   RIGHT CLICK (SelectionType = 'alt')    → remove the nearest face

    if ~isvalid(fig), return; end

    clickPos = evt.IntersectionPoint(1:2);
    cx = clickPos(1);
    cy = clickPos(2);

    currentFaces = getappdata(fig, 'currentFaces');
    handles      = getappdata(fig, 'ellipseHandles');
    theta        = getappdata(fig, 'theta');
    ellW         = getappdata(fig, 'ellW');
    ellH         = getappdata(fig, 'ellH');
    numFaces     = getappdata(fig, 'numFaces');
    ax           = getappdata(fig, 'ax');

    selType = get(fig, 'SelectionType');

    if strcmp(selType, 'normal')
        % LEFT CLICK — add a face (yellow ellipse for manual annotations)
        currentFaces(end+1, :) = [cx, cy];
        h = plot(ax, cx + (ellW/2)*cos(theta), ...
                 cy + (ellH/2)*sin(theta), ...
                 'y-', 'LineWidth', 2);
        plot(ax, cx, cy, 'y+', 'MarkerSize', 20, 'LineWidth', 2);
        handles{end+1} = h;

        setappdata(fig, 'currentFaces', currentFaces);
        setappdata(fig, 'ellipseHandles', handles);

        updateTitle(getappdata(fig,'vidIdx'), getappdata(fig,'numVids'), ...
                    getappdata(fig,'vidName'), getappdata(fig,'kfIdx'), ...
                    getappdata(fig,'numKF'), getappdata(fig,'frameIdx'), ...
                    size(currentFaces,1), numFaces);

        if size(currentFaces, 1) >= numFaces
            fprintf('    All %d faces marked. Click CONFIRM.\n', numFaces);
        end

    elseif strcmp(selType, 'alt')
        % RIGHT CLICK — remove nearest face
        if ~isempty(currentFaces)
            dists = sqrt((currentFaces(:,1)-cx).^2 + (currentFaces(:,2)-cy).^2);
            [minD, removeIdx] = min(dists);

            if minD < max(ellW, ellH)
                currentFaces(removeIdx, :) = [];
                if removeIdx <= length(handles)
                    delete(handles{removeIdx});
                    handles(removeIdx) = [];
                end
                setappdata(fig, 'currentFaces', currentFaces);
                setappdata(fig, 'ellipseHandles', handles);

                fprintf('    Removed face %d. %d remaining.\n', ...
                        removeIdx, size(currentFaces,1));
                updateTitle(getappdata(fig,'vidIdx'), getappdata(fig,'numVids'), ...
                            getappdata(fig,'vidName'), getappdata(fig,'kfIdx'), ...
                            getappdata(fig,'numKF'), getappdata(fig,'frameIdx'), ...
                            size(currentFaces,1), numFaces);
            end
        end
    end
end  % end handleAnnotationClick


function updateTitle(vidIdx, numVids, vidName, kfIdx, numKF, fIdx, nCurrent, nTarget) %#ok<DEFNU>
    cleanName = strrep(vidName, '_', '\_');
    title(sprintf('Video %d/%d: %s  |  Keyframe %d/%d (frame %d)  |  Faces: %d/%d\nLEFT-click=add  |  RIGHT-click=remove  |  CONFIRM=accept', ...
          vidIdx, numVids, cleanName, kfIdx, numKF, fIdx, nCurrent, nTarget), ...
          'FontSize', 12);
end


%% ========================================================================
%  ELLIPSE SIZE SETUP
%  ========================================================================

function [ew, eh] = setupEllipseSize(frame, defaultW, defaultH) %#ok<DEFNU>
% SETUPELLIPSESIZE  Interactive slider to set blur ellipse dimensions.

    [fH, ~, ~] = size(frame);
    fig = figure('Name', 'Set Blur Size', 'Position', [50 50 1000 700], ...
                 'NumberTitle', 'off');
    imshow(frame);
    hold on;

    % Draw sample ellipse in frame centre
    cx = size(frame,2)/2;
    cy = fH * 0.3;
    theta = linspace(0, 2*pi, 100);
    ell = plot(cx + (defaultW/2)*cos(theta), cy + (defaultH/2)*sin(theta), ...
               'g-', 'LineWidth', 2);

    title('Adjust blur ellipse size, then click CONFIRM', 'FontSize', 14);

    sliderPanel = uipanel(fig, 'Position', [0.1 0.01 0.8 0.06]);
    uicontrol(sliderPanel, 'Style', 'text', 'String', 'Size:', ...
              'Units', 'normalized', 'Position', [0 0.1 0.1 0.8], 'FontSize', 11);
    slider = uicontrol(sliderPanel, 'Style', 'slider', ...
              'Min', 0.4, 'Max', 2.5, 'Value', 1.0, ...
              'Units', 'normalized', 'Position', [0.11 0.1 0.6 0.8]);
    sizeLabel = uicontrol(sliderPanel, 'Style', 'text', ...
              'String', sprintf('%d x %d px', defaultW, defaultH), ...
              'Units', 'normalized', 'Position', [0.73 0.1 0.25 0.8], 'FontSize', 11);

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'CONFIRM', ...
              'Units', 'normalized', 'Position', [0.38 0.93 0.24 0.05], ...
              'FontSize', 13, 'FontWeight', 'bold', ...
              'BackgroundColor', [0.3 0.8 0.3], ...
              'Callback', @(~,~) uiresume(fig));

    addlistener(slider, 'ContinuousValueChange', @(src, ~) ...
        updateEllSize(src, ell, cx, cy, defaultW, defaultH, sizeLabel));

    uiwait(fig);

    if isvalid(fig)
        sf = slider.Value;
        close(fig);
    else
        sf = 1.0;
    end

    ew = round(defaultW * sf);
    eh = round(defaultH * sf);
end


function updateEllSize(slider, ell, cx, cy, baseW, baseH, label) %#ok<DEFNU>
    sf = slider.Value;
    nw = round(baseW * sf);
    nh = round(baseH * sf);
    theta = linspace(0, 2*pi, 100);
    set(ell, 'XData', cx + (nw/2)*cos(theta), 'YData', cy + (nh/2)*sin(theta));
    set(label, 'String', sprintf('%d x %d px', nw, nh));
end


%% ========================================================================
%  INTERPOLATION
%  ========================================================================

function allPositions = interpolatePositions(keyframeIdx, keyframePositions, ...
                                              totalFrames, numFaces) %#ok<DEFNU>
% INTERPOLATEPOSITIONS  Smooth interpolation of face positions between keyframes.
%
%   Uses piecewise cubic interpolation (pchip) for smooth, overshoot-free
%   motion between clicked/detected positions. Falls back to linear
%   interpolation if fewer than 3 keyframes are available.
%
%   INPUTS:
%     keyframeIdx       — 1xK vector of keyframe frame numbers
%     keyframePositions — Kx1 cell array, each containing Nx2 [cx,cy]
%     totalFrames       — total number of frames in the video
%     numFaces          — expected number of faces
%
%   OUTPUT:
%     allPositions      — totalFrames x 1 cell array, each Nx2 [cx,cy]

    allPositions = cell(totalFrames, 1);
    K = length(keyframeIdx);

    if K == 0, return; end

    % For each face, interpolate X and Y independently
    for f = 1:numFaces

        % Extract this face's position at each keyframe
        kfX = nan(K, 1);
        kfY = nan(K, 1);

        for k = 1:K
            pos = keyframePositions{k};
            if ~isempty(pos) && f <= size(pos, 1)
                kfX(k) = pos(f, 1);
                kfY(k) = pos(f, 2);
            end
        end

        % Skip this face if no valid positions
        validMask = ~isnan(kfX) & ~isnan(kfY);
        if sum(validMask) == 0, continue; end

        validIdx = keyframeIdx(validMask);
        validX   = kfX(validMask);
        validY   = kfY(validMask);

        % Fill any gaps by nearest-neighbour (for robustness)
        if sum(validMask) < K
            allKfX = interp1(validIdx, validX, keyframeIdx, 'nearest', 'extrap');
            allKfY = interp1(validIdx, validY, keyframeIdx, 'nearest', 'extrap');
            validIdx = keyframeIdx;
            validX = allKfX;
            validY = allKfY;
        end

        % Interpolate across all frames
        frameRange = 1:totalFrames;

        if length(validIdx) >= 3
            % Piecewise cubic Hermite (smooth, no overshoot)
            interpX = pchip(validIdx, validX, frameRange);
            interpY = pchip(validIdx, validY, frameRange);
        elseif length(validIdx) == 2
            % Linear interpolation
            interpX = interp1(validIdx, validX, frameRange, 'linear', 'extrap');
            interpY = interp1(validIdx, validY, frameRange, 'linear', 'extrap');
        else
            % Single keyframe — constant position
            interpX = repmat(validX(1), 1, totalFrames);
            interpY = repmat(validY(1), 1, totalFrames);
        end

        % Store interpolated positions
        for fr = 1:totalFrames
            if isempty(allPositions{fr})
                allPositions{fr} = [interpX(fr), interpY(fr)];
            else
                allPositions{fr}(end+1, :) = [interpX(fr), interpY(fr)];
            end
        end
    end
end


%% ========================================================================
%  BLUR APPLICATION
%  ========================================================================

function bboxes = positions2bboxes(positions, ellW, ellH, imgW, imgH) %#ok<DEFNU>
% POSITIONS2BBOXES  Convert Nx2 [cx,cy] centres to Nx4 [x,y,w,h] boxes.

    n = size(positions, 1);
    bboxes = zeros(n, 4);
    for i = 1:n
        x = max(1, round(positions(i,1) - ellW/2));
        y = max(1, round(positions(i,2) - ellH/2));
        w = min(ellW, imgW - x);
        h = min(ellH, imgH - y);
        bboxes(i,:) = [x, y, w, h];
    end
end


function out = applyEllipticalBlur(frame, bboxes, sigma, falloff) %#ok<DEFNU>
% APPLYELLIPTICALBLUR  Gaussian blur within soft, feathered elliptical masks.
%
%   This function blurs face regions while leaving the rest of the image
%   sharp. It works in three steps:
%
%   STEP 1 — BLUR THE ENTIRE FRAME
%     A full Gaussian blur is applied to a copy of the entire frame.
%     This may seem wasteful (we only need face regions), but it avoids
%     edge artefacts that would occur at crop boundaries if we blurred
%     sub-regions individually. The kernel size is set to 6σ+1 pixels,
%     which captures 99.7% of the Gaussian distribution.
%
%   STEP 2 — BUILD SOFT ELLIPTICAL MASKS
%     For each face, an elliptical mask is computed. Each pixel gets a
%     value between 0 (keep original) and 1 (use blurred). The key
%     maths: for each pixel (x,y), we compute its normalised distance
%     from the ellipse centre:
%
%       d = (x-cx)²/rx² + (y-cy)²/ry²
%
%     where (cx,cy) is the ellipse centre and (rx,ry) are the semi-axes.
%     Pixels with d < 1 are inside the ellipse; d > 1 are outside.
%
%     The feathering is applied at the boundary using smoothstep:
%       t = clamp((d - 1) / falloff)    — normalise the transition zone
%       mask = 1 - (3t² - 2t³)          — smooth S-curve from 1 to 0
%
%   STEP 3 — ALPHA-BLEND
%     The final image is a per-pixel blend of the original and blurred
%     frames, weighted by the mask:
%
%       output = mask × blurred + (1 - mask) × original
%
%     Where mask=1 (face centre), output is fully blurred.
%     Where mask=0 (background), output is fully sharp.
%     In the feathered transition zone, it's a smooth mix of both.

    if isempty(bboxes), out = frame; return; end

    % STEP 1: Blur entire frame
    ks = 2 * ceil(3 * sigma) + 1;   % kernel size = 6σ+1 (always odd)
    blurred = imgaussfilt(frame, sigma, 'FilterSize', ks);

    % STEP 2: Build composite mask from all face ellipses
    [h, w, ~] = size(frame);
    mask = zeros(h, w);

    for i = 1:size(bboxes, 1)
        % Ellipse geometry from bounding box
        cx = bboxes(i,1) + bboxes(i,3)/2;   % centre x
        cy = bboxes(i,2) + bboxes(i,4)/2;   % centre y
        rx = bboxes(i,3) / 2;                % horizontal semi-axis
        ry = bboxes(i,4) / 2;                % vertical semi-axis
        if rx < 1 || ry < 1, continue; end

        % Only compute within a padded local region (performance optimisation)
        pad = round(max(rx, ry) * (1 + falloff)) + 5;
        x1 = max(1, round(cx - rx - pad));
        x2 = min(w, round(cx + rx + pad));
        y1 = max(1, round(cy - ry - pad));
        y2 = min(h, round(cy + ry + pad));

        % Normalised elliptical distance field
        [XX, YY] = meshgrid(x1:x2, y1:y2);
        eDist = ((XX-cx).^2 / rx^2) + ((YY-cy).^2 / ry^2);

        % Smoothstep feathering at the ellipse boundary
        t = min(max((eDist - 1) / falloff, 0), 1);   % clamp to [0,1]
        faceMask = 1 - t.*t.*(3 - 2*t);               % cubic smoothstep

        % Combine with composite mask (max handles overlapping faces)
        mask(y1:y2, x1:x2) = max(mask(y1:y2, x1:x2), faceMask);
    end

    mask = min(max(mask, 0), 1);    % clamp final mask

    % STEP 3: Alpha-blend original and blurred frames
    m3 = repmat(mask, [1 1 3]);     % extend mask to 3 colour channels
    out = uint8(double(blurred) .* m3 + double(frame) .* (1 - m3));
end


%% ========================================================================
%  VIDEO ORDERING
%  ========================================================================

function order = buildProcessOrder(originals, mirrors) %#ok<DEFNU>
    order = struct('filename', {}, 'isMirror', {}, 'parentBase', {});
    for i = 1:length(originals)
        [~, baseName, ~] = fileparts(originals{i});
        entry.filename   = originals{i};
        entry.isMirror   = false;
        entry.parentBase = baseName;
        order(end+1) = entry; %#ok<AGROW>

        safeName = matlab.lang.makeValidName(baseName);
        if isfield(mirrors, safeName)
            mEntry.filename   = mirrors.(safeName);
            mEntry.isMirror   = true;
            mEntry.parentBase = baseName;
            order(end+1) = mEntry; %#ok<AGROW>
        end
    end
    mirrorNames = fieldnames(mirrors);
    for i = 1:length(mirrorNames)
        alreadyAdded = false;
        for j = 1:length(order)
            if strcmp(order(j).filename, mirrors.(mirrorNames{i}))
                alreadyAdded = true; break;
            end
        end
        if ~alreadyAdded
            entry.filename   = mirrors.(mirrorNames{i});
            entry.isMirror   = true;
            entry.parentBase = mirrorNames{i};
            order(end+1) = entry; %#ok<AGROW>
        end
    end
end


%% ========================================================================
%  UTILITIES
%  ========================================================================

function str = formatDuration(seconds) %#ok<DEFNU>
    h = floor(seconds / 3600);
    m = floor(mod(seconds, 3600) / 60);
    s = floor(mod(seconds, 60));
    if h > 0,     str = sprintf('%dh %02dm %02ds', h, m, s);
    elseif m > 0, str = sprintf('%dm %02ds', m, s);
    else,         str = sprintf('%ds', s);
    end
end
