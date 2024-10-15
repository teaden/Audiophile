//
//  ModuleBViewController.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/14/24.
//

import UIKit

// For Module B: Handles the display of zoomed FFT graph based on chosen sine wave frequency and Doppler Shift gesture recognition
class ModuleBViewController: UIViewController {
    
    @IBOutlet weak var userView: UIView!
    @IBOutlet weak var freqLabel: UILabel!
    @IBOutlet weak var dbLabel: UILabel!
    @IBOutlet weak var volLabel: UILabel!
    @IBOutlet weak var dopplerGestureLabel: UILabel!
    
    /// Setup audio model
    let audio = AudioModel(buffer_size: AudioConstants.AUDIO_BUFFER_SIZE)
    
    lazy var graph:MetalGraph? = {
        return MetalGraph(userView: self.userView)
    }()
    
    /// For periodically handling graph data updates and Doppler Shift gesture recognition updates
    var timer: Timer? = nil
    
    
    /// Slider step size when changing frequencies
    private let freqStep: Float = 50
    
    /// Action for changing frequency via slider
    @IBAction func changeFrequency(_ sender: UISlider) {
        sender.setValue(round(sender.value / freqStep) * freqStep, animated: false)
        self.audio.frequencyModuleB = sender.value
        freqLabel.text = "Frequency: \(sender.value)"
    }
    
    /// Action for changing volume via slider
    @IBAction func changeVolume(_ sender: UISlider) {
        self.audio.volumeModuleB = sender.value
        volLabel.text = "Volume: \(sender.value)"
    }
    
    /// Sets up time-domain and zoomed FFT graphs and begins processing audio
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if let graph = self.graph{
            graph.setBackgroundColor(r: 0, g: 0, b: 0, a: 1)
            
            graph.addGraph(withName: "fftZoomed",
                            shouldNormalizeForFFT: true,
                            numPointsInGraph: 201)
            
            graph.addGraph(withName: "time",
                numPointsInGraph: AudioConstants.AUDIO_BUFFER_SIZE)
            
            graph.makeGrids() /// Add grids to graph
        }
        
        /// Start up the audio model here, querying microphone and playing sine wave
        audio.startAudioIoProcessingModuleB(withFps: 20)
        audio.play()
        
        /// Run the loop for updating the graph, dB label, and Doppler Shift gesture recognition label peridocially
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.updateGraphAndLabels()
        }
    }
    
    /// Pauses audio processing and deallocates graphs when navigating away from ViewController
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        graph?.teardown()
        graph = nil
        audio.stop()
    }
    
    /// Used for periodically updating time-domain graph, zoomed FFT graph,, dB label, and Doppler Shift gesture recognition label
    func updateGraphAndLabels(){
        
        if let graph = self.graph {
            
            // Show the zoomed FFT
            graph.updateGraph(
                data: self.audio.zoomedFftSubArray,
                forKey: "fftZoomed"
            )
            
            graph.updateGraph(
                data: self.audio.timeSamples,
                forKey: "time"
            )
            
            self.dbLabel.text = "db: \(self.audio.zoomedFftMidIndexDb)"
            self.dopplerGestureLabel.text = self.audio.dopplerGesture.rawValue
        }
        
    }
}
