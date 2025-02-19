function [Nii_out,dat,prg] = spm_mtv_preproc(varargin)
% Multi-channel total variation (MTV) preprocessing of MR and CT data. 
%
% Requires that the SPM software is on the MATLAB path.
% SPM is available from: https://www.fil.ion.ucl.ac.uk/spm/software/spm12/
%
% For super-resolution, remember to compile private/pushpull.c (see 
% private/compile_pushpull)
%
% FORMAT [Nii,dat,prg] = spm_mtv_preproc(...)
%
% KEYWORD
% -------
%
% InputImages          - Cell array of either NIfTI filenames or nifti 
%                        objects. The cell array is of size 1 x C, where 
%                        C are the number of image channels. Each array 
%                        entry contains N_c images of the same channel. 
%                        If empty, uses spm_select ['']
% IterMax              - Maximum number of iteration [30]
% IterImage            - Maximum number of iterations for solving for the
%                        super-resolved image(s) [5]
% ADMMStepSize         - The infamous ADMM step size, set to zero for an 
%                        educated guess [0]
% Tolerance            - Convergence threshold, set to zero to run until 
%                        IterMax [1e-4]
% RegScaleSuperResMRI  - Scaling of regularisation for MRI super-
%                        resolution [5]
% RegScaleDenoisingMRI - Scaling of regularisation for MRI denoising, 
%                        increase this value for stronger denoising [5]
% RegSuperresCT        - Regularisation used for CT denoising [0.05]
% RegDenoisingCT       - Regularisation used for CT super-resolution [0.05]
% WorkersParfor        - Maximum number of parfor workers [Inf]
% OutputDirectory      - Directory for denoised images. If none given,
%                        writes results to same folder as input (prefixed 
%                        either den or sr) ['']
% Method               - Does either denoising ('denoise') or 
%                        super-resolution ('superres') ['denoise']
% Verbose              - Verbosity level: 
%                        *  0  = quiet
%                        * [1] = write   (print objective value and parameter estimates)
%                        *  2  = draw   +(figure w. log likelihood, mixture fits, recons)
%                        *  3  = result +(show observed and reconstructed images 
%                                         in spm_check_registration, when finished)
% VoxelSize            - Voxel size of super-resolved image [1 1 1]
% CoRegister           - For super-resolution, co-register input images [true] 
% ReadWrite            - Keep variables in workspace (requires more RAM,
%                        but faster), or read/write from disk (requires 
%                        less RAM, but slower) [false] 
% ZeroMissingValues    - Set outside field of view voxels to zero at end 
%                        of algorithm [true]
% IterGaussNewtonImage - Number of Gauss-Newton iterations for solving for 
%                        super-resolution [1]
% IterGaussNewtonRigid - Number of Gauss-Newton iterations for solving for
%                        rigid registration [1]
% Reference            - Struct with NIfTI reference images, if given 
%                        computes PSNR and displays it, for each iteration of 
%                        the algoirthm [{}] 
% DecreasingReg        - Regularisation decreases over iterations, based
%                        on the scheduler in spm_shoot_defaults 
%                        [method=superres:true, method=denoise:false]
% SliceProfile         - Slice selection profile, either a scalar (and the 
%                        slice-select direction will be found automatically) 
%                        or along directions x, y, z (same shape as
%                        InputImages):
%                        * 1 = Gaussian  (FWHM   = low-resolution voxel)
%                        * 2 = Rectangle (length = low-resolution voxel)
%                        [In-plane: Gaussian, Through-plane: Gaussian]
% SliceGap             - Gap between slices, either a scalar (and the 
%                        slice-select direction will be found automatically) 
%                        or along directions x, y, z (same shape as
%                        InputImages). A positive value means a gap, a 
%                        negative value means an overlap. [0]
% SliceGapUnit         - Percentage ('%') or milimeters ('mm') ['%']
% EstimateRigid        - Optimise a rigid alignment between observed images
%                        and their corresponding channel's reconstruction
%                        [false]
% ApplyBias            - Estimate bias field using spm_preproc8 and then 
%                        apply this bias field when denoising [false]
% EstimateBias         - Optimise a bias field [false]
% BiasFieldReg         - Bias field regularisation [1e4]
% MeanCorrectRigid     - Mean correct the rigid-body transform parameters 
%                        q [false]
% PaddingBB            - Pad bounding box with extra zeros in each
%                        direction [0]
% IsMPM                - Are we denoising to reconstruct MPMs? In that
%                        case, the bias field should be the same over
%                        echoes [false]
%
% OUTPUT
% ------
% 
% Nii - nifti object containing denoised/super-resolved images
% dat - 
% prg - 
% 
%__________________________________________________________________________
%
% Example: Super-resolve a set of thick-sliced MRIs
%
% % Read simulated, degraded MRIs
% InputImages{1} = nifti('TestData/sv_t1_icbm_normal_1mm_pn0_rf0.nii');                           
% InputImages{2} = nifti('TestData/sv_pd_icbm_normal_1mm_pn0_rf0.nii');
% InputImages{3} = nifti('TestData/sv_t2_icbm_normal_1mm_pn0_rf0.nii');
% 
% % Super-resolve the MRIs
% spm_mtv_preproc('InputImages',InputImages,'Method','superres','Verbose',2);
%
%__________________________________________________________________________
% The general principles are described in the following paper:
%
%     Brudfors M, Balbastre Y, Nachev P, Ashburner J.
%     MRI Super-Resolution Using Multi-channel Total Variation.
%     In Annual Conference on Medical Image Understanding and Analysis
%     2018 Jul 9 (pp. 217-228). Springer, Cham.
%
% OBS: The code uses MATLAB's parfor to parallelise and speed up certain
% processing. The code should be memory efficient, still, running parfor
% can lead to the use of more RAM than what is available. To decrease the
% number of parfor workers, use the WorkersParfor option described below.
%
%__________________________________________________________________________
% Copyright (C) 2018 Wellcome Centre for Human Neuroimaging

% First check that all is okay with SPM
spm_check_path('Longitudinal');

set_boundary_conditions;
    
%--------------------------------------------------------------------------
% Parse input
%--------------------------------------------------------------------------

p              = inputParser;
p.FunctionName = 'spm_mtv_preproc';
p.addParameter('InputImages', {}, @(in) ( isa(in,'nifti') || isempty(in) || ...
                                        ((ischar(in{1}) || isa(in{1},'nifti')) || (ischar(in{1}{1}) || isa(in{1}{1},'nifti'))) ) );
p.addParameter('IterMax', 30, @(in) (isnumeric(in) && in >= 0));
p.addParameter('IterImage', 5, @(in) (isnumeric(in) && in > 0));
p.addParameter('ADMMStepSize', 0, @(in) (isnumeric(in) && in >= 0));
p.addParameter('Tolerance', 1e-4, @(in) (isnumeric(in) && in >= 0));
p.addParameter('RegScaleSuperResMRI', 5, @(in) (isnumeric(in) && in > 0));
p.addParameter('RegScaleDenoisingMRI', 5, @(in) (isnumeric(in) && in > 0));
p.addParameter('RegSuperresCT', 0.05, @(in) (isnumeric(in) && in > 0));
p.addParameter('RegDenoisingCT', 0.05, @(in) (isnumeric(in) && in > 0));
p.addParameter('WorkersParfor', Inf, @(in) (isnumeric(in) && in >= 0));
p.addParameter('OutputDirectory', '', @ischar);
p.addParameter('Method', 'denoise', @(in) (ischar(in) && (strcmpi(in,'denoise') || strcmpi(in,'superres'))));
p.addParameter('Verbose', 1, @(in) (isnumeric(in) && in >= 0 && in <= 3));
p.addParameter('VoxelSize', [1 1 1], @(in) ((isnumeric(in) && (numel(in) == 1 || numel(in) == 3)) && ~any(in <= 0)) || isempty(in));
p.addParameter('CoRegister', true, @islogical);
p.addParameter('ReadWrite', false, @islogical);
p.addParameter('ZeroMissingValues', true, @islogical);
p.addParameter('IterGaussNewtonImage', 1, @(in) (isnumeric(in) && in > 0));
p.addParameter('IterGaussNewtonRigid', 1, @(in) (isnumeric(in) && in > 0));
p.addParameter('Reference', {}, @(in)  (isa(in,'nifti') || isempty(in)));
p.addParameter('DecreasingReg', [], @(in) (islogical(in) || isempty(in)));
p.addParameter('SliceProfile', {}, @(in) (isnumeric(in) || iscell(in)));
p.addParameter('SliceGap', 0, @(in) (isnumeric(in) || iscell(in)));
p.addParameter('SliceGapUnit', '%', @(in) (ischar(in) && (strcmp(in,'%') || strcmp(in,'mm'))));
p.addParameter('EstimateRigid', false, @islogical);
p.addParameter('EstimateBias', false, @islogical);
p.addParameter('ApplyBias', false, @islogical);
p.addParameter('MeanCorrectRigid', true, @islogical);
p.addParameter('PaddingBB', 0, @isnumeric);
p.addParameter('BiasFieldReg', 1e4, @(in) (isnumeric(in) && in > 0));
p.addParameter('IsMPM', false, @islogical);
p.parse(varargin{:});
InputImages   = p.Results.InputImages;
nit           = p.Results.IterMax;
nity          = p.Results.IterImage;
tol           = p.Results.Tolerance;
num_workers   = p.Results.WorkersParfor;
dir_out       = p.Results.OutputDirectory;
method        = p.Results.Method;
speak         = p.Results.Verbose; 
vx_sr         = p.Results.VoxelSize; 
coreg         = p.Results.CoRegister; 
do_readwrite  = p.Results.ReadWrite; 
zeroMissing   = p.Results.ZeroMissingValues; 
Nii_ref       = p.Results.Reference; 
dec_reg       = p.Results.DecreasingReg;
window        = p.Results.SliceProfile;
gap           = p.Results.SliceGap;
gapunit       = p.Results.SliceGapUnit;
EstimateRigid = p.Results.EstimateRigid;
ApplyBias     = p.Results.ApplyBias;
EstimateBias  = p.Results.EstimateBias;
bb_padding    = p.Results.PaddingBB;
rho           = p.Results.ADMMStepSize; 
IsMPM         = p.Results.IsMPM;

%--------------------------------------------------------------------------
% Preliminaries
%--------------------------------------------------------------------------

% Flag saying if we solve using projection matrices (A, At), or not
use_projmat = ~(strcmpi(method,'denoise') && ~EstimateRigid);

% Struct that will hold model variables
Nii = struct;

% Get image data
[Nii,C,is3d,modality] = parse_input_data(Nii,InputImages,use_projmat);

% Some sanity checks
if ~is3d && ApplyBias
    error('ApplyBias only works for 3D data!');
end
if IsMPM
    % Uses A LOT of temporary variables, so write to disk instead of doing
    % in memory
    do_readwrite = true;
end

% Super-resolution voxel-size related
if isempty(vx_sr)
    % Get voxel-size from input images
    vx_sr = get_vx_sr(Nii.x);
elseif numel(vx_sr) == 1
    vx_sr = vx_sr*ones(1,3); 
end

% Manage parfor
num_workers                        = min(min(C,num_workers),4);
if C == 1,             num_workers = 0; end
if num_workers == Inf, num_workers = nbr_parfor_workers; end
if num_workers > 1,    manage_parpool(num_workers);  end

if vx_sr(1) < 0.9
    % read-write aux. variables to not run in to memory issues..
    do_readwrite = true;
end

if speak >= 3
    % So that Verbose = 3 works for superres (because Nii_x are copied, then copies are deleted)
    Nii.x0 = Nii.x; 
end
    
% Make copies input data and update Nii_x        
Nii.x = copy_ims(Nii.x);
         
if strcmpi(method,'superres')
    % For super-resolution, down-sample subject in-plane resolution to
    % size of the in-plane resolution of the template image
    for c=1:C
        N = numel(Nii.x{c});
        for n=1:N
            f           = Nii.x{c}(n).dat.fname;        
            nf          = downsample_inplane(f,vx_sr);
            Nii.x{c}(n) = nifti(nf);
            delete(f);
        end
    end
end

% Some sanity checks
if ~isempty(Nii_ref) && use_projmat
    error('Solving with projection matrices and reference image(s) not yet implemented!');
end

% if speak >= 2
%     % Show MTV prior
%     show_model('rgb',Nii_x);
% end

%--------------------------------------------------------------------------
% Co-register input images (modifies images' orientation matrices)
%--------------------------------------------------------------------------

if coreg && is3d
    Nii.x = coreg_ims(Nii.x);
end

%--------------------------------------------------------------------------
% Initialise super-resolution/denoising
%--------------------------------------------------------------------------

% Set defaults, such as, voxel size, orientation matrix and image dimensions
if use_projmat
    % For super-resolution, calculate orientation matrix and dimensions 
    % from maximum bounding-box
    vx        = vx_sr;    
    [mat,dm]  = max_bb_orient(Nii.x,vx,bb_padding);    
    
    if isempty(dec_reg)
        dec_reg = true; 
    end
else
    mat       = Nii.x{1}(1).mat;
    dm        = Nii.x{1}(1).dat.dim;
    vx        = sqrt(sum(mat(1:3,1:3).^2));
    if ~is3d
        dm(3) = 1;
    end
    
    if isempty(dec_reg)
        dec_reg = false; 
    end        
end

% Initialise dat struct with projection matrices, etc.
dat = init_dat(method,Nii.x,mat,dm,window,gap,gapunit);    
% dat = init_dat_diffeo(Nii.x,mat,dm);

% Allocate auxiliary variables
Nii = alloc_aux_vars(Nii,do_readwrite,dm,mat,use_projmat,p);

if ApplyBias && speak >= 2
    % Show bias-field(s) generated by spm_preproc8
    show_model('bf',dat,Nii,modality);   
end

if use_projmat
    % Compute approximation to the diagonal of the Hessian 
    Nii.H = approx_hessian(Nii.H,Nii.x,dat);
end

%--------------------------------------------------------------------------
% Estimate model hyper-parameters
%--------------------------------------------------------------------------

% d  = '/home/mbrud/dev/mbrud/projects/MTV-preproc/Data/parashkev-reg';
% f  = {fullfile(d,'cr_1282601181791321211130022749_Flair.nii'), ...
%       fullfile(d,'cr_1282601181791321211130022749_T1.nii'), ...
%       fullfile(d,'cr_1282601181791321211130022749_T2.nii')};
% fprintf('OBS: using fixed parameter estimates!!\n')
% ox       = Nii.x;
% Nii.x{1} = nifti(f{1});
% Nii.x{2} = nifti(f{2});
% Nii.x{3} = nifti(f{3});

[tau,lam0,sched] = estimate_model_hyperpars(Nii.x,dec_reg,vx,modality,p);

% Nii.x = ox;

%--------------------------------------------------------------------------
% Start solving
%--------------------------------------------------------------------------

if speak >= 1
    if tol == 0
        fprintf('Start %s, running %d iterations\n', method, nit);
    else
        fprintf('Start %s, running (max) %d iterations\n', method, nit);
    end
    
    tstart = tic;
end

if ~isempty(Nii_ref)
    % Reference image(s) given, compute SSIM and PSNR

    % Observed and reference
    [psnr1,ssim1] = compute_image_metrics(Nii.x,Nii_ref);
    fprintf('   | ll1=%10.1f, ll2=%10.1f, ll=%10.1f, gain=%0.6f | psnr=%2.3f, ssim=%1.3f\n', 0, 0, 0, 0, psnr1, ssim1); 

    % Initial solution and reference
    [psnr1,ssim1] = compute_image_metrics(Nii.y,Nii_ref);
    fprintf('%2d | ll=%10.1f, ll1=%10.1f, ll2=%10.1f, gain=%0.6f | psnr=%2.3f, ssim=%1.3f\n', 0, 0, 0, 0, psnr1, ssim1); 
end

% Init coarse-to-fine schedueler
lam = sched.scl(1,:).*lam0;
if rho == 0
    rho = estimate_rho(tau,lam); 
end

ll     = -Inf;
llpart = 1;
ll3    = zeros(1,C);
for it=1:nit % Start main loop
            
    %----------------------------------------------------------------------
    % ADMM to update image
    %----------------------------------------------------------------------    
    
    for ity=1:nity % Start y loop
        
        % Update Nii_y, Nii_w, Nii_u
        [Nii,ll1,ll2,mtv_scale] = update_image(Nii,dat,tau,rho,lam,num_workers,modality,p);

        % Compute log-posterior (objective value)        
        ll     = [ll, sum(ll1) + ll2 + sum(ll3)];
        llpart = [llpart 1];
        gain   = get_gain(ll);

        if speak >= 1 || ~isempty(Nii_ref)
            % Some verbose    

            if ~isempty(Nii_ref)
                % Reference image(s) given, compute SSIM and PSNR
                [psnr1,ssim1] = compute_image_metrics(Nii.y,Nii_ref);
                
                fprintf('%2d %2d (y) | ll=%10.1f, ll1=%10.1f, ll2=%10.1f, ll3=%10.1f, gain=%0.6f | psnr=%2.3f, ssim=%1.3f\n', it, ity, ll(end), sum(ll1), ll2, sum(ll3), gain, psnr1, ssim1); 
            else
                fprintf('%2d %2d (y) | ll=%10.1f, ll1=%10.1f, ll2=%10.1f, ll3=%10.1f, gain=%0.6f\n', it, ity, ll(end), sum(ll1), ll2, sum(ll3), gain); 
            end

            if speak >= 2
                show_model('ll',ll,llpart);                
            end
        end   
        
        if tol > 0 && gain < tol
            % Converged
            break
        end
        
    end % End y loop    
   
    if speak >= 2 
        show_model('solution',use_projmat,modality,Nii,dat); 
        show_model('mtv',mtv_scale); clear mtv_scale
%         show_model('rgb',Nii.y);

        if ApplyBias
            show_model('bf',dat,Nii,modality);   
        end
    end
    
    if EstimateBias && ~use_projmat
        
        %------------------------------------------------------------------
        % Gauss-Newton to update bias field parameters
        %------------------------------------------------------------------
        
%         oNii = Nii;
%         Nii  = oNii;
        for i=1:1
            [Nii,ll1,ll3] = update_biasfield(Nii,dat,tau,num_workers,modality,p);

            % Compute log-posterior (objective value)             
            ll     = [ll, sum(ll1) + ll2 + sum(ll3)];
            llpart = [llpart 2];
            gain   = get_gain(ll);

            if speak >= 1
                fprintf('%2d (b) | ll=%10.1f, ll1=%10.1f, ll2=%10.1f, ll3=%10.1f, gain=%0.6f\n', it, ll(end), sum(ll1), ll2, sum(ll3), gain); 
                if speak >= 2
                    show_model('ll',ll,llpart);                
                end
            end
        end
    end
    
    if EstimateRigid
        
        %------------------------------------------------------------------
        % Gauss-Newton to update rigid alignment
        %------------------------------------------------------------------
                        
        % Update q
        [dat,ll1] = update_rigid(Nii,dat,tau,num_workers,p);                            
        
        % Compute log-posterior (objective value)             
        ll     = [ll, sum(ll1) + ll2 + sum(ll3)];
        llpart = [llpart 3];
        gain_q = get_gain(ll);
        
        if speak >= 1
            fprintf('%2d (q) | ll=%10.1f, ll1=%10.1f, ll2=%10.1f, ll3=%10.1f, gain=%0.6f\n', it, ll(end), sum(ll1), ll2, sum(ll3), gain_q); 
            if speak >= 2
                show_model('ll',ll,llpart);                
            end
        end
        
        % Update approximation to the diagonal of the Hessian 
        Nii.H = approx_hessian(Nii.H,Nii.x,dat);
    end
 
    %----------------------------------------------------------------------
    % Convergence checks
    %----------------------------------------------------------------------
        
    % Check convergence
    if tol > 0 && gain < tol && it > 1 && sched.scl(sched.it,1) == 1
        % Finished!
        break
    end

    % Stuff related to coarse-to-fine schedueler        
    if  sched.scl(sched.it,1) ~= 1 && sched.cnt >= sched.nxt(min(sched.it,numel(sched.nxt)))
        sched.it  = sched.it + 1;        
        lam       = sched.scl(min(sched.it,size(sched.scl,1)),:).*lam0;      
        rho       = estimate_rho(tau,lam); 
        sched.cnt = 0;
    end    
    sched.cnt = sched.cnt + 1;
    
end % End main loop

if speak >= 1
    telapsed = toc(tstart); 
    fprintf('Elapsed time is %g seconds.\n',telapsed);
else
    telapsed = NaN;
end

%--------------------------------------------------------------------------
% Write results
%--------------------------------------------------------------------------

if     strcmpi(method,'superres'), prefix = 'sr';
elseif strcmpi(method,'denoise'),  prefix = 'den';
end
   
Nii_out = nifti;
for c=1:C
    % Set output filename
    [pth,nam,ext] = fileparts(Nii.x{c}(1).dat.fname);
    if isempty(dir_out)
        % Write to same folder as input
        nfname = fullfile(pth,    [prefix nam ext]);
    else
        % Write to user specified folder
        nfname = fullfile(dir_out,[prefix nam ext]);
    end
    
    % Get output image data
    y = get_nii(Nii.y(c));  
    
    if strcmpi(modality,'MRI')
        % Ensure non-negativity (ad-hoc)
        y(y < 0) = 0;
    end  

    if strcmpi(modality,'CT')
        % Masks part of CT data (for correspond with masking that happens in
        % the segmentation toolbox)
        img     = single(Nii.x{c}(1).dat(:,:,:));
        msk     = isfinite(img) & (img~=0) & (img>-1020) & (img<3000);        
        y(~msk) = 0;
        clear msk img
    end
    
    if zeroMissing
        % Zeros areas of non-matching FOVs that has been filled in by the
        % algorithm.
        y = clean_fov(y,dat(c));
    end
    
    omat = mat;        
    if ~is3d
        % 2d, set z-translation to zero
        omat(3,4) = Nii.x{c}(1).mat(3,4);
    end
    
    % Write to NIfTI
    Nii_out(c) = create_nii(nfname,y,omat,[spm_type('float32') spm_platform('bigend')],'MTV recovered');
    
    % Delete temporary files
    for n=1:numel(Nii.x{c})
        delete(Nii.x{c}(n).dat.fname);
    end
    if do_readwrite
        delete(Nii.y(c).dat.fname);
        delete(Nii.u(c).dat.fname);
        delete(Nii.w(c).dat.fname);
        if use_projmat
            delete(Nii.H(c).dat.fname);
        end
        if ApplyBias || EstimateBias
            for n=1:numel(Nii.b{c})
                delete(Nii.b{c}(n).dat.fname);
            end
        end        
    end
end

% Output algorithm convergece, etc.
prg    = struct;
prg.ll = ll;
prg.it = it;
prg.t  = telapsed;

%--------------------------------------------------------------------------
% Show input and solved
%--------------------------------------------------------------------------

if speak >= 4          
    C      = numel(Nii_out);
    fnames = cell(1,2*C);
    cnt    = 1;
    for c=1:2:2*C    
        fnames{c}     = Nii.x0{cnt}(1).dat.fname;    
        fnames{c + 1} = Nii_out(cnt).dat.fname;
        cnt           = cnt + 1;
    end

    spm_check_registration(char(fnames))
end

if speak >= 5 && ~use_projmat
    % Have a look close-up
    show_model('closeup',Nii,Nii_out,dm);
end
%==========================================================================