//
//  AudioModel.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/2/24.
//

import Foundation

// Houses all functionality for recording audio signals related to iPhone sound card
class AudioModel {
    
    // MODULE A AND MODULE B PROPERTIES:
    
    var timeSamples: [Float]    /// Sampled audio on time domain
    var fftSamples: [Float]     /// Ssampled audio on frequency domain after FFT
    
    /// Novocaine audio manager for handling sound card input and output
    private lazy var audioManager: Novocaine? = {
        return Novocaine.audioManager()
    }()
    
    /// Used for calculations tied to performing vDSP FFT (input must be power of 2)
    private lazy var fftHelper: FFTHelper? = {
        return FFTHelper.init(fftSize: Int32(AUDIO_SAMPLE_BUFFER_SIZE))
    }()
    
    /// Buffer of audio samples from most recent signal (e.g., most recent microphone input) that will copy to timeSamples array
    private lazy var inputBuffer: CircularBuffer? = {
        return CircularBuffer.init(numChannels: Int64(self.audioManager!.numInputChannels),
                                   andBufferSize: Int64(AUDIO_SAMPLE_BUFFER_SIZE))
    }()
    
    /// Number of time-domain audio samples (i.e., size of timeSamples and circular inputBuffer)
    private var AUDIO_SAMPLE_BUFFER_SIZE: Int
    
    
    // MODULE A PROPERTIES:
    
    /// Stores the two frequencies and magnitudes of the two loudest tones played
    lazy var twoLargestFreqs: [FrequencyMagnitude] = [
        FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity),
        FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity)
    ]
    
    
    // MODULE B PROPERTIES:
    
    /// Inaudible sine wave frequency (17K Hz to 20K Hz) played when recognizing Doppler shifts
    var frequencyModuleB: Float = 17000.0 { /// Frequency in Hz (changeable by user via ModuleBViewController)
        didSet{
            if let manager = self.audioManager {
                /// If using swift for generating the sine wave: when changed, we need to update our increment
                phaseIncrementModuleB = Float(2*Double.pi*Double(frequencyModuleB) / manager.samplingRate)
            }
        }
    }
    
    /// Default volume of sine wave played at frequencyModuleB
    var volumeThousandsModuleB: Float = 0.5
    
    var zoomedFftMidIndexDb: Float = 0.0        /// Magnitude of sine wave played at frequencyModuleB
    var zoomedFftSubArray: [Float]              /// Subarray of fftSamples array ultimately centered at frequencyModuleB
    var dopplerGesture: DopplerGesture = .none  /// Indicates if hand moving toward, moving away from, or not moving relative to played sine wave
    
    private var phaseModuleB: Float = 0.0                       /// Phase of sine wave played at frequencyModuleB
    private var phaseIncrementModuleB: Float = 0.0              /// Phase increment of sine wave played at frequencyModuleB
    private var sineWaveRepeatMax:Float = Float(2*Double.pi)    /// Helps prevent overflow after numerous phase incremenets to frequencyModuleB sine wave
    
    /// Used for recording the last ten frequencies and volumes associated with played sine wave
    /// Helps ensure stability when recognizing doppler shifts (e.g., no doppler shift gestures recognized when changing frequencyMouleB)
    private var rollingFreqVolIndex: Int = 0
    private var lastTenFrequencies: [Float]?
    
    /// Used for establishing FFT noise baseline for determining Doppler shifts through relative comparisons
    private var rollingFftIndex: Int = 0
    private var lastTenFftAverages: [Float]?
    private var currentRollingFftAverage: [Float]?  // Replaces lastTenFftAverages after 10 averages
    
    /// Used for ensuring FFT data is positive for Doppler shift frequency bin comparisons
    private var bias: Float = 110.0
    
    // Used to adjusts inherent skewness between high and low frequency bins to allow for fair or level Doppler shift comparisons
    private var coreThresholdValues: [Float] = Array.init(repeating: 0.0, count: 10)
    private var coreThresholddAverageNum: Int = 0   // Amount of frames of high-low frequency ratios averaged into coreThreshold
    private var coreThresholdMean: Float = 0
    private var coreThresholdDeviation: Float = 0
    
    
    // INITIALIZATION:
    
    init(buffer_size: Int) {
        self.AUDIO_SAMPLE_BUFFER_SIZE = buffer_size
        timeSamples = Array.init(repeating: 0.0, count: self.AUDIO_SAMPLE_BUFFER_SIZE)
        fftSamples = Array.init(repeating: 0.0, count: self.AUDIO_SAMPLE_BUFFER_SIZE / 2)
        
        /// Simply sets the zoomed FFT subarray for Module B to be the same as the largest fftSamples array to start by default
        zoomedFftSubArray = fftSamples
    }
    
    
    // MODULE A AND B METHODS:
    
    /// Allows Novocaine audio manager to start processing audio
    func play(){
        if let manager = self.audioManager{
            manager.play()
        }
    }
    
    /// Ends Novocaine audio manager's audio processing
    func stop() {
        if let manager = self.audioManager{
            manager.pause()
            manager.inputBlock = nil
            manager.outputBlock = nil
        }
        
        if let buffer = self.inputBuffer {
            buffer.clear() // Just makes zeros
        }
        
        inputBuffer = nil
        fftHelper = nil
    }
    
    // Public function for starting processing of microphone data
    func startMicrophoneProcessingModuleA(withFps: Double) {
        // setup the microphone to copy to circualr buffer
        if let manager = self.audioManager {
            manager.inputBlock = self.handleMicrophone
            
            /// Repeat this fps times per second using the timer class
            /// Every time this is called, we update the arrays "timeSamples" and "fftSamples"
            Timer.scheduledTimer(withTimeInterval: 1.0 / withFps, repeats: true) { _ in
                self.runEveryIntervalModuleA()
            }
        }
    }
    
    /// Fills circular inputBuffer and timeSamples with time-domain audio samples from recent signal
    private func handleMicrophone (data: Optional<UnsafeMutablePointer<Float>>, numFrames: UInt32, numChannels: UInt32) {
        /// Copy samples from the microphone into circular buffer
        self.inputBuffer?.addNewFloatData(data, withNumSamples: Int64(numFrames))
    }
    
    
    // MODULE A METHODS:
    
    /// Records time-domain audio samples from mic, performs FFT, and indicates if two loudest tones are not silent (i.e., above 0 dB threshold)
    private func runEveryIntervalModuleA(){
        if self.inputBuffer != nil {
            /// Copy time data to swift array
            self.inputBuffer!.fetchFreshData(&self.timeSamples, // copied into this array
                                             withNumSamples: Int64(self.AUDIO_SAMPLE_BUFFER_SIZE))
            
            /// Now take FFT
            self.fftHelper!.performForwardFFT(withData: &self.timeSamples,
                                         andCopydBMagnitudeToBuffer: &self.fftSamples) /// FFT result is copied into fftSamples array
            
            let peakFreqs: [FrequencyMagnitude] = self.findTwoLargestFreqs(freqDist: 50)
            
            if peakFreqs[0].magnitude > 0 {
                self.twoLargestFreqs[0] = peakFreqs[0]
            }
            
            if peakFreqs[1].magnitude > 0 {
                self.twoLargestFreqs[1] = peakFreqs[1]
            }
        }
    }
    
    /// Utilizes peak finding and interpolation to retrieve frequencies of the two loudest tones at least 'freqDist' (e.g., 50 Hz) apart for Module A
    private func findTwoLargestFreqs(freqDist: Int) -> [FrequencyMagnitude] {
   
        /// Simply allow program to fail if this function is utilized without audio manager instantiated for pulling sampling rate
        guard let samplingRate = self.audioManager?.samplingRate else {
            fatalError("Audio manager not initialized for pulling sampling rate to peak find")
        }
        
        /// Converts desired frequency distance (e.g., 50 Hz) to distance in number of points or indices for sliding window max
        /// A floored number of points will ensure desired frequency distance is captured via slightly finer resolution differences
        let windowSizePts: Int = Int(Double(freqDist) * Double(self.AUDIO_SAMPLE_BUFFER_SIZE) / samplingRate)
        
        /// Assumes for purposes of lab that sliding window will have greater than 3 elements but this assumption may not be best for production setting
        /// Above assumption likely to hold given tones played will be 50Hz apart, 200ms or more, and need +- 3 Hz accuracy for frequency resolution
        /// Could alternatively for window sizes of 1 or 2 collect all potential peaks in separate array and find maximum elements from that array
        /// Will investigate further and implement the above solution if time
        guard windowSizePts >= 3 else {
            fatalError("Peak finding less accurate and interpolation via quadratic approximation not possible without sliding window of 3 elements")
        }
                
        /// Starting index of the final sliding window
        let finalWindowStartIndex: Int = fftSamples.count - windowSizePts
        
        /// Instantiate variables needed for vDSP_maxvi(_:_:_:_:_:)
        let n = vDSP_Length(windowSizePts)
        let stride = vDSP_Stride(1)
        var magnitudePeak: Float = .nan
        var windowIndexPeak: Int = -1
        
        /// Keep track of the top two frequencies and their associated magnitudes
        var maxFreqMags: [FrequencyMagnitude] = [
            FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity),
            FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity)
        ]
        
        /// Ensures same indices are not identified as peaks across different sliding windows
        /// Especially good for when window size is even
        /// e.g., when index 2 happens to be the max in both consecutive windows (0, 1, 2, 3) and (1, 2, 3, 4)
        var previousPeakIndices = Set<Int>()
        
        /// Start at index 1 since index 0 of fftSamples represents DC
        for i in 1...finalWindowStartIndex {
            vDSP_maxvi(&self.fftSamples + i, stride, &magnitudePeak, &windowIndexPeak, n)
            
            /// Calculate the index of peak in terms of overall fftSamples array (i.e., rather than current window)
            let absoluteIndexPeak = windowIndexPeak + i
            
            /// Final index position in current window of windowSizePts elements
            let currWindowEndIndex: Int = i + windowSizePts - 1
            
            /// Ensures that a potential peak at least has two neighbors within the current window
            /// Assumes that a peak or max will not be at fftSamples index 1
            /// The above assumptions is made because give the lab constraints fftSamples index 1 would not be an audible frequency
            if (absoluteIndexPeak - 1) >= i && (absoluteIndexPeak + 1) <= currWindowEndIndex {
                if !previousPeakIndices.contains(absoluteIndexPeak) {
                    let interpolatedPeakFreqMag: FrequencyMagnitude = interpolateMax(maxIndex: absoluteIndexPeak)
                    previousPeakIndices.insert(absoluteIndexPeak)
                    
                    if interpolatedPeakFreqMag.magnitude > maxFreqMags[0].magnitude {
                        maxFreqMags[1] = maxFreqMags[0]
                        maxFreqMags[0] = interpolatedPeakFreqMag
                    } else if interpolatedPeakFreqMag.magnitude > maxFreqMags[1].magnitude {
                        maxFreqMags[1] = interpolatedPeakFreqMag
                    }
                }
            }
        }
        return maxFreqMags
    }
    
    /// Takes the index of a sample peak from the fftSamples array and uses quadratic interpolation to find a better estimated peak frequency and magnitude
    /// Quadratic Approximation: https://www.dsprelated.com/freebooks/sasp/Quadratic_Interpolation_Spectral_Peaks.html
    private func interpolateMax(maxIndex: Int) -> FrequencyMagnitude {
        
        /// Simply allow program to fail if this function is utilized without audio manager instantiated for pulling sampling rate
        guard let samplingRate = self.audioManager?.samplingRate else {
            fatalError("Audio manager not initialized for pulling sampling rate to interpolate max")
        }
        
        /// Calculate frequency resolution  -> (sampling rate / 2) / (audio sample buffer size / 2) = sampling rate / audio sample buffer size
        let deltaF: Float = Float(samplingRate) / Float(self.AUDIO_SAMPLE_BUFFER_SIZE)
        
        /// Calculate frequency value of sample peak index
        let fTwo: Float = Float(maxIndex) * deltaF
        
        /// Find necessary magnitudes (i.e., amplitudes) for quadratic approximation
        let mOne: Float = self.fftSamples[maxIndex - 1]
        let mTwo: Float = self.fftSamples[maxIndex]
        let mThree: Float = self.fftSamples[maxIndex + 1]
        
        /// Estimate interpolated peak location
        let peakPosition: Float = 0.5 * (mOne - mThree) / (mOne - 2 * mTwo + mThree)
        
        /// Estimate interpolated frequency estimate
        let freqEstimate: Float = fTwo + peakPosition * deltaF
        
        /// Estimate magnitude (i.e., amplitude) at interpolated frequency
        let magnitudeEstimate: Float = mTwo - 0.25 * (mOne - mThree) * peakPosition
        
        return FrequencyMagnitude(frequency: freqEstimate, magnitude: magnitudeEstimate)
    }
    
    
    // MODULE B METHODS:
    
    /// Public function for starting processing of microphone data and output of sine wave
    func startAudioIoProcessingModuleB(withFps: Double, withSineFreq: Float) {
        self.frequencyModuleB = withSineFreq
        
        /// Allows Doppler shifts to be recognized from starting sine wave frequency and volume parameters
        /// Doppler shifts only recognized when frequency and volume have not changed for past 10 frames
        /// Prevents scenario where changes in sine wave frequency or volume are registered as Doppler shifts
        lastTenFrequencies = Array.init(repeating: self.frequencyModuleB, count: 10)
        
        /// Setup the microphone to copy to circualr buffer
        if let manager = self.audioManager {
            manager.inputBlock = self.handleMicrophone
            manager.outputBlock = self.handleSpeakerQueryWithSinusoid
            
            /// Repeat this fps times per second using the timer class
            /// Every time this is called, we update the arrays "timeSamples" and "fftSamples"
            Timer.scheduledTimer(withTimeInterval: 1.0/withFps, repeats: true) { _ in
                self.runEveryIntervalModuleB()
            }
        }
    }
    
    /// Functionality used for outputting sine wave to speaker
    private func handleSpeakerQueryWithSinusoid(data:Optional<UnsafeMutablePointer<Float>>, numFrames:UInt32, numChannels: UInt32) {
            if let arrayData = data{
                var i = 0
                let chan = Int(numChannels)
                let frame = Int(numFrames)
                if chan==1{
                    while i<frame{
                        arrayData[i] = sin(phaseModuleB)
                        phaseModuleB += phaseIncrementModuleB
                        if (phaseModuleB >= sineWaveRepeatMax) { phaseModuleB -= sineWaveRepeatMax }
                        i+=1
                    }
                } else if chan==2{
                    let len = frame*chan
                    while i<len{
                        arrayData[i] = sin(phaseModuleB)
                        arrayData[i+1] = arrayData[i]
                        phaseModuleB += phaseIncrementModuleB
                        if (phaseModuleB >= sineWaveRepeatMax) { phaseModuleB -= sineWaveRepeatMax }
                        i+=2
                    }
                }
                
                /// Adjust volume of audio file output
                vDSP_vsmul(arrayData, 1, &(self.volumeThousandsModuleB), arrayData, 1, vDSP_Length(numFrames*numChannels))
            }
        }
    
    /// Records time-domain audio samples from mic, performs FFT, zooms FFT array on chosen frequencyModuleB, and tracks Doppler shift gestures
    private func runEveryIntervalModuleB(){
        if self.inputBuffer != nil {
            /// Copy time data to swift array
            self.inputBuffer!.fetchFreshData(&self.timeSamples, // copied into this array
                                             withNumSamples: Int64(self.AUDIO_SAMPLE_BUFFER_SIZE))
            
            /// Now take FFT
            self.fftHelper!.performForwardFFT(withData: &self.timeSamples,
                                         andCopydBMagnitudeToBuffer: &self.fftSamples) /// FFT result is copied into fftSamples array
            
            /// Add currently set volume and sine wave frequency to respective arrays of past 10 data points
            /// Only start looking for Doppler shifts if freq and volume have not changed during the past 10 frames
            /// Prevents scenario where freq and volume changes register as Doppler shifts
            self.lastTenFrequencies![self.rollingFreqVolIndex] = self.frequencyModuleB
            
            self.trackDopplerShift()
            
            /// Circularly update frequency and volume again 10 times
            self.rollingFreqVolIndex += 1
            if self.rollingFreqVolIndex == 10 {
                self.rollingFreqVolIndex = 0
            }
        }
    }
    
    /// Ensures chosen sine wave frequency for Module B remains as the center point of the FFT graph to better see Doppler shift gestures
    private func trackDopplerShift() {
        /// Simply allow program to fail if this function is utilized without audio manager instantiated for pulling sampling rate
        guard let samplingRate = self.audioManager?.samplingRate else {
            fatalError("Audio manager not initialized for pulling sampling rate to interpolate max")
        }
        
        /// Calculates the FFT array index of the chosen frequency of the currently playing sine wave
        let midIndex: Int = Int(Double(self.frequencyModuleB) * Double(AudioConstants.AUDIO_BUFFER_SIZE) / samplingRate) + 1
        
        /// Creates a subarray of FFT array zoomed in and centered on chosen frequency +/- 100 indices for graphical view on frontend
        let numPts = 100
        self.zoomedFftSubArray = Array(self.fftSamples[(midIndex - numPts)...(midIndex + numPts)])
        self.zoomedFftMidIndexDb = self.fftSamples[midIndex]
        
        /// Ensures normalized zoomed FFT array has positive values for Doppler shift frequency bin magnitude ratio comparisons
        if self.rollingFftIndex == 0 {
            let zoomedFftMin = vDSP.minimum(self.zoomedFftSubArray)
            
            if zoomedFftMin < 0 {
                self.bias = -1 * zoomedFftMin
            }
        }
        
        /// Normalized zoomed FFT array for doppler shift calculations
        var normalizedFftArray: [Float] = self.zoomedFftSubArray
        self.normalizeFFTData(&normalizedFftArray, gain: 1.0, bias: self.bias)
        
        /// Averages "range" number of frequency magnitudes both before and after chosen frequency for tracking Doppler shifts
        let range = 4
        var currentAverages: [Float] = [0.0, 0.0]
        vDSP_meanv(&normalizedFftArray + (numPts - range), vDSP_Stride(1), &(currentAverages[0]), vDSP_Length(range))
        vDSP_meanv(&normalizedFftArray + (numPts + 1), vDSP_Stride(1), &(currentAverages[1]), vDSP_Length(range))
        
        /// Do not track Doppler shifts if user has changed chosen sine wave frequency or volume recently
        /// This prevents from sine wave frequency or volume changes registering as Doppler shifts
        if vDSP.mean(self.lastTenFrequencies!) != self.frequencyModuleB {
            /// Reset FFT baseline average 'lastTenFftAverages' for magnitudes and nosie when chosen sine wave frequency or volume changes
            self.lastTenFftAverages = nil
            self.coreThresholdValues = Array.init(repeating: 0.0, count: 10)
            self.coreThresholddAverageNum = 0
            self.currentRollingFftAverage = currentAverages
            self.rollingFftIndex = 1
            self.dopplerGesture = .unavailable
        
        /// Add to current rolling FFT average if there is no 10-point averaged FFT baseline for relative comparisons for Doppler shift determination
        } else if self.lastTenFftAverages == nil {
            self.currentRollingFftAverage = self.currentRollingFftAverage == nil ? currentAverages : vDSP.add(self.currentRollingFftAverage!, currentAverages)
            self.rollingFftIndex += 1
            self.dopplerGesture = .calibrating
        
        /// Compares current-baseline high frequency magnitudes against current-baseline low frequency magnitudes for 10 frames to learn "skewness" threshold
        } else if self.coreThresholddAverageNum < 10 {
            self.coreThresholdValues[self.coreThresholddAverageNum] = (currentAverages[1] / self.lastTenFftAverages![1]) / (currentAverages[0] / self.lastTenFftAverages![0])
            self.coreThresholddAverageNum += 1
            
            /// Calculate mean and standard deviation of the 10 threshold values
            if self.coreThresholddAverageNum == 10 {
                
                let count = self.coreThresholdValues.count
                let n = vDSP_Length(count)

                vDSP_meanv(&self.coreThresholdValues, 1, &self.coreThresholdMean, n)
                
                self.coreThresholdDeviation = vDSP.maximum(self.coreThresholdValues) - vDSP.minimum(self.coreThresholdValues)
            }
            
            self.dopplerGesture = .calibrating
            
        /// Compare current-baseline high frequency magnitude averages to current-baseline low frequency magnitude averages
        /// Ratio of ratios may mitigate some of the effects of noise that both sides experience
        } else {
            let upperThreshold: Float = self.coreThresholdMean + self.coreThresholdDeviation
            let lowerThreshold: Float = self.coreThresholdMean - self.coreThresholdDeviation
            
            let ratioOfRatios = (currentAverages[1] / self.lastTenFftAverages![1]) / (currentAverages[0] / self.lastTenFftAverages![0])
            print("upper:", upperThreshold)
            print("lower:", lowerThreshold)
            print("RofR:", ratioOfRatios)
            
            if ratioOfRatios > upperThreshold {
                self.dopplerGesture = .toward
            } else if ratioOfRatios < lowerThreshold {
                self.dopplerGesture = .away
            } else {
                self.dopplerGesture = .none
            }
            
            if self.dopplerGesture == .none {
                self.currentRollingFftAverage = self.currentRollingFftAverage == nil ? currentAverages : vDSP.add(self.currentRollingFftAverage!, currentAverages)
                self.rollingFftIndex += 1
            }
        }
        
        /// Establish a new baseline for noise comparisons after 10 frames in current rolling average
        if self.rollingFftIndex == 10 {
            self.lastTenFftAverages = vDSP.divide(
                Float(self.rollingFftIndex),
                self.currentRollingFftAverage!
            )
            
            self.currentRollingFftAverage = nil
            self.rollingFftIndex = 0
            
            // Reset and recalculate coreThresholdValues
            self.coreThresholdValues = Array.init(repeating: 0.0, count: 10)
            self.coreThresholddAverageNum = 0
        }
    }
    
    /// Normalizes FFT output magnitude similar to MetalGraph shouldNormalizeForFFT
    /// Utilized because the zoomed and normalized FFT graph shows apparent Doppler shifts that are hard to find in the raw data
    func normalizeFFTData(_ data: inout [Float], gain: Float, bias: Float) {
        var gain: Float = gain
        var bias: Float = bias
        vDSP_vsmsa(data, 1, &gain, &bias, &data, 1, vDSP_Length(data.count))
    }
}
