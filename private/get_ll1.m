function ll = get_ll1(use_projmat,y,x,tau,dat)
% Compute log of likelihood part
% _______________________________________________________________________
%  Copyright (C) 2018 Wellcome Trust Centre for Neuroimaging
  
if use_projmat
    % We use the projection matrices (A, At)
    
    Ay = A(y,dat);
    ll = 0;
    for n=1:dat.N
        msk = isfinite(x{n}) & x{n} ~= 0;
        msk = msk(:);
        ll  = ll - 0.5*tau(n)*sum((double(x{n}(msk)) - double(Ay{n}(msk))).^2);
    end
else
    % We do not use the projection matrices (A, At)
    msk = isfinite(x{1}) & x{1} ~= 0;
    msk = msk(:);
    ll  = -0.5*tau*sum((double(x{1}(msk)) - double(y(msk))).^2);
end   
%==========================================================================