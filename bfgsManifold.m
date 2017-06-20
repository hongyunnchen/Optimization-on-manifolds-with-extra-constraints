function  [x, cost, info, options] = bfgsManifold(problem, x, options)
    
    DEBUG = 0;

    % Verify that the problem description is sufficient for the solver.
    if ~canGetCost(problem)
        warning('manopt:getCost', ...
            'No cost provided. The algorithm will likely abort.');
    end
    if ~canGetGradient(problem) && ~canGetApproxGradient(problem)
        % Note: we do not give a warning if an approximate gradient is
        % explicitly given in the problem description, as in that case the user
        % seems to be aware of the issue.
        warning('manopt:getGradient:approx', ...
            ['No gradient provided. Using an FD approximation instead (slow).\n' ...
            'It may be necessary to increase options.tolgradnorm.\n' ...
            'To disable this warning: warning(''off'', ''manopt:getGradient:approx'')']);
        problem.approxgrad = approxgradientFD(problem);
    end
    
    % Set local defaults here
    localdefaults.minstepsize = 1e-10;
    localdefaults.maxiter = 1000;
    localdefaults.tolgradnorm = 1e-6;
   
    
    % Merge global and local defaults, then merge w/ user options, if any.
    localdefaults = mergeOptions(getGlobalDefaults(), localdefaults);
    if ~exist('options', 'var') || isempty(options)
        options = struct();
    end
    options = mergeOptions(localdefaults, options);
    
    timetic = tic();
    
    % If no initial point x is given by the user, generate one at random.
    if ~exist('x', 'var') || isempty(x)
        xCur = problem.M.rand();
    end
    
    % Create a store database and get a key for the current x
    storedb = StoreDB(options.storedepth);
    key = storedb.getNewKey();
    
    % Compute objective-related quantities for x
    [cost, grad] = getCostGrad(problem, xCur, storedb, key);
    gradnorm = problem.M.norm(xCur, grad);
    
    % Iteration counter.
    % At any point, iter is the number of fully executed iterations so far.
    iter = 0;
    
    % Save stats in a struct array info, and preallocate.
    stats = savestats();
    info(1) = stats;
    info(min(10000, options.maxiter+1)).iter = [];
    
    if options.verbosity >= 2
        fprintf(' iter\t               cost val\t    grad. norm\n');
    end
    

    %TODO: To consolidate the following vars.
    
    %Coefficients for Wolf condition and line search
    c1 = 0.0001;
    c2 = 0.9;
    amax = 1000;

    %Parameter of Hessian update
    memory = 10;
    
    %BFGS
    k = 0;
    sHistory = cell(1,memory); %represents x_k+1 - x_k at T_x_k+1
    yHistory = cell(1,memory); %represents df_k+1 - df_k
    xHistory = cell(1,memory); %represents x's.
    
    M = problem.M;
    
    
    while true
        
        % Display iteration information
        if options.verbosity >= 2
            fprintf('%5d\t%+.16e\t%.8e\n', iter, cost, gradnorm);
        end
        
        % Start timing this iteration
        timetic = tic();
        
        % Run standard stopping criterion checks
        [stop, reason] = stoppingcriterion(problem, xCur, options, ...
            info, iter+1);
        
        % If none triggered, run specific stopping criterion check
        if ~stop && stats.stepsize < options.minstepsize
            stop = true;
            reason = sprintf(['Last stepsize smaller than minimum '  ...
                'allowed; options.minstepsize = %g.'], ...
                options.minstepsize);
        end
        
        if stop
            if options.verbosity >= 1
                fprintf([reason '\n']);
            end
            break;
        end
        
        
        
        %fprintf('\nNorm at start of iteration %d is %f\n', k, M.norm(xCur,getGradient(problem,xCur)));
        %            fprintf('Cost at start of iteration %d is %f\n', k, getCost(problem,xCur));
        
        
        
        %obtain the direction for line search
        if (k>=memory)
            negdir = direction(M, sHistory,yHistory,xHistory,...
                xCur,getGradient(problem,xCur),memory);

        else
            negdir = direction(M, sHistory,yHistory,xHistory,...
                xCur,getGradient(problem,xCur),k);

        end
        
        %DEBUG only
%         if (k>=memory)
%             negdir = directiondummy(M, sHistory,yHistory,xHistory,...
%                 xCur,getGradient(problem,xCur),memory);
%         else
%             negdir = directiondummy(M, sHistory,yHistory,xHistory,...
%                 xCur,getGradient(problem,xCur),k);            
%         end
        
        p = M.mat(xCur, -M.vec(xCur,negdir));
        
        
        %Get the stepsize (Default to 1)
        alpha = linesearch(problem,M,xCur,p,c1,c2,amax);
%         alpha = linesearchv2(problem,M,xCur,p);
        newkey = storedb.getNewKey();
        lsstats = [];

        
        
        %Update
        xNext = M.retr(xCur,p,alpha); %!! CAN WE USE RETR HERE?
        sk = M.transp(xCur,xNext,M.mat(xCur,alpha*M.vec(xCur,p)));
        yk = M.mat(xNext, M.vec(xNext, getGradient(problem,xNext))...
            - M.vec(xNext,M.transp(xCur, xNext, getGradient(problem,xCur))));
        
        %DEBUG only
        if DEBUG == 1
            fprintf('alpha is %f \n', alpha);
            fprintf('Check if p is descent direction: %f\n',...
                M.inner(xCur,p,getGradient(problem,xCur)))
            checkWolfe(problem,M,xCur,p,c1,c2,alpha);
            checkCurvatureCur(problem,M,xCur,alpha,p);
            checkCurvatureNext(M,xNext,sk,yk);
        end
        
        if (k>=memory)
            sHistory = sHistory([2:end 1]); %the most recent vector is on the right
            sHistory{memory} = sk;
            yHistory = yHistory([2:end 1]); %the most recent vector is on the right
            yHistory{memory} = yk;
            xHistory = xHistory([2:end 1]); %the most recent vector is on the right
            xHistory{memory} = xCur;
            k = k+1;
        else
            k = k+1;
            sHistory{k} = sk;
            yHistory{k} = yk;
            xHistory{k} = xCur;
        end
        
        % Compute the new cost-related quantities for x
        [newcost, newgrad] = getCostGrad(problem, xNext, storedb, newkey);
        newgradnorm = problem.M.norm(xNext, newgrad);
        
        % Make sure we don't use too much memory for the store database
        storedb.purge();
        
        % Transfer iterate info        
        xCur = xNext;
        key = newkey;
        cost = newcost;
        grad = newgrad;
        gradnorm = newgradnorm;
        stepsize = M.inner(xCur,p,p)*alpha;
        
        % iter is the number of iterations we have accomplished.
        iter = iter + 1;
        
        % Log statistics for freshly executed iteration
        stats = savestats();
        info(iter+1) = stats; 
        

    end
    
    x = xCur;
    cost = getCost(problem,xCur);
    
    info = info(1:iter+1);

    if options.verbosity >= 1
        fprintf('Total time is %f [s] (excludes statsfun)\n', ...
                info(end).time);
    end
    
    
    % Routine in charge of collecting the current iteration stats
    function stats = savestats()
        stats.iter = iter;
        stats.cost = cost;
        stats.gradnorm = gradnorm;
        if iter == 0
            stats.stepsize = NaN;
            stats.time = toc(timetic);
            stats.linesearch = [];
        else
            stats.stepsize = stepsize;
            stats.time = info(iter).time + toc(timetic);
            stats.linesearch = lsstats;
        end
        stats = applyStatsfun(problem, xCur, storedb, key, options, stats);
    end
end

%Check if <sk,yk> > 0 at the current point
function checkCurvatureCur(problem,M,xCur,alpha,p)
    sk = M.mat(xCur,alpha*M.vec(xCur,p));
    xNext = M.retr(xCur,p,alpha);
    yk = M.vec(xCur,M.transp(xNext,xCur,getGradient(problem,xNext)))-...
        M.vec(xCur,getGradient(problem,xCur));
    yk = M.mat(xCur,yk);
    if (M.inner(xCur,sk,yk) < 0)
        fprintf('<sk,yk> is negative at xCur with val %f\n', M.inner(xCur,sk,yk));
    end
end

%Check if <sk,yk> > 0 at the next point
function checkCurvatureNext(M,xNext,sk,yk)
    if (M.inner(xNext,sk,yk) < 0)
        fprintf('<sk,yk> is negative at xNext with val %f\n', M.inner(xNext,sk,yk));
    end
end

%Check if Wolfe condition is satisfied.
function checkWolfe(problem,M,x,p,c1,c2,alpha)
    correct = 1;
    xnew = M.retr(x,p,alpha);
    if (getCost(problem,xnew)-getCost(problem,x))>...
            c1*alpha*M.inner(x,getGradient(problem,x),p)
        fprintf('Wolfe Cond 1:Armijo is violated\n')
        correct = 0;
    end
    if (abs(M.inner(xnew,M.transp(x,xnew,p),getGradient(problem,xnew))) >...
            -c2*M.inner(x,p,getGradient(problem,x)))
        correct = 0;
        fprintf('Wolfe Cond 2: flat gradient is violated\n')
        fprintf('     newgrad is %f\n',M.inner(xnew,M.transp(x,xnew,p),getGradient(problem,xnew)));
        fprintf('     oldgrad is %f\n',-c2*M.inner(x,p,getGradient(problem,x)));
    end
    if correct == 1
        fprintf('Wolfe is correct\n')
    end
end

%Iteratively it returns the search direction based on memory.
function dir = direction(M, sHistory,yHistory,xHistory,xCur,xgrad,iter)
    if (iter ~= 0)        
        sk = sHistory{iter};
        yk = yHistory{iter};
        xk = xHistory{iter};
        rouk = 1/(M.inner(xCur,sk,yk));
        %DEBUG
%         fprintf('Rouk is %f \n', rouk);
        tempvec = M.vec(xCur,xgrad) - rouk*M.inner(xCur,sk,xgrad)*M.vec(xCur,yk);
        temp = M.mat(xCur,tempvec);
        %transport to the previous point.
        temp = M.transp(xCur,xk,temp);
        temp = direction(M, sHistory,yHistory,xHistory,xk,...
            temp,iter-1);
        %transport the vector back
        temp = M.transp(xk,xCur,temp);
        tempvec = M.vec(xCur,temp) - rouk*M.inner(xCur,yk,temp)*M.vec(xCur,sk);
        tempvec = tempvec + rouk*M.inner(xCur,sk,xgrad)*M.vec(xCur,sk);
        dir = M.mat(xCur, tempvec);
    else
        dir = xgrad;
    end
end

function dir = directiondummy(M, sHistory,yHistory,xHistory,...
                    xCur,xgrad,k)
    dir = xgrad;
end

%This version follows Qi et al, 2010
function alpha = linesearchv2(problem, M, x, p)
    %For bedugging. Shows phi(alpha)
%     n = 1000;
%     steps = linspace(-10,10,n);
%     costs = zeros(1,n);
%     for i = 1:n
%         costs(1,i) = getCost(problem,M.retr(x,p,steps(i)));
%     end
%     figure
%     plot(steps,costs);
%     xlabel('x')

    alpha = 1;
    c = M.inner(x,getGradient(problem,x),p);
    while (getCost(problem,M.retr(x,p,2*alpha))-getCost(problem,x) < alpha*c)
        alpha = 2*alpha;
    end
    while (getCost(problem,M.retr(x,p,alpha))-getCost(problem,x) >= 0.5*alpha*c)
        alpha = 0.5 * alpha;
    end
end


%This part follows Nocedal p59-60 for strong Wolfe conditions.
function alpha = linesearch(problem,M,x,p,c1,c2,amax)
    %For bedugging. Shows phi(alpha)
%     n = 1000;
%     steps = linspace(-10,10,n);
%     costs = zeros(1,n);
%     for i = 1:n
%         costs(1,i) = getCost(problem,M.retr(x,p,steps(i)));
%     end
%     figure
%     plot(steps,costs);
%     xlabel('x')

    aprev = 0;
    acur = 1;
    i = 1;
    gradAtZero = M.inner(x,getGradient(problem,x),p);
    while acur < amax
        xCur = M.retr(x,p,acur);
        if (getCost(problem,xCur)>getCost(problem,x)+c1*acur*gradAtZero)||...
                (problem.cost(xCur)>=getCost(problem,M.retr(x,p,aprev)) && i>1)
            alpha = zoom(problem,M,aprev,acur,x,p,c1,c2);
            return;
        end
        %MAYBE EXP is needed?
        gradAtCur = M.inner(xCur,getGradient(problem,xCur),M.transp(x,xCur,p));
        if (abs(gradAtCur) <= -c2*gradAtZero)
            alpha = acur;
            return;
        end
        if gradAtCur >= 0
            alpha = zoom(problem,M,acur,aprev,x,p,c1,c2);
            return;
        end
        aprev = acur;
        acur = acur * 2;
        i = i+1;
    end
    alpha = amax; %Not sure if this is right.
end

function alpha = zoom(problem,M,alo,ahi,x,p,c1,c2)
    costAtZero = getCost(problem,x);
    gradAtZero = M.inner(x,getGradient(problem,x),p);
    while abs(alo-ahi) > 1e-10
        anew = (alo+ahi)/2;
        costAtAnew = getCost(problem,M.retr(x,p,anew));
        costAtAlo = getCost(problem,M.retr(x,p,alo));
        if (costAtAnew > costAtZero +c1*anew*gradAtZero) || (costAtAnew >= costAtAlo)
            ahi = anew;
        else    
            xNew = M.retr(x,p,anew);
            gradAtAnew = M.inner(xNew,getGradient(problem,xNew),M.transp(x,xNew,p));
            if abs(gradAtAnew) <= -c2*gradAtZero
                alpha = anew;
                return
            end
            if gradAtAnew*(ahi-alo) >= 0 
                ahi = alo;
            end
            alo = anew;
        end
    end
    alpha = (alo+ahi)/2;
end
