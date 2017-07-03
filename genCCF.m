function [CCF,forestPredictsTest,forestProbsTest,treeOutputTest] = ...
    genCCF(nTrees,XTrain,YTrain,bReg,optionsFor,XTest,bKeepTrees,iFeatureNum,bOrdinal)
%genCCF Generate a canonical correlation forest
%
% CCF = genCCF(nTrees,XTrain,YTrain)
%
% Creates a canonical correlation forest (CCF) comprising of nTrees
% canonical correlation trees (CCT) containing splits based on the a CCA
% analysis between the training data and a binary representation of the
% class labels.
%
% Required Inputs:
%         nTrees = Number of trees to create (default 500)
%         XTrain = Array giving training features.  Each row should be a
%                  seperate data point and each column a seperate feature.
%                  Must be numerical array with missing values marked as
%                  NaN if iFeatureNum is provided, otherwise can be any
%                  format accepted by processInputData function
%         YTrain = Class data.  Three formats are accepted: a binary
%                  represenetation where each row is a seperate data point
%                  and contains only a single non zero term the column of
%                  which indicates the class, a numeric vector with unique
%                  values taken as seperate class labels or a cell array of
%                  strings giving the name.
%
% Advanced usage:
%
% [CCF, forPred, forProbs, treePred, cumForPred] =
%  genCCF(nTrees,XTrain,YTrain,bReg,options,XTest,bKeepTrees,iFeatureNum,bOrdinal)
%
% Options Inputs:
%           bReg = Whether to perform regression instead of classification.
%                  Default = false (i.e. classification).
%        options = Options object created by optionsClassCCF.  If left
%                  blank then a default set of options corresponding to the
%                  method detailed in the paper is used.
%          XTest = Test data to make predictions for.  If the input
%                  features for the test data are known at test time then
%                  using this input with the option bKeepTrees = false can
%                  significantly reduce the memory requirement.
%     bKeepTrees = If false and XTest is given then the individual trees
%                  are not stored in order to save memory.  Default = true
%    iFeatureNum = Vector for grouping of categorical variables as
%                  generated by processInputData function.  If left blank
%                  then the data is processed using processInputData.
%       bOrdinal = If the data is to be processed, this allows
%                  specification of ordinal variables.  For default
%                  behaviour see processInputData.m
%
% Outputs:
%            CCF = Structure with four fields, trees giving a Cell array of
%                  CCTs, options giving the options structure,
%                  inputProcessDetails giving details required to replicate
%                  input feature transform as done during the training and
%                  if bagging has been used (i.e. running CCF-BAG) then an
%                  out of bag error is also provided. Thus if trying to use
%                  the out of bag error for parameter selection, CCF-BAG
%                  must be used, an options structure for which can be
%                  made using optionsClassCCF.defaultOptionsCCFBag.
%                  Forest prediction can be made using predictFromCCF
%                  function or  individual trees using the predictFromCCT
%                  function. Note predictFromCCF applies the
%                  inputProcess so this does not need to be done manually.
%        forPred = Forest predictions for XTest
%       forProbs = Forest probabilities for XTest
%       treePred = Individual tree predictiosn for XTest
%
% Tom Rainforth 09/10/15

mypath = path;
locToolbox = [regexprep(mfilename('fullpath'),'genCCF',''), 'toolbox'];
bInPath = ~isempty(strfind(mypath,locToolbox));

if ~exist('nTrees','var') || isempty(nTrees)
    nTrees = 500;
end

if ~exist('bReg','var') || isempty(bReg)
    bReg = false;
end

if ~exist('bOrdinal','var')
    bOrdinal = [];
elseif ~isempty(bOrdinal)
    bOrdinal = logical(bOrdinal);
end

if ~bInPath
    addpath(locToolbox);
end

if ~exist('optionsFor','var') || isempty(optionsFor)
    if bReg
        optionsFor = optionsClassCCF.defaultOptionsReg;
    else
        optionsFor = optionsClassCCF;
    end
end

    
bNaNtoMean = strcmpi(optionsFor.missingValuesMethod,'mean');

if ~isnumeric(XTrain) || ~exist('iFeatureNum','var') || isempty(iFeatureNum)
    % If XTrain not in numeric form or if a grouping of features is not
    % provided, apply the input data processing.
    if exist('iFeatureNum','var') && ~isempty(iFeatureNum)
        warning('iFeatureNum provided but XTrain not in array format, over-riding');
    end
    if ~exist('XTest','var') || isempty(XTest)
        [XTrain, iFeatureNum, inputProcessDetails] = processInputData(XTrain,bOrdinal,[],bNaNtoMean);
    else
        [XTrain, iFeatureNum, inputProcessDetails, XTest] = processInputData(XTrain,bOrdinal,XTest,bNaNtoMean);
    end
else
    mu_XTrain = nanmean(XTrain,1);
    std_XTrain = nanstd(XTrain,[],1);
    inputProcessDetails = struct('bOrdinal',true(1,size(XTrain,2)),'mu_XTrain',mu_XTrain,'std_XTrain',std_XTrain);
    inputProcessDetails.Cats = cell(0,1);
    XTrain = replicateInputProcess(XTrain,inputProcessDetails);
    if ~isempty(XTest)
        XTest = replicateInputProcess(XTest,inputProcessDetails);
    end
end

if ~exist('bKeepTrees','var') || isempty(bKeepTrees)
    bKeepTrees = true;
end

N = size(XTrain,1);
D = numel(fastUnique(iFeatureNum)); % Note that setting of number of features to subsample is based only
% number of features before expansion of categoricals.


if ~bReg
    
    [YTrain, classes, optionsFor] = classExpansion(YTrain,N,optionsFor);
        
    if numel(classes)==1
        warning('Only 1 class present in training data!');
    end
    
    optionsFor = optionsFor.updateForD(D);
    
    % Stored class names can be used to link the ids given in the CCT to the
    % actual class names
    optionsFor.classNames = classes;
      
else
    
    muY = mean(YTrain);
    stdY = std(YTrain,[],1);
    
    % TODO do something more efficient here
    % For now just set stdY to be 1 instead of zero to prevent NaNs if a
    % dimensions has no variation.
    stdY(stdY==0) = 1;
    
    YTrain = bsxfun(@rdivide,bsxfun(@minus,YTrain,muY),stdY);
    
    optionsFor = optionsFor.updateForD(D);    
    optionsFor.org_muY = muY;
    optionsFor.org_stdY = stdY;
    optionsFor.mseTotal = 1;    
end

projection_fields = {'CCA','PCA','CCAclasswise','Original','Random'};
for npf = 1:numel(projection_fields)
    if ~isfield(optionsFor.projections,projection_fields{npf})
        optionsFor.projections.(projection_fields{npf}) = false;
    end
end
optionsFor.projections = orderfields(optionsFor.projections,projection_fields);

nOut = nargout;

if nOut<2 && ~bKeepTrees
    bKeepTrees = true;
    warning('Selected not to keep trees but only requested a single output of the trees, reseting bKeepTrees to true');
end

if ~exist('XTest','var') || isempty(XTest)
    if nOut>1
        error('To return more than just the trees themselves, must input the test points');
    else
        XTest = NaN(0,size(XTrain,1));
    end
end

forest = cell(1,nTrees);
if nOut>1
    treeOutputTest = NaN(size(XTest,1),nTrees,size(YTrain,2));
end

if optionsFor.bUseParallel == true
    parfor nT = 1:nTrees
        tree = genTree(XTrain,YTrain,bReg,optionsFor,iFeatureNum,N);
        if bKeepTrees
            forest{nT} = tree;
        end
        if nOut>1
            treeOutputTest(:,nT,:) = predictFromCCT(tree,XTest);
        end
    end
else
    for nT = 1:nTrees
        tree = genTree(XTrain,YTrain,bReg,optionsFor,iFeatureNum,N);
        if bKeepTrees
            forest{nT} = tree;
        end
        if nOut>1
            treeOutputTest(:,nT,:) = predictFromCCT(tree,XTest);
        end
    end
end

CCF.Trees = forest;
CCF.bReg = bReg;
CCF.options = optionsFor;
CCF.inputProcessDetails = inputProcessDetails;
CCF.classNames = optionsFor.classNames;

if bReg
    CCF.nOutputs = size(muY,2);
else
    CCF.bSepPred = optionsFor.bSepPred;
    CCF.task_ids = optionsFor.task_ids;
end

if optionsFor.bBagTrees && bKeepTrees
    cumOOb = zeros(size(YTrain,1),size(CCF.Trees{1}.predictsOutOfBag,2));
    nOOb = zeros(size(YTrain,1),1);
    for nTO = 1:numel(CCF.Trees)
        cumOOb(CCF.Trees{nTO}.iOutOfBag,:) = cumOOb(CCF.Trees{nTO}.iOutOfBag,:)+CCF.Trees{nTO}.predictsOutOfBag;
        nOOb(CCF.Trees{nTO}.iOutOfBag) = nOOb(CCF.Trees{nTO}.iOutOfBag)+1;
    end
    oobPreds = bsxfun(@rdivide,cumOOb,nOOb);
    if bReg
        CCF.outOfBagError = nanmean((oobPreds-bsxfun(@plus,bsxfun(@times,YTrain,stdY),muY)).^2,1);
    elseif CCF.bSepPred
        CCF.outOfBagError = (1-nanmean((oobPreds>0.5)==YTrain,1));
    else
        forPreds = NaN(size(XTrain,1),numel(optionsFor.task_ids));
        YTrainCollapsed = NaN(size(XTrain,1),numel(optionsFor.task_ids));
        for nO = 1:(numel(optionsFor.task_ids)-1)
            [~,forPreds(:,nO)] = max(oobPreds(:,optionsFor.task_ids(nO):optionsFor.task_ids(nO+1)-1),[],2);
            [~,YTrainCollapsed(:,nO)] = max(YTrain(:,optionsFor.task_ids(nO):optionsFor.task_ids(nO+1)-1),[],2);
        end
        [~,forPreds(:,end)] = max(oobPreds(:,optionsFor.task_ids(end):end),[],2);
        [~,YTrainCollapsed(:,end)] = max(YTrain(:,optionsFor.task_ids(end):end),[],2);
        CCF.outOfBagError = (1-nanmean(forPreds==YTrainCollapsed,1));
    end
else
    CCF.outOfBagError = 'OOB error only returned if bagging used and trees kept.  Please use CCF-Bag instead via options=optionsClassCCF.defaultOptionsCCFBag';
end

if nOut<2
    return
end

[forestPredictsTest, forestProbsTest] = treeOutputsToForestPredicts(CCF,treeOutputTest);

end

function tree = genTree(XTrain,YTrain,bReg,optionsFor,iFeatureNum,N)
% A sub-function is used so that it can be shared between the for and
% parfor loops

if strcmpi(optionsFor.missingValuesMethod,'random')
    % Randomly set the missing values.  This will be different for each
    % tree
    XTrain = random_missing_vals(XTrain);
end

if optionsFor.bBagTrees
    iTrainThis = datasample(1:N,N);
    iOob = setdiff(1:N,iTrainThis)';
else
    iTrainThis = 1:N;
end

XTrainBag = XTrain(iTrainThis,:);
YTrainBag = YTrain(iTrainThis,:);

if strcmpi(optionsFor.treeRotation,'rotationForest')
    % This allows functionality to use the Rotation Forest algorithm as a
    % meta method for individual CCTs
    prop_classes_eliminate = optionsFor.RotForpClassLeaveOut;
    if bReg
        prop_classes_eliminate = 0;
    end
    [R,muX,XTrainBag] = rotationForestDataProcess(XTrainBag,YTrainBag,optionsFor.RotForM,...
                                optionsFor.RotForpS,prop_classes_eliminate);
elseif strcmpi(optionsFor.treeRotation,'random')
    R = randomRotation(size(XTrain,2));
    muX = mean(XTrain,1);
    XTrainBag = bsxfun(@minus,XTrainBag,muX)*R;
elseif strcmpi(optionsFor.treeRotation,'pca')
    [R,muX,XTrainBag] = pcaLite(XTrainBag,false,false);
end

tree = growCCT(XTrainBag,YTrainBag,bReg,optionsFor,iFeatureNum,0);

if optionsFor.bBagTrees
    tree.iOutOfBag = iOob;
    tree.predictsOutOfBag = predictFromCCT(tree,XTrain(iOob,:));
end

if ~strcmpi(optionsFor.treeRotation,'none')
    tree.rotDetails = struct('R',R,'muX',muX);
end

end
