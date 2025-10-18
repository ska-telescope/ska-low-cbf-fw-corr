# -*- coding: utf-8 -*-
#
# Copyright (c) 2022 CSIRO Space and Astronomy.
# All rights reserved
import numpy as np
import scipy.fftpack
import scipy.signal

"""
The correlator filterbank critically samples each SPS coarse channel.
Parameters
- 4096 point FFT
- 12x4096 FIR taps
- Critically sampled. Input data is oversampled by 32/27, output keeps the
central 3456 fine channels.
- Input samples have a period of 1080ns, for a bandwidth of
(1/1080ns) = 925.925 kHz.
- Used bandwidth is (27/32) of this, i.e. (27/32)*925925.925 = 781.25 kHz
- Output fine channels have a bandwidth of 925925.925/4096 = 226.056 Hz
"""

FINE_PER_COARSE = 3456
"""Fine channels per coarse channel"""

FFT_LENGTH = 4096
"""Number of points in the FFT"""

FIR_TAPS = 12
"""total number of FIR taps, in units of the fft size"""

# No oversampling for the default correlator filterbank.
OS_NUMERATOR = 32
OS_DENOMINATOR = 32

DEFAULT_FILTER = np.zeros(1)


class PolyphaseFilterBank:
    def __init__(
        self,
        fir_file,
        correction_filter: np.ndarray = DEFAULT_FILTER,
        fft_length: int = FFT_LENGTH,
        fir_taps: int = FIR_TAPS,
        oversample_numerator: int = OS_NUMERATOR,
        oversample_denominator: int = OS_DENOMINATOR,
    ):
        """
        :param fir_file: text file containing FIR tap values
        (file object or str path)
        """
        # Load the FIR taps from a text file
        self.fir = np.loadtxt(fir_file)
        # scale and round as per the firmware filtertaps.
        self.fir = np.round(self.fir)
        # number of points in the FFT
        self.fft_length = int(fft_length)
        # total number of FIR taps, in units of the fft size
        self.fir_taps = fir_taps
        # Check : have we got the correct number of fir taps ?
        if len(self.fir) != (self.fir_taps * self.fft_length):
            raise Exception("Wrong number of FIR taps.")

        self.oversample_numerator = oversample_numerator
        self.oversample_denominator = oversample_denominator
        self.sample_step = int(
            round(fft_length / (oversample_numerator / oversample_denominator))
        )

        self.clipped = False  # has clipping occurred?
        self.real_max = 0  # maximum value
        self.imag_max = 0  # maximum value

        self.correction_filter = correction_filter

    def filter(
        self,
        din: np.ndarray,
        time_steps: int = None,
        derotate: bool = False,
        keep: int = FINE_PER_COARSE,
        filter_scale=512,
        fft_scale=128,
        saturate: bool = True,
        preload_zeros: int = 0,
        pre_filter: bool = False,
    ) -> np.ndarray:
        """
        Apply Polyphase FilterBank (PFB) to the data in a 1-D numpy array.

        :param din: Input data to filter.
        :param time_steps: Number of output time samples to calculate, defaults
        to processing the full input data din
        :param derotate: enable derotation of the filterbank output for
        oversampled filterbanks
        (i.e. oversample numerator != oversample denominator)
        :param keep: Number of output frequency channels to keep, centered
        around DC. default value of 108 corresponds to the used portion of the
        channel for a 128 point FFT, and 32/27 oversampling
        :param filter_scale: scaling factor to apply at the output of the FIR
        filter.
        :param fft_scale: scaling factor to apply at the output of the FFT.
        :param saturate: if True, limit the output to 16 bit integers.
        :param zero_pad: pads the front of the input data with zeros, as occurs
        in the
        firmware with preloading of data from the previous corner turn frame.

        :return: Result of applying PFB.
        """

        if preload_zeros > 0:
            # Zero pad the front of the data so that the data for the first fft
            # comes from the first self.sample_step samples of the input data
            din_padded = np.zeros(
                din.shape[0] + preload_zeros, dtype=np.complex64
            )
            din_padded[preload_zeros : (preload_zeros + din.shape[0])] = din
            din = din_padded

        if time_steps is None:
            # Calculate the number of time steps needed to use all input data.
            preload_length = self.fft_length * self.fir_taps - self.sample_step
            time_steps = (len(din) - preload_length) // self.sample_step

        dout = np.zeros((time_steps, self.fft_length), dtype=np.complex64)

        # Prefilter to flatten the prior filterbank frequency response
        if pre_filter:
            prefiltered = scipy.signal.lfilter(self.correction_filter, 1, din)
        else:
            prefiltered = din

        for time_sample in range(time_steps):
            temp = (
                prefiltered[
                    (time_sample * self.sample_step) : (
                        time_sample * self.sample_step
                        + self.fir_taps * self.fft_length
                    )
                ]
                * self.fir
            )
            temp.shape = (self.fir_taps, self.fft_length)
            dout[time_sample] = (
                scipy.fftpack.fft(np.sum(temp, axis=0) / filter_scale)
                / fft_scale
            )

        if derotate:
            # Remove rotation due to oversampling
            for f in range(self.fft_length):
                dout[:, f] = dout[:, f] * np.exp(
                    -1j
                    * f
                    * self.oversample_denominator
                    / self.oversample_numerator
                    * np.arange(time_steps)
                    * 2
                    * np.pi
                )

        # Select the central "keep" frequencies
        dout = np.fft.fftshift(dout, axes=1)
        fmin = int((self.fft_length / 2) - (keep / 2))
        fmax = int((self.fft_length / 2) + (keep / 2))
        dout = dout[:, fmin:fmax]

        self.clipped = False
        self.real_max = np.max(np.abs(dout.real))
        self.imag_max = np.max(np.abs(dout.imag))
        if saturate:
            # check if clipping is going to occur.
            # We both check and clip so that we can leave a record, both of
            # whether clipping occurred (in self.clipped) and of the
            # maximum value prior to clipping (in self.real_max, self.imag_max)
            if (self.real_max > 32767) or (self.imag_max > 32767):
                self.clipped = True
                # limit data to 16 bits dynamic range, i.e. [-32768, 32767)
                np.clip(dout.real, -32768, 32767, out=dout.real)
                np.clip(dout.imag, -32768, 32767, out=dout.imag)

        return dout
