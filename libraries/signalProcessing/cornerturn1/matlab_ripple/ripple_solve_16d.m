%% Configure
clear all;
run_optimisation = 0;

%%
load("filt_27_1024_16d.txt", '-ascii');
x=filt_27_1024_16d;
disp(['Size = ' num2str(size(x))])
offset=0;  % adjust to get symmetrical impulse response
sps_impulse=x((417+offset):864:end); 
% note DC response of SPS = sum(sps_impulse) = 132761
imp2=sps_impulse/sum(sps_impulse); %subsample 

% Scale the SPS filter to have unity response across the frequency band
imp2_freq = fft(imp2,1024);
%imp2_scaling = sqrt(sum(imp2_freq(1:433).*conj(imp2_freq(1:433)))/433);
%res = res / scaling;
impulse=imp2/sum(imp2);
%impulse = imp2 / imp2_scaling;

impulse= [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 impulse' 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0]';
impf=fft(impulse);
impf=impf/max(abs(impf));  %frequency response to be compensated

comp2=1./impf;  % compensation in frequency calculation
res=ifft(comp2); % to time domain
res=res(3:end);    % trim

res=res/sum(res);  %scale
final=round(res*2^16);
res=final/2^16;

%% Optimisation
if run_optimisation
    original_18bit = final;
    cur_18bit = original_18bit;
    combined_response = fft(impulse,1024).*fft(cur_18bit/65536,1024);    
    cur_cost = max(abs(db(combined_response(1:433))));
    disp(['Cost = ' num2str(cur_cost)]);
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
        else
            amp = 0.5 * randn(1);
            fscale = randn(1);
            cur_18bit_test(1:25) = round(cur_18bit(1:25) + amp * cos(((0:24).')*fscale));
            use_cos = 1;
        end
        cur_18bit_test(26:49) = cur_18bit_test(24:-1:1);

        combined_response = fft(impulse,1024).*fft((cur_18bit_test)/65536,1024);
        new_cost = max(abs(db(combined_response(1:433))));
        if new_cost < cur_cost
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
    % Pre optimised filter
    cur_18bit = [3, -5, 9, -14, 22, -31, 42, -58, 96, -129, 176, -234, 303, -384, 474, -625, 1883, -1705, 2110, -2496, 2857, -3168, 3406, -3557, 69167, -3557, 3406, -3168, 2857, -2496, 2110, -1705, 1883, -625, 474, -384, 303, -234, 176, -129, 96, -58, 42, -31, 22, -14, 9, -5, 3].';
end

%% Johns filter, don't know exactly how it was generated
% f2 = [7, -10, 13, -18, 24, -33, 43, -58, 94, -123, 168, -223, 289, -365, 451, -593, 1785, -1617, 2000, -2366, 2709, -3003, 3229, -3372, 65535, -3372, 3229, -3003, 2709, -2366, 2000, -1617, 1785, -593, 451, -365, 289, -223, 168, -123, 94, -58, 43, -33, 24, -18, 13, -10, 7];
% f2 = f2 * 65536 / sum(f2);
% scaled to have DC gain 65536
f2 = [7, -10, 14, -18, 25, -34, 44, -59, 96, -127, 173, -230, 297, -376, 464, -611, 1840, -1666, 2061, -2438, 2791, -3094, 3327, -3475, 67531, -3475, 3327, -3094, 2791, -2438, 2061, -1666, 1840, -611, 464, -376, 297, -230, 173, -127, 96, -59, 44, -34, 25, -18, 14, -10, 7];
f2 = f2.';

f2_freq = fft(f2/65536,1024);
f2_scaling = sqrt(sum(f2_freq(1:433).*conj(f2_freq(1:433)))/433);
f2 = round(f2 / f2_scaling);

%% Plot frequency and impulse responses
figure(3);
clf;
subplot(4,1,1);
hold on;
grid on;
plot((0:1023)/1024,db(fft(sps_impulse,1024)),'r.-');
xline(0.422);
axis([0 0.5, 102.4, 103]);
title("Frequency Response of SPS filter 16d to be compensated for")

subplot(4,1,2);
hold on;
grid on;
plot((0:1023)/1024,db(fft(cur_18bit/65536,1024)),'r.-');
plot((0:1023)/1024,db(fft(f2/65536,1024)),'g.-');
axis([0 0.5, -0.3, 0.3]);
title('Compensation filter, red improved, green original');
xline(0.422);

subplot(4,1,3);
hold on;
grid on;
plot((0:1023)/1024,db(fft(imp2,1024).*fft(cur_18bit/65536,1024)) + db(f2_scaling),'r-'); 
plot((0:1023)/1024,db(fft(imp2,1024).*fft(f2/65536,1024)) + db(f2_scaling),'g-'); 
ylabel("dB")
xline(0.422); % edge of passband
axis([0 0.5 -0.004 0.004]); 
title('Combined response, red improved, green original');

subplot(4,1,4);
hold on;
grid on;
plot(cur_18bit,'r.-');
plot(f2,'g.-');
title('FIR taps');

%% Write text files with the filter frequency response per 226 Hz and 5.4kHz channels
f4096 = zeros(4096,1);
f4096(1:25) = cur_18bit(25:49)/65536;
f4096(4073:4096) = cur_18bit(1:24)/65536;
f_226Hz = real(fftshift(fft(f4096)));  % filter is symmetric so the imaginary part is just roundoff error
f_226Hz = f_226Hz(321:(2048+1728));
f_226Hz_sqr = f_226Hz.^2;  % power response
% 5.4 kHz response
f_5400Hz_sqr = zeros(144,1);
for i=1:144
    f_5400Hz_sqr(i) = sum(f_226Hz_sqr(((i-1)*24 + 1):((i-1)*24 + 24))) / 24;
end

save("ripple_16d_226Hz_voltage.txt","f_226Hz",'-ascii');
save("ripple_16d_226Hz_power.txt","f_226Hz_sqr",'-ascii');
save("ripple_16d_5400Hz_power.txt","f_5400Hz_sqr",'-ascii');
figure(4);
clf;
hold on;
grid on;
plot(db(f_226Hz),'r.-');
%plot((0:1023)/1024,db(fft(f2/65536,1024)),'g.-');
%axis([0 0.5, -0.3, 0.3]);
title('Compensation filter, 226 Hz channels (4096 point FFT)');
xline(0.422);


%% Print the filter
dvec = "f = [";
for i=1:48
    dvec = strcat(dvec,num2str(cur_18bit(i)),", ");
end
dvec = strcat(dvec, num2str(cur_18bit(49)), "]");
disp(dvec);
