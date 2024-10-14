//
//  AudioModel.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/2/24.
//

import Foundation

/// Holds
struct FrequencyMagnitude {
    let frequency: Float
    let magnitude: Float
}

class AudioModel {
    
    var timeSamples: [Float]
    var fftSamples: [Float]
    var volumeModuleB: Float = 0.3 // user setable volume
    
    var frequencyModuleB: Float = 0.0 { // frequency in Hz (changeable by user)
        didSet{
            if let manager = self.audioManager {
                // if using swift for generating the sine wave: when changed, we need to update our increment
                phaseIncrementModuleB = Float(2*Double.pi*Double(frequencyModuleB) / manager.samplingRate)
            }
        }
    }
    
    lazy var twoLargestFreqs: [FrequencyMagnitude] = [
        FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity),
        FrequencyMagnitude(frequency: -1.0, magnitude: -Float.infinity)
    ]
    
    private var AUDIO_SAMPLE_BUFFER_SIZE: Int
    
    private var phaseModuleB: Float = 0.0
    private var phaseIncrementModuleB: Float = 0.0
    private var sineWaveRepeatMax:Float = Float(2*Double.pi)
    
    private lazy var audioManager: Novocaine? = {
        return Novocaine.audioManager()
    }()
    
    private lazy var fftHelper: FFTHelper? = {
        return FFTHelper.init(fftSize: Int32(AUDIO_SAMPLE_BUFFER_SIZE))
    }()
    
    
    private lazy var inputBuffer: CircularBuffer? = {
        return CircularBuffer.init(numChannels: Int64(self.audioManager!.numInputChannels),
                                   andBufferSize: Int64(AUDIO_SAMPLE_BUFFER_SIZE))
    }()
            
    init(buffer_size: Int) {
        self.AUDIO_SAMPLE_BUFFER_SIZE = buffer_size
        timeSamples = Array.init(repeating: 0.0, count: self.AUDIO_SAMPLE_BUFFER_SIZE)
        fftSamples = Array.init(repeating: 0.0, count: self.AUDIO_SAMPLE_BUFFER_SIZE / 2)
    }
    
    func play(){
        if let manager = self.audioManager{
            manager.play()
        }
    }
    
    func stop() {
        if let manager = self.audioManager{
            manager.pause()
            manager.inputBlock = nil
            manager.outputBlock = nil
        }
        
        if let buffer = self.inputBuffer {
            buffer.clear() // just makes zeros
        }
        
        inputBuffer = nil
        fftHelper = nil
    }
    
    // public function for starting processing of microphone data
    func startMicrophoneProcessingModuleA(withFps: Double) {
        // setup the microphone to copy to circualr buffer
        if let manager = self.audioManager {
            manager.inputBlock = self.handleMicrophone
            
            // Repeat this fps times per second using the timer class
            // Every time this is called, we update the arrays "timeSamples" and "fftSamples"
            Timer.scheduledTimer(withTimeInterval: 1.0 / withFps, repeats: true) { _ in
                self.runEveryIntervalModuleA()
            }
        }
    }
    
    // public function for starting processing of audio input and output
    func startAudioIoProcessingModuleB(withFps:Double){
        // setup the microphone to copy to circualr buffer
        if let manager = self.audioManager {
            manager.inputBlock = self.handleMicrophone
            manager.outputBlock = self.handleSpeakerQueryWithSinusoid
            
            // repeat this fps times per second using the timer class
            //   every time this is called, we update the arrays "timeSamples" and "fftSamples"
            Timer.scheduledTimer(withTimeInterval: 1.0/withFps, repeats: true) { _ in
                self.runEveryIntervalModuleB()
            }
        }
    }
    
    private func handleMicrophone (data: Optional<UnsafeMutablePointer<Float>>, numFrames: UInt32, numChannels: UInt32) {
        // copy samples from the microphone into circular buffer
        self.inputBuffer?.addNewFloatData(data, withNumSamples: Int64(numFrames))
    }
    
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
                }else if chan==2{
                    let len = frame*chan
                    while i<len{
                        arrayData[i] = sin(phaseModuleB)
                        arrayData[i+1] = arrayData[i]
                        phaseModuleB += phaseIncrementModuleB
                        if (phaseModuleB >= sineWaveRepeatMax) { phaseModuleB -= sineWaveRepeatMax }
                        i+=2
                    }
                }
                // adjust volume of audio file output
                vDSP_vsmul(arrayData, 1, &(self.volumeModuleB), arrayData, 1, vDSP_Length(numFrames*numChannels))
            }
        }
    
    private func runEveryIntervalModuleA(){
        if self.inputBuffer != nil {
            // copy time data to swift array
            self.inputBuffer!.fetchFreshData(&self.timeSamples, // copied into this array
                                             withNumSamples: Int64(self.AUDIO_SAMPLE_BUFFER_SIZE))
            
            // now take FFT
            self.fftHelper!.performForwardFFT(withData: &self.timeSamples,
                                         andCopydBMagnitudeToBuffer: &self.fftSamples) // fft result is copied into fftData array
            
            // at this point, we have saved the data to the arrays:
            //   timeData: the raw audio samples
            //   fftData:  the FFT of those same samples
            // the user can now use these variables however they like
            
            let peakFreqs: [FrequencyMagnitude] = self.findTwoLargestFreqs(freqDist: 50)
            
            if peakFreqs[0].magnitude > 0 {
                self.twoLargestFreqs[0] = peakFreqs[0]
            }
            
            if peakFreqs[1].magnitude > 0 {
                self.twoLargestFreqs[1] = peakFreqs[1]
            }
        }
    }
    
    private func runEveryIntervalModuleB(){
        if self.inputBuffer != nil {
            // copy time data to swift array
            self.inputBuffer!.fetchFreshData(&self.timeSamples, // copied into this array
                                             withNumSamples: Int64(self.AUDIO_SAMPLE_BUFFER_SIZE))
            
            // now take FFT
            self.fftHelper!.performForwardFFT(withData: &self.timeSamples,
                                         andCopydBMagnitudeToBuffer: &self.fftSamples) // fft result is copied into fftData array
        }
    }
    
    /// Utilizes peak finding and interpolation to retrieve frequencies of the two loudest tones at least 'freqDist' (e.g., 50 Hz) apart
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
}
