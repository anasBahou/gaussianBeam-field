function [u,us,xSmp]=MCfieldGaussianBeamDebug(xTar,sigt,albedo,box_min,box_max,apertureVmf_l,apertureVmf_v,signl,signv,varl,varv,dirl,dirv,maxItr,lambda,smpFlg,smpFunc,movmf,sct_type,ampfunc,gpuFunc)
%xl: a 3xNl or 2xNl vector of positions of where beam is focused (do not have to be
%on a gread)
%xv: 3xNv or 2xNv, center of viewing beam
%sign l, sign v : is beam facing upward (1) or downward (-1)
%varl, varv: scalars. beam std in fourier plane
u_nomean = 0;
xRep = 0;
wRep = 0;
movmf.mu3 = complex(0);

% get the dimensions size
if((numel(box_max) ~= 2 && numel(box_max) ~= 3) || ...
        (size(box_max,2) ~= 1) || (any(size(box_max) ~= size(box_min))))
    error('Invalid box size');
end

dim = size(box_min,1);

unmeanl = [0;0;1];

% Nl = size(xl,2);
% Nv = size(xv,2);

%% Prepare for algorithm

% Initiate output parameters
% u = zeros(Nv,Nl,class(xv));
% us =zeros(Nv,Nl,class(xv));
u_size = max(apertureVmf_l.dim,apertureVmf_v.dim);
u_size = u_size(2:end);

u = complex(zeros(u_size,class(apertureVmf_v.mu1)));
us = u;


% Box size
box_w = box_max-box_min;
V=prod(box_w);

% apertureVmf_l = movmfAperture(varl,xl,-1,dirl,2,2);
% apertureVmf_v = movmfAperture(varv,xv,1,dirv,3,2);

% threshold to begin kill particles with low weight
killThr=0.2;

%% Begin the main loop
for itr=1:maxItr
    if(mod(itr,1e3) == 0) 
        disp([num2str(round(1e2 * itr/maxItr)), '%'])
    end
    % Sample the first scatter
    % x: first scattering point
    % px: probability by which first point was sampled. Needed so that
    % importance sampling integration is weighted properly
    switch mod(smpFlg,10)
        case 1
            % uniform distribution
            x=rand(dim,1).*(box_w)+box_min;
            px=1;
        case 2
            % exponential distribution
            [x,px]=expSmpX(box_min,box_max,unmeanl,sigt(2));
        case 3
            [x,px,xMissIter] = smpVmfBeam(apertureVmf_l,smpFunc,box_min,box_max);
            px = px * V; % The reson I multiple with V - same prob as uniform
            xRep = xRep + xMissIter;
        case 4
            [x,px,xMissIter,n] = smpVmfBeamSum(apertureVmf_l,smpFunc,box_min,box_max);
            px = px * V; % The reson I multiple with V - same prob as uniform
            xRep = xRep + xMissIter;
    end
     xSmp = x;
     x = xTar; px = 1;
%     px = max(px,smpFunc(1).pxMin);
    
    dz = cubeDist(x,box_min,box_max,-dirl);
    throughputVmf_l = movmfThroughput(apertureVmf_l,x,-signl,sigt(2),dz);
    conv_vmf_l0 = movmfConv(throughputVmf_l,movmf);
    
    % First scattering direction
    %implement an option to sample w isotropically (add apropriate input flag).
    %otherwise implement an option that samples one of the incoming
    %illumination of interest and sample a direction from that Gaussian. 
    %sampling probability w0p should be
    switch floor(smpFlg/10)
        case 1
            w=randn(dim,1); w=w/norm(w);
            w0p=1/sqrt(2^(dim-1)*pi);
        case 3
            [w,w0p] = vmfFirstDirection(conv_vmf_l0);
        case 4
            [w,w0p] = vmfFirstDirectionSum(conv_vmf_l0);
        case 5
            [w,w0p] = vmfFirstDirectionSum_sameBeam(conv_vmf_l0,n);
    end
    
    % for each lighting direction, the viewing direction gets different
    % direction
    
    randPhase = exp(2*pi*1i*rand);

    dz = cubeDist(x,box_min,box_max,dirv);
    throughputVmf_v = movmfThroughput(apertureVmf_v,x,signv,sigt(2),dz);
    
%     conv_vmf_l0.mu1 = conv_vmf_l0.mu1*0 + conv_vmf_l0.mu1(1);
%     conv_vmf_l0.mu2 = conv_vmf_l0.mu2*0 + conv_vmf_l0.mu2(1);
%     conv_vmf_l0.mu3 = conv_vmf_l0.mu3*0 + conv_vmf_l0.mu3(1);
%     conv_vmf_l0.c = conv_vmf_l0.c*0 + conv_vmf_l0.c(1);
    
%     if(gpuFunc.active)
    if(false)
        us = integrateMultGPU(gpuFunc,us,conv_vmf_l0,throughputVmf_v,randPhase / sqrt(px));
    else
        movmf_mult = movmfMultiple(conv_vmf_l0,throughputVmf_v,false);
        [integrateMult] = movmfIntegrate(movmf_mult);
        us = us + squeeze(integrateMult * randPhase / sqrt(px));
    end
    
    rotatedMovmf_l = movmf;
    rotatedMovmf_l.mu1 = rotatedMovmf_l.mu3 .* w(1);
    rotatedMovmf_l.mu2 = rotatedMovmf_l.mu3 .* w(2);
    rotatedMovmf_l.mu3 = rotatedMovmf_l.mu3 .* w(3);
    
    throughputVmf_l_times_movmf = movmfMultiple(throughputVmf_l,rotatedMovmf_l,true);
    throughputVmf_l_times_movmf.c = throughputVmf_l_times_movmf.c - log(w0p);
    el = movmfIntegrate(throughputVmf_l_times_movmf);
%     el = movmfIntegrate(throughputVmf_l_times_movmf) / w0p;

    % number of scattering events
    pL=0;
    
    % intensity loss due to albedo
    weight=albedo;
    
    % begin paths sampling loop
    while 1

        pL=pL+1;

        % calculate the complex volumetric throughput for the last
        % scattering event in case of multiple scattering
        if (pL>1)
            
            randPhase = exp(2*pi*1i*rand);

            % rotate the scattering function on direction of ow
            rotatedMovmf_v = movmf;
            rotatedMovmf_v.mu1 = rotatedMovmf_v.mu3 .* ow(1);
            rotatedMovmf_v.mu2 = rotatedMovmf_v.mu3 .* ow(2);
            rotatedMovmf_v.mu3 = rotatedMovmf_v.mu3 .* ow(3);
            
            dz = cubeDist(x,box_min,box_max,dirv);
            throughputVmf_v = movmfThroughput(apertureVmf_v,x,signv,sigt(2),dz);
                
            if(gpuFunc.active)
%             if(false)
                rotatedMovmf_v.mu1 = gpuArray(rotatedMovmf_v.mu1);
                rotatedMovmf_v.mu2 = gpuArray(rotatedMovmf_v.mu2);
                rotatedMovmf_v.mu3 = gpuArray(rotatedMovmf_v.mu3);
                rotatedMovmf_v.c = gpuArray(real(rotatedMovmf_v.c));
                u = MSintegrateMultGPU(gpuFunc,u,throughputVmf_v,rotatedMovmf_v,el,gpuArray(randPhase / sqrt(px)));
            else
                throughputVmf_v_times_movmf = movmfMultiple(throughputVmf_v,rotatedMovmf_v,true);
                ev = movmfIntegrate(throughputVmf_v_times_movmf);
                u = u + squeeze(ev .* el / sqrt(px) * randPhase);
            end
            
        end

       
        % advance to the next scattering event
        d=-log(-rand+1)/(sigt(1));
        x = x+d*w;

        % move to the next particle if the next scattering event is outside
        % the box
        if(max(x>box_max) || max(x<box_min))
            break
        end

        % albedo intensity reduction. If the intensity is too low, it is
        % possible that the particle will be killed
        if weight<killThr
            if rand>albedo
                break
            end
        else
            weight=weight*albedo;
        end

        % Sample new scatteing direction
        ow=w;
        w=smpampfunc_general(ow, sct_type,ampfunc);
    end
  
end

%% Normalization
u=u*sqrt(1/maxItr*V*sigt(2));
us=us*sqrt(1/maxItr*V*sigt(2));
um = u;

u = u+us;

end