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
    
    /// For Module exceptional credit recognizing "ooo" and "ahh"
    var lastVowel: VowelSound = .none
    
    /// Stores the two frequencies and magnitudes of the two loudest tones played
    lazy var twoLargestFreqs: [FrequencyMagnitude] = [
        FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity),
        FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity)
    ]
    
    /// Upper and lower decibel threshold for recognizing two loudest tones
    private var upperDecibelThreshold: Float = 5.0
    private var lowerDecibelThreshold: Float = -1
    
    /// Decibel thresholds for recognizing max and second-max freq of vowel sounds
    private var upperVowelDbThreshold: Float = 20.0
    private var lowerVowelDbThreshold: Float = 10.0
    
    
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
    
    var zoomedFftMidIndexDb: Float = 0.0                   /// Magnitude of sine wave played at frequencyModuleB
    var zoomedFftSubArray: [Float]                         /// Subarray of fftSamples array ultimately centered at frequencyModuleB
    var dopplerGesture: DopplerGesture = .calibrating      /// Indicates if hand moving toward, moving away from, or not moving relative to played sine wave
    
    private var phaseModuleB: Float = 0.0                       /// Phase of sine wave played at frequencyModuleB
    private var phaseIncrementModuleB: Float = 0.0              /// Phase increment of sine wave played at frequencyModuleB
    private var sineWaveRepeatMax:Float = Float(2*Double.pi)    /// Helps prevent overflow after numerous phase incremenets to frequencyModuleB sine wave
    
    /// Index of chosen sine wave frequency peak from fftSamples
    private var midIndex: Int = -1
    
    /// Used for establishing FFT noise baseline for determining Doppler shifts through relative comparisons
    private var rollingFftIndex: Int = 0
    private var lastTenFftAverages: [Float]?
    private var currentRollingFftAverage: [Float]?  // Replaces lastTenFftAverages after 10 averages
    
    /// Used for ensuring FFT data is positive for Doppler shift frequency bin comparisons
    private var bias: Float = 110.0
    
    /// Stabilization period after user changes frequency ensures frequency chage not registered as Doppler Shift
    private var previousFrequency: Float = 17000.0      /// Used for recording the previous with played sine wave
    private var isStabilizing: Bool = false
    private var stabilizationCounter: Int = 0
    private let stabilizationThreshold: Int = 30
    
    /// A core threshold value is one sample of the ratio between preceding and subsequent frequency magnitudes relative to played sine wave frequency
    /// Used for learning and "zeroing out" the skewness between both low and high frequency ranges so that Doppler Shifts (i.e., relative increases/decreases) can be determined
    private var coreThresholdValues: [Float] = []
    private let thresholdWindowSize: Int = 30
    private var coreThresholdMean: Float = 0.0
    private var coreThresholdDeviation: Float = 0.0
    private var coreThresholddAverageNum: Int = 0 // Counter for threshold calculation
    
    /// Calibration is a small period of gathering core threshold values before Doppler shift gesture recognition is ready
    private var isCalibrating: Bool = true
    private var calibrationSampleCount: Int = 0
    private let calibrationSampleThreshold: Int = 30
    
    
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
            buffer.clear() /// Just makes zeros
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
            
            if peakFreqs[0].magnitude > self.upperDecibelThreshold  {
                self.twoLargestFreqs[0] = peakFreqs[0]
            }
            
            if peakFreqs[1].magnitude > self.lowerDecibelThreshold {
                self.twoLargestFreqs[1] = peakFreqs[1]
            }
            
  
            if (peakFreqs[0].magnitude > self.upperVowelDbThreshold || peakFreqs[1].magnitude > self.lowerVowelDbThreshold) {
                recognizeVowels(freqOne: peakFreqs[0].frequency, freqTwo: peakFreqs[1].frequency)
            }
        }
    }
    
    /// Recognize common "ooo" and "ahhh" largest and second largest frequency basis
    private func recognizeVowels(freqOne: Float, freqTwo: Float) {
        let maxFreqBase: Int = Int(freqOne) / 100
        let maxFreqTwoBase: Int = Int(freqTwo) / 100
        
        if maxFreqBase != 0 && maxFreqTwoBase != 0 {
            /// Second frequency is seems to be 3 times as large as first frequency for "ooo"
            if maxFreqTwoBase / maxFreqBase == 3 {
                self.lastVowel = .ooo
            } else {
                /// The ratio between first and second frequency with either as denominator seems to bounce around between 5 and 7
                /// This could be related to how second frequency magnitude is demoted to that of the first when a new largest frequency magnitude is discovered
                if (maxFreqBase / maxFreqTwoBase == 7 || maxFreqTwoBase / maxFreqBase == 7) ||
                    (maxFreqBase / maxFreqTwoBase == 5 || maxFreqTwoBase / maxFreqBase == 5) {
                    self.lastVowel = .ahh
                }
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
        
        /// Allows Doppler shifts to be recognized from starting sine wave frequency
        /// Doppler shifts only recognized when frequency and volume have not changed
        /// Prevents scenario where changes in sine wave frequency are  registered as Doppler shifts
        self.previousFrequency = frequencyModuleB
        
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
            
            self.trackDopplerShift()
        }
    }
    
    /// Tracks Doppler shift gestures by processing FFT data and updating thresholds
    private func trackDopplerShift() {
        /// Ensure the audio manager is initialized to get the sampling rate
        guard let samplingRate = self.audioManager?.samplingRate else {
            fatalError("Audio manager not initialized for pulling sampling rate to interpolate max")
        }
        
        /// Check if the sine wave frequency has changed
        if self.frequencyModuleB != self.previousFrequency {
            /// Indicate stabilization so that frequency change not registered as Doppler Shift
            self.isStabilizing = true
            self.stabilizationCounter = 0
            self.dopplerGesture = .unavailable
            self.previousFrequency = self.frequencyModuleB

            /// Update midIndex and other frequency-dependent variables
            let midIndex: Int = Int(Double(self.frequencyModuleB) * Double(AudioConstants.AUDIO_BUFFER_SIZE) / samplingRate) + 1
            self.midIndex = midIndex
        } else if self.midIndex == -1 {
            /// Initialize midIndex if not set to valid index
            let midIndex: Int = Int(Double(self.frequencyModuleB) * Double(AudioConstants.AUDIO_BUFFER_SIZE) / samplingRate) + 1
            self.midIndex = midIndex
        }

        /// Create a subarray of FFT data centered on the chosen frequency
        let numPts = 100
        let fftSamplesCount = self.fftSamples.count
        let startIdx = max(0, midIndex - numPts)
        let endIdx = min(fftSamplesCount - 1, midIndex + numPts)
        self.zoomedFftSubArray = Array(self.fftSamples[startIdx...endIdx])
        self.zoomedFftMidIndexDb = self.fftSamples[midIndex]

        /// Normalize the FFT data to have positive values for ratio calculations
        if self.rollingFftIndex == 0 {
            let zoomedFftMin = vDSP.minimum(self.zoomedFftSubArray)
            self.bias = zoomedFftMin < 0 ? -zoomedFftMin : 0
        }
        var normalizedFftArray: [Float] = self.zoomedFftSubArray
        self.normalizeFFTData(&normalizedFftArray, gain: 1.0, bias: self.bias)

        /// Averages "range" number of frequency magnitudes before and after the chosen frequency
        /// These are the respective frequency bins (i.e., magnitudes) that will be compared to determine a Doppler Shift
        let range = 10
        var currentAverages: [Float] = [0.0, 0.0]
        vDSP_meanv(&normalizedFftArray + (numPts - range), vDSP_Stride(1), &(currentAverages[0]), vDSP_Length(range))
        vDSP_meanv(&normalizedFftArray + (numPts + 1), vDSP_Stride(1), &(currentAverages[1]), vDSP_Length(range))

        /// Slightly delay Doppler Shift gesture recognition if frequency has changed
        /// If frequency has changed, reset all baseline thresholds and historical fft averages of past frames
        if self.isStabilizing {
            self.stabilizationCounter += 1
            if self.stabilizationCounter >= stabilizationThreshold {
                // End of stabilization period; reset necessary variables
                self.isStabilizing = false
                self.lastTenFftAverages = nil
                self.coreThresholdValues = []
                self.coreThresholdMean = 0.0
                self.coreThresholdDeviation = 0.0
                self.currentRollingFftAverage = nil
                self.rollingFftIndex = 0
                self.isCalibrating = true
                self.calibrationSampleCount = 0
                self.dopplerGesture = .calibrating
            }
            /// Skip further processing during stabilization
            return
        }
        
        /// Accumulate FFT magnitudes to compute the baseline
        if self.lastTenFftAverages == nil {
            self.currentRollingFftAverage = self.currentRollingFftAverage == nil
                ? currentAverages
                : vDSP.add(self.currentRollingFftAverage!, currentAverages)
            self.rollingFftIndex += 1

            /// Compute the baseline averages after collecting enough data
            if self.rollingFftIndex >= 30 {
                self.lastTenFftAverages = vDSP.divide(
                    Float(self.rollingFftIndex),
                    self.currentRollingFftAverage!
                )
                self.currentRollingFftAverage = nil
                self.rollingFftIndex = 0
            }

            /// Indicate calibration is in progress
            self.dopplerGesture = .calibrating
            return
        }

        /// Collect samples of ratio of current-baseline high freq magnitude and current-baseline low freq magnitude ratios
        /// Increases in current high frequency magnitudes or current low frequency magnitudes relative to these samples may suggest "towards", "away" Doppler shift motions
        if self.isCalibrating {
            let ratioOfRatios = (currentAverages[1] / self.lastTenFftAverages![1]) /
                                (currentAverages[0] / self.lastTenFftAverages![0])

            /// Add the new ratio to the coreThresholdValues
            self.coreThresholdValues.append(ratioOfRatios)
            self.calibrationSampleCount += 1

            /// Calculate mean and standard deviation once enough samples are collected,
            if self.calibrationSampleCount >= calibrationSampleThreshold {
                self.coreThresholdMean = vDSP.mean(self.coreThresholdValues)
                self.coreThresholdDeviation = vDSP.standardDeviation(self.coreThresholdValues)

                /// Handle zero or small standard deviation by utilizing a fraction of the mean
                let minDeviation = 0.05 * abs(self.coreThresholdMean) // Adjust as needed
                if self.coreThresholdDeviation < minDeviation {
                    self.coreThresholdDeviation = minDeviation
                }

                /// End calibration
                self.isCalibrating = false
                self.calibrationSampleCount = 0
                self.dopplerGesture = .none // Ready to detect gestures
            } else {
                /// Continue collecting calibration data
                self.dopplerGesture = .calibrating
            }

            /// Update the rolling FFT average for baseline adjustment
            self.currentRollingFftAverage = self.currentRollingFftAverage == nil
                ? currentAverages
                : vDSP.add(self.currentRollingFftAverage!, currentAverages)
            self.rollingFftIndex += 1

            /// Update the baseline averages periodically
            if self.rollingFftIndex >= 30 {
                self.lastTenFftAverages = vDSP.divide(
                    Float(self.rollingFftIndex),
                    self.currentRollingFftAverage!
                )
                self.currentRollingFftAverage = nil
                self.rollingFftIndex = 0
            }

            /// Skip gesture detection during calibration
            return
        }

        // Calculate the ratio of ratios for current data
        let ratioOfRatios = (currentAverages[1] / self.lastTenFftAverages![1]) /
                            (currentAverages[0] / self.lastTenFftAverages![0])

        // Calculate mean and standard deviation of the threshold sample values
        self.coreThresholdMean = vDSP.mean(self.coreThresholdValues)
        self.coreThresholdDeviation = vDSP.standardDeviation(self.coreThresholdValues)

        /// Handle zero or small standard deviation
        let minDeviation = 0.05 * abs(self.coreThresholdMean)
        if self.coreThresholdDeviation < minDeviation {
            self.coreThresholdDeviation = minDeviation
        }

        // Define upper and lower thresholds for gesture detection
        let upperThreshold: Float = self.coreThresholdMean + 3 * self.coreThresholdDeviation
        let lowerThreshold: Float = self.coreThresholdMean - 3 * self.coreThresholdDeviation

        /// Detect gestures based on thresholds
        if ratioOfRatios > upperThreshold {
            self.dopplerGesture = .toward
        } else if ratioOfRatios < lowerThreshold {
            self.dopplerGesture = .away
        } else {
            self.dopplerGesture = .none
        }

        /// Only update thresholds and baseline when no gesture is detected
        /// i.e., we want to recognize noise when there is no influence on the played audio
        if self.dopplerGesture == .none {
            /// Add the new ratio to the rolling threshold values
            self.coreThresholdValues.append(ratioOfRatios)
            if self.coreThresholdValues.count > thresholdWindowSize {
                // Maintain the window size by removing the oldest value
                self.coreThresholdValues.removeFirst()
            }

            /// Update the rolling FFT average
            self.currentRollingFftAverage = self.currentRollingFftAverage == nil
                ? currentAverages
                : vDSP.add(self.currentRollingFftAverage!, currentAverages)
            self.rollingFftIndex += 1

            /// Update the baseline averages periodically
            if self.rollingFftIndex >= 30 {
                self.lastTenFftAverages = vDSP.divide(
                    Float(self.rollingFftIndex),
                    self.currentRollingFftAverage!
                )
                self.currentRollingFftAverage = nil
                self.rollingFftIndex = 0
            }
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
