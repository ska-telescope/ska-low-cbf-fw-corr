function W = generate_MaxFlt_centered(nbuff, nTap)
% Generate maximal flat filter coefficients

%{
% Author: J Bunton, 22 August 2015
Filter Response to meet correlator requirements
For a monochromatic signal, total power (all channels) remains constant
independent of frequency
Starting point are the maximally flat filters
this is improved with some simple optimisation

Calculation should be done only once per Simulink simulation  

nbuff = typically 4096
nTaps = # of taps, typically 8 or 12 

%} 

%{ 
SVN keywords
 $Rev:: 47                                                                                         $: Revision of last commit
 $Author:: bradford                                                                                $: Author of last commit
 $Date:: 2016-04-19 16:30:25 +1000 (Tue, 19 Apr 2016)                                              $: Date of last commit
 $LastChangedDate:: 2016-04-19 16:30:25 +1000 (Tue, 19 Apr 2016)                                   $: Date of last change
 $HeadURL: svn://codehostingbt.aut.ac.nz/svn/LOWCBF/Modelling/CSP_DSP/CSP_Dataflow/generate_MaxFl#$: Repo location
%}


%% Filter design coefficients 
% disp('generate_MaxFlt')

nTap2 = 2*nTap;  % say around 8 or 12 
nTap2p1 = nTap2+1; 

imp=maxflat(nTap2,'sym',.5*nTap2/nTap2p1);
imp=interpft(imp,nTap2)*nTap2p1/nTap2; %Take to 2*ntap (24) tap filter (2 channel, 12tap FIR)

%keyboard

% plot(db(fft(imp)),'o-')

% Interate to improve (hard coded 10 times) 
for k=1:10

    impf=fft(imp);
    imph=imp.*cos( ((1:length(imp))-1)*pi);
    impfh=fft(imph);
    errorf =(impf.*conj(impf)+impfh.*conj(impfh));
    errorf=errorf/errorf(1);
    errorf=1-errorf;
    error=fftshift((ifft(errorf)));
    imp=imp+error/2.0; %(2.5*( abs(impf)+abs(impfh) ));

end

cor=imp;
corh=cor.*cos( ((1:length(imp))-1)*pi);

corf=freqz(cor,2048)*2048;
corfh=freqz(corh,2000)*2000;
ampf=corf.*conj(corf)+corfh.*conj(corfh);
error = fftshift((ifft(1-ampf)));

%keyboard
%{
Variable nbuff*nTap is the length of the filter. 
Typically: 4096 freq channels * 8 taps) 

12x32 is a 12 tap FIR section, 32 channel filterbank
%} 
%
W=interpft(cor,nbuff*nTap);  %change this line to alter length of filter.

cor_pad = [0 0 0 0 cor 0 0 0 0];
W2 = interpft(cor_pad,nbuff*(nTap+4));

[Wmv,Wmi] = max(W);
[W2mv,W2mi] = max(W2);

W2c = W2((W2mi-nTap*nbuff/2):(W2mi+nTap*nbuff/2 - 1));
W2c_reversed = [0 W2c(end:-1:2)];
W2c_averaged = (W2c + W2c_reversed)/2;

W_low = (Wmi-nTap*nbuff/2);
W_high = (Wmi+nTap*nbuff/2 - 1);
if (W_low < 1)
    W_pad = 1-W_low;
    W_low = 1;
else
    W_pad = 0;
end
if (W_high > nTap*nbuff)
    W_high = nTap*nbuff;
end

Wc = zeros(1,nTap*nbuff);
Wc(W_pad+1:nTap*nbuff) = W(W_low:W_high);

figure(10);
clf;
hold on;
grid on;
plot(Wc,'r.-');
plot([nTap*nbuff/2+1, nTap*nbuff/2+1],[0 1],'g-')
plot(W2c,'b.-');
plot(W2c_reversed,'go');

freq_response = fft(W2c);
fr2 = circshift(freq_response,nTap);
fr3 = circshift(freq_response,2*nTap);
fr4 = circshift(freq_response,3*nTap);
fr5 = circshift(freq_response,4*nTap);
figure(12);
clf;
hold on;
grid on;
plot(10*log10(abs(freq_response).^2),'r.-');
plot(10*log10(abs(fr2).^2),'g.-');
plot(10*log10(abs(freq_response).^2 + abs(fr2).^2 + abs(fr3).^2 + abs(fr4).^2 + abs(fr5).^2),'b.-');
title('freq response, original');
ylabel('dB')
%keyboard
W2ca2 = zeros(1,1572864);
W2ca2(1:49152) = W2c_averaged;
freq_response = fft(W2ca2);
fr2 = circshift(freq_response,nTap*32);
fr3 = circshift(freq_response,2*nTap*32);
fr4 = circshift(freq_response,3*nTap*32);
fr5 = circshift(freq_response,4*nTap*32);
figure(13);
clf;
hold on;
grid on;
plot(10*log10(abs(freq_response).^2),'r.-');
plot(10*log10(abs(fr2).^2),'g.-');
plot(10*log10(abs(fr3).^2),'c.-');
plot(10*log10(abs(fr4).^2),'m.-');
plot(10*log10(abs(fr5).^2),'y.-');
plot(10*log10(abs(freq_response).^2 + abs(fr2).^2 + abs(fr3).^2 + abs(fr4).^2 + abs(fr5).^2),'b.-');
title('freq response, symmetric filter');
ylabel('dB')

W = W2c_averaged(:); % force column 

return 