% Main for the script that implements an attractor based neural firing
% model on a stimulus regime that's supposed to mimic the Mante task.

%% Pre-processing and Basic Definitions
close all;

% Whether to use GPU
useGPU = false;
if useGPU
    reset(gpuDevice(1)); % Resets gpu memory, if anything is in it.
end

% If a "preprocessor" like directive is passed from a calling instance of
% ParameterExplorer, figure mode must not be docked for parllel/ssh workers
% ... Else, the script is being run as a stand-alone, so params struct
% should be cleared in case user changes a value
if ~exist('PE_MODE__','var')
    PE_MODE__ = false;
end
if PE_MODE__
    % Has to be set, because parallel matlab workers hate docked windows
    set(0,'DefaultFigureWindowStyle','normal');
else
    set(0,'DefaultFigureWindowStyle','docked');
    clear params;
end

% Shortcut functions
normalize   = @(x) x ./ mean(x);
zscore      = @(x) (x-mean(x))./std(x);
dsamp       = @(x) downsample(x,10);

%% General Flags

% Whether to reset network after each trial
trialReset = false;
% Turn on additional plotting
figures.on              = true;
figures.save            = true;
figures.showStimuli     = true;
figures.showInputComp   = true;
figures.midprocess      = false;

%% General Paramters
% The lines below this comment provide an optional entry point for my
% ParameterExplorer class.
if ~(exist('params','var') || PE_MODE__)
   params = struct( ...
           ... Model Resolution/Precision
           'dt',    2e-4, ... Model bin size
           'bin_t', 5e-2, ... How to bin post hoc for analysis
           ... Model noise
           'sigma', 0.1,    ...
       ... ---TASK PARAMETERS---
           ... General Trial Controls
           'nTrials',       7200, ...
           'trialDuration', 2,  ... 3, ...
           ... General Stimulus
           'iFrac',         0.15, ...   Randomly select a third of the population for each stimulus to receive
           ... How Opposing Stim Handled (how to compute cells stim fed to)
           'oppSimple',     false, ...
           ... Context Stimulus
           'context_trialStart',    0.1, ...
           'context_trialEnd',      1.4, ...
           ... Color Motion Stimulus
           'color_trialStart',      0.6, ... 0.35, ...
           'color_trialEnd',        1.6,    ... 1.1, ...
           ... Dot Color Stimulus
           'dot_trialStart',        0.6, ... 0.35, ...
           'dot_trialEnd',          1.6, ... 1.1, ...
       ... ---NEURAL NETWORK PARAMETERS---
           ... Number of neurons of each type
           'nInh',      5, ...
           'nExc',      100, ...
           ... Neural Properties
           'rMax0E',    100, ...
           'rMax0I',    200, ...
           'p0E',       0.40, ...
           'p0I',       0.1, ...
           ...Time Constants
           'tausE',     0.025, ...
           'tausI',     0.005, ...
           'tauDbar',   0.2, ...
           'tauDvar',   0.01,     ...
           'tauM',      0.010, ...
           ... Input Properties
           'Imax',      6, ... scales input such that max equals this
           'IthE',      17.75, ... current needed for half maximal input
           'IthI',      20, ...
           'IwidthE',   3, ...
           'IwidthI',   5, ...
           ... Connection Properties
           'WEErecurrent_factor',       200, ...
           'WEEasym_factor',            50,  ...
           'WIE_factor',                -320, ...
           'WEI_factor',                320, ...
           'sigmaWEErec',               0 , ...
           'sigmaWEEasym',              0, ...
           'sigmaIE',                   0, ...
           'pEE',                       0.06 ...
       );
   savedir = '~/Data/Miller/LargeTrialSet';
   savedir = ParameterExplorer.savelocation(params, ...
       'projectfolder',savedir);
end

fprintf('SaveLocation: %s\n',savedir);

% Setup neuron counts
neurIdentites=[false(1,params.nExc) true(1,params.nInh)];
nCells = params.nExc + params.nInh;

% Setup random stream for main script (different than random streams that
% are operating to construct stimuli, connections, and neuron properties,
% respectively)
MainStream = RandStream.create('mrg32k3a','NumStreams',1,'seed','shuffle');

% Assign param variables to main space variables that will be directly
% called in the simulation
dt = params.dt;
sigma = params.dt;
nStimConditions = 3;

%% Initialize Parameter-based Simulation Vectors
% ------------------------------------------------------------------------
% NEURAL VECTORS
NP = NeuronProperties(); % Encapsulated code for setting up overall neuron/synaptic vectors
    % First, we set the properties to build the the output properties
    NP.neurIdentities = neurIdentites;
    NP.rMax0E   =params.rMax0E;     NP.rMax0I=params.rMax0I;
    NP.p0E      =params.p0E;        NP.p0I=params.p0I;
    NP.tausE    =params.tausE;      NP.tausI=params.tausI;
    NP.tauDbar  =params.tauDbar;    NP.tauDvar=params.tauDvar;
    NP.tauMbar  =params.tauM;
    NP.IwidthI  =params.IwidthI;    NP.IwidthE = params.IwidthE;
    NP.Ith0E    =params.IthE;        NP.Ith0I = params.IthI;

    % Then, we invoke the generation method to create them
    NP = NP.generateOutputParams;

    % last return the vectors for the simulation
    [tauM,tauD,tauS,p0,sFrac,rMax,Iwidth,Ith] = NP.returnOutputs();
    clear NP;

% ------------------------------------------------------------------------
% CONECTION VECTORS

% Setup W matrix constructor
Connect = ConnectionProperties(); % Creates W vector
    % First, we set the properties to build the W matrix
    Connect.neurIdentities  = neurIdentites;
    Connect.Rec.EE          = params.WEErecurrent_factor;
    Connect.Base.EE         = params.WEEasym_factor;
    Connect.Base.IE         = params.WIE_factor;
    Connect.Base.EI         = params.WEI_factor;
    Connect.Sigma.Rec.EE    = params.sigmaWEErec;
    Connect.Sigma.EE        = params.sigmaWEEasym;
    Connect.Sigma.IE        = params.sigmaIE;
    Connect.P.EE            = params.pEE;

    % then, we invoke the generation method to create W
    Connect = Connect.generateConnections();
    if figures.on, Connect.visualize(savedir); end;

    % last return the vectors for the simulation
    [W] = Connect.returnOutputs(); clear Connect;

% ------------------------------------------------------------------------
% STIMULI VECTORS
    GeneralStim = InputStimulus();
        % The following parameters should be put into the moving parameter
        % set
        GeneralStim.neurIdentities = neurIdentites;
        GeneralStim.dt = params.dt;
        GeneralStim.nTrials = params.nTrials; % number of trials
        GeneralStim.trialDuration = params.trialDuration; % seconds
        GeneralStim.iFrac = 0.3; clear Iapp;
        if params.oppSimple
            GeneralStim.opposites = 'negative';
        else
            GeneralStim.opposites = 'population';
            %GeneralStim.opposingPopInh=0.5;
        end
    % (1) Setup Context Stimulus
    Context = GeneralStim;
        Context.trialStart  = params.context_trialStart;
        Context.trialStop   = params.context_trialEnd;
        Context.nAmps     = 1; % creates positive/negative states by default, unless option toggled
        Context=Context.generateStimuli();
        [Iapp.context, trials.context, trials.raw.context, trials.bin, t] = ...
          Context.returnOutputs();
    % (2) Setup Dot Stimulus
    Motion = GeneralStim;
        Motion.trialStart     = params.dot_trialStart;
        Motion.trialStop      = params.dot_trialEnd;
        Motion.nAmps        = 3;
        Motion=Motion.generateStimuli();
        [Iapp.motion, trials.motion, trials.raw.motion] = Motion.returnOutputs();
    % (3) Setup Color Stimulus
    Color = GeneralStim;
        Color.trialStart    = params.color_trialStart;
        Color.trialStop     = params.color_trialEnd;
        Color.nAmps       = 3;
        Color=Color.generateStimuli();
        [Iapp.color, trials.color, trials.raw.color] = Color.returnOutputs();

    % Clear uneeded variables from workspace
    clear Context Dots Color GeneralStim;

   % Racast Iapp as the superposition of the inputs influence on cells
   Iapp = Iapp.context + Iapp.color + Iapp.motion;
   Iapp = (params.Imax/max(max(Iapp))) * Iapp;

%% Execute Simulation

r = zeros(length(t),nCells);    % Firing rate for each cell at all time points
D = zeros(length(t),nCells);    % Depression variable for each cell at all time points
S = zeros(length(t),nCells);    % Synaptic gating variable for each cell at all time points
% noise for each simulation step
noise = sigma*randn(MainStream,1,length(t))/sqrt(dt);
% trial trackers for post-processing
TrialCollection.r = zeros(params.nTrials,floor(length(t)/params.nTrials),nCells);
TrialCollection.F = zeros(nStimConditions,params.nTrials,nCells);
if useGPU
        r=gpuArray(r);
        D=gpuArray(D);
        S=gpuArray(S);
end
if figures.showInputComp
    Itot = zeros(length(t),nCells);
    Isynap = zeros(length(t),nCells);
    Irand = zeros(length(t),nCells);
end

for tr = 1:params.nTrials

    % Obtain start and stop indices of trial
    startInd   = max(trials.bin(tr,1),2);
    stopInd    = trials.bin(tr,2);

    % Reset, if requested in flag options
    if trialReset
        r(startInd,:) = 0.0;                            % Initializing if resetting to different stimuli
        D(startInd,:) = 1.0;
        S(startInd,:) = 0.0;
    end

    %% Step Through Times
    for i = startInd:stopInd


        I = S(i-1,:)*W+Iapp(i,:) + noise(i);

        % --- Save input subcomponents for plotting
        if figures.showInputComp
            Itot(i,:) = gather(I);
            Isynap(i,:) = gather(S(i-1,:));
        end
        % ---

        rinf = rMax./(1.+exp(-(I-Ith)./Iwidth));        % Firing rate curve gives the steady state r
        r(i,:) = rinf + (r(i-1,:)-rinf).*exp(-dt./tauM);  % Update r from the previous timestep

        Dinf = 1./(1.+p0.*r(i-1,:).*tauD);                  % Steady state value of D for Poisson spiking
        D(i,:) = Dinf + ( D(i-1,:)-Dinf).*...
            exp(-dt*(p0.*r(i-1,:)+1./tauD));  % Update with adjusted time constant

        Sinf = sFrac.*p0.*r(i,:).*D(i,:).*tauS./(1.0+sFrac.*p0.*r(i,:).*D(i,:).*tauS); % Steady state value of synaptic gating vatiable assuming vesicle release at a rate p0*r*D
        S(i,:) = Sinf + ( S(i-1,:)-Sinf) .* ...
            exp(-dt*(sFrac.*p0.*r(i,:).*D(i,:)+1./tauS)); % update S with adjusted tau
    end

    %% Collect post-trial measures
     TrialCollection.r(tr,:,:)    = frProcess(r(trials.bin(tr,1):trials.bin(tr,2),:),...
         size(TrialCollection.r(tr,:,:)));
     TrialCollection.F(:,tr,:) = ... 
         repmat([trials.context(tr), trials.motion(tr), trials.color(tr)]',...
         1,1,nCells);


    %% Mid-process plotting
    if figures.on && figures.midprocess

        f=figure(1);
        figures.nSubplot = 2;

        subplot(figures.nSubplot,1,figures.nSubplot-1);
        imagesc(t,1:nCells-params.nInh,r(:,1:end-params.nInh)'); axis tight;
        colorbar; title('Exc');
        subplot(figures.nSubplot,1,figures.nSubplot);
        imagesc(t,nCells-params.nInh+1:nCells,r(:,end-params.nInh+1:end)'); axis tight;
        colorbar; title('Inh');

        drawnow;

        if figures.save
            filename=sprintf('Activity_BeforeTrial_%d',tr);
            saveThis(f,savedir,filename,'png','TrialRecord');
%             saveThis(f,savedir,filename,'fig','TrialRecord');
        end
    end

end

%% Post-trial plotting

if figures.on
    
    % INPUTS
    if figures.showInputComp
        f=characterizeInputs(Itot,Isynap,Iapp);
        if figures.save
            saveThis(f,savedir,'InputComponents','png');
        end
    end;

    % STIMULI VERSUS FIRING
    f=figure(150);
    figures.nSubplot = 2;

    if figures.showStimuli
        figures.nSubplot=figures.nSubplot+1;
        subplot(figures.nSubplot,1,1); hold on;

        p1=plot(dsamp(t),dsamp(trials.raw.context),'linewidth',2);
        p2=plot(dsamp(t),dsamp(trials.raw.motion),'linewidth',2);
        p3=plot(dsamp(t),dsamp(trials.raw.color),'linewidth',2);

        axis tight;

        plot_digital(dsamp(t),dsamp(trials.raw.context),...
            'color',get(p1,'color'));
        plot_digital(dsamp(t),dsamp(trials.raw.motion),...
            'color',get(p2,'color'));
        plot_digital(dsamp(t),dsamp(trials.raw.color),...
            'color',get(p3,'color'));

        legend([p1 p2 p3],'Context','Dots','Color');

    end

    subplot(figures.nSubplot,1,figures.nSubplot-1);
    imagesc(t,1:nCells-params.nInh,r(:,1:end-params.nInh)'); axis tight;
    colorbar; title('Exc');
    subplot(figures.nSubplot,1,figures.nSubplot);
    imagesc(t,nCells-params.nInh+1:nCells,r(:,end-params.nInh+1:end)'); axis tight;
    colorbar; title('Inh');

    if figures.save
        filename='ActivityLog';
        saveThis(f,savedir,filename,'png');
%         saveThis(f,savedir,filename,'fig');
    end

end

%% Post-simulation analysis
meanrate  = mean(r,1);
stdrate   = std(r,1);

fprintf('\n--------\nMean R:\t');   fprintf('%9.3f ',meanrate);
fprintf('\n--------\nStd R:\t');    fprintf('%9.3f ',stdrate);
fprintf('\n--------\n');

%% Carry Out Population Analysis

% First, we need to obtain the denoising matrices, regression-components,
% and the regression subspace
% populationAnalyses(TrialCollection,dt);

% Now plot projections of population averaged network onto each of the
% components that approximate variance of the network that "best describe"
% that task dimension

%% Can simple mecahnism extract would-be decision from this?

%% Final Save
% Print out key parameters!
fprintf('\n--------\n');
fprintf('Recurrent EE: %3.2f, Asymmetric EE: %3.2f, \nEI: %3.2f, \nIE: %5.2f, II %3.2f', ...
    params.WEErecurrent_factor,params.WEEasym_factor, params.WEI_factor, ...
    params.WIE_factor, 0);
fprintf('\n--------\n');
    
 clearvars -except r trials Iapp TrialCollection params;
save('Record');
