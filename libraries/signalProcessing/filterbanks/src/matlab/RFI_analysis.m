clear all;
correlatorFilterbankTaps = round(2^17 * generate_MaxFlt_centered(4096,12)); 

%%
% offset the starting number for the figures
fbase = 0;
% Number of consecutive samples to mark as RFI
samplesToMark = 1;
write_ROM = 1;

%%
figure(1 + fbase);
clf;
hold on;
grid on;
plot(correlatorFilterbankTaps,'r.-');

%%
filt = correlatorFilterbankTaps;  % load appropriate filter, adjust values L to OS to match
L=length(filt); % length of filter
P=12;   % length of polyphase filter
FF=L/P; % length of FFT
step = 1024; % step along filter for calculation
OS = 1;  % oversampling ratio
alias = zeros(1,49152);
alias2 = zeros(1,49152);

% Signal power with no RFI
out_ideal = fft(filt);
out_ideal_power = sum(out_ideal .* conj(out_ideal));

for m=1:(length(filt) - samplesToMark)

    rfi = zeros(length(filt),1);
    rfi(m:(m+samplesToMark-1)) = 1;
    
    rfi = 1-rfi;
    out = fft(rfi.*filt); % set marked values at filter position to zero
    Chan = ceil(P*OS/2);   % half filter channel response with including transition
    
    % Calculate the power in the bandpass of the filter
    signalP = sum(out(1:(Chan+1)).*conj(out(1:(Chan+1)))); 
    signalP = signalP + sum(out(L-Chan+1:L).*conj(out(L-Chan+1:L)));
    
    % Calculate the alias power excluding the adjacent channel
    Chan3 = floor(Chan*1.5);
    % +1 to account for DC, +1 to account for 1-based matlab indexing,
    % so the range is ((Chan3+2):(L-Chan3))
    rfiP = sum(out((Chan3+2):L-Chan3).*conj(out((Chan3+2):L-Chan3)));
    
    alias(m) = rfiP/signalP; %Alias power relative to channel power
    
    % Alternate method of calculating RFI power
    % Total power after subtracting from the ideal output
    total_error = out - out_ideal;
    rfiP2 = sum(total_error .* conj(total_error));
    alias2(m) = rfiP2 / out_ideal_power;
    
end

alias_r =reshape(alias,step,[]);
alias_av = sum(alias_r,1)/step;  % average data across "step" samples

alias2_r =reshape(alias2,step,[]);
alias2_av = sum(alias2_r,1)/step;  % average data across "step" samples

figure(2 + fbase);
clf;
plot(db(out/out(1)));
grid on;
title('Filter response');
ylabel('dB');

figure(3 + fbase)
clf;
hold on;
plot(db(alias)/2,'r.-'); % already power, so divide "db" function output by 2
plot(db(alias2)/2,'g.-');
grid on;
title('Alias Power relative to Channel power');
ylabel('dB');
xlabel('RFI sample offset');

figure(4 + fbase);
clf;
hold on;
plot(db(alias_av)/2);
plot(db(alias2_av)/2);
grid on;
title('Subsampled Alias power relative to channel power');
ylabel('dB');
xlabel('RFI sample offset / 1024');

% Write out a ROM that contains alias2_av

if write_ROM == 1
    disp('            case rom_addr is');
    for ra = 0:47
        disp( ['                when "' dec2binX(ra,6) '" => o_RFI_weight <= "' dec2binX(ceil(2^32 * alias2_av(ra+1)),24) '",']);
    end
    disp(['                when others => o_RFI_weight <= "000000000000000000000000",']);
    disp('            end case;');
end




