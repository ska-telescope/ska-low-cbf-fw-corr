%% Configure
clear all;
run_optimisation = 0;
write_files = 1;

%%
load("filt_27_1024_18a.txt", '-ascii');
x=filt_27_1024_18a;

disp(['Size = ' num2str(size(x))])
offset=0;  % adjust to get symmetrical impulse response
sps_impulse=x((577+offset):864:end); 
% note DC response of SPS = sum(sps_impulse) = 132761
imp2=sps_impulse/sum(sps_impulse); %subsample 

%% Full calculation of the frequency response
x_full = zeros(864*1024,1);
% center x so that the fft is real
x_full(1:9216) = x(9217:end);
x_full((864*1024 - 9215):(864*1024)) = x(1:9216);

full_freq = real(fft(x_full)/sum(x));
full_freq_433 = full_freq(1:433);

x_full2 = zeros(864*51,1);
x_full2(1:9216) = x(9217:end);
x_full2((51*864 - 9215):(51*864)) = x(1:9216);
full2_freq = real(fft(x_full2)/sum(x));

%%

% Scale the SPS filter to have unity response across the frequency band
%imp2_freq = fft(imp2,1024);
%imp2_scaling = sqrt(sum(imp2_freq(1:433).*conj(imp2_freq(1:433)))/433);
%res = res / scaling;
%impulse=imp2/sum(imp2);
%impulse = imp2 / imp2_scaling;

%impulse= [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 impulse' 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0]';
% fft(impulse,1024) is used below for the TPM frequency response
%impf=fft(impulse);

impf = ones(51,1);
impf(1:23) = full2_freq(1:23);
impf(30:51) = full2_freq(23:-1:2);
impf(24:29) = [0.8614 0.70074 0.5898 0.5898 0.70074 0.8614];  % no need to compensate outside the used region

impf=impf/max(abs(impf));  %frequency response to be compensated

comp2=1./impf;  % compensation in frequency calculation
res=ifft(comp2); % to time domain
res = res/sum(res);
final=round(res*2^16);
final_1024 = zeros(1024,1);
final_1024(1:25) = final(1:25);
final_1024(1001:1024) = final(28:51);
res=final/2^16;

%res=res(3:end);    % trim

%res=res/sum(res);  %scale
% final=round(res*2^16);
% final_1024 = zeros(1024,1);
% final_1024(1:25) = final(25:49);
% final_1024(1001:1024) = final(1:24);
% res=final/2^16;

%% Optimisation
if run_optimisation
    original_18bit = final_1024;
    cur_18bit = original_18bit;
    cur_18bit_freq = fft(cur_18bit/65536);
    combined_response = full_freq_433 .* cur_18bit_freq(1:433);    
    cur_cost = max(abs(db(combined_response(1:433))));
    disp(['Cost = ' num2str(cur_cost)]);
    %keyboard
    iter_max = 1000000;
    fscale = 0;
    amp = 0;
    iters_since_change = iter_max;
    for opt = 1:iter_max
        cur_18bit_test = cur_18bit;
        if iters_since_change < 20
            amp = 0.1 * randn(1);
            cur_18bit_test(1:25) = cur_18bit(1:25) + round(amp * rand_change);
            use_cos = 0;
        elseif rand(1) < 0.8
            amp = rand(1);
            rand_change = randn(25,1);
            cur_18bit_test(1:25) = cur_18bit(1:25) + round(amp * rand_change);
            use_cos = 0;
        elseif rand(1) < 0.3
            rand_change = zeros(25,1);
            rand_change(floor(rand(1)*25) + 1) = 1;
            if rand(1) > 0.5
                cur_18bit_test(1:25) = cur_18bit(1:25) + rand_change;
            else
                cur_18bit_test(1:25) = cur_18bit(1:25) - rand_change;
            end
            use_cos = 0;
        else
            amp = 0.5 * randn(1);
            fscale = randn(1);
            rand_change = cos(((0:24).')*fscale);
            cur_18bit_test(1:25) = round(cur_18bit(1:25) + amp * rand_change);
            use_cos = 1;
        end
        %keyboard
        cur_18bit_test(1001:1024) = cur_18bit_test(25:-1:2);
        %keyboard
        cur_18bit_test_freq = fft(cur_18bit_test/65536);
        combined_response = full_freq_433 .* cur_18bit_test_freq(1:433);
        % combined_response = fft(impulse,1024).*fft((cur_18bit_test)/65536,1024);
        
        new_cost = max(abs(db(combined_response(1:433))));
        if (new_cost < cur_cost)  %  || ((new_cost < (1.05 * cur_cost)) && rand(1) < 0.05)
            cur_cost = new_cost;
            cur_18bit = cur_18bit_test;
            disp(['Cost = ' num2str(cur_cost) ', use cos = ' num2str(use_cos), ' Amp = ' num2str(amp) ', fscale = ' num2str(fscale) ', iters since change = ' num2str(iters_since_change)]);
            iters_since_change = 0;
        else
            iters_since_change = iters_since_change + 1;
        end
    end

    imp2_freq = fft(cur_18bit/65536,1024);
    imp2_scaling = sqrt(sum(imp2_freq(1:433).*conj(imp2_freq(1:433)))/433);
    cur_18bit = round(cur_18bit / imp2_scaling);
else
    % Pre calculated optimised filter
    cur_18bit = zeros(1024,1);
    cur_18bit(1:25) = [68751, -3165, 3040, -2843, 2583, -2288, 1944, -1653, 1209, -1263, 652, -362, 284, -213, 155, -111, 78, -51, 36, -21, 12, -7, 4, -2, 1];
    cur_18bit(1001:1024) = [1, -2, 4, -7, 12, -21, 36, -51, 78, -111, 155, -213, 284, -362, 652, -1263, 1209, -1653, 1944, -2288, 2583, -2843, 3040, -3165];
end

%% Johns filter, don't know exactly how it was generated
% f2 = [7, -10, 13, -18, 24, -33, 43, -58, 94, -123, 168, -223, 289, -365, 451, -593, 1785, -1617, 2000, -2366, 2709, -3003, 3229, -3372, 65535, -3372, 3229, -3003, 2709, -2366, 2000, -1617, 1785, -593, 451, -365, 289, -223, 168, -123, 94, -58, 43, -33, 24, -18, 13, -10, 7];
% f2 = f2 * 65536 / sum(f2);
% scaled to have DC gain 65536
f2 = [8, -11, 15, -19, 26, -37, 53, -70, 96, -127, 166, -211, 265, -325, 603, -1196, 1113, -1532, 1796, -2115, 2389, -2629, 2812, -2927, 69253, -2927, 2812, -2629, 2389, -2115, 1796, -1532, 1113, -1196, 603, -325, 265, -211, 166, -127, 96, -70, 53, -37, 26, -19, 15, -11, 8];
f2 = f2.';

f2_freq = fft(f2/65536,1024);
f2_scaling = sqrt(sum(f2_freq(1:433).*conj(f2_freq(1:433)))/433);
f2 = round(f2 / f2_scaling);
f2_1024 = zeros(1024,1);
f2_1024(1:25) = f2(25:49);
f2_1024(1001:1024) = f2(1:24);

%% Plot frequency and impulse responses
figure(1);
clf;
subplot(4,1,1);
hold on;
grid on;
plot((0:1023)/1024,db(fft(sps_impulse,1024)),'r.-');
xline(0.422);
axis([0 0.5, 102.4, 103]);
ylabel('dB');
title("Frequency Response of SPS filter 18a to be compensated for")

subplot(4,1,2);
hold on;
grid on;
plot((0:1023)/1024,db(fft(cur_18bit/65536)),'r.-');
ylabel('dB');
%plot((0:1023)/1024,db(fft(f2_1024/65536)),'g.-');
axis([0 0.5, -0.3, 0.3]);
title('Compensation filter');
xline(0.422);

subplot(4,1,3);
hold on;
grid on;

cur_18bit_freq = fft(cur_18bit/65536);
combined_response = full_freq_433 .* cur_18bit_freq(1:433);

f2_1024_freq = fft(f2_1024/65536);
combined_response_f2 = full_freq_433 .* f2_1024_freq(1:433);
% Fudge factors for the overall gain for the plot are not significant
plot((0:432)/1024,db(combined_response) + db(f2_scaling) + 0.002,'r-'); 
%plot((0:432)/1024,db(combined_response_f2) + db(f2_scaling),'g-'); 
ylabel("dB")
xline(0.422); % edge of passband
axis([0 0.5 -0.002 0.002]); 
title('Combined response');

subplot(4,1,4);
hold on;
grid on;
plot(cur_18bit(1:25),'r.-');
%plot(f2_1024(1:25),'g.-');
title('FIR taps');

%% Write text files with the filter frequency response per 226 Hz and 5.4kHz channels

if write_files 
    f4096 = zeros(4096,1);
    f4096(1:25) = cur_18bit(1:25)/65536;
    f4096(4073:4096) = cur_18bit(1001:1024)/65536;
    f_226Hz = real(fftshift(fft(f4096)));  % filter is symmetric so the imaginary part is just roundoff error
    f_226Hz = f_226Hz(321:(2048+1728));
    f_226Hz_sqr = f_226Hz.^2;  % power response
    % 5.4 kHz response
    f_5400Hz_sqr = zeros(144,1);
    for i=1:144
        f_5400Hz_sqr(i) = sum(f_226Hz_sqr(((i-1)*24 + 1):((i-1)*24 + 24))) / 24;
    end

    save("ripple_18a_226Hz_voltage.txt","f_226Hz",'-ascii');
    save("ripple_18a_226Hz_power.txt","f_226Hz_sqr",'-ascii');
    save("ripple_18a_5400Hz_power.txt","f_5400Hz_sqr",'-ascii');
    figure(4);
    clf;
    hold on;
    grid on;
    plot(db(f_226Hz),'r.-');
    %plot((0:1023)/1024,db(fft(f2/65536,1024)),'g.-');
    %axis([0 0.5, -0.3, 0.3]);
    title('Compensation filter, 226 Hz channels (4096 point FFT)');
    xline(0.422);
end

%% Print the filter
dvec = "f = [";
for i=1001:1024
    dvec = strcat(dvec,num2str(cur_18bit(i)),", ");
end
for i=1:24
    dvec = strcat(dvec,num2str(cur_18bit(i)),", ");
end
dvec = strcat(dvec, num2str(cur_18bit(25)), "]");
disp(dvec);
