classdef NN < handle
    properties(Constant)
        %SAVE_FIELD = {'gpu', 'real', 'blobs'};

        FLAG  = 0;
        FLAG_TRAIN = NN.FLAG + 1;
        FLAG_TEST  = NN.FLAG + 2;
    end

    properties
        gpu;
        real = 'double';

        blobs;
        index;
        input;
        output;
        link;

        batchSize;
        weight;
        gradient;
        error;
    end

    methods
        function nn = NN(arg)
            if(isa(arg, 'char'))
                file = arg;
                % TODO
            elseif(isa(arg, 'Blob'))
                blobs = arg;

                nn.gpu = (gpuDeviceCount > 0);
                if(nn.gpu)
                    real = 'double';
                end
                nn.blobs = blobs;

                blobNum = length(blobs);
                nn.input = sparse(blobNum, 1);
                nn.output = sparse(blobNum, 1);
                nn.link = sparse(blobNum, blobNum);
                nn.weight = cell(blobNum);
                nn.gradient = cell(blobNum);
            end
        end

        function nn = setIndex(nn, index)
            if(index > length(nn.blobs))
                error('Index exceeds blob number!');
            end
            nn.index = index;
        end

        function nn = setInput(nn)
            nn.input(nn.index) = true;
        end

        function nn = setOutput(nn)
            nn.output(nn.index) = true;
        end
        
        function nn = setNext(nn, index)
            nn.link(nn.index, index) = true;
            nn.setIndex(index);
        end

        function setDefaultLink(nn)
            nn.input(1) = true;
            nn.output(end) = true;
            for i = 1:(length(nn.blobs) - 1)
                nn.link(i, i + 1) = true;
            end
        end

        function initialize(nn, opt)
            [from, to] = find(nn.link);
            for i = 1:length(from)
                f = from(i);
                t = to(i);

                dimFrom = nn.blobs(f).dimension;
                dimTo = nn.blobs(t).dimension;

                nn.weight{f, t} = ...
                    [NN.zeros(dimTo, 1, nn.gpu, nn.real), ...
                     (NN.rand(dimTo, dimFrom, nn.gpu, nn.real) - 0.5) * 2 / sqrt(dimFrom)];
                nn.gradient{f, t} = NN.zeros(dimTo, dimFrom + 1, nn.gpu, nn.real);
            end
        end

        function train(nn, in, out, opt)
            opt.flag = NN.FLAG_TRAIN;

            if(opt.train == Opt.TRAIN_HANDLE)
                batchNum = 1;
                nn.batchSize = opt.batchSize;
            else
                if(opt.train == Opt.TRAIN_COMPACT)
                    out = cellfun(@(x) bsxfun(@eq, unique(x)', x), out, 'UniformOutput', false);
                end
     
                in = NN.cast(in, nn.real);
                out = NN.cast(out, nn.real);
            
                batchNum = ceil(opt.sampleNum / opt.batchSize);
            end
     
            for e = 1:opt.epochNum
                tic;
                if(opt.train ~= Opt.TRAIN_HANDLE)
                    permutation = randperm(opt.sampleNum);
                end
                for b = 1:batchNum
                    if(opt.train == Opt.TRAIN_HANDLE)
                        inBatch = in(opt);
                        outBatch = out(opt);
                    else
                        sel = permutation((b - 1) * opt.batchSize + 1:min(b * opt.batchSize, opt.sampleNum));
                        nn.batchSize = length(sel); 
                        inBatch = NN.slice(in, sel);
                        outBatch = NN.slice(out, sel);
                    end
     
                    nn.clean(opt);
                    nn.forward(inBatch, opt);
                    nn.backward(outBatch, opt);
                    nn.update(opt);
                end
                time = toc;
                fprintf('[DNN Training] Epoch = %d, Time = %.3f s, MSE = %.3f\n', e, time, nn.error);
            end
        end

        function clean(nn, opt)
            for i = 1:length(nn.blobs)
                blob = nn.blobs(i);
                blob.value = NN.zeros(blob.dimension, nn.batchSize, nn.gpu, nn.real);
                blob.error = NN.zeros(blob.dimension, nn.batchSize, nn.gpu, nn.real);
                blob.extra = NN.zeros(blob.dimension, nn.batchSize, nn.gpu, nn.real);
            end
        end

        function forward(nn, inBatch, opt)
            in = find(nn.input);
            for i = 1:length(in)
                nn.blobs(in(i)).value = inBatch{i};
            end

            [from, to] = find(nn.link);
            for i = 1:length(from)
                f = from(i);
                t = to(i);
                blobFrom = nn.blobs(f);
                blobTo = nn.blobs(t);
                
                if(bitand(blobTo.type, Blob.LU))
                    blobTo.value = blobTo.value + nn.weight{f, t} * NN.pad(blobFrom.value, nn.batchSize, nn.gpu, nn.real);
                end

                if(bitand(blobTo.type, Blob.OP_RELU))
                    blobTo.value = blobTo.value .* (blobTo.value > 0);
                end

                if(bitand(blobTo.type, Blob.OP_FAST_SIGMOID))
                    blobTo.value = blobTo.value ./ (1 + abs(blobTo.value));
                end
                
                if(bitand(blobTo.type, Blob.DROPOUT))
                    if(opt.flag == NN.FLAG_TRAIN)
                        if(isempty(blobTo.extra))
                            blobTo.extra = (NN.rand(blobTo.dimension, nn.batchSize, nn.gpu, nn.real) > opt.dropout);
                        end
                        blobTo.value = blobTo.value .* blobTo.extra;
                    elseif(opt.flag == NN.FLAG_TEST)
                        blobTo.value = blobTo.value * (1 - opt.dropout);
                    end
                end

                if(bitand(blobTo.type, Blob.LOSS_SQUARED))
                    %
                end

                if(bitand(blobTo.type, Blob.LOSS_SOFTMAX))
                    blobTo.value = exp(bsxfun(@minus, blobTo.value, max(blobTo.value)));
                    blobTo.value = bsxfun(@rdivide, blobTo.value, sum(blobTo.value));
                end
            end
        end

        function backward(nn, outBatch, opt)
            out = find(nn.output);
            nn.error = 0;
            for i = 1:length(out)
                nn.blobs(out(i)).error = nn.blobs(out(i)).value - outBatch{i};
                nn.error = nn.error + sum(sum(nn.blobs(out(i)).error .* nn.blobs(out(i)).error)) / nn.batchSize;
            end

            [from, to] = find(nn.link);
            for i = length(from):-1:1
                f = from(i);
                t = to(i);
                blobFrom = nn.blobs(f);
                blobTo = nn.blobs(t);

                if(bitand(blobTo.type, Blob.LOSS_SQUARED))
                    %
                end

                if(bitand(blobTo.type, Blob.LOSS_SOFTMAX))
                    %
                end

                if(bitand(blobTo.type, Blob.OP_RELU))
                    blobTo.error = blobTo.error .* (blobTo.value > 0);
                end

                if(bitand(blobTo.type, Blob.OP_FAST_SIGMOID))
                    temp = 1 - abs(blobTo.value);
                    blobTo.error = blobTo.error .* temp .* temp;
                end
                
                if(bitand(blobTo.type, Blob.DROPOUT))
                    blobTo.error = blobTo.error .* blobTo.extra;
                end

                if(bitand(blobTo.type, Blob.LU))
                    blobFrom.error = blobFrom.error + nn.weight{f, t}(:, 2:end)' * blobTo.error;
                end
            end
        end

        function update(nn, opt)
            [from, to] = find(nn.link);
            for i = 1:length(from)
                f = from(i);
                t = to(i);
                blobFrom = nn.blobs(f);
                blobTo = nn.blobs(t);

                gradient = (opt.learn / nn.batchSize) * blobTo.error * (NN.pad(blobFrom.value, nn.batchSize, nn.gpu, nn.real))';
                if(opt.lambda)
                    gradient = gradient + opt.lambda * nn.weight{f, t};
                end
                if(opt.momentum)
                    gradient = gradient + opt.momentum * nn.gradient{f, t};
                    nn.gradient{f, t} = gradient;
                end
                nn.weight{f, t} = nn.weight{f, t} - gradient;
            end
        end

        function predicted = test(nn, in, opt)
            opt.flag = NN.FLAG_TEST;
            batchNum = ceil(opt.sampleNum / opt.batchSize);

            out = find(nn.output);
            predicted = cell(1, length(out));

            tic;
            for b = 1:batchNum
                sel = (b - 1) * opt.batchSize + 1:min(b * opt.batchSize, opt.sampleNum);
                nn.batchSize = length(sel);

                inBatch = NN.slice(in, sel);
                
                nn.clean(opt);
                nn.forward(inBatch, opt);

                outBatch = {nn.blobs(out).value};
                if(opt.test == Opt.TEST_MAX)
                    outBatch = cellfun(@NN.maxIndex, outBatch, 'UniformOutput', false);
                end
                predicted = cellfun(@(x, y) [x, gather(y)], predicted, outBatch, 'UniformOutput', false);
            end
            time = toc;
            fprintf('[DNN Testing] Time = %.3f s\n', time);
        end
    end
    
    methods(Static)
        function out = zeros(x, y, gpu, real)
            if(gpu)
                out = gpuArray.zeros(x, y, real);
            else
                out = zeros(x, y, real);
            end
        end

        function out = ones(x, y, gpu, real)
            if(gpu)
                out = gpuArray.ones(x, y, real);
            else
                out = ones(x, y, real);
            end
        end

        function out = rand(x, y, gpu, real)
            if(gpu)
                out = gpuArray.rand(x, y, real);
            else
                out = rand(x, y, real);
            end
        end
        
        function in = cast(in, real)
            in = cellfun(@(x) cast(x, real), in, 'UniformOutput', false);
        end

        function out = maxIndex(in)
            [~, out] = max(in);
        end

        function out = slice(in, sel)
            out = cellfun(@(x) x(:, sel), in, 'UniformOutput', false);
        end

        function out = pad(in, size, gpu, real)
            out = [NN.ones(1, size, gpu, real); in];
        end
    end
end