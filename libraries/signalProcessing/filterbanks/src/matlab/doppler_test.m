%% Doppler simulation
% Simulates a single tone, which is received at two different stations with
% different delays.
% The result is run through the correlator filterbank and the cross
% correlation of the two stations is calculated.
clear all;

% SPS channel center frequency
SPS_f = 300e6;

% Source signal - tone at this frequency
% Correlator fine channels are spaced 226.056 Hz apart.
tone_loc = 200.5; % Number of fine channels from the center of the SPS channel
f_src = SPS_f + 226.0561342592592 * tone_loc;  % Note 100 MHz is a multiple of T_sps

% SPS sample period
T_sps = 1080e-9;  % Actual SPS channels have a 1080 ns period

% Number of SPS samples to process. Correlator filterbank preload is 
% 11*4096 samples, so 15*4096 gives 4 samples at the filterbank output
N_sps = 15 * 4096; % 15 * 4096 = 61440
N_sps_padded = N_sps + 4096; % Calculate more samples than we need so that we can apply padding

% Station delays, expressed as a sinusoid with given amplitude and phase
% Simulate two stations 
delay_amp(1) = 0;  % 100us = 30 km from the phase center (100e-6 * 3e8 = 30e3)
delay_phase(1) = 0;   % In radians, 0 to 2pi over the course of a day

delay_amp(2) = 300e-6;
delay_phase(2) = pi/4;

% Offset to apply to the delays to ensure the delay is a positive value to
% avoid negative indexing errors in matlab
delay_offset = 0; % max(delay_amp) + 2 * T_sps; 

%% Plot the delays
figure(1);
clf;
hold on;
grid on;
plot((0:(N_sps-1))*T_sps,(1/T_sps) * delay_amp(1) * sin(delay_phase(1) + 2*pi*(0:(N_sps-1))*T_sps/(24*60*60)),'r-');
plot((0:(N_sps-1))*T_sps,(1/T_sps) * delay_amp(2) * sin(delay_phase(2) + 2*pi*(0:(N_sps-1))*T_sps/(24*60*60)),'g-');
xlabel('time (seconds)');
ylabel('delay (SPS samples)');
title('Delays for each station');

%% Calculate the samples at each station
samples = zeros(N_sps_padded,2); 
for station = 1:2
    sampling_times = T_sps * (0:(N_sps_padded-1)) - (delay_offset + delay_amp(station) * sin(delay_phase(station) + 2*pi*(0:(N_sps_padded-1))*T_sps/(24*60*60)));
    samples(:,station) = exp(1i*2*pi*sampling_times * f_src);
end

%% Plot samples
figure(2);
clf;
hold on;
grid on;
plot(real(samples(1:4096,1)),'r.-');
plot(imag(samples(1:4096,1)),'g.-');
plot(real(samples(1:4096,2)),'rx-');
plot(imag(samples(1:4096,2)),'gx-');
title('Samples, red real, green imaginary');

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Create visibility
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Apply Coarse delay (a whole number of SPS samples)
% Single sampling offset calculated at the start (t=0) of the frame
samples_coarse = zeros(N_sps,2);  % samples after application of the coarse delay
for station = 1:2
    delay_t0(station) = delay_amp(station) * sin(delay_phase(station) + 0);
    delay_samples_t0(station) = floor(delay_t0(station) / T_sps);
    samples_coarse(:,station) = samples((delay_samples_t0(station) + 1):(delay_samples_t0(station) + N_sps),station);
end


%% Apply doppler correction 
% A delay of t seconds corresponds to a linear phase shift across the band.
% As a function of the frequency f in Hz : 
%   delta_phi(f) = 2*pi*f*t
samples_coarse_doppler = zeros(N_sps,2);  % Samples after applying the coarse delay and the Doppler correction
for station = 1:2
    sampling_times = delay_offset + delay_amp(station) * sin(delay_phase(station) + 2*pi*(0:(N_sps-1))*T_sps/(24*60*60));
    sampling_times = sampling_times - delay_samples_t0(station) * T_sps;
    delta_phi = 2 * pi * SPS_f * sampling_times.';
    samples_coarse_doppler(:,station) = samples_coarse(:,station) .* exp(1i * delta_phi);
end

%% Filterbank

% One block of 3456 fine channels for each station, with doppler applied
samples_coarse_doppler_fine = zeros(3456,2); 

% One block of 3456 fine channels for each station, no doppler applied
samples_coarse_fine = zeros(3456,2);

% One block of 3456 fine channels for each station, no doppler applied,
% phase correction applied after the filterbank
samples_coarse_fine_phase = zeros(3456,2);

for station = 1:2

    % filterbank applied, no doppler
    t2 = correlatorFilterbank(samples_coarse(:,station),0);
    samples_coarse_fine(:,station) = t2(:,end);
    
    % Get the phase offset for the selected filterbank output
    sampling_times = delay_offset + delay_amp(station) * sin(delay_phase(station) + 2*pi*(0:(N_sps-1))*T_sps/(24*60*60));
    % filterbank uses 12*4096 taps, last block is centered on 6*4096 taps
    % from the end
    last_block_delay = sampling_times(end - 6*4096 + 1) - delay_samples_t0(station) * T_sps; 
    samples_coarse_fine_phase(:,station) = samples_coarse_fine(:,station) * exp(1i * 2* pi * SPS_f * last_block_delay);
    
    fine_delay_correction = exp(1i * pi * (last_block_delay/T_sps) * (-1728:1727)/2048);
    samples_coarse_fine_phase(:,station) = samples_coarse_fine_phase(:,station) .* (fine_delay_correction.');
    
    % filterbank applied after doppler
    t1 = correlatorFilterbank(samples_coarse_doppler(:,station),0);
    samples_coarse_doppler_fine(:,station) = t1(:,end);
    samples_coarse_doppler_fine(:,station) = samples_coarse_doppler_fine(:,station) .* (fine_delay_correction.');
    
end
disp("----------------------");
disp('with doppler:');
disp(samples_coarse_doppler_fine(1729 + floor(tone_loc),:));
disp('no doppler, phase correction post filterbank:');
disp(samples_coarse_fine_phase(1729 + floor(tone_loc),:));
disp('no doppler, no phase correction:');
disp(samples_coarse_fine(1729 + floor(tone_loc),:));


figure(3);
clf;
subplot(2,1,1);
hold on;
grid on;
plot(abs(samples_coarse_doppler_fine(:,1)),'r*-')
plot(abs(samples_coarse_doppler_fine(:,2)),'go-')
xlabel('Fine channel');
ylabel('Filterbank absolute value');
title('Input to the correlation, with doppler');
subplot(2,1,2);
hold on;
grid on;
plot(abs(samples_coarse_fine_phase(:,1)),'r*-')
plot(abs(samples_coarse_fine_phase(:,2)),'go-')
xlabel('Fine channel');
ylabel('Filterbank absolute value');
title('Input to the correlation, no doppler');

