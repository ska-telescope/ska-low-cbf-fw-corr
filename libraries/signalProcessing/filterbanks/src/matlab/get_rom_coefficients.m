% Get the ROM contents for the FIR filter coefficients

PSSFilterbankTaps = round(2^17 * generate_MaxFlt(64,12));   % PSS, 64 point FFT, 12 taps.
PSTFilterbankTaps = round(2^17 * generate_MaxFlt(256,12));  % PST, 256 point FFT, 12 taps
%correlatorFilterbankTaps = round(2^17 * generate_MaxFlt(4096,12)); % Correlator, 4096 point FFT, 12 taps.

correlatorFilterbankTaps = round(2^17 * generate_MaxFlt_centered(4096,12)); 

figure(1);
clf;
hold on;
grid on;
plot(correlatorFilterbankTaps,'r.-');
plot(correlatorFilterbankTaps(end:-1:1),'g.-');
for f1 = 0:12
    plot([f1*4096,f1*4096],[0 80000],'b-');
end

figure(2);
clf;
hold on;
grid on;
title('prototype frequency response');
plot(abs(fftshift(fft(correlatorFilterbankTaps))),'r.-');


write_coe = 1;
if (write_coe == 1)

    % Correlator FIR taps
    filtertaps = correlatorFilterbankTaps;
    for rom = 1:12
        fid = fopen(['correlatorFIRTaps' num2str(rom) '.coe'],'w');
        fprintf(fid,'memory_initialization_radix = 2;\n');
        fprintf(fid,'memory_initialization_vector = ');
        for rline = 1:4096
            dstr = dec2binX(filtertaps((rom-1)*4096 + (rline-1) + 1),18);
            fprintf(fid,['\n' dstr]);
        end
        fprintf(fid,';\n');
        fclose(fid);
        
        % Write initialisation file for xpm memory (used in versal)
        fid = fopen(['correlatorFIRTaps' num2str(rom) '.mem'],'w');
        for rline = 1:4096
            dval = filtertaps((rom-1)*4096 + (rline-1) + 1);
            if (dval < 0)
                dval = dval + 2^20; % 5 hex digits, 20 bit value, low 18 bits actually used in the memory.
            end
            dstr = dec2hex(dval,5); % 5 hex digits
            fprintf(fid,[dstr '\n']);
        end
        fclose(fid);
    end

%     % PSS FIR taps
%     % Coefficients are double buffered (because it doesn't cost anything to do it)
%     % so are just duplicated here.
%     filtertaps = PSSFilterbankTaps;
%     for rom = 1:12
%         fid = fopen(['PSSFIRTaps' num2str(rom) '.coe'],'w');
%         fprintf(fid,'memory_initialization_radix = 2;\n');
%         fprintf(fid,'memory_initialization_vector = ');
%         % First half of the memory.
%         for rline = 1:64
%             dstr = dec2binX(filtertaps((rom-1)*64 + (rline-1) + 1),18);
%             fprintf(fid,['\n' dstr]);
%         end
%         % Another copy for the other half of the memory (double buffered).
%         for rline = 1:64
%             dstr = dec2binX(filtertaps((rom-1)*64 + (rline-1) + 1),18);
%             fprintf(fid,['\n' dstr]);
%         end    
%         fprintf(fid,';\n');
%         fclose(fid);
%     end
% 
%     % PST FIR taps
%     filtertaps = PSTFilterbankTaps;
%     for rom = 1:12
%         fid = fopen(['PSTFIRTaps' num2str(rom) '.coe'],'w');
%         fprintf(fid,'memory_initialization_radix = 2;\n');
%         fprintf(fid,'memory_initialization_vector = ');
%         % First half of the memory.
%         for rline = 1:256
%             dstr = dec2binX(filtertaps((rom-1)*256 + (rline-1) + 1),18);
%             fprintf(fid,['\n' dstr]);
%         end
%         % Another copy for the other half of the memory (double buffered).
%         for rline = 1:256
%             dstr = dec2binX(filtertaps((rom-1)*256 + (rline-1) + 1),18);
%             fprintf(fid,['\n' dstr]);
%         end    
%         fprintf(fid,';\n');
%         fclose(fid);
%     end

end


