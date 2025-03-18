%%
clear all;
do_optimisation = 0;

%%
load("filt_27_1024_18a.txt", '-ascii');
x=filt_27_1024_18a;
disp(['Size = ' num2str(size(x))])
offset=0;  % adjust to get symmetrical impulse response
sps_impulse=x((577+offset):864:end); 
imp2 = sps_impulse/sum(sps_impulse); %subsample 
impulse=imp2/sum(imp2);
impulse= [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 impulse' 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0]';
impf=fft(impulse);
impf=impf/max(abs(impf));  %frequency response to be compensated

%c=1.026; d=1.133; %symmetric 1.015,1,1,  Fudge factor
%impf(16:19)= c*impf(16:19);
%impf(17:18)= d*impf(17:18);

comp2=1./impf;  % compensation in frequency calculation
res=ifft(comp2); % to time domain
res=res(3:end);    % trim

res=res/sum(res);  %scale
final=round(res*2^16);
res=final/2^16;


%% Optimisation
if (do_optimisation)
    original_18bit = final;
    cur_18bit = original_18bit;
    combined_response = fft(impulse,1024).*fft(cur_18bit/65536,1024);    
    cur_cost = max(abs(db(combined_response(1:433))));
    disp(['Cost = ' num2str(cur_cost)]);
    iter_max = 1000000;
    fscale = 0;
    amp = 0;
    for opt = 1:iter_max
        cur_18bit_test = cur_18bit;
        if rand(1) < 0.5
            amp = rand(1);
            cur_18bit_test(1:25) = cur_18bit(1:25) + round(amp * randn(25,1));
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
            disp(['Cost = ' num2str(cur_cost) ', use cos = ' num2str(use_cos), ' Amp = ' num2str(amp) ', fscale = ' num2str(fscale)]);
        end
    end

    imp2_freq = fft(cur_18bit/65536,1024);
    imp2_scaling = sqrt(sum(imp2_freq(1:433).*conj(imp2_freq(1:433)))/433);
    cur_18bit = round(cur_18bit / imp2_scaling);
else
    cur_18bit = [2, -4, 8, -13, 19, -31, 47, -65, 91, -123, 162, -208, 261, -320, 596, -1182, 1099, -1514, 1775, -2089, 2360, -2597, 2778, -2892, 68476, -2892, 2778, -2597, 2360, -2089, 1775, -1514, 1099, -1182, 596, -320, 261, -208, 162, -123, 91, -65, 47, -31, 19, -13, 8, -4, 2].';
end
%% Johns filter, don't know exactly how it was generated
%f2 = [5, -7, 12, -21, 31, 169, -676, 504, -833, 1007, -1243, 1442, -1620, 1756, -1842, 68166, -1842, 1756, -1620, 1442, -1243, 1007, -833, 504, -676, 169, 31, -21, 12, -7, 5];
% 49 tap filter with DC gain 65536
f2 = [8, -11, 15, -19, 26, -37, 53, -70, 96, -127, 166, -211, 265, -325, 603, -1196, 1113, -1532, 1796, -2115, 2389, -2629, 2812, -2927, 69253, -2927, 2812, -2629, 2389, -2115, 1796, -1532, 1113, -1196, 603, -325, 265, -211, 166, -127, 96, -70, 53, -37, 26, -19, 15, -11, 8];
f2 = f2.';

f2_freq = fft(f2/65536,1024);
f2_scaling = sqrt(sum(f2_freq(1:433).*conj(f2_freq(1:433)))/433);
f2 = round(f2 / f2_scaling);

%% plot 
figure(1);
clf;

subplot(4,1,1);
hold on;
grid on;
plot((0:1023)/1024,db(fft(sps_impulse,1024)),'r.-');
xline(0.422);
axis([0 0.5, 102.4, 103]);
title("Frequency Response of SPS filter 18a to be compensated for")

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

save("ripple_18a_226Hz_voltage.txt","f_226Hz",'-ascii');
save("ripple_18a_226Hz_power.txt","f_226Hz_sqr",'-ascii');
save("ripple_18a_5400Hz_power.txt","f_5400Hz_sqr",'-ascii');
figure(2);
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

