
function DetectorPeatones()
% Cargamos la camara de nuestro ordenador
cam = webcam('USB2.0 HD UVC WebCam');

% Fichero auxiliar que ayuda a determinar la altura de un peat�n en funci�n de p�xeles.
scaleDataFile   = 'pedScaleTable.mat';
obj = setupSystemObjects(scaleDataFile);

% Cargamos un detector de personas ACF previamente entrenado 
detector = peopleDetectorACF('caltech');

tracks = initializeTracks();
nextId = 1; 

% Par�metros globales que sirven para mejorar el rendimiento del seguimiento. 
option.ROI                  = [40 60 550 230];  % A rectangle [x, y, w, h] that limits the processing area to ground locations.
option.scThresh             = 0.3;              % A threshold to control the tolerance of error in estimating the scale of a detected pedestrian. 
option.gatingThresh         = 0.9;              % A threshold to reject a candidate match between a detection and a track.
option.gatingCost           = 100;              % A large value for the assignment cost matrix that enforces the rejection of a candidate match.
option.costOfNonAssignment  = 10;               % A tuning parameter to control the likelihood of creation of a new track.
option.timeWindowSize       = 16;               % A tuning parameter to specify the number of frames required to stabilize the confidence score of a track.
option.confidenceThresh     = 2;                % A threshold to determine if a track is true positive or false alarm.
option.ageThresh            = 8;                % A threshold to determine the minimum length required for a track being true positive.
option.visThresh            = 0.6;              % A threshold to determine the minimum visibility value for a track being true positive.

while true
    frame   = readFrame(cam);
    [centroids, bboxes, scores] = detectPeople();
    predictNewLocationsOfTracks();
    [assignments, unassignedTracks, unassignedDetections] = detectionToTrackAssignment();
    updateAssignedTracks();    
    updateUnassignedTracks();    
    deleteLostTracks();    
    createNewTracks();    
    displayTrackingResults();

    if ~isOpen(obj.videoPlayer)
        break;
    end
end
    function obj = setupSystemObjects(scaleDataFile)
        obj.videoPlayer = vision.VideoPlayer;                                         
        ld = load(scaleDataFile, 'pedScaleTable');
        obj.pedScaleTable = ld.pedScaleTable;
    end

    function tracks = initializeTracks()
        % Crea un array vac�o que representa cada objeto en movimiento 
        tracks = struct(...
            'id', {}, ...
            'color', {}, ...
            'bboxes', {}, ... % Matriz que representa los cuadros delimitadores
            'scores', {}, ... % Vector para registrar la puntuaci�n de clasificaci�n del detector de personas
            'kalmanFilter', {}, ... % Filtro de Kalman utilizado para trackear. Se trackea el punto central del objeto en la imagen
            'age', {}, ... % N�mero de fotogramas
            'totalVisibleCount', {}, ...  % N�mmero total de fotogramas en los que se consigui� detectar el objeto
            'confidence', {}, ...    % Representa la confianza que tenemos en el frame         
            'predPosition', {}); % Cuadro delimitador predicho para el siguiente frame
    end


    function frame = readFrame(cam)
        frame = snapshot(cam);
        frame = imresize(frame,[240 420]);
    end

    function [centroids, bboxes, scores] = detectPeople()
        % Cambiamos el tama�o de la imagen para aumentar la resoluci�n
        resizeRatio = 1.5;
        frame = imresize(frame, resizeRatio, 'Antialiasing',false);
        
        % Deteccion usando el detector ACF
        [bboxes, scores] = detect(detector, frame, option.ROI, ...
            'WindowStride', 2,...
            'NumScaleLevels', 4, ...
            'SelectStrongest', false);
        
        % Altura estimada del peat�n seg�n la ubicaci�n de sus pies
        height = bboxes(:, 4) / resizeRatio;
        y = (bboxes(:,2)-1) / resizeRatio + 1;        
        yfoot = min(length(obj.pedScaleTable), round(y + height));
        estHeight = obj.pedScaleTable(yfoot); 
        
        
        % Eliminamos detecciones cuyo tama�o no concuerda con el tama�o esperado
        invalid = abs(estHeight-height)>estHeight*option.scThresh;        
        bboxes(invalid, :) = [];
        scores(invalid, :) = [];
        [bboxes, scores] = selectStrongestBbox(bboxes, scores, ...
                            'RatioType', 'Min', 'OverlapThreshold', 0.6);
                        
        % C�lculo de centroides
        if isempty(bboxes)
            centroids = [];
        else
            centroids = [(bboxes(:, 1) + bboxes(:, 3) / 2), ...
                (bboxes(:, 2) + bboxes(:, 4) / 2)];
        end
    end

    function predictNewLocationsOfTracks()
        for i = 1:length(tracks)
            % Ultimo cuadro delimitador 
            bbox = tracks(i).bboxes(end, :);
            
            % Predicci�n del centroide 
            predictedCentroid = predict(tracks(i).kalmanFilter);
            
            % Actualizamos centroide
            tracks(i).predPosition = [predictedCentroid - bbox(3:4)/2, bbox(3:4)];
        end
    end

    function [assignments, unassignedTracks, unassignedDetections] = ...
            detectionToTrackAssignment()
        % El objetivo de esta funci�n es asignar detecciones a los trackers minimizando el coste
        % Primero se calcula la relaci�n entre el cuadro delimitador predicho y el detectado
        predBboxes = reshape([tracks(:).predPosition], 4, [])';
        cost = 1 - bboxOverlapRatio(predBboxes, bboxes);        
        cost(cost > option.gatingThresh) = 1 + option.gatingCost;
        
        % Asignamos detecciones a los trackers 
        [assignments, unassignedTracks, unassignedDetections] = ...
            assignDetectionsToTracks(cost, option.costOfNonAssignment);
    end

    function updateAssignedTracks()
        % Actualiza cada tracker asignado con su detecci�n correspondiente
        numAssignedTracks = size(assignments, 1);
        for i = 1:numAssignedTracks
            trackIdx = assignments(i, 1);
            detectionIdx = assignments(i, 2);
            centroid = centroids(detectionIdx, :);
            bbox = bboxes(detectionIdx, :);
            correct(tracks(trackIdx).kalmanFilter, centroid);
            
            % Actualiza el cuadro delimitador
            T = min(size(tracks(trackIdx).bboxes,1), 4);
            w = mean([tracks(trackIdx).bboxes(end-T+1:end, 3); bbox(3)]);
            h = mean([tracks(trackIdx).bboxes(end-T+1:end, 4); bbox(4)]);
            
            tracks(trackIdx).bboxes(end+1, :) = [centroid - [w, h]/2, w, h];
            tracks(trackIdx).age = tracks(trackIdx).age + 1;
            tracks(trackIdx).scores = [tracks(trackIdx).scores; scores(detectionIdx)];
            tracks(trackIdx).totalVisibleCount = tracks(trackIdx).totalVisibleCount + 1;
            
            % Ajusta la confianza de cada tracker 
            T = min(option.timeWindowSize, length(tracks(trackIdx).scores));
            score = tracks(trackIdx).scores(end-T+1:end);
            tracks(trackIdx).confidence = [max(score), mean(score)];
        end
    end

    function updateUnassignedTracks()
        % Marca cada tracker no asignado como invisible
        for i = 1:length(unassignedTracks)
            idx = unassignedTracks(i);
            tracks(idx).age = tracks(idx).age + 1;
            tracks(idx).bboxes = [tracks(idx).bboxes; tracks(idx).predPosition];
            tracks(idx).scores = [tracks(idx).scores; 0];
            
            T = min(option.timeWindowSize, length(tracks(idx).scores));
            score = tracks(idx).scores(end-T+1:end);
            tracks(idx).confidence = [max(score), mean(score)];
        end
    end

    function deleteLostTracks()
        % Elimina los trackers que han sido invisibles en muchos frames
        if isempty(tracks)
            return;
        end        
        ages = [tracks(:).age]';
        totalVisibleCounts = [tracks(:).totalVisibleCount]';
        visibility = totalVisibleCounts ./ ages;
        
        confidence = reshape([tracks(:).confidence], 2, [])';
        maxConfidence = confidence(:, 1);

        lostInds = (ages <= option.ageThresh & visibility <= option.visThresh) | ...
             (maxConfidence <= option.confidenceThresh);

        tracks = tracks(~lostInds);
    end

    function createNewTracks()
        % Crea nuevos trackers seg�n el n�mero de trackers sin asignar
        unassignedCentroids = centroids(unassignedDetections, :);
        unassignedBboxes = bboxes(unassignedDetections, :);
        unassignedScores = scores(unassignedDetections);
        for i = 1:size(unassignedBboxes, 1)            
            centroid = unassignedCentroids(i,:);
            bbox = unassignedBboxes(i, :);
            score = unassignedScores(i);
            kalmanFilter = configureKalmanFilter('ConstantVelocity', ...
                centroid, [2, 1], [5, 5], 100);
            newTrack = struct(...
                'id', nextId, ...
                'color', 255*rand(1,3), ...
                'bboxes', bbox, ...
                'scores', score, ...
                'kalmanFilter', kalmanFilter, ...
                'age', 1, ...
                'totalVisibleCount', 1, ...
                'confidence', [score, score], ...
                'predPosition', bbox);
            tracks(end + 1) = newTrack; %#ok<AGROW>
            nextId = nextId + 1;
        end
    end
    
    function displayTrackingResults()
        % Dibuja un cuadro delimitador de color para cada tracker.
        % Se muestra tambi�n la puntuaci�n de cada detecci�n
        displayRatio = 4/3;
        frame = imresize(frame, displayRatio);
        if ~isempty(tracks)
            ages = [tracks(:).age]';        
            confidence = reshape([tracks(:).confidence], 2, [])';
            maxConfidence = confidence(:, 1);
            avgConfidence = confidence(:, 2);
            opacity = min(0.5,max(0.1,avgConfidence/3));
            noDispInds = (ages < option.ageThresh & maxConfidence < option.confidenceThresh) | ...
                       (ages < option.ageThresh / 2);
            for i = 1:length(tracks)
                if ~noDispInds(i)
                    bb = tracks(i).bboxes(end, :);
                    bb(:,1:2) = (bb(:,1:2)-1)*displayRatio + 1;
                    bb(:,3:4) = bb(:,3:4) * displayRatio;
                    frame = insertShape(frame, ...
                                            'FilledRectangle', bb, ...
                                            'Color', tracks(i).color, ...
                                            'Opacity', opacity(i));
                    frame = insertObjectAnnotation(frame, ...
                                            'rectangle', bb, ...
                                            num2str(avgConfidence(i)), ...
                                            'Color', tracks(i).color);
                end
            end
        end
        frame = insertShape(frame, 'Rectangle', option.ROI * displayRatio, ...
                                'Color', [255, 0, 0], 'LineWidth', 3);
        obj.videoPlayer(frame);
    end
end
