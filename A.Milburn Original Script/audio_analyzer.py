import librosa
import yaml
import os
import time
import warnings
import numpy as np
import scipy
import soundfile as sf
from wavinfo import WavInfoReader
import argparse
from scipy.signal import butter, filtfilt
import essentia
import essentia.standard as ess
from essentia import array as e_array
from essentia.standard import BeatsLoudness, OnsetRate, PitchSalience, Loudness
#from mutagen.mp3 import MP3

# Silence librosa's "n_fft too large for input signal" warning: it fires on the
# short decimated buffers chroma_cens produces and is harmless (it zero-pads).
warnings.filterwarnings("ignore", message=r"n_fft=\d+ is too large", category=UserWarning)
# Silence essentia INFO logs (e.g. TriangularBands recomputing its filter bank).
essentia.log.infoActive = False

# Frame and hop sizes.
frame_size = 2048 # Bigger is better to detect lower frequencies - 1024 can detect down to 85hz
hop_size = 512 # Smaller is better to detect onsets quickly -- 256 means .005 secs
sig_digits = 3
MAX_ABS_SAMPLE = 1000.0 # Float WAVs are nominally in [-1, 1]; a peak past this (e.g. an unstable-filter blowup to ~1e29) is treated as corrupt and the file is skipped.
STD_DEV_QUARTER = 0.02 # How statistically consistent the quarter note offset should be before we adjust the grid.   Smaller is stricter
GRID_OFFSET_DIVISOR = 8 # 8 for 32nd notes, 4 for 16th notes, 2 for 8th notes -- this is the size of the window that we consider when looking for an overall grid offset (like dcbias for rhythm)


# Butterworth filter design functions
def butter_lowpass_filter(data, cutoff, fs, order=5):
    b, a = butter(order, cutoff / (0.5 * fs), btype='low', analog=False)
    y = filtfilt(b, a, data)
    return y

def butter_highpass_filter(data, cutoff, fs, order=5):
    b, a = butter(order, cutoff / (0.5 * fs), btype='high', analog=False)
    y = filtfilt(b, a, data)
    return y

def butter_bandpass_filter(data, lowcut, highcut, fs, order=5):
    nyquist = 0.5 * fs
    low = lowcut / nyquist
    high = highcut / nyquist
    b, a = butter(order, [low, high], btype='band')
    y = filtfilt(b, a, data)
    return y


# Function to truncate floating point values, just saving file size
def trunc(values, decs=0):
    return np.trunc(values*10**decs)/(10**decs)

# Function to compute the autocorrelation of a single frame's worth of audio
def autocorrelation(x):
    """
    Compute the autocorrelation of the signal, and find the lag at which the
    autocorrelation first reaches a maximum.
    """
    xp = x-np.mean(x)
    f = np.fft.fft(xp)
    f = np.array([np.real(v)**2+np.imag(v)**2 for v in f])
    pi = np.fft.ifft(f)

    denominator = np.sum(xp**2)
    if denominator != 0:
        acf = np.real(pi)[:x.size//2]/denominator
    else:
        acf = np.zeros_like(np.real(pi)[:x.size//2])  # or some other appropriate value
    
    # Exclude the zero-lag value by starting from 1
    # Add 1 because the argmax function returns a 0-based index
    dominant_period = np.argmax(acf[1:]) + 1
    strength = acf[dominant_period]
    
    return dominant_period, strength

# Function to compute the likelhihood of a kick drum
def estimate_kickiness(y, sr, threshold=0.75, hop_length=4096):
    # Compute the Short-Time Fourier Transform (STFT)
    D = librosa.stft(y, n_fft=8192)

    # Compute the spectrogram magnitude
    S_mag, _ = librosa.magphase(D)

    # Compute the Mel-frequency spectrogram
    mel_spec = librosa.feature.melspectrogram(S=S_mag, sr=sr)

    # Compute the onset envelope, targeting only the low-frequency range of the spectrum.
    onsets = librosa.onset.onset_strength(sr=sr, S=mel_spec, fmin=40, fmax=160, hop_length=hop_length)

    # Set a threshold for onset strength
    strong_onsets = onsets > threshold

    return strong_onsets.sum()

def calculate_swing(all_onsets, tempo):
    """
    Calculate swing metrics based on onset times and tempo.
    
    Args:
        onsets_by_band (dict): A dictionary containing onset times for different frequency bands.
        tempo (float): Estimated tempo of the audio in BPM.
        
    Returns:
        tuple: (swing_8th, strong_swing_8th, swing_16th, strong_swing_16th)
    """
    weak_8th_count = 0
    weak_16th_count = 0

    offset_quarter_values = []

    # Calculate beat duration and grid intervals
    beat_duration = 60 / tempo
    quarter_note_duration = beat_duration
    eighth_note_duration = beat_duration / 2
    sixteenth_note_duration = beat_duration / 4

    # Calculate the end time of the grid based on the last onset
    end_time = all_onsets[-1] + beat_duration

    # Generate the grid of imaginary onsets
    grid_quarter = np.arange(0, end_time, quarter_note_duration)
    grid_8th = np.arange(0, end_time, eighth_note_duration)
    grid_16th = np.arange(0, end_time, sixteenth_note_duration)

    # Calculate offset for quarter notes
    for onset in all_onsets:
        # Find the nearest quarter note grid point
        nearest_quarter_idx = np.argmin(np.abs(grid_quarter - onset))
        nearest_quarter = grid_quarter[nearest_quarter_idx]

        # Calculate offset for quarter notes only if the onset is close to a quarter note position
        if abs(onset - nearest_quarter) < quarter_note_duration / GRID_OFFSET_DIVISOR:  # 32nd 
            offset_quarter = (onset - nearest_quarter) / quarter_note_duration
            offset_quarter_values.append(offset_quarter)

        #print(onset, nearest_quarter, abs(onset - nearest_quarter),quarter_note_duration / 8 )

    # Calculate average offset and standard deviation for quarter notes
    avg_offset_quarter = np.mean(offset_quarter_values) if offset_quarter_values else 0
    std_offset_quarter = np.std(offset_quarter_values) if offset_quarter_values else 0

    # Adjust the grid if the offset is consistent (low standard deviation)
    if std_offset_quarter < STD_DEV_QUARTER and abs(avg_offset_quarter) > 0.0001:  # Adjust the threshold as needed
        offset_adjustment = avg_offset_quarter * quarter_note_duration
        #print_colorfully("\tAdjusting grid based on consistent offset:", color='white', end='')
        print_colorfully(offset_adjustment, color='purple')
        grid_8th += offset_adjustment
        grid_16th += offset_adjustment

    # Calculate swing values relative to the adjusted grid
    swing_8th_values = []
    swing_16th_values = []

    for onset in all_onsets:
        # Find the nearest 8th note grid point
        nearest_8th_idx = np.argmin(np.abs(grid_8th - onset))
        nearest_8th = grid_8th[nearest_8th_idx]

        # Calculate swing for 8th notes on weak beats
        if nearest_8th_idx % 2 == 1:
            swing_8th = (onset - nearest_8th) / eighth_note_duration
            swing_8th_values.append(swing_8th)
            weak_8th_count += 1

        # Find the nearest 16th note grid point
        nearest_16th_idx = np.argmin(np.abs(grid_16th - onset))
        nearest_16th = grid_16th[nearest_16th_idx]

        # Calculate swing for 16th notes on weak beats
        if nearest_16th_idx % 2 == 1:
            swing_16th = (onset - nearest_16th) / sixteenth_note_duration
            swing_16th_values.append(swing_16th)
            weak_16th_count += 1

    # Calculate average swing values
    avg_swing_8th = np.mean(swing_8th_values) if swing_8th_values else 0
    avg_swing_16th = np.mean(swing_16th_values) if swing_16th_values else 0

    # Calculate standard deviation of swing values
    std_swing_8th = np.std(swing_8th_values) if swing_8th_values else 0
    std_swing_16th = np.std(swing_16th_values) if swing_16th_values else 0


    if avg_swing_8th < 0:
        print_colorfully('\tignoring negative swing value for 8th notes', color='gray')
        avg_swing_8th = 0
    if avg_swing_16th < 0:
        print_colorfully('\tignoring negative swing value for 16th notes', color='gray')
        avg_swing_16th = 0

    #print('\tswing 8th:', end='')
    print_colorfully(round(avg_swing_8th, 3),'\tstd:',round(std_swing_8th, 3), color='yellow')
    #print('\tswing 16th:', end='')
    print_colorfully(round(avg_swing_16th, 3),'\tstd:',round(std_swing_16th, 3), color='yellow')
    if std_offset_quarter < STD_DEV_QUARTER and avg_offset_quarter != 0:
        print_colorfully("\tavg_offset_quarter", avg_offset_quarter, "std_offset_quarter", std_offset_quarter, color='yellow')

    return avg_swing_8th, std_swing_8th, avg_offset_quarter, std_offset_quarter, avg_swing_16th, std_swing_16th, weak_8th_count, weak_16th_count


import re

def bpm_from_filename(s: str) -> float:
    bpm = 0.0
    # Extract clusters of numbers from the string
    a = re.findall(r'\d+', s)
    if not a:
        return bpm
    for f_str in a:
        f = float(f_str)
        if 48 < f < 210:
            bpm = f
            break
    return bpm



def analyze_file(filepath, bpm_override=None):
    print("--- RUNNING LATEST SCRIPT VERSION ---") # <--- ADD THIS LINE

    print(f'\analyze_file file: {filepath}')

    # Get the file creation date
    stat = os.stat(filepath)
    modified_date = time.ctime(stat.st_mtime) # mtime is the last modified time which is the best we can do on a linux server

    try:
        y, sr = librosa.load(filepath, mono=False)
    except Exception as e:
        print(f"\tError loading file {filepath}: {e}")
        return None

    # Some files arrive with non-finite samples (inf/NaN), which blow up
    # downstream features (e.g. tempogram: "Input must be finite", and
    # "overflow encountered in square"). Replace them with zeros up front.
    if not np.all(np.isfinite(y)):
        bad = int(np.count_nonzero(~np.isfinite(y)))
        print(f"\tWarning: {bad} non-finite sample(s) found; zeroing them.")
        y = np.nan_to_num(y, nan=0.0, posinf=0.0, neginf=0.0)

    # Other files are finite but wildly out of range -- e.g. an unstable
    # low-pass filter that rang up to ~1e29. librosa runs in float32, where
    # squaring such values overflows to inf, surfacing as "overflow encountered
    # in square" and then "Input must be finite". The isfinite check above
    # cannot catch these (they are finite, just enormous), so check the peak:
    # audio is nominally in [-1, 1], so a peak past MAX_ABS_SAMPLE means the
    # file is corrupt. Raise here; process_audio_file's except logs one clean
    # skip line, and we bail before librosa ever squares the bad samples.
    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if peak > MAX_ABS_SAMPLE:
        n_bad = int(np.count_nonzero(np.abs(y) > MAX_ABS_SAMPLE))
        raise ValueError(
            f"out-of-range samples (peak {peak:.2e}, {n_bad} > {MAX_ABS_SAMPLE:g}); "
            f"likely corrupt float WAV (unstable filter?)"
        )

    # Getting the duration of the audio file
    duration = librosa.get_duration(y=y, sr=sr)
    print(f'\tDuration: {duration}')

    # Checking if the audio is mono, stereo or multi-channel
    if y.ndim == 1:
        print("\tThis is a mono signal.")
    elif y.ndim == 2 and y.shape[0] == 2:
        print("\tThis is a stereo signal.")
        # Convert stereo to mono for further analysis
        y = librosa.to_mono(y)
    else:
        print("\tThis is a multi-channel file, and we're not equipped to handle it.")
        return None

    if duration < 0.1:
        print("\tFile is too short for analysis. Using default values.")
        # Return a structure with empty or zeroed values consistent with the full analysis
        return {
            'file': filepath, 'modified_date': modified_date, 'duration': 0.0, 'adjusted_hop_size': 0,
            'adjusted_frame_size': 0, 'sample_rate': sr, 'onset_infos': [], 'pitch_salience': 0.0,
            'kickiness': 0.0, 'bpm_est': 0.0, 'rms': [], 'avg_swing_8th': 0.0, 'avg_swing_16th': 0.0,
            'std_swing_8th': 0.0, 'std_swing_16th': 0.0, 'avg_offset_quarter': 0.0, 'std_offset_quarter': 0.0,
            'weak_8th_count': 0, 'weak_16th_count': 0, 'avg_tempogram_ratio': [], 'spectral_centroids': [],
            'spectral_contrast': [], 'spectral_flatness': [], 'chroma': [], 'chroma_cens': [], 'chroma_smooth': [],
            'cepstral_coefficients': [], 'onset_times': [], 'autocorrelation_periods': [],
            'autocorrelation_strengths': [], 'mfcc': [], 'spectral_rolloff': [], 'zero_crossing_rate': [],
            'hpcp': [], 'integrated_loudness_ebur128': 0.0
        }

    # Adjust frame sizes for short files
    frame_size = 2048  # Default frame size
    adjusted_frame_size = min(frame_size, int(sr * duration / 10))
    adjusted_frame_size = 2**int(np.log2(adjusted_frame_size)) # coeerces to the nearest power of 2
    adjusted_hop_size = int(adjusted_frame_size / 2)


    # Analyzing tempo
    tempo = librosa.feature.tempo(y=y, sr=sr, max_tempo=220.0)
    tempogram = trunc(librosa.feature.tempogram(y=y, sr=sr), decs=sig_digits)
    tempogram_ratio = librosa.feature.tempogram_ratio(tg=tempogram, sr=sr)
    avg_tempogram_ratio = np.mean(np.array(tempogram_ratio), axis=1)

    avg_tempo = bpm_from_filename(filepath) or tempo.tolist()[0]

    print('a',end='')

    # Computing the RMS and spectral properties.
    print('\tComputing RMS and spectral properties',adjusted_frame_size, adjusted_hop_size)
    rms = trunc(librosa.feature.rms(y=y, frame_length=adjusted_frame_size, hop_length=adjusted_hop_size), decs=sig_digits)
    avg_rms = np.mean(np.array(rms), axis=1)[0]
    spectral_centroids = trunc(librosa.feature.spectral_centroid(y=y, sr=sr, n_fft=adjusted_frame_size, hop_length=adjusted_hop_size), decs=sig_digits)
    spectral_contrast = trunc(librosa.feature.spectral_contrast(y=y, n_fft=adjusted_frame_size, hop_length=adjusted_hop_size), decs=sig_digits)
    spectral_flatness = trunc(librosa.feature.spectral_flatness(y=y, n_fft=adjusted_frame_size, hop_length=adjusted_hop_size), decs=sig_digits)

    # Cepstrum analysis - useful for pitch tracking and harmonic analysis
    print('\tComputing cepstrum')
    D = librosa.stft(y, n_fft=adjusted_frame_size, hop_length=adjusted_hop_size)
    S_mag = np.abs(D)
    cepstral_features = []
    for frame in range(S_mag.shape[1]):
        spectrum = S_mag[:, frame]
        log_spectrum = np.log(spectrum + 1e-10)
        cepstrum = np.real(np.fft.ifft(log_spectrum))
        cepstrum = cepstrum[:len(cepstrum)//2]
        cepstral_features.append(cepstrum)
    cepstral_features = np.array(cepstral_features).T
    cepstral_coefficients = trunc(cepstral_features, decs=sig_digits)

    # Chroma feature extraction.
    chroma = trunc(librosa.feature.chroma_stft(y=y, sr=sr, n_fft=adjusted_frame_size, hop_length=adjusted_hop_size), decs=sig_digits)
    chroma_cens = trunc(librosa.feature.chroma_cens(y=y, sr=sr), decs=sig_digits)

    # Onset detection
    sr_factor = 44100.0 / sr
    try:
        onset_rate = OnsetRate() 
        wronsets, onset_rate_value  = onset_rate(y)
    except Exception as e:
        print(f"\tError running OnsetRate: {e}")
        return None
    onsets = [onset + 0.005 for onset in wronsets]
    corrected_onsets = [onset * sr_factor for onset in onsets]
    print(f'\tCorrected onsets: {np.around(corrected_onsets, 3)}')

    # Beats Loudness analysis
    beats_loudness_algo = BeatsLoudness(beatDuration=0.07, 
                                        beatWindowDuration=0.11, 
                                        frequencyBands=[60, 160, 1600, 9000], 
                                        sampleRate=sr,
                                        beats=corrected_onsets)
    loudness, loudness_band_ratio = beats_loudness_algo.compute(y)
    beat_loudness = list(loudness)
    beat_bands = [list(band) for band in loudness_band_ratio]
    max_band_powers = [max(band) for band in zip(*beat_bands)] if beat_bands else []
    onset_infos = []
    if len(corrected_onsets) != len(beat_loudness) or len(corrected_onsets) != len(beat_bands):
        print_colorfully("\tMismatch in list lengths: corrected_onsets, beat_loudness, beat_bands",len(corrected_onsets), len(beat_loudness), len(beat_bands), color='red')
    
    loudness_threshold_orig = 0.53
    max_band_power_threshold_orig = 0.25
    min_loudness_threshold = 0.10
    min_max_band_power_threshold = 0.05

    for onset, loudness_val, bands in zip(corrected_onsets, beat_loudness, beat_bands):
        if onset < 0.04: onset = 0  
        band_bools = [0] * len(bands)
        loudness_threshold = loudness_threshold_orig
        max_band_power_threshold = max_band_power_threshold_orig
        
        while not any(band_bools) and (loudness_threshold > min_loudness_threshold) and (max_band_power_threshold > min_max_band_power_threshold):
            band_bools = [int(band_loudness > loudness_val * loudness_threshold and band_loudness > max_band_power * max_band_power_threshold) 
                        for band_loudness, max_band_power in zip(bands, max_band_powers)]
            if not any(band_bools):
                loudness_threshold -= loudness_threshold * 0.15
                max_band_power_threshold -= max_band_power_threshold * 0.15

        ting = {'onset': round(onset, 4), 'loudness': round(loudness_val, 5), 'bands': bands, 'band_bools': band_bools}
        onset_infos.append(ting)

    print(f'\tOnset infos length: {len(onset_infos)}')
    for info in onset_infos:
        for key, value in info.items():
            if isinstance(value, np.ndarray): info[key] = value.tolist()
            elif isinstance(value, (np.float32, np.float64)): info[key] = round(float(value), sig_digits)
            elif key == 'bands': info[key] = [round(float(v), sig_digits) for v in value]

    all_onsets = np.array([onset_info['onset'] for onset_info in onset_infos])
    avg_swing_8th, std_swing_8th, avg_offset_quarter, std_offset_quarter, avg_swing_16th, std_swing_16th, weak_8th_count, weak_16th_count = calculate_swing(all_onsets, avg_tempo)
    kickiness = estimate_kickiness(y, sr)
    
    print_colorfully(avg_rms, color='yellow')
    pitch_salience_weighted_rms = (get_pitch_salience_weighted_rms(y, sr) / avg_rms) * 100 
    print('\tpitch_salience_weighted_rms', pitch_salience_weighted_rms)

    # Chroma filter, harmonic extraction, and smoothing.
    chroma_orig = librosa.feature.chroma_cqt(y=y, sr=sr,  hop_length=adjusted_hop_size)
    y_harm = librosa.effects.harmonic(y=y, margin=8)
    chroma_harm = librosa.feature.chroma_cqt(y=y_harm, sr=sr, hop_length=adjusted_hop_size)
    chroma_filter = np.minimum(chroma_harm, librosa.decompose.nn_filter(chroma_harm, aggregate=np.median, metric='cosine'))
    chroma_smooth = scipy.ndimage.median_filter(chroma_filter, size=(1, 9))
    hsl_list = chroma_to_list(chroma_smooth, sig_digits)
    print('\tchroma_harm', np.mean(chroma_harm))

    # Autocorrelation
    autocorr_frame_size = adjusted_frame_size * 20
    autocorr_hop_size = adjusted_hop_size * 20 * 4
    if len(y) >= autocorr_frame_size:
        frames = librosa.util.frame(y, frame_length=autocorr_frame_size, hop_length=autocorr_hop_size)
        autocorr = [autocorrelation(frame) for frame in frames.T]
    else:
        autocorr = [(0,0.001)]  
    autocorr_periods = [int(v[0]) for v in autocorr]
    autocorr_strengths = [float(v[1]) for v in autocorr]

    # --- NEW ESSENTIA ANALYSES ---
    print("\tComputing new Essentia features...")
    y_essentia = e_array(y) # Convert to essentia's array type

    # 1. MFCC (Mel-Frequency Cepstral Coefficients) - Frame-based processing
    try:
        windowing = ess.Windowing(type='hann')
        spectrum = ess.Spectrum()
        mfcc_algo = ess.MFCC()
        
        mfcc_frames = []
        for frame in ess.FrameGenerator(y_essentia, frameSize=adjusted_frame_size, hopSize=adjusted_hop_size):
            windowed_frame = windowing(frame)
            spectrum_frame = spectrum(windowed_frame)
            mfcc_frame, _ = mfcc_algo(spectrum_frame)
            mfcc_frames.append(mfcc_frame)
        
        if mfcc_frames:
            mfccs = np.array(mfcc_frames).T  # Shape: (n_coeffs, n_frames)
        else:
            mfccs = np.zeros((13, 1))  # Default 13 MFCC coefficients
            
    except Exception as e:
        print(f"\tMFCC analysis failed: {e}, using zeros")
        mfccs = np.zeros((13, 1))
    
    # 2. Spectral Rolloff - Frame-based processing
    try:
        rolloff_algo = ess.RollOff()
        rolloff_frames = []
        for frame in ess.FrameGenerator(y_essentia, frameSize=adjusted_frame_size, hopSize=adjusted_hop_size):
            windowed_frame = windowing(frame)
            spectrum_frame = spectrum(windowed_frame)
            rolloff_frame = rolloff_algo(spectrum_frame)
            rolloff_frames.append(rolloff_frame)
        
        if rolloff_frames:
            spectral_rolloff = np.array(rolloff_frames)
        else:
            spectral_rolloff = np.array([0.0])
            
    except Exception as e:
        print(f"\tSpectral rolloff analysis failed: {e}, using zeros")
        spectral_rolloff = np.array([0.0])

    # 3. Zero Crossing Rate - Frame-based processing
    try:
        zcr_algo = ess.ZeroCrossingRate()
        zcr_frames = []
        for frame in ess.FrameGenerator(y_essentia, frameSize=adjusted_frame_size, hopSize=adjusted_hop_size):
            zcr_frame = zcr_algo(frame)
            zcr_frames.append(zcr_frame)
        
        if zcr_frames:
            zero_crossing_rate = np.array(zcr_frames)
        else:
            zero_crossing_rate = np.array([0.0])
            
    except Exception as e:
        print(f"\tZero crossing rate analysis failed: {e}, using zeros")
        zero_crossing_rate = np.array([0.0])

    # 4. HPCP (Harmonic Pitch Class Profile) - For Essentia 2.1b6.dev1389
    try:
        # For this specific beta version, try the spectral peaks approach
        windowing = ess.Windowing(type='hann')
        spectrum = ess.Spectrum()
        spectral_peaks = ess.SpectralPeaks(orderBy="magnitude", magnitudeThreshold=0.00001, minFrequency=20, maxFrequency=3500, maxPeaks=60)
        hpcp_algo = ess.HPCP()
        
        frame_size = 2048
        hop_size = 1024
        hpcp_values = []
        
        for frame in ess.FrameGenerator(e_array(y_harm), frameSize=frame_size, hopSize=hop_size):
            windowed_frame = windowing(frame)
            spectrum_frame = spectrum(windowed_frame)
            frequencies, magnitudes = spectral_peaks(spectrum_frame)
            
            if len(frequencies) > 0:
                try:
                    hpcp_frame = hpcp_algo(frequencies, magnitudes)
                    hpcp_values.append(hpcp_frame)
                except Exception as inner_e:
                    # If 2-arg fails, try 1-arg (spectrum only)
                    try:
                        hpcp_frame = hpcp_algo(spectrum_frame)
                        hpcp_values.append(hpcp_frame)
                    except:
                        continue
        
        if hpcp_values:
            hpcp = np.mean(hpcp_values, axis=0)
            print(f"\tHPCP analysis completed with {len(hpcp_values)} frames")
        else:
            hpcp = np.zeros(12)  # Standard HPCP size
            print("\tHPCP analysis: no valid frames found")
        
    except Exception as e:
        print(f"\tHPCP analysis failed: {e}, using zeros")
        hpcp = np.zeros(12)

    # 5. EBU R 128 Loudness (Integrated/Average only)
    try:
        # LoudnessEBUR128 expects VECTOR_STEREOSAMPLE: a (n_samples, 2) float32
        # numpy array passed directly. Do NOT wrap in essentia.array (that yields
        # a MATRIX_REAL, which the algorithm refuses to convert).
        if y.ndim == 1:
            # Convert mono to stereo by duplicating the channel -> (n, 2)
            y_stereo = np.column_stack((y, y))
        else:
            # librosa.load(mono=False) returns (channels, n); we need (n, 2)
            y_stereo = y.T if y.shape[0] == 2 else y

        y_stereo = np.ascontiguousarray(y_stereo, dtype=np.float32)
        loudness_ebur_algo = ess.LoudnessEBUR128()
        # Outputs: momentaryLoudness, shortTermLoudness, integratedLoudness, loudnessRange
        _, _, integrated_loudness, _ = loudness_ebur_algo(y_stereo)
        integrated_loudness = float(integrated_loudness)
        print(f"\tIntegrated Loudness (EBU R 128): {integrated_loudness:.{sig_digits}f} LUFS")
        
    except Exception as e:
        print(f"\tEBU R 128 Loudness analysis failed: {e}, using default value")
        integrated_loudness = -23.0  # Default LUFS value
    # --- END OF NEW ANALYSES ---

    # Formatting for output
    formatted_chroma = [[round(float(value), 2) for value in frame] for frame in zip(*chroma)]
    
    result = {
        'file': filepath,
        'modified_date': modified_date,
        'duration': round(float(duration), sig_digits),
        'adjusted_hop_size': adjusted_hop_size,
        'adjusted_frame_size': adjusted_frame_size,
        'sample_rate': sr,
        'onset_infos': onset_infos,
        'pitch_salience': round(float(pitch_salience_weighted_rms), sig_digits),
        'kickiness': round(float(kickiness), sig_digits),
        'bpm_est': round(bpm_override or float(tempo.tolist()[0]), sig_digits),
        'rms': [round(float(v), sig_digits) for v in rms.tolist()[0]],
        'avg_swing_8th': round(float(avg_swing_8th), sig_digits),
        'avg_swing_16th': round(float(avg_swing_16th), sig_digits),
        'std_swing_8th': round(float(std_swing_8th), 6),
        'std_swing_16th': round(float(std_swing_16th), 6),
        'avg_offset_quarter': round(float(avg_offset_quarter), 6),
        'std_offset_quarter': round(float(std_offset_quarter), 6),
        'weak_8th_count': round(float(weak_8th_count), 6),
        'weak_16th_count': round(float(weak_16th_count), 6),
        'avg_tempogram_ratio': avg_tempogram_ratio.tolist(),
        'spectral_centroids': [round(float(v), sig_digits) for v in spectral_centroids.tolist()[0]],
        'spectral_contrast': [round(float(v), sig_digits) for v in spectral_contrast.tolist()[0]],
        'spectral_flatness': [round(float(v), sig_digits) for v in spectral_flatness.tolist()[0]],
        'chroma':  formatted_chroma,
        'chroma_cens': [[round(float(v), sig_digits) for v in frame] for frame in zip(*chroma_cens.tolist())],
        'chroma_smooth': hsl_list,
        'cepstral_coefficients': [[round(float(v), sig_digits) for v in frame] for frame in cepstral_coefficients.tolist()],
        'onset_times': [round(float(v), sig_digits) for v in all_onsets.tolist()],
        'autocorrelation_periods': autocorr_periods,
        'autocorrelation_strengths': autocorr_strengths,
        
        # New Feature Results
        'mfcc': [[round(float(v), sig_digits) for v in frame] for frame in mfccs.T.tolist()],
        'spectral_rolloff': [round(float(v), sig_digits) for v in spectral_rolloff.tolist()],
        'zero_crossing_rate': [round(float(v), sig_digits) for v in zero_crossing_rate.tolist()],
        'hpcp': [round(float(v), sig_digits) for v in hpcp.tolist()] if hpcp.ndim == 1 else [[round(float(v), sig_digits) for v in frame] for frame in hpcp.T.tolist()],
        'integrated_loudness_ebur128': round(float(integrated_loudness), sig_digits),
      }
    return result


def analyze_file_quick(filepath):
    """Quick analysis that only computes RMS."""
    print("--- RUNNING QUICK ANALYSIS ---")
    print(f'analyze_file_quick file: {filepath}')

    # Get the file creation date
    stat = os.stat(filepath)
    modified_date = time.ctime(stat.st_mtime)

    try:
        y, sr = librosa.load(filepath, mono=False)
    except Exception as e:
        print(f"\tError loading file {filepath}: {e}")
        return None

    # Some files arrive with non-finite samples (inf/NaN), which blow up
    # downstream features (e.g. tempogram: "Input must be finite", and
    # "overflow encountered in square"). Replace them with zeros up front.
    if not np.all(np.isfinite(y)):
        bad = int(np.count_nonzero(~np.isfinite(y)))
        print(f"\tWarning: {bad} non-finite sample(s) found; zeroing them.")
        y = np.nan_to_num(y, nan=0.0, posinf=0.0, neginf=0.0)

    # Other files are finite but wildly out of range -- e.g. an unstable
    # low-pass filter that rang up to ~1e29. librosa runs in float32, where
    # squaring such values overflows to inf, surfacing as "overflow encountered
    # in square" and then "Input must be finite". The isfinite check above
    # cannot catch these (they are finite, just enormous), so check the peak:
    # audio is nominally in [-1, 1], so a peak past MAX_ABS_SAMPLE means the
    # file is corrupt. Raise here; process_audio_file's except logs one clean
    # skip line, and we bail before librosa ever squares the bad samples.
    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if peak > MAX_ABS_SAMPLE:
        n_bad = int(np.count_nonzero(np.abs(y) > MAX_ABS_SAMPLE))
        raise ValueError(
            f"out-of-range samples (peak {peak:.2e}, {n_bad} > {MAX_ABS_SAMPLE:g}); "
            f"likely corrupt float WAV (unstable filter?)"
        )

    # Getting the duration of the audio file
    duration = librosa.get_duration(y=y, sr=sr)
    print(f'\tDuration: {duration}')

    # Checking if the audio is mono, stereo or multi-channel
    if y.ndim == 1:
        print("\tThis is a mono signal.")
    elif y.ndim == 2 and y.shape[0] == 2:
        print("\tThis is a stereo signal.")
        # Convert stereo to mono for further analysis
        y = librosa.to_mono(y)
    else:
        print("\tThis is a multi-channel file, and we're not equipped to handle it.")
        return None

    if duration < 0.1:
        print("\tFile is too short for analysis. Using default values.")
        return {
            'file': filepath, 'modified_date': modified_date, 'duration': 0.0,
            'sample_rate': sr, 'rms': []
        }

    # Adjust frame sizes for short files
    frame_size = 2048
    adjusted_frame_size = min(frame_size, int(sr * duration / 10))
    adjusted_frame_size = 2**int(np.log2(adjusted_frame_size))
    adjusted_hop_size = int(adjusted_frame_size / 2)

    # Computing the RMS
    print('\tComputing RMS', adjusted_frame_size, adjusted_hop_size)
    rms = trunc(librosa.feature.rms(y=y, frame_length=adjusted_frame_size, hop_length=adjusted_hop_size), decs=sig_digits)

    result = {
        'file': filepath,
        'modified_date': modified_date,
        'duration': round(float(duration), sig_digits),
        'sample_rate': sr,
        'rms': [round(float(v), sig_digits) for v in rms.tolist()[0]],
    }
    return result


def mono_to_stereo(y):
  """Converts a mono signal to stereo."""
  y_stereo = np.zeros((2, len(y)))
  y_stereo[0] = y
  y_stereo[1] = y
  return y_stereo

def get_loudness(y, sr):
  """Calculates the overall loudness of an audio file in dB."""
  loudness = Loudness()
  loudness_data = loudness(y)
  return loudness_data

def get_pitch_salience_weighted_rms(y, sr, window_size=512, hop_size=256):
  """Calculates the pitch salience weighted RMS on a frame-by-frame basis using a Hamming window."""
  window = ess.Windowing(type='hamming', size=window_size)
  pitch_salience = PitchSalience()
  pitch_salience_weighted_rms = []
  print('\tlen(y)', len(y), hop_size, window_size)
  for i in range(0, len(y) - window_size, hop_size):
    frame = y[i:i + window_size]
    frame = window(frame)
    pitch_salience_data = pitch_salience(frame)
    rms_val = np.sqrt(np.mean(frame**2))
    pitch_salience_weighted_rms.append(pitch_salience_data * rms_val)
  mean_pitch_salience_weighted_rms = np.mean(pitch_salience_weighted_rms) if pitch_salience_weighted_rms else 0
  print('\tmean_pitch_salience_weighted_rms',mean_pitch_salience_weighted_rms)
  return mean_pitch_salience_weighted_rms


# Converts chroma_smooth to a list of hsl tuples
def chroma_to_list(chroma_smooth, sig_digits):
    hsl_list = []
    swapped_chroma = list(zip(*chroma_smooth))
    for chroma_vector in swapped_chroma:
        strongest_bin_index = np.argmax(chroma_vector)
        delta = np.max(chroma_vector) - np.min(chroma_vector)
        saturation = delta
        lightness = np.max(chroma_vector)
        hue = strongest_bin_index * (360 / len(chroma_vector))
        hsl_tuple = [round(float(v), sig_digits) for v in [hue,saturation,lightness]]
        hsl_list.append(hsl_tuple)
    return hsl_list


def align_onsets(onsets_dict, tolerance_window):
    """Aligns close onsets across an arbitrary number of arrays of onsets."""
    aligned_onsets_dict = {}
    all_onsets = np.sort(np.concatenate(list(onsets_dict.values())))
    unique_aligned_onsets = []
    for onset in all_onsets:
        close_onsets_by_band = {band: onsets[np.abs(onsets - onset) <= tolerance_window] for band, onsets in onsets_dict.items()}
        close_onsets_all_bands = np.concatenate(list(close_onsets_by_band.values()))
        if len(close_onsets_all_bands) > 0:
            aligned_onset = np.mean(close_onsets_all_bands)
            unique_aligned_onsets.append(aligned_onset)
    unique_aligned_onsets = np.unique(np.array(unique_aligned_onsets))
    for band, onsets in onsets_dict.items():
        new_onsets = []
        for onset in onsets:
            aligned_onset = min(unique_aligned_onsets, key=lambda x: abs(x - onset), default=None)
            if aligned_onset is not None and abs(aligned_onset - onset) <= tolerance_window:
                new_onsets.append(aligned_onset)
            else:
                new_onsets.append(onset)
        aligned_onsets_dict[band] = np.array(new_onsets)
    return aligned_onsets_dict

def print_colorfully(*args, color='white', **kwargs):
    color_codes = {
        'red': '\033[91m', 'green': '\033[92m', 'yellow': '\033[93m',
        'blue': '\033[94m', 'magenta': '\033[95m', 'cyan': '\033[96m',
        'white': '\033[97m', 'gray': '\033[90m'
    }
    color_code = color_codes.get(color, '\033[97m')
    #print(f"{color_code}", end='')
    print(*args, **kwargs)
    #print("\033[0m", end='')

def process_wav_file(filename, filepath, yaml_filepath, n, bpm_override=None):
    print_colorfully(filepath, color='cyan')
    result = analyze_file(filepath, bpm_override)
    if result is not None:
        with open(yaml_filepath, 'w') as outfile:
            yaml.dump(result, outfile)
    else:
        print_colorfully(f"Failed to analyze {filepath}", color='red')

def analyze_directory_or_file(path, bpm_override=None, quick=False):
    """Handles both directories and single files."""
    if os.path.isdir(path):
        n = 0
        for filename in sorted(os.listdir(path)):
            if filename.endswith(('.wav', '.mp3')):
                n += 1
                filepath = os.path.join(path, filename)
                yaml_filepath = filepath + '.yaml'
                if not os.path.exists(yaml_filepath):
                    process_audio_file(filepath, yaml_filepath, n, bpm_override, quick)
    elif os.path.isfile(path) and path.endswith(('.wav', '.mp3')):
        process_audio_file(path, path + '.yaml', None, bpm_override, quick)
    else:
        print_colorfully(f"Error: Path '{path}' is not a valid file or directory.", color='red')

def process_audio_file(filepath, yaml_filepath, n=None, bpm_override=None, quick=False):
    """Processes a single audio file and saves analysis to YAML."""
    if n:
        print_colorfully(f"\n{n}\t", color='yellow', end='')
    print_colorfully(filepath, color='cyan')
    
    try:
        if quick:
            result = analyze_file_quick(filepath)
        else:
            result = analyze_file(filepath, bpm_override)
    except Exception as e:
        # Some files can't be analyzed (e.g. non-finite / overflowing samples
        # that break librosa mid-computation). Skip them with a warning rather
        # than aborting the whole batch.
        print_colorfully(f"\tWarning: skipping {filepath}: {type(e).__name__}: {e}", color='yellow')
        return

    if result is not None:
        try:
            with open(yaml_filepath, 'w') as outfile:
                yaml.dump(result, outfile)
        except Exception as e:
            print_colorfully(f"\tError saving YAML for {filepath}: {e}", color='red')
    else:
        print_colorfully(f"Failed to analyze {filepath}", color='red')


def main():
    parser = argparse.ArgumentParser(description='Analyze audio files.')
    parser.add_argument('path', type=str, help='Path to a directory or a single audio file')
    parser.add_argument('--bpm', type=float, help='Override the analyzed BPM value')
    parser.add_argument('--quick', action='store_true', help='Quick analysis: compute only RMS')
    args = parser.parse_args()
    analyze_directory_or_file(args.path, bpm_override=args.bpm, quick=args.quick)

if __name__ == '__main__':
    main()