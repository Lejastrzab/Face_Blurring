%% ========================================================================
%  blurFacesInFolder.m  (Click-to-Blur)
%  ========================================================================
%
%  PURPOSE:
%    Batch-blurs faces in video stimuli of social interaction dyads.
%    You click on each face in the first frame of each unique video.
%    The blur is then applied at that fixed position across all frames.
%    Mirror videos (ending in '_m') automatically reuse coordinates
%    from their parent video with horizontally flipped positions.
%
%  DESIGN PHILOSOPHY:
%    YOU identify the faces(which takes ~5 seconds per unique video), 
%    and the script handles the rest with zero detection errors, 
%    zero dropout, and zero flicker.
%
%    For the HUMAN face, RetinaFace can optionally refine the position
%    frame-by-frame (since it works well on humans). But if it ever
%    drops out, the blur simply stays at the last known good position.
%    For the ROBOT face, the clicked position is used for every frame
%    with no detection attempted.
%
%  WORKFLOW:
%    1. Place this script in your stimuli folder (or specify the path)
%    2. Run: blurFacesInFolder
%    3. For each unique video (non-mirror), a frame appears
%    4. Click on the centre of HEAD 1, then HEAD 2
%    5. Adjust blur size with the slider, click CONFIRM
%    6. The script processes that video + its mirror automatically
%    7. Repeat for each unique video
%
%    All click positions are saved to a .mat file. If you re-run the
%    script, it will ask whether to reuse saved positions or re-click.
%
%  MIRROR CONVENTION:
%    A video named "trial_01.mov" and "trial_01_m.mov" are treated as
%    a pair. You only click on "trial_01.mov"; the mirror version
%    gets horizontally flipped coordinates automatically.
%
%  REQUIREMENTS:
%    - MATLAB R2025a+ (for optional RetinaFace refinement)
%    - Computer Vision Toolbox
%    - Image Processing Toolbox
%    - Deep Learning Toolbox + RetinaFace add-on (optional but recommended)
%
%  AUTHOR:  [Laura Jastrzab]
%  DATE:    [March 11, 2026]
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
%  CONFIGURATION
%  ------------------------------------------------------------------------

% --- Gaussian blur sigma -------------------------------------------------
GAUSSIAN_SIGMA = 55;

% --- Use RetinaFace to refine HUMAN face position? -----------------------
% true  = RetinaFace gently adjusts the human blur position frame-by-frame
%         (smooth, never drops out — falls back to last good position)
% false = both faces use purely fixed positions from your clicks
%         (simplest, most predictable, zero chance of any detection error)
USE_RETINAFACE_REFINEMENT = true;

% --- RetinaFace confidence threshold (only used if refinement is on) -----
% Lowered to 0.4 to maintain detection during partial head turns (e.g.,
% "no" head shakes). Since we only accept detections NEAR a clicked
% position, false positives on bodies are already filtered out by
% distance, so a lower threshold here is safe.
CONFIDENCE_THRESHOLD = 0.4;

% --- Temporal smoothing for RetinaFace refinement ------------------------
% How much weight to give the NEW detected position each frame.
% Higher = follows movement more closely (good for head shakes/nods)
% Lower  = more stable but sluggish (blur lags behind movement)
%   0.2 = very heavy smoothing (barely moves)
%   0.4 = moderate (follows gentle head turns and nods well)
%   0.5 = responsive (follows head shakes — recommended for your stimuli)
%   0.7 = very responsive (tracks fast movement, slightly less stable)
% Only applies when USE_RETINAFACE_REFINEMENT = true.
% NOTE: When RetinaFace loses the face (e.g., head turned away during a
% "no" shake), the blur simply stays at the last known position — no
% dropout. It picks back up when the face returns.
TEMPORAL_ALPHA = 0.5;

% --- Elliptical mask softness --------------------------------------------
MASK_FALLOFF = 0.20;

% --- Video formats --------------------------------------------------------
VIDEO_EXTENSIONS = {'.mp4', '.avi', '.mov', '.mkv', '.wmv', '.m4v'};

% --- Mirror suffix --------------------------------------------------------
% Videos ending with this suffix before the extension are treated as
% mirrors of the base video. E.g., "trial01_m.mp4" mirrors "trial01.mp4"
MIRROR_SUFFIX = '_m';

%% ------------------------------------------------------------------------
%  STEP 1: FIND AND ORGANISE VIDEOS
%  ------------------------------------------------------------------------

if ~isfolder(dstFolder), mkdir(dstFolder); end

% Find all video files
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

% --- Separate into originals and mirrors ---------------------------------
% An "original" is any video whose base name does NOT end with MIRROR_SUFFIX.
% A "mirror" is any video whose base name DOES end with MIRROR_SUFFIX.
% We link each mirror to its parent original.

originals = {};       % list of original video filenames
mirrors   = struct(); % map: original base name -> mirror filename

for i = 1:length(videoFiles)
    [~, baseName, ext] = fileparts(videoFiles{i});

    if endsWith(baseName, MIRROR_SUFFIX)
        % This is a mirror — find its parent
        parentBase = baseName(1:end-length(MIRROR_SUFFIX));
        mirrors.(matlab.lang.makeValidName(parentBase)) = videoFiles{i};
    else
        originals{end+1} = videoFiles{i}; %#ok<AGROW>
    end
end

numOriginals = length(originals);
numMirrors   = length(fieldnames(mirrors));
totalVideos  = length(videoFiles);

fprintf('\n==========================================================\n');
fprintf('  FACE BLUR v7.0 — Click-to-Blur\n');
fprintf('==========================================================\n');
fprintf('  Source:     %s\n', srcFolder);
fprintf('  Output:     %s\n', dstFolder);
fprintf('  Total videos:    %d\n', totalVideos);
fprintf('  Originals:       %d  (you will click on these)\n', numOriginals);
fprintf('  Mirrors (_m):    %d  (coordinates auto-mirrored)\n', numMirrors);
fprintf('  Sigma:           %d px\n', GAUSSIAN_SIGMA);
fprintf('  RetinaFace:      %s\n', mat2str(USE_RETINAFACE_REFINEMENT));
fprintf('==========================================================\n\n');

%% ------------------------------------------------------------------------
%  STEP 2: LOAD OR CREATE CLICK POSITIONS
%  ------------------------------------------------------------------------

coordsFile = fullfile(srcFolder, 'face_blur_coords.mat');

if isfile(coordsFile)
    fprintf('  Found saved coordinates: %s\n', coordsFile);
    fprintf('  Do you want to reuse them? (Saves re-clicking)\n');
    choice = input('  Reuse saved coordinates? (y/n): ', 's');
    if strcmpi(choice, 'y')
        loaded = load(coordsFile);
        coords = loaded.coords;
        ellipseW = loaded.ellipseW;
        ellipseH = loaded.ellipseH;
        fprintf('  Loaded %d saved positions. Ellipse: %dx%d px\n\n', ...
                length(fieldnames(coords)), ellipseW, ellipseH);
    else
        [coords, ellipseW, ellipseH] = clickAllOriginals(originals, srcFolder);
        save(coordsFile, 'coords', 'ellipseW', 'ellipseH');
        fprintf('  Coordinates saved to: %s\n\n', coordsFile);
    end
else
    [coords, ellipseW, ellipseH] = clickAllOriginals(originals, srcFolder);
    save(coordsFile, 'coords', 'ellipseW', 'ellipseH');
    fprintf('  Coordinates saved to: %s\n\n', coordsFile);
end

%% ------------------------------------------------------------------------
%  STEP 3: INITIALISE RETINAFACE (optional)
%  ------------------------------------------------------------------------

detector = [];
if USE_RETINAFACE_REFINEMENT
    try
        try
            detector = faceDetector("large-network", InputSize=[960 960]);
            fprintf('  RetinaFace (large) loaded for human face refinement.\n');
        catch
            detector = faceDetector("small-network", InputSize=[960 960]);
            fprintf('  RetinaFace (small) loaded for human face refinement.\n');
        end
    catch
        fprintf('  RetinaFace not available. Using fixed positions only.\n');
        USE_RETINAFACE_REFINEMENT = false;
    end
end

%% ------------------------------------------------------------------------
%  STEP 4: LOGGING
%  ------------------------------------------------------------------------

logFile = fullfile(dstFolder, 'processing_log.txt');
fid = fopen(logFile, 'w');
fprintf(fid, 'Face Blur Log v6.0 — Click-to-Blur\n');
fprintf(fid, 'Start: %s\nSigma: %d | Ellipse: %dx%d\n\n', ...
        datestr(now), GAUSSIAN_SIGMA, ellipseW, ellipseH);

%% ------------------------------------------------------------------------
%  STEP 5: PROCESS ALL VIDEOS
%  ------------------------------------------------------------------------

successCount = 0;
failCount    = 0;
totalStart   = tic;
processOrder = buildProcessOrder(originals, mirrors, MIRROR_SUFFIX);

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
        etaStr = formatDuration((elapsed/(v-1)) * (length(processOrder) - v + 1));
    else
        etaStr = 'calculating...';
    end

    fprintf('----------------------------------------------------------\n');
    fprintf('  Video %d/%d: %s', v, length(processOrder), videoName);
    if isMirror
        fprintf('  [MIRROR of %s]', parentBase);
    end
    fprintf('\n');
    fprintf('  Progress: %.1f%%  |  ETA: %s\n', ((v-1)/length(processOrder))*100, etaStr);
    fprintf('----------------------------------------------------------\n');
    fprintf(fid, 'Video %d/%d: %s (mirror=%d)\n', v, length(processOrder), videoName, isMirror);

    % --- Get coordinates for this video ----------------------------------
    safeParent = matlab.lang.makeValidName(parentBase);
    if ~isfield(coords, safeParent)
        fprintf('  *** No coordinates found for parent: %s. Skipping.\n', parentBase);
        fprintf(fid, '  SKIPPED — no coordinates\n\n');
        failCount = failCount + 1;
        continue;
    end

    c = coords.(safeParent);  % struct with .head1x, .head1y, .head2x, .head2y

    try
        vidReader   = VideoReader(srcPath);
        frameRate   = vidReader.FrameRate;
        frameWidth  = vidReader.Width;
        frameHeight = vidReader.Height;

        % If this is a mirror, flip the X coordinates
        if isMirror
            h1x = frameWidth - c.head1x;
            h1y = c.head1y;
            h2x = frameWidth - c.head2x;
            h2y = c.head2y;
        else
            h1x = c.head1x;
            h1y = c.head1y;
            h2x = c.head2x;
            h2y = c.head2y;
        end

        vidWriter = VideoWriter(dstPath, 'MPEG-4');
        vidWriter.FrameRate = frameRate;
        vidWriter.Quality   = 95;
        open(vidWriter);

        % --- Per-video state ---------------------------------------------
        frameCount = 0;

        % Smoothed positions (initialised from clicks)
        sm1x = h1x;  sm1y = h1y;
        sm2x = h2x;  sm2y = h2y;

        while hasFrame(vidReader)
            frame = readFrame(vidReader);
            frameCount = frameCount + 1;

            % --- Optional RetinaFace refinement for human face -----------
            if USE_RETINAFACE_REFINEMENT && ~isempty(detector)
                [bboxes, scores, ~] = detect(detector, frame);
                if istable(bboxes), bboxes = table2array(bboxes); end
                bboxes = double(bboxes);

                % Filter by confidence
                if ~isempty(bboxes) && ~isempty(scores)
                    keep = scores >= CONFIDENCE_THRESHOLD;
                    bboxes = bboxes(keep, :);
                    scores = scores(keep);
                end

                % Filter by upper frame region
                if ~isempty(bboxes)
                    cy = bboxes(:,2) + bboxes(:,4)/2;
                    keep = cy < frameHeight * 0.60;
                    bboxes = bboxes(keep, :);
                    if ~isempty(scores), scores = scores(keep); end
                end

                if ~isempty(bboxes)
                    % Find which detection is closest to head1 or head2
                    for d = 1:size(bboxes, 1)
                        detCX = bboxes(d,1) + bboxes(d,3)/2;
                        detCY = bboxes(d,2) + bboxes(d,4)/2;

                        dist1 = sqrt((detCX - sm1x)^2 + (detCY - sm1y)^2);
                        dist2 = sqrt((detCX - sm2x)^2 + (detCY - sm2y)^2);

                        % Only refine if detection is reasonably close
                        % to one of the clicked positions. We use 1.5x the
                        % ellipse size as the maximum distance — generous
                        % enough to follow head shakes and nods, but tight
                        % enough to reject false positives on the body.
                        maxDist = max(ellipseW, ellipseH) * 1.5;

                        if dist1 < dist2 && dist1 < maxDist
                            % Refine head 1
                            sm1x = TEMPORAL_ALPHA * detCX + (1-TEMPORAL_ALPHA) * sm1x;
                            sm1y = TEMPORAL_ALPHA * detCY + (1-TEMPORAL_ALPHA) * sm1y;
                        elseif dist2 < dist1 && dist2 < maxDist
                            % Refine head 2
                            sm2x = TEMPORAL_ALPHA * detCX + (1-TEMPORAL_ALPHA) * sm2x;
                            sm2y = TEMPORAL_ALPHA * detCY + (1-TEMPORAL_ALPHA) * sm2y;
                        end
                        % If detection is far from both, ignore it
                        % (false positive on body/background)
                    end
                end
                % If no detections: sm1/sm2 simply carry forward (no dropout)
            end

            % --- Build fixed-size bounding boxes -------------------------
            box1 = [round(sm1x - ellipseW/2), round(sm1y - ellipseH/2), ellipseW, ellipseH];
            box2 = [round(sm2x - ellipseW/2), round(sm2y - ellipseH/2), ellipseW, ellipseH];

            box1 = clampBox(box1, frameWidth, frameHeight);
            box2 = clampBox(box2, frameWidth, frameHeight);

            % --- Apply blur ----------------------------------------------
            blurredFrame = applyEllipticalBlur(frame, [box1; box2], ...
                                               GAUSSIAN_SIGMA, MASK_FALLOFF);

            writeVideo(vidWriter, blurredFrame);

            if mod(frameCount, round(frameRate)) == 0
                fprintf('    Frame %d...\n', frameCount);
            end
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

%% ------------------------------------------------------------------------
%  STEP 6: SUMMARY
%  ------------------------------------------------------------------------

totalElapsed = toc(totalStart);
fclose(fid);

fprintf('\n==========================================================\n');
fprintf('  COMPLETE: %d OK, %d failed of %d\n', successCount, failCount, length(processOrder));
fprintf('  Time: %s\n', formatDuration(totalElapsed));
fprintf('  Output: %s\n', dstFolder);
fprintf('==========================================================\n');

end  % end main function


%% ========================================================================
%  CLICK INTERFACE
%  ========================================================================

function [coords, ellipseW, ellipseH] = clickAllOriginals(originals, srcFolder)
% CLICKALLORIGINALS  Click on both heads in the first frame of each video.
%
%   Returns a struct 'coords' keyed by video base name, where each entry
%   contains .head1x, .head1y, .head2x, .head2y (centres of each head).
%   Also returns the ellipse size (same for all videos).

    coords = struct();
    ellipseW = 0;
    ellipseH = 0;

    fprintf('\n  You will now click on both heads in each video.\n');
    fprintf('  Total videos to click: %d\n', length(originals));
    fprintf('  (Mirror videos are handled automatically)\n\n');

    for i = 1:length(originals)
        [~, baseName, ~] = fileparts(originals{i});
        videoPath = fullfile(srcFolder, originals{i});

        % Read first usable frame (skip ~0.1s to avoid black frames)
        vid = VideoReader(videoPath);
        vid.CurrentTime = min(0.1, vid.Duration * 0.1);
        frame = readFrame(vid);
        [fH, fW, ~] = size(frame);

        % --- Show frame and collect clicks --------------------------------
        fig = figure('Name', sprintf('Video %d/%d: %s', i, length(originals), originals{i}), ...
                     'Position', [50 50 1200 750], 'NumberTitle', 'off');
        imshow(frame);
        title(sprintf('Video %d/%d: %s\nClick on the CENTRE of HEAD 1 (either agent)', ...
              i, length(originals), strrep(originals{i}, '_', '\_')), ...
              'FontSize', 13);

        % Click 1
        [x1, y1] = ginput(1);
        hold on;
        plot(x1, y1, 'g+', 'MarkerSize', 25, 'LineWidth', 3);

        title(sprintf('Now click on the CENTRE of HEAD 2'), 'FontSize', 13);

        % Click 2
        [x2, y2] = ginput(1);
        plot(x2, y2, 'c+', 'MarkerSize', 25, 'LineWidth', 3);

        % --- Ellipse size (set on first video, reuse for all) ------------
        if i == 1
            defaultEW = round(fH * 0.09);   % slightly tighter default
            defaultEH = round(fH * 0.12);   % covers head without excess

            % Draw initial ellipses
            theta = linspace(0, 2*pi, 100);
            ell1 = plot(x1 + (defaultEW/2)*cos(theta), y1 + (defaultEH/2)*sin(theta), ...
                        'g-', 'LineWidth', 2);
            ell2 = plot(x2 + (defaultEW/2)*cos(theta), y2 + (defaultEH/2)*sin(theta), ...
                        'c-', 'LineWidth', 2);

            title('Adjust ellipse size with slider, then click CONFIRM', 'FontSize', 13);

            % Slider
            sliderPanel = uipanel(fig, 'Position', [0.1 0.01 0.8 0.06]);
            uicontrol(sliderPanel, 'Style', 'text', 'String', 'Blur Size:', ...
                      'Units', 'normalized', 'Position', [0 0.1 0.12 0.8], 'FontSize', 11);
            sizeSlider = uicontrol(sliderPanel, 'Style', 'slider', ...
                      'Min', 0.4, 'Max', 2.5, 'Value', 1.0, ...
                      'Units', 'normalized', 'Position', [0.13 0.1 0.6 0.8]);
            sizeLabel = uicontrol(sliderPanel, 'Style', 'text', ...
                      'String', sprintf('%d x %d px', defaultEW, defaultEH), ...
                      'Units', 'normalized', 'Position', [0.75 0.1 0.23 0.8], 'FontSize', 11);

            % Confirm button
            uicontrol(fig, 'Style', 'pushbutton', 'String', 'CONFIRM', ...
                      'Units', 'normalized', 'Position', [0.38 0.93 0.24 0.05], ...
                      'FontSize', 13, 'FontWeight', 'bold', ...
                      'BackgroundColor', [0.3 0.8 0.3], ...
                      'Callback', @(~,~) uiresume(fig));

            addlistener(sizeSlider, 'ContinuousValueChange', @(src, ~) ...
                updateEllipseSize(src, ell1, ell2, x1, y1, x2, y2, ...
                                  defaultEW, defaultEH, sizeLabel));

            fprintf('  Adjust slider for blur size, then click CONFIRM.\n');
            uiwait(fig);

            if isvalid(fig)
                sf = sizeSlider.Value;
                close(fig);
            else
                sf = 1.0;
            end

            ellipseW = round(defaultEW * sf);
            ellipseH = round(defaultEH * sf);

            fprintf('  Ellipse size set: %d x %d px\n\n', ellipseW, ellipseH);
        else
            % For subsequent videos, show ellipses at the saved size
            % and auto-close after clicks
            theta = linspace(0, 2*pi, 100);
            plot(x1 + (ellipseW/2)*cos(theta), y1 + (ellipseH/2)*sin(theta), ...
                 'g-', 'LineWidth', 2);
            plot(x2 + (ellipseW/2)*cos(theta), y2 + (ellipseH/2)*sin(theta), ...
                 'c-', 'LineWidth', 2);
            title('Positions recorded. Closing in 1 second...', 'FontSize', 13);
            pause(1);
            if isvalid(fig), close(fig); end
        end

        % Store coordinates
        safeName = matlab.lang.makeValidName(baseName);
        coords.(safeName).head1x = x1;
        coords.(safeName).head1y = y1;
        coords.(safeName).head2x = x2;
        coords.(safeName).head2y = y2;

        fprintf('  %s: Head1=[%.0f,%.0f]  Head2=[%.0f,%.0f]\n', ...
                baseName, x1, y1, x2, y2);
    end
end


function updateEllipseSize(slider, ell1, ell2, x1, y1, x2, y2, baseW, baseH, label)
    sf = slider.Value;
    nw = round(baseW * sf);
    nh = round(baseH * sf);
    theta = linspace(0, 2*pi, 100);
    set(ell1, 'XData', x1 + (nw/2)*cos(theta), 'YData', y1 + (nh/2)*sin(theta));
    set(ell2, 'XData', x2 + (nw/2)*cos(theta), 'YData', y2 + (nh/2)*sin(theta));
    set(label, 'String', sprintf('%d x %d px', nw, nh));
end


%% ========================================================================
%  VIDEO ORDERING
%  ========================================================================

function order = buildProcessOrder(originals, mirrors, mirrorSuffix)
% BUILDPROCESSORDER  Build a processing list: each original followed by its mirror.
%
%   This ensures the original is always processed before its mirror,
%   and groups them together in the output log.

    order = struct('filename', {}, 'isMirror', {}, 'parentBase', {});

    for i = 1:length(originals)
        [~, baseName, ~] = fileparts(originals{i});

        % Add the original
        entry.filename   = originals{i};
        entry.isMirror   = false;
        entry.parentBase = baseName;
        order(end+1) = entry; %#ok<AGROW>

        % Check if this original has a mirror
        safeName = matlab.lang.makeValidName(baseName);
        if isfield(mirrors, safeName)
            mEntry.filename   = mirrors.(safeName);
            mEntry.isMirror   = true;
            mEntry.parentBase = baseName;
            order(end+1) = mEntry; %#ok<AGROW>
        end
    end

    % Also add any mirror videos whose parent wasn't found
    % (in case naming convention doesn't perfectly match)
    mirrorNames = fieldnames(mirrors);
    for i = 1:length(mirrorNames)
        alreadyAdded = false;
        for j = 1:length(order)
            if strcmp(order(j).filename, mirrors.(mirrorNames{i}))
                alreadyAdded = true;
                break;
            end
        end
        if ~alreadyAdded
            entry.filename   = mirrors.(mirrorNames{i});
            entry.isMirror   = true;
            entry.parentBase = mirrorNames{i};
            order(end+1) = entry; %#ok<AGROW>
            fprintf('  Warning: mirror "%s" has no matching original.\n', ...
                    mirrors.(mirrorNames{i}));
        end
    end
end


%% ========================================================================
%  BLUR
%  ========================================================================

function out = applyEllipticalBlur(frame, bboxes, sigma, falloff)
    if isempty(bboxes), out = frame; return; end

    ks = 2 * ceil(3 * sigma) + 1;
    blurred = imgaussfilt(frame, sigma, 'FilterSize', ks);

    [h, w, ~] = size(frame);
    mask = zeros(h, w);

    for i = 1:size(bboxes, 1)
        cx = bboxes(i,1) + bboxes(i,3)/2;
        cy = bboxes(i,2) + bboxes(i,4)/2;
        rx = bboxes(i,3) / 2;
        ry = bboxes(i,4) / 2;
        if rx < 1 || ry < 1, continue; end

        pad = round(max(rx, ry) * (1 + falloff)) + 5;
        x1 = max(1, round(cx - rx - pad));
        x2 = min(w, round(cx + rx + pad));
        y1 = max(1, round(cy - ry - pad));
        y2 = min(h, round(cy + ry + pad));

        [XX, YY] = meshgrid(x1:x2, y1:y2);
        eDist = ((XX-cx).^2 / rx^2) + ((YY-cy).^2 / ry^2);

        t = min(max((eDist - 1) / falloff, 0), 1);
        faceMask = 1 - t.*t.*(3 - 2*t);

        mask(y1:y2, x1:x2) = max(mask(y1:y2, x1:x2), faceMask);
    end

    mask = min(max(mask, 0), 1);
    m3 = repmat(mask, [1 1 3]);
    out = uint8(double(blurred) .* m3 + double(frame) .* (1 - m3));
end


%% ========================================================================
%  UTILITIES
%  ========================================================================

function clamped = clampBox(box, imgW, imgH)
    x = max(1, box(1));
    y = max(1, box(2));
    w = min(box(3), imgW - x);
    bh = min(box(4), imgH - y);
    clamped = [x, y, w, bh];
end

function str = formatDuration(seconds)
    h = floor(seconds / 3600);
    m = floor(mod(seconds, 3600) / 60);
    s = floor(mod(seconds, 60));
    if h > 0,     str = sprintf('%dh %02dm %02ds', h, m, s);
    elseif m > 0, str = sprintf('%dm %02ds', m, s);
    else,         str = sprintf('%ds', s);
    end
end
