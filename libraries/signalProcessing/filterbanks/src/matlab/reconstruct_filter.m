% Script to read correlator Filterbank coefficient (.coe) files
% and plot the filter taps (impulse response) and frequency response
% Also shows effect of adding in aliased signal from adjacent channel
% intended to flatten the overall frequency response

% kb 2023-09-30

close all;
clear all;

file_stem = "correlatorFIRTaps"

BRANCH_LEN = 12  % taps in each FIR filter preceding filterbank's FFT  
N_BRANCHES = 4096  % Filterbank channels

coefs = zeros(BRANCH_LEN, N_BRANCHES);

for k = 1:BRANCH_LEN
  fname = sprintf("correlatorFIRTaps%d.coe", k);
  fid = fopen(fname, "r");

  % discard first two Xilinx directive lines in file
  for m =1:2
    vals = fgets(fid);
  end
  % read the 18-digit binary values from every other line
  %printf("Reading taps from file '%s'\n", fname)
  for m = 1:N_BRANCHES
    chars = fgets(fid);
    coefs(k, m) = bin2dec(chars(1:18));
  end
  fclose(fid);

end

% account for the coeficients being 18-bit 2's complement not straight binary
neg_vals = coefs >= 2^17;
coefs(neg_vals) = coefs(neg_vals) - 2^18;
% combine the branches back into the original FIR filter
taps = reshape(coefs.', BRANCH_LEN * N_BRANCHES,1);

% find tap that is the midpoint of the filter (will have fractional part)
midpt = BRANCH_LEN * N_BRANCHES/2;

% plot filter tap coefficients
hnd = plot([1:length(taps)], taps, 'b', [midpt, midpt], [-17500,77500],'--r' );
%set(hnd, "LineWidth", 2);
% adjust plot x-axis to be tight around the tap range
a = axis();
a(2) = length(taps);
axis(a);
grid;
xlabel("tap number")
title("Correlator filter taps")

% plot frequency response of filter
figure();
cs = 800e6/1024 * 32/27 /4096; % channel spacing
[h,w] = freqz(taps, 1, 2^17);
h = h/h(1); % normalise response to unity
tsample = 1080e-9;
plot(w/(2*pi*tsample), 20*log10(abs(h)), 'b', [cs,cs]/2, [-17.5,2.6],'--r' )
title("Correlator Fine Channel Filter frequency response")
xlabel("Frequency (Hz)")
ylabel("dB")
grid;
axis([0, 200, -20, 5]);

% plot sum of filter response + alias from adjacent channel
figure()
h_lo = h(1:33);  % in-channel signal
h_hi = flipud(h(33:65));  % aliased signal from adjacent channel
plot(([1:33]-1)*800e6/1024*32/27/4096/32, ...
       	10*log10(abs(h_hi).^2 +  abs(h_lo).^2));
grid;
xlabel("Frequency (Hz)")
ylabel("Power (dB)")
title("Filter response including aliased adjacent channel")




