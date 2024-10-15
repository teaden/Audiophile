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
    var frequencyModuleB: Float = 17500.0 { /// Frequency in Hz (changeable by user via ModuleBViewController)
        didSet{
            if let manager = self.audioManager {
                /// If using swift for generating the sine wave: when changed, we need to update our increment
                phaseIncrementModuleB = Float(2*Double.pi*Double(frequencyModuleB) / manager.samplingRate)
            }
        }
    }
    
    var volumeModuleB: Float = 0.5              /// Users can set volume of sine wave played at frequencyModuleB
    var zoomedFftMidIndexDb: Float = 0.0        /// Magnitude of sine wave played at frequencyModuleB
    var zoomedFftSubArray: [Float]              /// Subarray of fftSamples array ultimately centered at frequencyModuleB
    var dopplerGesture: DopplerGesture = .none  /// Indicates if hand moving toward, moving away from, or not moving relative to played sine wave
    
    private var phaseModuleB: Float = 0.0                       /// Phase of sine wave played at frequencyModuleB
    private var phaseIncrementModuleB: Float = 0.0              /// Phase increment of sine wave played at frequencyModuleB
    private var sineWaveRepeatMax:Float = Float(2*Double.pi)    /// Helps prevent overflow after numerous phase incremenets to frequencyModuleB sine wave
    
    /// Used for recording the last ten frequencies and volumes associated with played sine wave
    /// Helps ensure stability when recognizing doppler shifts (i.e., no doppler shift gestures recognized when chaning frequencyMouleB or volumeModuleB)
    private var rollingIndex: Int = 0
    private var lastTenFrequencies: [Float] = Array.init(repeating: Float.random(in: 0.0..<1.0), count: 10)
    private var lastTenVolumes: [Float] = Array.init(repeating: Float.random(in: 0.0..<1.0), count: 10)
    
    
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
    func startAudioIoProcessingModuleB(withFps:Double) {
        
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
                vDSP_vsmul(arrayData, 1, &(self.volumeModuleB), arrayData, 1, vDSP_Length(numFrames*numChannels))
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
            
            self.lastTenVolumes[self.rollingIndex] = self.volumeModuleB
            self.lastTenFrequencies[self.rollingIndex] = self.frequencyModuleB
            
            self.trackDopplerShift()
            
            self.rollingIndex = (self.rollingIndex + 1) % 10
            print(self.rollingIndex)
        }
    }
    
    /// Ensures chosen sine wave frequency for Module B remains as the center point of the FFT graph to better see Doppler shift gestures
    private func trackDopplerShift() {
        /// Simply allow program to fail if this function is utilized without audio manager instantiated for pulling sampling rate
        guard let samplingRate = self.audioManager?.samplingRate else {
            fatalError("Audio manager not initialized for pulling sampling rate to interpolate max")
        }
        
        let numPts = 100
        
        let midIndex: Int = Int(Double(self.frequencyModuleB) * Double(AudioConstants.AUDIO_BUFFER_SIZE) / samplingRate) + 1
        self.zoomedFftSubArray = Array(self.fftSamples[(midIndex - numPts)...(midIndex + numPts)])
        self.zoomedFftMidIndexDb = self.fftSamples[midIndex]
        
        let stride = vDSP_Stride(1)
        let n = vDSP_Length(numPts)

        var lowerFreqMaxMag: Float = .nan
        var upperFreqMaxMag: Float = .nan

        vDSP_maxv(&self.zoomedFftSubArray, stride, &lowerFreqMaxMag, n)
        vDSP_maxv(&self.zoomedFftSubArray + (numPts + 1), stride, &upperFreqMaxMag, n)

        if lowerFreqMaxMag >= (0.85 * self.zoomedFftMidIndexDb) && lowerFreqMaxMag > upperFreqMaxMag {
            self.dopplerGesture = .away
        } else if upperFreqMaxMag >= (0.85 * self.zoomedFftMidIndexDb) && upperFreqMaxMag > lowerFreqMaxMag {
            self.dopplerGesture = .toward
        } else {
            self.dopplerGesture = .none
        }
    }
}
